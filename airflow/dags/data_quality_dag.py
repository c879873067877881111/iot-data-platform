"""
Data Quality DAG（資料品質檢查）
================================
每小時跑 6 項資料品質檢查，把結果寫進 data_quality_log，便於追蹤感測器健康度。

- 排程    ：每小時整點執行（@hourly）
- 設計理念：與 etl_pipeline 分離 —— ETL 只負責清洗，這支 DAG 負責「監控品質」
- 結果用途：
  - 短期：dashboard 顯示哪些感測器在掉資料 / 出異常值
  - 長期：累積品質歷史，方便找出常壞的設備
- 為什麼配置驅動：CHECKS 是個 list of dict，新增檢查只要加一筆，不用改邏輯
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.operators.python import PythonOperator

from core.db import CONN_ID

default_args = {
    "owner": "iot-platform",
    "retries": 1,                         # 只重試 1 次，這是監控 DAG
    "retry_delay": timedelta(minutes=5),
}

# 品質檢查清單：每筆指定「檢查名稱、說明、SQL（回傳一個數字）、警戒閾值」
# 規則：SELECT 出的數字 <= threshold 為 PASS，否則 FAIL
CHECKS = [
    {
        # 斷線：感測器送 NULL 應該是少數，太多代表大規模斷線
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
        # 接線錯誤：功率不可能為負，出現就是硬體問題
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
        # 電壓異常：台灣家用單相電壓約 110V、工業 220V，180~260V 是合理上下界
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
        # 時鐘漂移：感測器時鐘跑到未來，代表時間同步沒做好
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
        # 重複率：COUNT(*) - COUNT(DISTINCT key) 就是「重複了多少筆」
        # 過高代表網路重送嚴重，或 watermark 邏輯沒有正確阻擋
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
        # Ingestion gap：應該活著的設備（is_active=TRUE）超過 10 分鐘沒資料 → 可能掛了
        # NOT EXISTS 比 LEFT JOIN ... IS NULL 在大表上更快
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
    {
        # Dim sync：fact 表有 device_id 在 dim_devices view 找不到 → seed 跟 ingest path 走偏
        # fact 沒 FK（IoT 高頻寫入 anti-pattern），由這條 check 在資料層補位
        "check_type": "DIM_SYNC",
        "description": "Devices in fact_energy_readings (last 1 day) missing from dim_devices",
        "sql": """
            SELECT COUNT(DISTINCT f.device_id)
            FROM fact_energy_readings f
            WHERE f.reading_time > NOW() - INTERVAL '1 day'
              AND NOT EXISTS (
                  SELECT 1 FROM dim_devices d
                  WHERE d.device_id = f.device_id
              )
        """,
        "threshold": 0,
    },
]


def run_quality_checks(**context):
    """逐項跑 SQL，把結果（含 PASS/FAIL）寫進 data_quality_log。

    刻意不在這裡發告警 —— 通知系統（Slack / Email）由外部訂閱 data_quality_log 處理，
    保持 DAG 單一職責：產生資料、不負責通知。
    """
    hook = PostgresHook(postgres_conn_id=CONN_ID)

    for check in CHECKS:
        # SQL 一定要回傳單一數字（COUNT），不然 [0] 會 index out of range
        result = hook.get_first(check["sql"])[0]
        status = "PASS" if result <= check["threshold"] else "FAIL"

        # 每次檢查都寫一筆紀錄，累積歷史趨勢（即使 PASS 也要寫，才看得到時間序列）
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
    schedule="@hourly",              # 每小時整點跑一次
    start_date=datetime(2026, 1, 1),
    catchup=False,                   # 不補跑歷史排程
    tags=["quality", "iot"],
) as dag:

    # 單一 task：跑完 6 項檢查
    PythonOperator(
        task_id="run_quality_checks",
        python_callable=run_quality_checks,
    )
