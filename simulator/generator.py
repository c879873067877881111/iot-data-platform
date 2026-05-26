"""
IoT Power Meter Simulator (Gateway 角色)
========================================
模擬「gateway 把設備 modbus 讀值翻成 MQTT 上拋」這一層 —— 不是模擬「設備自身就有 MQTT 能力」。

對應現實：工業現場的 PLC / smart meter 多半只講 modbus / RS-485，沒有 MQTT stack；
需要一個 gateway（本機跑的 collector 程式）抓 register、組 payload、publish 到 broker。
這支 simulator 對應的就是 gateway 角色 —— 內部生成讀值（取代 modbus 抓 register 那段）
後 publish 成 MQTT topic，讓下游能練習真實 IoT 部署的資料流。

模擬參數：多場站 / 多設備、24 小時負載曲線、高斯雜訊、異常注入，方便下游 ETL 練清洗。

Usage:
    python generator.py                  # 連續模式：每分鐘 publish 一輪 MQTT
    python generator.py --backfill 7     # 先補 7 天歷史資料（直寫 DB），完再進連續模式

為什麼 backfill 走 DB 而不是 MQTT：
    Broker 是「即時通道」，灌歷史時間戳語意不對，且大批量容易塞爆 buffer。
    歷史回補是離線批次工作，直接寫 staging table 比較乾淨。

為什麼設定全部寫在這個檔頂部、不繞 yaml / 不留 default：
    Simulator 是 single deployment（demo 跑在 docker-compose 內），沒有 dev/staging/prod
    切換需求。所有設定全是 module 常數，缺 env 就 KeyError —— 不留 fallback
    避免「default 蓋掉真實設定」的隱性 bug。
"""

import argparse
import copy
import logging
import math
import os
import random
import signal
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from models import DeviceReading, DeviceSpec
from mqtt_publisher import MqttPublisher
from writer import PgWriter

# MQTT — docker-compose 透過 .env 傳進來；缺一個直接 KeyError，不留 default。
MQTT_HOST = os.environ["MQTT_HOST"]
MQTT_PORT = int(os.environ["MQTT_PORT"])
MQTT_USERNAME = os.environ["MQTT_USERNAME"]
MQTT_PASSWORD = os.environ["MQTT_PASSWORD"]

# DB — 僅 backfill 模式才用；缺也直接 KeyError，避免假裝能跑。
DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ["DB_PORT"])
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]

# 模擬器產生參數
INTERVAL_SECONDS = 60       # 連續模式每輪間隔
NOISE_PCT = 0.03            # 高斯雜訊比例（standard deviation）
ANOMALY_PROBABILITY = 0.005 # 每筆讀值出現異常的機率
DUPLICATE_PROBABILITY = 0.01  # 模擬 MQTT 重送 / DB 重複寫入

# 時間戳一律帶 Asia/Taipei，下游 TIMESTAMPTZ 自動轉 UTC 存
TWN_TZ = ZoneInfo("Asia/Taipei")

# 24 小時負載曲線（per site_type）：rated_power × profile[hour] = 該小時實際功率
PROFILES = {
    "factory": [
        0.60, 0.60, 0.60, 0.55, 0.55, 0.60,   # 00-05
        0.70, 0.85, 0.95, 1.00, 1.00, 0.95,   # 06-11
        0.90, 0.95, 1.00, 1.00, 0.95, 0.90,   # 12-17
        0.85, 0.80, 0.75, 0.70, 0.65, 0.60,   # 18-23
    ],
    "office": [
        0.10, 0.10, 0.10, 0.10, 0.10, 0.10,
        0.15, 0.30, 0.70, 0.90, 0.95, 1.00,
        0.85, 0.95, 1.00, 0.95, 0.90, 0.70,
        0.40, 0.20, 0.15, 0.10, 0.10, 0.10,
    ],
    "warehouse": [
        0.15, 0.15, 0.15, 0.15, 0.15, 0.15,
        0.20, 0.40, 0.60, 0.70, 0.75, 0.80,
        0.70, 0.75, 0.80, 0.75, 0.70, 0.50,
        0.30, 0.20, 0.15, 0.15, 0.15, 0.15,
    ],
}

