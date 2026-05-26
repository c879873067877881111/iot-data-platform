"""
Cumulative Populate DAG（device_activity_cumulated 每日增量）
============================================================
資料流：fact_daily_energy (D-1) → device_activity_cumulated（device_id 維度的日期陣列）

- 排程    ：每日 03:00 跑一次（cron: 0 3 * * *）— 排在 etl_pipeline daily 聚合之後
- 處理範圍：只處理 D-1（昨天）資料
- 冪等性  ：SQL 用 SELECT DISTINCT + ON CONFLICT DO UPDATE，重跑同一天安全
- 失敗重試：自動重試 2 次，每次間隔 2 分鐘

cumulative table 用途：把「每個 device 哪幾天有資料 / 哪幾天 pf 偏低」壓成陣列，
查「過去 30 天活躍天數」之類的問題從掃 fact 變成讀一個 row，差兩個量級。
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
    dag_id="cumulative_populate",
    default_args=default_args,
    description="Incremental populate device_activity_cumulated from yesterday's fact_daily_energy",
    schedule="0 3 * * *",            # 每日 03:00（etl_pipeline daily 聚合 02:00 已完成 D-1 資料）
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["etl", "iot", "cumulative"],
) as dag:

    populate = PythonOperator(
        task_id="cumulative_populate",
        python_callable=run_sql_file,
        op_args=["cumulative_populate.sql"],
    )
