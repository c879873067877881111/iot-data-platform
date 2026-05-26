"""MQTT publisher for simulated device readings.

Topic 約定：iot/sites/{site_id}/devices/{device_id}/telemetry
Payload：JSON（DeviceReading dump）
QoS：1（at-least-once，搭配 raw_device_readings 在 ETL 階段去重）

刻意不在 publisher 端做 batching —— 工業 IoT 現場的設備本來就是各自獨立發送，
這樣模擬比較貼近真實。Ingestor 端負責 buffer。

連線語意：
- `connect()` 同步阻塞到 CONNACK 收到，失敗會 raise ConnectionError（fail-fast）
- 斷線後 paho 內部自動以 1s → 60s 退避重連，不需上層介入
- `publish()` 等 PUBACK 才回，QoS 1 真的有效；超時會記錄 ERROR
"""

import json
import logging
import threading
from dataclasses import asdict

import paho.mqtt.client as mqtt

from models import DeviceReading

logger = logging.getLogger(__name__)

TOPIC_TEMPLATE = "iot/sites/{site_id}/devices/{device_id}/telemetry"

CONNECT_TIMEOUT_SEC = 10
PUBLISH_TIMEOUT_SEC = 5


def _serialize(reading: DeviceReading) -> str:
    payload = asdict(reading)
    payload["collected_at"] = reading.collected_at.isoformat()
    return json.dumps(payload, default=str)


class MqttPublisher:
    def __init__(self, host: str, port: int, client_id: str = "iot-simulator",
                 username: str | None = None, password: str | None = None):
        self._host = host
        self._port = port
        self._client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=client_id,
        )
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        # 斷線自動重連：1s → 2s → 4s → ... → 60s 上限
        self._client.reconnect_delay_set(min_delay=1, max_delay=60)
        if username:
            self._client.username_pw_set(username, password)

        # Event 把 paho 的 async CONNACK 轉成同步 wait
        self._connack = threading.Event()
        self._connack_reason = None

    def _on_connect(self, client, userdata, flags, reason_code, properties):
        # paho 在 network thread 觸發；reconnect 時也會再叫一次
        self._connack_reason = reason_code
        if reason_code == 0:
            logger.info("MQTT connected to %s:%d", self._host, self._port)
        else:
            logger.error("MQTT connect refused: %s", reason_code)
        self._connack.set()

    def _on_disconnect(self, client, userdata, flags, reason_code, properties):
        # 不主動重連 —— reconnect_delay_set 已開啟 paho 內建重連
        logger.warning("MQTT disconnected: %s — auto-reconnect armed", reason_code)

    def connect(self, timeout: float = CONNECT_TIMEOUT_SEC) -> None:
        """同步連線：阻塞到 CONNACK 收到，失敗就 raise。"""
        self._client.connect(self._host, self._port, keepalive=60)
        self._client.loop_start()
        if not self._connack.wait(timeout):
            raise ConnectionError(
                f"MQTT connect timeout after {timeout}s "
                f"to {self._host}:{self._port}"
            )
        if self._connack_reason != 0:
            raise ConnectionError(
                f"MQTT broker refused connect: {self._connack_reason}"
            )

    def publish_many(self, readings: list[DeviceReading]) -> int:
        """批次 publish：先全部 enqueue，再批次等 PUBACK，回傳 acked 筆數。

        逐筆 wait 會把 latency 累加（N 筆 × broker RTT），批次等則總時間 ≈ max(RTT)。
        對每分鐘 15 筆規模差異不大，但工業 IoT 擴大後（千筆/min）會放大成數十倍。
        """
        pending = []
        for r in readings:
            topic = TOPIC_TEMPLATE.format(
                site_id=r.site_id,
                device_id=r.device_id,
            )
            info = self._client.publish(topic, _serialize(r), qos=1)
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                logger.error("Publish enqueue failed (rc=%s) topic=%s", info.rc, topic)
                continue
            pending.append((info, topic))

        acked = 0
        for info, topic in pending:
            info.wait_for_publish(timeout=PUBLISH_TIMEOUT_SEC)
            if info.is_published():
                acked += 1
            else:
                logger.error("Publish NOT acknowledged topic=%s", topic)
        return acked

    def close(self):
        self._client.loop_stop()
        self._client.disconnect()