# 設備清單：(device_id, site_id, site_type, rated_power_kw)
DEVICES = [
    ("DEV_TPE01_MAIN", "SITE_TPE_01", "factory",   2000),
    ("DEV_TPE01_L1",   "SITE_TPE_01", "factory",    800),
    ("DEV_TPE01_L2",   "SITE_TPE_01", "factory",    800),
    ("DEV_TPE01_AC",   "SITE_TPE_01", "factory",    400),
    ("DEV_TPE02_MAIN", "SITE_TPE_02", "office",     500),
    ("DEV_TPE02_FL3",  "SITE_TPE_02", "office",     200),
    ("DEV_TPE02_SRV",  "SITE_TPE_02", "office",     150),
    ("DEV_HSC01_MAIN", "SITE_HSC_01", "factory",   5000),
    ("DEV_HSC01_FAB",  "SITE_HSC_01", "factory",   2500),
    ("DEV_HSC01_CHL",  "SITE_HSC_01", "factory",   1500),
    ("DEV_TXG01_MAIN", "SITE_TXG_01", "factory",   3000),
    ("DEV_TXG01_CNC",  "SITE_TXG_01", "factory",   1800),
    ("DEV_KHH01_MAIN", "SITE_KHH_01", "warehouse", 1000),
    ("DEV_KHH02_MAIN", "SITE_KHH_02", "factory",   4000),
    ("DEV_KHH02_SMT",  "SITE_KHH_02", "factory",   2000),
]


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def get_load_factor(site_type: str, hour: int) -> float:
    profile = PROFILES.get(site_type, PROFILES["factory"])
    return profile[hour % len(profile)]


def generate_reading(spec: DeviceSpec, ts: datetime) -> DeviceReading:
    hour = ts.hour
    minute_frac = ts.minute / 60.0
    load = get_load_factor(spec.site_type, hour)
    next_load = get_load_factor(spec.site_type, (hour + 1) % 24)
    load = load + (next_load - load) * minute_frac

    noise = random.gauss(0, NOISE_PCT)
    load = max(0.05, load + noise)

    is_anomaly = random.random() < ANOMALY_PROBABILITY
    if is_anomaly:
        load *= random.choice([1.5, 0.3, 2.0])

    active_power = spec.rated_power_kw * load
    voltage = 220.0 + random.gauss(0, 2.0)
    if is_anomaly:
        voltage += random.choice([-20, 30])

    power_factor = min(1.0, max(0.5, 0.92 + random.gauss(0, 0.02)))
    apparent_power = active_power / power_factor if power_factor > 0 else active_power
    reactive_power = math.sqrt(max(0, apparent_power**2 - active_power**2))
    current = (active_power * 1000) / (voltage * 1.732) if voltage > 0 else 0
    frequency = 60.0 + random.gauss(0, 0.05)
    energy_delta = active_power * (1 / 60)  # 1-minute interval → kWh
    spec.energy_accumulator += energy_delta
    demand_kw = active_power * (1.0 + random.gauss(0, 0.02))

    quality_flag = "ANOMALY" if is_anomaly else "RAW"

    reading = DeviceReading(
        site_id=spec.site_id,
        device_id=spec.device_id,
        collected_at=ts,
        voltage_avg=round(voltage, 2),
        current_avg=round(current, 3),
        active_power=round(active_power, 2),
        reactive_power=round(reactive_power, 2),
        power_factor=round(power_factor, 4),
        frequency=round(frequency, 2),
        energy_kwh=round(spec.energy_accumulator, 2),
        demand_kw=round(demand_kw, 2),
        quality_flag=quality_flag,
    )

    # Inject dirty data (~2% chance per reading)
    if random.random() < 0.008:
        # NULL fields — sensor dropout
        reading.active_power = None
        reading.reactive_power = None
        reading.quality_flag = "RAW"
    elif random.random() < 0.006:
        # Negative power — sensor wiring error
        reading.active_power = -abs(reading.active_power)
        reading.quality_flag = "RAW"
    elif random.random() < 0.005:
        # Future timestamp — clock drift
        reading.collected_at = ts + timedelta(hours=random.randint(1, 3))
        reading.quality_flag = "RAW"

    return reading


