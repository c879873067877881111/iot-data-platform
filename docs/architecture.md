# Architecture

工業 IoT 製程能耗監控平台：**多源採集 → MQTT Broker → Ingestor → Airflow ETL + SPC → Star Schema → REST API**。

## 系統全貌

兩條 ingestion 路徑，在 PostgreSQL raw 層匯流：

```
          HTTP Path                              MQTT Path
                                            
┌────────────────┐                       ┌────────────────┐
│ ThingSpeak     │                       │ Simulator      │
│ PZEM-004T      │                       │ 15 devices     │
│ Channel API    │                       │ paho-mqtt 2.x  │
│ (第三方雲端)    │                        │ (publish QoS 1)│
└────────┬───────┘                       └────────┬───────┘
         │ HTTP GET /feeds.json                   │ topic:
         │                                        │  iot/sites/+/
         │                                        │  devices/+/telemetry
         │                                        ▼
         │                                ┌────────────────┐
         │                                │ Mosquitto      │
         │                                │ broker :1883   │
         │                                │ QoS 1          │
         │                                └────────┬───────┘
         │                                         │ subscribe
         │                                         ▼
         │                                ┌────────────────┐
         │                                │ mqtt-ingestor  │
         │                                │ batch 100/5s   │
         │                                │ auto-reconnect │
         │                                └────────┬───────┘
         │                                         │
         ▼                                         ▼
┌─────────────────────────────────────────────────────────────┐
│                  PostgreSQL（staging 層匯流）                 │
│       raw_device_readings（單一表，兩條 path 共寫）           │
│       TIMESTAMPTZ · PARTITION BY month                       │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│           Airflow ETL (etl_pipeline DAG, 每 10 分鐘)          │
│  ① dedup → ② mark_bad → ③ compute Δ → ④ hourly → ⑤ daily    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│   Warehouse:                                                 │
│   ├ dim_sites_scd / dim_devices_scd  (SCD2 + EXCLUDE)        │
│   ├ dim_sites / dim_devices          (view: is_current=TRUE) │
│   ├ fact_energy_readings             (per-minute, monthly)   │
│   ├ fact_hourly_energy / fact_daily_energy                   │
│   ├ device_activity_cumulated        (累積活躍日期陣列)        │
│   └ data_quality_log                                         │
└──────────────┬──────────────────────────────────┬───────────┘
               │                                  │
               ▼                                  ▼
   ┌────────────────────┐              ┌──────────────────────┐
   │ Spring Boot REST   │              │ data_quality DAG     │
   │ /sites /energy     │              │ (每小時)              │
   │ /summary           │              │ 7 項 threshold check │
   │ + Swagger UI       │              │ → data_quality_log   │
   └────────────────────┘              └──────────────────────┘
```

### 為什麼 ThingSpeak 不走 broker？

ThingSpeak 是第三方公開平台，提供 HTTP REST API。**我們只是它的下游 consumer，不能要求它 publish 到我的 Mosquitto**。所以這條路徑由 Airflow 主動 pull。

而 simulator 模擬的是 **gateway**（對應現實裡 modbus → MQTT 橋接程式，例如本機跑的 collector），代設備把讀值組成 payload publish 到 broker —— 因為真實 PLC / smart meter 多半只講 modbus / RS-485，沒 MQTT stack。所以 simulator 對外露的介面是 publish 而不是「設備自己 publish」。

## 設計亮點

- **兩條 ingestion 路徑**
  - MQTT path：模擬 gateway → broker → ingestor → staging（pub/sub 解耦，貼近真實工業 IoT 部署）
  - HTTP path：Airflow 拉 ThingSpeak Channel API → staging（外部第三方平台標準作法）
- **Mosquitto auth-hardened**：`allow_anonymous=false` + 三個分權帳號（simulator 只能 publish / ingestor 只能 subscribe / healthcheck 獨立 topic）+ ACL topic 隔離，最小權限
- **MQTT QoS 1 + DB idempotent**：傳輸層容忍重送，由 SQL `ON CONFLICT DO UPDATE` + `ROW_NUMBER()` 在資料層去重。注意：broker 異常掉電仍可能丟最近 60s 訊息（`autosave_interval=60`，對 demo 夠用，production 該調短或開 sync flush）；且 ingestor 沒開 persistent session，自己斷線期間 broker 不替它 queue
- **Backfill 走 DB 直寫，不走 broker**：歷史時間戳灌進 broker 語意不對，且易塞爆 buffer
- **Dimension 表 SCD Type 2 + EXCLUDE constraint**：設備搬廠 / 改 spec 保留歷史版本鏈；`EXCLUDE USING gist` 硬擋同 natural key 時間區間重疊；對下游用 view 暴露當前版本，API/ETL 不用改 SQL。SCD update 走 `apply_device_change()` 原子 function
- **Fact 表無 FK + 月分區**：IoT 高頻寫入 FK 卡 lock 是 anti-pattern；一致性由 ETL 保證。`raw_device_readings` 與 `fact_energy_readings` 都 `PARTITION BY RANGE`，支援 partition pruning 與 `DETACH PARTITION` 秒級 retention
- **全鏈路 TIMESTAMPTZ**：schema TZ-aware，日級聚合用 `AT TIME ZONE 'Asia/Taipei'` 切日，避免 UTC 切日造成「台灣 23:30 跟 00:30 屬於不同日」的怪結果
- **Bounded Queries**：所有聚合 SQL 加時間窗口，避免全表掃描
- **ETL DAG 和品質檢查 DAG 解耦**：`etl_pipeline` 跑清洗、`data_quality` 跑 7 項 threshold-based health check，互不阻塞。品質檢查目前用固定 threshold（非 mean/σ control limit），定位是「可演化成完整 SPC control chart 的雛形」

## DAG 排程

| DAG | 頻率 | 任務數 |
|-----|------|--------|
| `ingest_thingspeak`   | 每 5 分鐘 | 1 |
| `etl_pipeline`        | 每 10 分鐘 | 5 |
| `data_quality`        | 每小時 | 7 項 threshold-based health check（含 DIM_SYNC）|
| `cumulative_populate` | 每日 03:00 | 1（D-1 增量併進 `device_activity_cumulated`）|

## 技術棧

`PostgreSQL` · `Python 3.11` · `Java 17 (Spring Boot)` · `Airflow 3.0.2` · `Eclipse Mosquitto 2.0` · `paho-mqtt 2.x` · `uv` · `Docker`
