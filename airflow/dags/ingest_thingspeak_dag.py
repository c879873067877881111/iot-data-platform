"""
ThingSpeak Ingestion DAG（真實 IoT 資料採集）
=============================================
從 ThingSpeak 公開頻道抓取真實 PZEM-004T 電力感測器資料，
寫進 raw_device_readings 後，由 etl_pipeline DAG 接手清洗。

- 排程    ：每 5 分鐘執行一次（cron: */5 * * * *）
- 資料源  ：ThingSpeak Channel 972755 — ESP Energy Monitor (PZEM-004T)
- 去重策略：用 MAX(collected_at) 當 watermark，只寫比這個時間新的資料
- 失敗重試：失敗自動重試 2 次（網路抖動、ThingSpeak 偶爾不穩）

不在這層做資料清洗：髒資料（NULL、負值、未來時間）交給 etl_pipeline 統一處理，
這層的責任只有「忠實地把外部資料搬進來」。
"""

import logging
import math
from datetime import datetime, timedelta, timezone

import requests
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook

from core.db import CONN_ID

logger = logging.getLogger(__name__)

default_args = {
    "owner": "iot-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),   # 短 retry，API 通常很快恢復
}

# ThingSpeak 頻道 → 對應到我們的 (site_id, device_id) 與欄位 mapping
# 多頻道時直接加 dict 到 list 即可，下方 fetch_and_store 會自動迴圈處理
CHANNELS = [
    {
        "channel_id": 972755,
        "site_id": "SITE_EXT_01",
        "device_id": "DEV_EXT_PZEM",
        # ThingSpeak 的 field1~field8 是通用名稱，這裡對應到我們的欄位語意
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


def safe_float(val):
    """把 ThingSpeak 回傳的字串安全轉成 float；NaN/Inf/None 都回 None。
    這樣髒值會以 NULL 進 raw 表，後續由 mark_rejected.sql 標 REJECTED_NULL。
    """
    if val is None:
        return None
    try:
        v = float(val)
        return None if math.isnan(v) or math.isinf(v) else v
    except (ValueError, TypeError):
        return None


def to_utc_aware(ts_str):
    """把 ISO 時間字串轉成 tz-aware UTC datetime。
    Postgres 端 schema 是 TIMESTAMPTZ，會自動處理時區轉換 — 寫入要帶 tzinfo。
    """
    dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    return dt.astimezone(timezone.utc)


def fetch_and_store(**context):
    """主流程：對每個頻道 → 抓取最新 10 筆 → 去掉已寫過的 → 批次寫入 raw 表。"""
    hook = PostgresHook(postgres_conn_id=CONN_ID)

    for ch in CHANNELS:
        # 取最近 10 筆（足以覆蓋 5 分鐘排程 + 一點延遲緩衝）
        url = THINGSPEAK_API.format(channel_id=ch["channel_id"])
        resp = requests.get(url, params={"results": 10}, timeout=30)
        resp.raise_for_status()
        data = resp.json()

        feeds = data.get("feeds", [])
        if not feeds:
            logger.info("Channel %s: no feeds returned", ch["channel_id"])
            continue

        # Watermark 去重：先查 DB 裡這個 device 已存到哪個時間點
        # 比這時間新的才寫，避免重送（也避免 ThingSpeak 回傳重複資料）
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
            collected_at = to_utc_aware(feed["created_at"])

            # 已經寫過就跳過（watermark 比對）
            if last_collected and collected_at <= last_collected:
                continue

            row = {
                "site_id": ch["site_id"],
                "device_id": ch["device_id"],
                "collected_at": collected_at,
            }
            # 把 field1~field6 依 mapping 映射到對應欄位
            for ts_field, db_col in ch["fields"].items():
                row[db_col] = safe_float(feed.get(ts_field))

            rows.append(row)

        logger.info(
            "Channel %s: fetched %d, new %d",
            ch["channel_id"],
            len(feeds),
            len(rows),
        )

        if not rows:
            continue

        # 批次寫入（一次 round-trip，比 row-by-row 快很多）
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
    schedule="*/5 * * * *",          # 每 5 分鐘拉一次（與 ThingSpeak 上傳頻率對齊）
    start_date=datetime(2026, 1, 1),
    catchup=False,                   # 不補跑歷史
    tags=["ingestion", "iot", "thingspeak"],
) as dag:

    # 只有一個 task，沒有依賴串接
    PythonOperator(
        task_id="fetch_and_store",
        python_callable=fetch_and_store,
    )
