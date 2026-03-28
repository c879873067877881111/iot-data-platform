"""
IoT Power Meter Simulator

Generates realistic electrical readings for multiple sites/devices,
following configurable 24-hour load profiles with noise and anomalies.

Usage:
    python generator.py                  # continuous mode (default)
    python generator.py --backfill 7     # generate 7 days of historical data
"""

import argparse
import logging
import math
import os
import random
import signal
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import yaml

from models import DeviceReading, DeviceSpec
from writer import PgWriter

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# Device topology: (device_id, site_id, site_type, rated_power_kw)
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


def load_config() -> dict:
    config_path = Path(__file__).parent / "config.yaml"
    with open(config_path) as f:
        raw = f.read()
    for key, val in os.environ.items():
        raw = raw.replace(f"${{{key}}}", val)
    return yaml.safe_load(raw)


def build_dsn(cfg: dict) -> dict:
    db = cfg["database"]
    return {
        "host": db.get("host", "postgres"),
        "port": int(db.get("port", 5432)),
        "dbname": db.get("dbname", "iot_platform"),
        "user": db.get("user", "iot_user"),
        "password": db.get("password", "iot_pass"),
    }


def get_load_factor(profiles: dict, site_type: str, hour: int) -> float:
    profile = profiles.get(site_type, profiles.get("factory"))
    return profile[hour % len(profile)]


def generate_reading(
    spec: DeviceSpec,
    ts: datetime,
    profiles: dict,
    noise_pct: float,
    anomaly_prob: float,
) -> DeviceReading:
    hour = ts.hour
    minute_frac = ts.minute / 60.0
    load = get_load_factor(profiles, spec.site_type, hour)
    next_load = get_load_factor(profiles, spec.site_type, (hour + 1) % 24)
    load = load + (next_load - load) * minute_frac

    noise = random.gauss(0, noise_pct)
    load = max(0.05, load + noise)

    is_anomaly = random.random() < anomaly_prob
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


def backfill(writer: PgWriter, specs: list, profiles: dict, cfg: dict, days: int):
    noise = cfg["generation"]["noise_pct"]
    anomaly = cfg["generation"]["anomaly_probability"]
    now = datetime.now().replace(second=0, microsecond=0)
    start = now - timedelta(days=days)
    ts = start
    batch = []
    total = 0
    while ts < now:
        for spec in specs:
            reading = generate_reading(spec, ts, profiles, noise, anomaly)
            batch.append(reading)
            # ~1% duplicate — same device, same timestamp, slightly different values
            if random.random() < 0.01:
                dup = generate_reading(spec, ts, profiles, noise, anomaly)
                batch.append(dup)
        if len(batch) >= 500:
            total += writer.write(batch)
            batch.clear()
        ts += timedelta(minutes=1)
    if batch:
        total += writer.write(batch)
    logger.info("Backfill complete: %d readings over %d days", total, days)


def run_continuous(writer: PgWriter, specs: list, profiles: dict, cfg: dict):
    interval = cfg["generation"]["interval_seconds"]
    noise = cfg["generation"]["noise_pct"]
    anomaly = cfg["generation"]["anomaly_probability"]

    running = True

    def _stop(sig, frame):
        nonlocal running
        running = False
        logger.info("Shutting down...")

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    logger.info("Continuous mode: %d devices, interval=%ds", len(specs), interval)
    while running:
        ts = datetime.now().replace(second=0, microsecond=0)
        readings = []
        for spec in specs:
            reading = generate_reading(spec, ts, profiles, noise, anomaly)
            readings.append(reading)
            if random.random() < 0.01:
                readings.append(generate_reading(spec, ts, profiles, noise, anomaly))
        writer.write(readings)
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="IoT Power Meter Simulator")
    parser.add_argument("--backfill", type=int, default=0,
                        help="Generate N days of historical data before starting")
    args = parser.parse_args()

    cfg = load_config()
    dsn = build_dsn(cfg)
    profiles = cfg["profiles"]
    specs = build_specs()
    writer = PgWriter(dsn)

    try:
        if args.backfill > 0:
            logger.info("Backfilling %d days...", args.backfill)
            backfill(writer, specs, profiles, cfg, args.backfill)
        run_continuous(writer, specs, profiles, cfg)
    finally:
        writer.close()


if __name__ == "__main__":
    main()
