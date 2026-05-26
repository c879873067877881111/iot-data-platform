"""MQTT → PostgreSQL ingestor.

訂閱 iot/sites/+/devices/+/telemetry，把 telemetry 訊息 batch 寫入 raw_device_readings。
這支服務只負責「把訊息搬進 staging」，去重 / 品質檢查 / 聚合 是 Airflow ETL 的職責。

設計考量：
- Batch flush：累積 BATCH_SIZE 筆 或 FLUSH_INTERVAL 秒，先到先觸發 —— 避免低流量時資料卡在記憶體
- 失敗策略：malformed JSON 丟掉並 log，不要 crash 整支服務
- 重連：paho-mqtt reconnect_delay_set 處理斷線。QoS 1 + broker persistence 救得回 in-flight 訊息；
  但這支沒開 MQTT persistent session —— ingestor 自己斷線期間 broker 不會替它 queue 訊息。
  對 demo 可接受；production 要關掉 clean session（或 MQTT 5 SessionExpiry）才能補上斷線窗口
- DB flush 失敗 buffer 上限：超過 MAX_BUFFER_SIZE 丟最舊的 + log warning，避免 DB 長期掛 → 無聲 OOM
"""

import json
import logging
import os
import signal
import threading
import time
from datetime import datetime

import paho.mqtt.client as mqtt
import psycopg2
from psycopg2.extras import execute_values

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

TOPIC_FILTER = "iot/sites/+/devices/+/telemetry"
BATCH_SIZE = 100
FLUSH_INTERVAL = 5.0  # seconds
MAX_BUFFER_SIZE = 10000  # DB 長期掛時的上限，超過就 drop 最舊的（avoid silent OOM）

INSERT_SQL = """
INSERT INTO raw_device_readings
    (site_id, device_id, collected_at, voltage_avg, current_avg,
     active_power, reactive_power, power_factor, frequency,
     energy_kwh, demand_kw, quality_flag)
VALUES %s
"""


def build_dsn() -> dict:
    # 缺 env 直接 KeyError；不留 fallback default，避免改了 .env 密碼卻連上
    # default 密碼 DB 這種 misconfig 偷偷跑起來（對齊 CLAUDE.md 規約）
    return {
        "host": os.environ["DB_HOST"],
        "port": int(os.environ["DB_PORT"]),
        "dbname": os.environ["DB_NAME"],
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
    }


def parse_payload(raw: bytes) -> tuple | None:
    """把 MQTT payload 轉成 INSERT 用的 tuple；解析失敗回 None。
    collected_at 必須是 tz-aware ISO（如 '...+08:00' 或 '...Z'）— naive 字串會被 drop。
    """
    try:
        data = json.loads(raw)
        ts = datetime.fromisoformat(data["collected_at"])
        if ts.tzinfo is None:
            logger.warning("Drop reading with naive timestamp: %s", data["collected_at"])
            return None
        return (
            data["site_id"],
            data["device_id"],
            ts,
            data.get("voltage_avg"),
            data.get("current_avg"),
            data.get("active_power"),
            data.get("reactive_power"),
            data.get("power_factor"),
            data.get("frequency"),
            data.get("energy_kwh"),
            data.get("demand_kw"),
            data.get("quality_flag", "RAW"),
        )
    except (json.JSONDecodeError, KeyError, ValueError) as e:
        logger.warning("Drop malformed payload: %s", e)
        return None


