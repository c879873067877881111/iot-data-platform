"""
ETL Pipeline DAG
================
raw_device_readings → deduplicate → compute delta → hourly agg → daily agg

Schedule: every 10 minutes
Idempotent: all SQL uses INSERT ... ON CONFLICT DO UPDATE
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

from core.db import run_sql_file

default_args = {
    "owner": "iot-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="etl_pipeline",
    default_args=default_args,
    description="IoT readings: deduplicate → transform → aggregate",
    schedule="*/10 * * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["etl", "iot"],
) as dag:

    deduplicate = PythonOperator(
        task_id="deduplicate_raw",
        python_callable=run_sql_file,
        op_args=["deduplicate_raw.sql"],
    )

    mark_rejected = PythonOperator(
        task_id="mark_rejected",
        python_callable=run_sql_file,
        op_args=["mark_rejected.sql"],
    )

    compute_delta = PythonOperator(
        task_id="compute_energy_delta",
        python_callable=run_sql_file,
        op_args=["compute_energy_delta.sql"],
    )

    hourly = PythonOperator(
        task_id="aggregate_hourly",
        python_callable=run_sql_file,
        op_args=["aggregate_hourly.sql"],
    )

    daily = PythonOperator(
        task_id="aggregate_daily",
        python_callable=run_sql_file,
        op_args=["aggregate_daily.sql"],
    )

    deduplicate >> mark_rejected >> compute_delta >> hourly >> daily
