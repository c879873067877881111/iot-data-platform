"""
ETL Pipeline DAG（核心 ETL 流程）
================================
資料流：raw_device_readings → 去重 → 標記髒資料 → 算 delta → 小時聚合 → 日聚合

- 排程    ：每 10 分鐘執行一次（cron: */10 * * * *）
- 冪等性  ：所有 SQL 都用 INSERT ... ON CONFLICT DO UPDATE，重跑安全
- 失敗重試：每個 task 失敗會自動重試 2 次，每次間隔 2 分鐘
- 任務串接：每步 SQL 獨立成一個 task，方便在 Airflow UI 看到每階段成功/失敗

每個 SQL 檔案的細節說明請看 dags/sql/*.sql 的檔頭註解。
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

from core.db import run_sql_file

# 所有 task 共用的預設參數
default_args = {
    "owner": "iot-platform",
    "retries": 2,                          # 失敗自動重試 2 次（網路抖動、瞬間鎖表都可救回）
    "retry_delay": timedelta(minutes=2),   # 重試間隔，避免緊接著再炸一次
}

with DAG(
    dag_id="etl_pipeline",
    default_args=default_args,
    description="IoT readings: deduplicate → transform → aggregate",
    schedule="*/10 * * * *",        # 每 10 分鐘跑一次
    start_date=datetime(2026, 1, 1),
    catchup=False,                  # 不要補跑歷史排程（重啟服務時不會一次塞爆 100 個 run）
    tags=["etl", "iot"],
) as dag:

    # Step 1：去重 + 過濾髒資料，把 raw 搬進 fact_energy_readings
    deduplicate = PythonOperator(
        task_id="deduplicate_raw",
        python_callable=run_sql_file,
        op_args=["deduplicate_raw.sql"],
    )

    # Step 1b：把髒資料貼標籤並標記 processed，避免下次重掃
    mark_rejected = PythonOperator(
        task_id="mark_rejected",
        python_callable=run_sql_file,
        op_args=["mark_rejected.sql"],
    )

    # Step 2：用 LAG 算 energy_delta（這分鐘相對上分鐘多用了多少電）
    compute_delta = PythonOperator(
        task_id="compute_energy_delta",
        python_callable=run_sql_file,
        op_args=["compute_energy_delta.sql"],
    )

    # Step 3：per-minute → per-hour 聚合
    hourly = PythonOperator(
        task_id="aggregate_hourly",
        python_callable=run_sql_file,
        op_args=["aggregate_hourly.sql"],
    )

    # Step 4：per-hour → per-day 聚合
    daily = PythonOperator(
        task_id="aggregate_daily",
        python_callable=run_sql_file,
        op_args=["aggregate_daily.sql"],
    )

    # 任務依賴：必須線性執行，後面的步驟依賴前面寫進去的資料
    deduplicate >> mark_rejected >> compute_delta >> hourly >> daily
