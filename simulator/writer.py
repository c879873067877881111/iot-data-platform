"""PostgreSQL writer for device readings."""

import logging
from typing import List

import psycopg2
from psycopg2.extras import execute_values

from models import DeviceReading

logger = logging.getLogger(__name__)

INSERT_SQL = """
INSERT INTO raw_device_readings
    (site_id, device_id, collected_at, voltage_avg, current_avg,
     active_power, reactive_power, power_factor, frequency,
     energy_kwh, demand_kw, quality_flag)
VALUES %s
"""


class PgWriter:
    def __init__(self, dsn: dict):
        self._dsn = dsn
        self._conn = None

    def _connect(self):
        if self._conn is None or self._conn.closed:
            self._conn = psycopg2.connect(**self._dsn)
            self._conn.autocommit = True
            logger.info("Connected to PostgreSQL")

    def write(self, readings: List[DeviceReading]) -> int:
        if not readings:
            return 0
        self._connect()
        rows = [
            (r.site_id, r.device_id, r.collected_at,
             r.voltage_avg, r.current_avg, r.active_power,
             r.reactive_power, r.power_factor, r.frequency,
             r.energy_kwh, r.demand_kw, r.quality_flag)
            for r in readings
        ]
        with self._conn.cursor() as cur:
            execute_values(cur, INSERT_SQL, rows)
        logger.info("Wrote %d readings", len(rows))
        return len(rows)

    def close(self):
        if self._conn and not self._conn.closed:
            self._conn.close()