def build_specs() -> list[DeviceSpec]:
    return [
        DeviceSpec(dev_id, site_id, stype, rated)
        for dev_id, site_id, stype, rated in DEVICES
    ]


def backfill(writer: PgWriter, specs: list, days: int):
    """歷史補資料直寫 DB —— 不經過 MQTT broker（broker 不適合回放歷史時間戳）。"""
    now = datetime.now(TWN_TZ).replace(second=0, microsecond=0)
    start = now - timedelta(days=days)
    ts = start
    batch = []
    total = 0
    while ts < now:
        for spec in specs:
            batch.append(generate_reading(spec, ts))
            # ~1% duplicate：模擬 broker QoS 1 重送 — copy 上一筆並微擾 voltage。
            # 不能再 call generate_reading() 一次，否則 spec.energy_accumulator 會多加，
            # 讓電表累計值 silently drift（baseline 抬升，下游 LAG delta 看不出來）。
            if random.random() < DUPLICATE_PROBABILITY:
                dup = copy.copy(batch[-1])
                dup.voltage_avg = round(dup.voltage_avg + random.gauss(0, 0.5), 2)
                batch.append(dup)
        if len(batch) >= 500:
            total += writer.write(batch)
            batch.clear()
        ts += timedelta(minutes=1)
    if batch:
        total += writer.write(batch)
    logger.info("Backfill complete: %d readings over %d days", total, days)


def run_continuous(publisher: MqttPublisher, specs: list):
    """連續模式：每 INTERVAL_SECONDS 一輪，每個設備 publish 一筆 MQTT。

    Topic: iot/sites/{site_id}/devices/{device_id}/telemetry
    下游可用 wildcard 訂閱：iot/sites/+/devices/+/telemetry
    """
    running = True

    def _stop(sig, frame):
        nonlocal running
        running = False
        logger.info("Shutting down...")

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    logger.info("Continuous mode (MQTT): %d devices, interval=%ds",
                len(specs), INTERVAL_SECONDS)
    while running:
        ts = datetime.now(TWN_TZ).replace(second=0, microsecond=0)
        readings = []
        for spec in specs:
            readings.append(generate_reading(spec, ts))
            # 1% 同設備、同時間戳的重複事件，模擬網路重送 — copy 上一筆並微擾 voltage。
            # 不能再 call generate_reading() 一次，否則 energy_accumulator 會多加（drift bug）。
            if random.random() < DUPLICATE_PROBABILITY:
                dup = copy.copy(readings[-1])
                dup.voltage_avg = round(dup.voltage_avg + random.gauss(0, 0.5), 2)
                readings.append(dup)
        acked = publisher.publish_many(readings)
        if acked != len(readings):
            logger.warning(
                "Publish loss: %d/%d acked @ %s",
                acked, len(readings), ts.isoformat(),
            )
        else:
            logger.info("Published %d readings @ %s", acked, ts.isoformat())
        time.sleep(INTERVAL_SECONDS)


def main():
    parser = argparse.ArgumentParser(description="IoT Power Meter Simulator")
    parser.add_argument("--backfill", type=int, default=0,
                        help="先補 N 天歷史資料（直寫 DB），完再進連續模式")
    args = parser.parse_args()

    specs = build_specs()

    # Backfill 先跑（直寫 DB），跑完再進連續模式 publish MQTT
    if args.backfill > 0:
        dsn = {
            "host": DB_HOST, "port": DB_PORT, "dbname": DB_NAME,
            "user": DB_USER, "password": DB_PASSWORD,
        }
        writer = PgWriter(dsn)
        try:
            logger.info("Backfilling %d days via DB writer...", args.backfill)
            backfill(writer, specs, args.backfill)
        finally:
            writer.close()

    publisher = MqttPublisher(
        host=MQTT_HOST, port=MQTT_PORT,
        username=MQTT_USERNAME, password=MQTT_PASSWORD,
    )
    publisher.connect()
    try:
        run_continuous(publisher, specs)
    finally:
        publisher.close()


if __name__ == "__main__":
    main()
