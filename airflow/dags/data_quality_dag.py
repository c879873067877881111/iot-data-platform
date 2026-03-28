"""
Data Quality DAG
================
Runs basic quality checks on IoT data and logs results.

Schedule: hourly
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.operators.python import PythonOperator

from core.db import CONN_ID

default_args = {
    "owner": "iot-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

CHECKS = [
    {
        "check_type": "NULL_POWER",
        "description": "Readings with null active_power",
        "sql": """
            SELECT COUNT(*) FROM raw_device_readings
            WHERE active_power IS NULL
              AND ingested_at > NOW() - INTERVAL '2 hours'
        """,
        "threshold": 10,
    },
    {
        "check_type": "NEGATIVE_POWER",
        "description": "Readings with negative active_power (sensor wiring error)",
        "sql": """
            SELECT COUNT(*) FROM raw_device_readings
            WHERE active_power < 0
              AND ingested_at > NOW() - INTERVAL '2 hours'
        """,
        "threshold": 10,
    },
    {
        "check_type": "VOLTAGE_RANGE",
        "description": "Readings with voltage outside 180-260V",
        "sql": """
            SELECT COUNT(*) FROM raw_device_readings
            WHERE (voltage_avg < 180 OR voltage_avg > 260)
              AND ingested_at > NOW() - INTERVAL '2 hours'
        """,
        "threshold": 5,
    },
    {
        "check_type": "FUTURE_TIMESTAMP",
        "description": "Readings with collected_at in the future (clock drift)",
        "sql": """
            SELECT COUNT(*) FROM raw_device_readings
            WHERE collected_at > NOW()
              AND ingested_at > NOW() - INTERVAL '2 hours'
        """,
        "threshold": 5,
    },
    {
        "check_type": "DUPLICATE_RATE",
        "description": "Duplicate readings per (site, device, time) in last 2 hours",
        "sql": """
            SELECT COUNT(*) - COUNT(DISTINCT (site_id, device_id, collected_at))
            FROM raw_device_readings
            WHERE ingested_at > NOW() - INTERVAL '2 hours'
        """,
        "threshold": 20,
    },
    {
        "check_type": "INGESTION_GAP",
        "description": "Devices with no data in the last 10 minutes",
        "sql": """
            SELECT COUNT(DISTINCT device_id)
            FROM dim_devices d
            WHERE d.is_active = TRUE
              AND NOT EXISTS (
                  SELECT 1 FROM raw_device_readings r
                  WHERE r.device_id = d.device_id
                    AND r.ingested_at > NOW() - INTERVAL '10 minutes'
              )
        """,
        "threshold": 3,
    },
]


def run_quality_checks(**context):
    hook = PostgresHook(postgres_conn_id=CONN_ID)

    for check in CHECKS:
        result = hook.get_first(check["sql"])[0]
        status = "PASS" if result <= check["threshold"] else "FAIL"

        hook.run(
            """
            INSERT INTO data_quality_log
                (check_type, status, metric_value, threshold_value, message)
            VALUES (%s, %s, %s, %s, %s)
            """,
            parameters=(
                check["check_type"],
                status,
                result,
                check["threshold"],
                check["description"],
            ),
        )


with DAG(
    dag_id="data_quality",
    default_args=default_args,
    description="Hourly data quality checks on IoT readings",
    schedule="@hourly",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["quality", "iot"],
) as dag:

    PythonOperator(
        task_id="run_quality_checks",
        python_callable=run_quality_checks,
    )
