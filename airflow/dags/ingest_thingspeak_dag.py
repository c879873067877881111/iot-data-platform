"""
ThingSpeak Ingestion DAG
========================
Fetches real IoT sensor data from ThingSpeak public channels
and writes to raw_device_readings for ETL processing.

Schedule: every 5 minutes
Source: Channel 972755 — ESP Energy Monitor (PZEM-004T)
"""

from datetime import datetime, timedelta

import requests
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook

from core.db import CONN_ID

default_args = {
    "owner": "iot-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
}

# ThingSpeak channel → (site_id, device_id) mapping
CHANNELS = [
    {
        "channel_id": 972755,
        "site_id": "SITE_EXT_01",
        "device_id": "DEV_EXT_PZEM",
        "fields": {
            "field1": "energy_kwh",
            "field2": "active_power",
            "field3": "voltage_avg",
            "field4": "current_avg",
            "field5": "frequency",
            "field6": "power_factor",
        },
    },
]

THINGSPEAK_API = "https://api.thingspeak.com/channels/{channel_id}/feeds.json"


def fetch_and_store(**context):
    hook = PostgresHook(postgres_conn_id=CONN_ID)

    for ch in CHANNELS:
        url = THINGSPEAK_API.format(channel_id=ch["channel_id"])
        resp = requests.get(url, params={"results": 5}, timeout=30)
        resp.raise_for_status()
        data = resp.json()

        feeds = data.get("feeds", [])
        if not feeds:
            continue

        # Get last ingested timestamp to avoid duplicates
        last_ts = hook.get_first(
            """
            SELECT MAX(collected_at) FROM raw_device_readings
            WHERE site_id = %s AND device_id = %s
            """,
            parameters=(ch["site_id"], ch["device_id"]),
        )
        last_collected = last_ts[0] if last_ts and last_ts[0] else None

        rows = []
        for feed in feeds:
            collected_at = feed["created_at"]

            # Skip already ingested readings
            if last_collected and datetime.fromisoformat(
                collected_at.replace("Z", "+00:00")
            ).replace(tzinfo=None) <= last_collected:
                continue

            row = {
                "site_id": ch["site_id"],
                "device_id": ch["device_id"],
                "collected_at": collected_at,
            }
            for ts_field, db_col in ch["fields"].items():
                val = feed.get(ts_field)
                row[db_col] = float(val) if val is not None else None

            rows.append(row)

        if not rows:
            continue

        hook.insert_rows(
            table="raw_device_readings",
            rows=[
                (
                    r["site_id"],
                    r["device_id"],
                    r["collected_at"],
                    r.get("voltage_avg"),
                    r.get("current_avg"),
                    r.get("active_power"),
                    r.get("reactive_power"),
                    r.get("power_factor"),
                    r.get("frequency"),
                    r.get("energy_kwh"),
                    r.get("demand_kw"),
                )
                for r in rows
            ],
            target_fields=[
                "site_id",
                "device_id",
                "collected_at",
                "voltage_avg",
                "current_avg",
                "active_power",
                "reactive_power",
                "power_factor",
                "frequency",
                "energy_kwh",
                "demand_kw",
            ],
        )


with DAG(
    dag_id="ingest_thingspeak",
    default_args=default_args,
    description="Fetch real IoT sensor data from ThingSpeak public channels",
    schedule="*/5 * * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["ingestion", "iot", "thingspeak"],
) as dag:

    PythonOperator(
        task_id="fetch_and_store",
        python_callable=fetch_and_store,
    )