class Ingestor:
    def __init__(self, mqtt_host: str, mqtt_port: int, dsn: dict,
                 mqtt_user: str | None = None, mqtt_password: str | None = None):
        self._dsn = dsn
        self._conn = None
        self._buffer: list[tuple] = []
        # _lock 保護 _buffer / _last_flush（短臨界區，操作快）。
        # _flush_lock 把整個 _flush() body serialize ── 兩個 thread 可同時觸發 flush
        # （network thread BATCH_SIZE 滿 + periodic thread idle 過 FLUSH_INTERVAL），
        # 但 psycopg2 conn 不可並發、_ensure_conn() 也會 race，所以 flush 動作必須串行。
        self._lock = threading.Lock()
        self._flush_lock = threading.Lock()
        self._running = True
        # monotonic 避免 wall-clock 被 ntp 倒退時 idle 算出負值
        self._last_flush = time.monotonic()

        self._client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id="mqtt-ingestor",
        )
        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message
        self._client.on_disconnect = self._on_disconnect
        # 自動重連退避：1s 起跳，最多 60s，避免 broker 重啟時雪崩
        self._client.reconnect_delay_set(min_delay=1, max_delay=60)
        if mqtt_user:
            self._client.username_pw_set(mqtt_user, mqtt_password)
        self._client.connect(mqtt_host, mqtt_port, keepalive=60)

    def _ensure_conn(self):
        if self._conn is None or self._conn.closed:
            self._conn = psycopg2.connect(**self._dsn)
            self._conn.autocommit = True
            logger.info("Connected to PostgreSQL")

    def _on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            logger.info("MQTT connected, subscribing %s", TOPIC_FILTER)
            client.subscribe(TOPIC_FILTER, qos=1)
        else:
            logger.error("MQTT connect failed: %s", reason_code)

    def _on_disconnect(self, client, userdata, flags, reason_code, properties):
        logger.warning("MQTT disconnected: %s (will auto-reconnect)", reason_code)

    def _on_message(self, client, userdata, msg):
        row = parse_payload(msg.payload)
        if row is None:
            return
        with self._lock:
            self._buffer.append(row)
            size = len(self._buffer)
        if size >= BATCH_SIZE:
            self._flush()

    def _flush(self):
        # _flush_lock：serialize flush 動作。psycopg2 conn 不可並發、_ensure_conn 也會 race。
        # 兩個 thread 同時觸發時，後到者排隊；不丟訊息（buffer swap 在 _lock 內 atomic）。
        with self._flush_lock:
            with self._lock:
                if not self._buffer:
                    self._last_flush = time.monotonic()
                    return
                rows, self._buffer = self._buffer, []
            try:
                self._ensure_conn()
                with self._conn.cursor() as cur:
                    execute_values(cur, INSERT_SQL, rows)
                logger.info("Flushed %d readings", len(rows))
            except Exception as e:
                logger.error("Flush failed: %s — putting %d rows back", e, len(rows))
                # 寫入失敗就把資料退回 buffer 前面，下次再試 —— 但守住 MAX_BUFFER_SIZE 上限，
                # 不然 DB 長期掛掉時 buffer 會無聲 OOM。超過上限就 drop 最舊的（FIFO）。
                with self._lock:
                    merged = rows + self._buffer
                    if len(merged) > MAX_BUFFER_SIZE:
                        dropped = len(merged) - MAX_BUFFER_SIZE
                        merged = merged[-MAX_BUFFER_SIZE:]
                        logger.warning(
                            "Buffer over %d, dropped %d oldest rows", MAX_BUFFER_SIZE, dropped
                        )
                    self._buffer = merged
                # 強制下次重連 — 先關掉舊連線避免 leak（broken conn 也可能未被 server 釋放）
                # self._conn 寫入受 _flush_lock 保護，不會 race。
                if self._conn is not None:
                    try:
                        self._conn.close()
                    except Exception:
                        pass
                    self._conn = None
            # 不論成功失敗都更新 last_flush，避免 periodic 連續觸發失敗的 flush
            with self._lock:
                self._last_flush = time.monotonic()

    def _periodic_flush(self):
        """背景執行緒：到 FLUSH_INTERVAL 沒到 BATCH_SIZE 也要 flush 一次。"""
        while self._running:
            time.sleep(1.0)
            # _last_flush 在 network thread (_on_message → _flush) 與此 thread 都會動 → 進 lock
            with self._lock:
                idle = time.monotonic() - self._last_flush
            if idle >= FLUSH_INTERVAL:
                self._flush()

    def run(self):
        flusher = threading.Thread(target=self._periodic_flush, daemon=True)
        flusher.start()
        self._client.loop_forever()

    def stop(self):
        logger.info("Shutting down ingestor...")
        self._running = False
        self._client.disconnect()
        self._flush()  # 把 buffer 最後清乾淨
        if self._conn and not self._conn.closed:
            self._conn.close()


def main():
    # 缺 env 直接 KeyError；broker allow_anonymous=false，沒帳密反正連不上
    mqtt_host = os.environ["MQTT_HOST"]
    mqtt_port = int(os.environ["MQTT_PORT"])
    mqtt_user = os.environ["MQTT_USERNAME"]
    mqtt_pass = os.environ["MQTT_PASSWORD"]
    ingestor = Ingestor(mqtt_host, mqtt_port, build_dsn(), mqtt_user, mqtt_pass)

    def _stop(sig, frame):
        ingestor.stop()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    logger.info("Ingestor starting: mqtt=%s:%d", mqtt_host, mqtt_port)
    ingestor.run()


if __name__ == "__main__":
    main()
