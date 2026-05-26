# IoT Data Platform

工業 IoT 製程能耗監控平台：**設備 → MQTT Broker → Ingestor → Airflow ETL → Star Schema 倉儲 → REST API + SPC 監控**。

整合真實 IoT 感測器（[ThingSpeak PZEM-004T](https://thingspeak.com/channels/972755)）與本機模擬 gateway（代設備把讀值 publish 成 MQTT），展示完整的工業資料流：從現場通訊協定（MQTT / 可延伸 Modbus）到資料工程清洗，再到 SPC（Statistical Process Control）製程監控。

## Architecture

兩條 ingestion 路徑，在 PostgreSQL staging table 匯流：

```
        HTTP Path                              MQTT Path

┌────────────────┐                      ┌────────────────┐
│  ThingSpeak    │                      │  Simulator     │
│  PZEM-004T     │                      │  15 devices    │
│  Channel API   │                      │  paho-mqtt 2.x │
│  (第三方雲端)   │                       │  (publish Q1)  │
└────────┬───────┘                      └────────┬───────┘
         │ HTTP GET /feeds.json                  │ topic:
         │ (Airflow pull /5min)                  │  iot/sites/+/
         │                                       │  devices/+/telemetry
         │                                       ▼
         │                               ┌────────────────┐
         │                               │  Mosquitto     │
         │                               │  broker :1883  │
         │                               │  QoS 1         │
         │                               └────────┬───────┘
         │                                        │ subscribe
         │                                        ▼
         │                               ┌────────────────┐
         │                               │  mqtt-ingestor │
         │                               │  batch 100/5s  │
         │                               │  auto-reconnect│
         │                               └────────┬───────┘
         ▼                                        ▼
┌────────────────────────────────────────────────────────────┐
│              PostgreSQL（staging 層匯流）                    │
│              raw_device_readings (with quality_flag)        │
└─────────────────────────────┬──────────────────────────────┘
                              ▼
┌────────────────────────────────────────────────────────────┐
│         Airflow ETL (etl_pipeline DAG, 每 10 分鐘)          │
│   ① dedup → ② mark_bad → ③ compute Δ → ④ hourly → ⑤ daily  │
└─────────────────────────────┬──────────────────────────────┘
                              ▼
┌────────────────────────────────────────────────────────────┐
│   Warehouse: dim_sites / dim_devices /                      │
│              fact_energy_readings / fact_hourly /           │
│              fact_daily / data_quality_log                  │
└──────────────┬──────────────────────────┬──────────────────┘
               │                          │
               ▼                          ▼
   ┌──────────────────┐         ┌──────────────────────┐
   │ Spring Boot REST │         │ data_quality DAG     │
   │ /sites /energy   │         │ (每小時)              │
   │ /summary         │         │ 7 項 threshold check │
   │ + Swagger UI     │         │ → data_quality_log   │
   └──────────────────┘         └──────────────────────┘
```

> 為什麼 ThingSpeak 不走 broker？它是第三方公開平台，**只提供 HTTP API**，無法 publish 到我的 Mosquitto。Simulator 模擬的是「gateway 代設備 publish MQTT」這一層（對應現實裡 modbus → MQTT 橋接程式），所以才走 MQTT publish。

## Tech Stack

| Layer            | Technology                                          |
|------------------|-----------------------------------------------------|
| Field Protocol   | MQTT 5（paho-mqtt 2.x） · HTTP（ThingSpeak Channel API）|
| Broker           | Eclipse Mosquitto 2.0                               |
| Ingestion        | Python 3.11 subscriber service（batch writer）       |
| Database         | PostgreSQL 16（Star Schema）                         |
| ETL / SPC        | Apache Airflow 3.0.2（LocalExecutor）                |
| API              | Spring Boot 3.5 · MyBatis 3 · Java 17               |
| API Docs         | Swagger UI（springdoc-openapi）                      |
| Python Tooling   | uv（package manager + lockfile，取代 pip + venv）    |
| Infra            | Docker Compose（10 services）                        |

## Data Model（Star Schema + SCD Type 2）

```
   ┌──────────────────┐                          ┌──────────────────┐
   │ dim_sites_scd    │                          │ dim_devices_scd  │
   │ (SCD2: version,  │                          │ (SCD2: version,  │
   │  effective_from, │                          │  effective_from, │
   │  effective_to,   │                          │  effective_to,   │
   │  is_current...)  │                          │  is_current...)  │
   └────────┬─────────┘                          └────────┬─────────┘
            │ view (is_current=TRUE)                      │
            ▼                                             ▼
       ┌─────────┐                                   ┌──────────┐
       │dim_sites│                                   │dim_devices│
       │  (view) │                                   │  (view)  │
       └─────────┘                                   └──────────┘

                ┌──────────────────────────┐
                │  fact_energy_readings    │   ← base fact（per-minute）
                │  PARTITION BY month      │      無 FK（由 ETL 保證一致性）
                └────────────┬─────────────┘
                             │ aggregate hourly
                             ▼
                ┌──────────────────────────┐
                │   fact_hourly_energy     │   ← per-hour
                └────────────┬─────────────┘
                             │ aggregate daily
                             ▼
                ┌──────────────────────────┐
                │   fact_daily_energy      │   ← per-day
                └────────────┬─────────────┘
                             │ daily incremental
                             ▼
                ┌──────────────────────────┐
                │ device_activity_cumulated│   ← per-device 累積活躍日期陣列
                └──────────────────────────┘
```

- **Dimensions（SCD Type 2）**：`dim_sites_scd` / `dim_devices_scd` 保留歷史版本（設備搬廠、改 spec 不覆寫）
  - **`EXCLUDE USING gist` constraint** 硬擋同 natural key 時間區間重疊
  - 對下游用同名 view `dim_sites` / `dim_devices` 暴露當前版本，API/ETL 不用改 SQL
  - `apply_device_change()` PL/pgSQL function 把「close 舊版 + 開新版」包成原子操作（呼叫範例見 `db/init.sql` 函式註解）
  - view 只暴露「當前版本」的業務欄位；想看 SCD metadata（`effective_from` / `effective_to` / `version_number` / `change_reason`）直接走 `dim_devices_scd` / `dim_sites_scd` 實表
- **Fact 表**：刻意**沒 FK** — IoT 高頻寫入 FK 卡 lock；且 view 不能當 FK target。一致性由 ETL 保證
  - `fact_energy_readings` 月分區（partition pruning + 易維運）
  - 預建到 2026-12 + DEFAULT partition 兜底；年底要補下一年 partition（見 `db/init.sql` 開頭 ⚠️ note）
- **Staging**：`raw_device_readings` — MQTT 訊息與 ThingSpeak 抓取共寫的著陸區，含 `quality_flag`，同樣月分區
- **時區**：全部時間欄位 `TIMESTAMPTZ`；日級聚合用 `AT TIME ZONE 'Asia/Taipei'` 切日
- **SPC log**：`data_quality_log` — 製程監控檢查歷史（control chart 資料源）

## ETL Pipeline

```
deduplicate_raw → mark_rejected → compute_energy_delta → aggregate_hourly → aggregate_daily
```

- **Idempotent**：所有 SQL 使用 `INSERT ... ON CONFLICT DO UPDATE` —— 配合 MQTT QoS 1 at-least-once 語意，重複訊息不會造成資料汙染
- **Deduplication**：`ROW_NUMBER() OVER (PARTITION BY ...)` 去重策略
- **Bounded Queries**：所有聚合 SQL 加上時間窗口，避免全表掃描

**資料清洗**：原始訊號約 2% 異常，ETL 在進倉儲前完成清洗與標記：

| 類型 | 場景 | 處理方式 |
|------|------|----------|
| NULL power | 感測器斷線 | `REJECTED_NULL` |
| 負值 power | 接線錯誤 | `REJECTED_NEGATIVE` |
| 未來時間戳 | 設備時鐘漂移 | `REJECTED_FUTURE` |
| 重複資料 | MQTT QoS 1 重送 / 網路重試 | `ROW_NUMBER` 去重 |
| 異常讀數 | simulator 端隨機注入（`ANOMALY_PROBABILITY=0.5%`，模擬感測器偶發雜訊）| 沿用 payload 帶的 `ANOMALY` flag，不進 fact 表 |

## 資料品質監控（SPC 雛形）

`data_quality_dag` 每小時跑 **7 項 threshold-based health check**，把結果寫進 `data_quality_log` 累積歷史趨勢。每項指標都對應到 SPC 的某個概念（量測系統穩定性、規格界線、訊號完整性），但**目前用固定 threshold，不是 mean/σ 控制限** —— 把它定位成「可演化成完整 control chart 的雛形」，不是已實作的 SPC 系統。

### 檢查項目

| 檢查指標 | 對應 SPC 概念 | Threshold | 偵測目的 |
|---------|---------|----------------|---------|
| `NULL_POWER` | 量測系統可用性 | 2 小時內 NULL ≤ 10 | 感測器斷線 / 通訊中斷 |
| `NEGATIVE_POWER` | 物理不可能讀值 | 2 小時內負值 ≤ 10 | 接線錯誤 / 量測極性錯置 |
| `VOLTAGE_RANGE` | 規格界線（Specification Limit）| 180V ≤ V ≤ 260V | 電源品質異常 |
| `FUTURE_TIMESTAMP` | 量測系統時鐘漂移 | 未來時間筆數 ≤ 5 | NTP 同步失效 |
| `DUPLICATE_RATE` | 訊號完整性 | 2 小時內重複 ≤ 20 | 網路層重送 / watermark 失效 |
| `INGESTION_GAP` | 製程資料持續性 | 活躍設備 10 分鐘無資料 ≤ 3 | 設備離線 / broker 路徑中斷 |
| `DIM_SYNC` | dim / fact 一致性 | 24 小時內 fact 出現的 `device_id` 全部要有 `is_current` SCD 版本（>0 即 FAIL）| 設備搬廠 / 新設備 seed 漏 SCD update |

**設計理念**：
- ETL DAG（`etl_pipeline`）負責**資料清洗**——把超出物理可能的讀值剔除
- 品質 DAG（`data_quality`）負責**穩定性監控**——每小時取一點寫進 log，累積長期 trend
- 兩個 DAG 解耦：清洗失敗不影響品質記錄，品質檢查失敗不影響倉儲寫入
- 通知系統（Slack / Email）應訂閱 `data_quality_log`，由外部處理——DAG 只負責產生資料

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/sites` | 列出所有場站 |
| GET | `/api/sites/{siteId}` | 場站詳情 |
| GET | `/api/sites/{siteId}/devices` | 場站設備列表 |
| GET | `/api/energy/hourly` | 小時用電查詢 |
| GET | `/api/energy/daily` | 日用電查詢 |
| GET | `/api/energy/summary` | 場站日用電摘要 |

Query parameters：`siteId`、`deviceId`、`startDate`、`endDate`

- **Success**：直接回傳 JSON（無 envelope wrapper）
- **Error**：RFC 7807 ProblemDetail（`application/problem+json`）

Swagger UI：`http://localhost:8080/swagger-ui.html`

## Design Notes（關鍵設計決策）

幾個面試常被追問的設計選擇，理由寫在這：

1. **Backfill 走 DB 直寫，不走 MQTT broker**
   Broker 是「即時通道」，把歷史時間戳灌進去語意不對，且大批量灌訊息易塞爆 broker buffer。歷史回補是離線批次工作，直接寫 staging table 比較乾淨。

2. **MQTT QoS 1（at-least-once）+ DB idempotent**
   不選 QoS 2（exactly-once）因為 4-way handshake 對 IoT 流量是 overkill。改用 QoS 1 容忍重送，下游 SQL 用 `INSERT ... ON CONFLICT DO UPDATE` + `ROW_NUMBER()` 去重——把「不重複」的責任放在資料層而非傳輸層。

3. **Ingestor batch flush：100 筆 OR 5 秒**
   先到先觸發，避免低流量時資料卡在記憶體。Flush 失敗時把 batch 退回 buffer 前面下次重試，conn 標記為 None 強制重連。

4. **Mosquitto healthcheck 用 `-E` 純連線測試，不訂閱 `$SYS/#`**
   `$SYS` 預設 `sys_interval = 10s`，short timeout 健康檢查會週期性 false negative，導致 `depends_on: service_healthy` 抖動。

5. **uv + pyproject.toml + uv.lock，取代 pip + requirements.txt**
   uv（Rust 寫的 package manager）解析速度 10-100x 快於 pip；lockfile 確保 transitive deps reproducible。Docker build 從 30-60s 降到 2s。

6. **Airflow Dockerfile 維持 pip（不跟 uv 統一）**
   Airflow 官方 image 對 dependency 結構（含 constraints.txt、providers）有自己的假設，硬塞 uv 容易踩坑。**「跟著 framework 走」vs「自家 service 用最新工具」是不同判斷**。

7. **ETL DAG 和 SPC DAG 解耦**
   `etl_pipeline` 負責資料清洗，`data_quality` 負責製程穩定性監控。清洗失敗不影響 SPC 記錄，反之亦然。通知系統（Slack/Email）應訂閱 `data_quality_log`，由外部處理——DAG 單一職責。

8. **Dimension 表用 SCD Type 2，fact 表拿掉 FK**
   設備搬廠 / 改 spec 是真實業務事件，覆寫會丟歷史；改用 SCD2 保留版本鏈。`EXCLUDE USING gist` 硬擋同 natural key 的時間區間重疊，避免應用層犯錯造成髒資料。Fact 表刻意**沒 FK** — 一是 view 不能當 FK target，二是 IoT 高頻寫入下 FK 卡 lock 是 anti-pattern。一致性由 ETL 保證。SCD update 走 `apply_device_change()` PL/pgSQL function（一個原子操作完成 close 舊版 + 開新版 + 防呆），不要 copy-paste UPDATE+INSERT 兩段 SQL。

9. **Raw + per-minute fact 月分區**
   `raw_device_readings` 與 `fact_energy_readings` 都 `PARTITION BY RANGE (collected_at)`，每月一個 partition + DEFAULT 兜底。查詢自動 partition pruning，舊資料 retention 用 `DETACH PARTITION` 秒回（不用 DELETE 掃全表）。年底前要手動補下一年的 12 個 partition，或接 pg_partman / pg_cron 自動建。

## Industrial Protocol Coverage

目前已實作：
- **MQTT**：模擬 gateway 用 paho-mqtt publish 到 Mosquitto broker，topic 結構 `iot/sites/{site_id}/devices/{device_id}/telemetry`，QoS 1
- **HTTP REST**：ThingSpeak Channel API 抓取（Airflow `ingest_thingspeak` DAG）

可延伸接入（作者已具備相關經驗，未納入本專案以保持範圍聚焦）：
- **Modbus TCP**：pymodbus，適用於 PLC、變頻器、冷凍機、AHU、電錶等工業設備
- **SECS/GEM**：半導體設備標準通訊協定

延伸方式：另起一支 bridge service 從工業協議讀值，**publish 到同一個 MQTT topic 結構**，下游 ingestor → ETL → 倉儲完全不用改動。這是 broker 解耦設計的好處。

## Quick Start

```bash
cp .env.example .env   # 修改密碼（開發環境可直接使用預設值）

# Mosquitto bootstrap：passwd 被 .gitignore，必須自己生
#（密碼要對應 .env 裡的 MQTT_*_PASSWORD；換密碼後也用同樣指令重產）
docker run --rm -v $PWD/mosquitto/config:/c eclipse-mosquitto:2.0 \
  mosquitto_passwd -c -b /c/passwd simulator iot_sim_pass
docker run --rm -v $PWD/mosquitto/config:/c eclipse-mosquitto:2.0 \
  mosquitto_passwd -b /c/passwd ingestor iot_ing_pass
docker run --rm -v $PWD/mosquitto/config:/c eclipse-mosquitto:2.0 \
  mosquitto_passwd -b /c/passwd healthcheck iot_hc_pass

docker compose up -d
```

> 第一個 `mosquitto_passwd` 用 `-c` 建檔（會清空既有檔案），後續帳號用 `-b` 追加。
> 完整說明見 `mosquitto/config/passwd.example`。

| Service | URL |
|---------|-----|
| PostgreSQL | `localhost:5432` |
| Mosquitto MQTT | `localhost:1883` |
| Airflow UI | `http://localhost:8081`（admin/admin） |
| API Server | `http://localhost:8080` |
| Swagger UI | `http://localhost:8080/swagger-ui.html` |

啟動後行為：
- Simulator 先 backfill 3 天歷史資料（直寫 staging），之後切換為**連續模式發送 MQTT**
- mqtt-ingestor 訂閱所有 `iot/sites/+/devices/+/telemetry`，batch 寫入 `raw_device_readings`
- Airflow `etl_pipeline` 每 10 分鐘執行 ETL，`data_quality` 每小時跑 SPC 檢查，`ingest_thingspeak` 每 5 分鐘拉真實 IoT 資料，`cumulative_populate` 每日 03:00 增量更新 device 活躍日期

驗證 MQTT 訊號流：
```bash
# 訂閱看看 simulator 在 publish 什麼（network 名稱 = compose project 名 + _default）
docker run --rm --network data-platform_default eclipse-mosquitto:2.0 \
  mosquitto_sub -h mosquitto -t 'iot/sites/+/devices/+/telemetry' -v
```

查詢 API：
```bash
# 查詢場站列表
curl http://localhost:8080/api/sites

# 查詢某場站的日用電
curl "http://localhost:8080/api/energy/daily?siteId=SITE_TPE_01&startDate=2026-03-25&endDate=2026-03-28"

# 查詢所有場站的每日摘要
curl "http://localhost:8080/api/energy/summary?startDate=2026-03-27"
```

查詢 SPC 監控結果：
```sql
SELECT check_type, status, metric_value, threshold_value, check_time
FROM data_quality_log
ORDER BY check_time DESC LIMIT 50;
```

### 改 schema 後重建

Postgres init script（`db/init.sql` + `db/01-create-users.sh`）**只在資料目錄是空的時候才會跑**。
改完 schema 直接 `restart` 或 `up` 不會重跑 —— 舊 schema 還在 volume 裡，新 DAG 跑下去會撞 column 不存在或 type 不對。

```bash
docker compose down -v       # -v 把 postgres_data volume 一起洗
docker compose up -d --build
```

`-v` 會連同 Airflow metadata 跟歷史讀值一起洗掉，是預期行為 —— 這個專案沒有 prod 資料保留需求，simulator 起來會自動 backfill 3 天歷史補齊。

## Tests

```bash
# Java（API server）
cd api-server && mvn test

# Python（mqtt-ingestor parse_payload）
cd mqtt-ingestor && uv sync && .venv/bin/pytest
```

| Service | Layer | Framework | Tests |
|---------|-------|-----------|-------|
| api-server | DAO | @MybatisTest + H2（PostgreSQL mode） | 12 |
| api-server | Service | Mockito | 12 |
| api-server | Controller | @WebMvcTest + MockMvc | 9 |
| mqtt-ingestor | parse_payload | pytest | 5 |

## Project Structure

```
├── .env.example             # 環境變數模板（含 MQTT 三個分權帳號密碼）
├── db/
│   └── init.sql             # Schema + SCD2 trigger/function + seed data（含 apply_device_change 呼叫範例）
├── mosquitto/
│   ├── Dockerfile           # COPY --chmod=0700 把 passwd/acl 權限烙進 image
│   └── config/
│       ├── mosquitto.conf   # auth-hardened（allow_anonymous=false）
│       ├── acl              # topic ACL：simulator write / ingestor read / healthcheck 獨立 topic
│       └── passwd.example   # bootstrap 指令（實際 passwd 被 .gitignore）
├── simulator/               # MQTT publisher（模擬 gateway：代設備把 modbus 讀值翻成 MQTT 上拋）
│   ├── pyproject.toml       # uv 專案定義
│   ├── uv.lock              # 鎖定 transitive deps（reproducible build）
│   ├── Dockerfile           # uv sync --frozen --no-dev
│   ├── .dockerignore        # 排除 host .venv 污染 prod image
│   ├── generator.py         # 連續模式 publish MQTT；backfill 模式直寫 DB
│   ├── mqtt_publisher.py    # paho-mqtt 2.x 封裝（QoS 1, auto-reconnect）
│   ├── models.py            # DeviceReading, DeviceSpec dataclasses
│   └── writer.py            # backfill 用的 PostgreSQL batch writer
├── mqtt-ingestor/           # MQTT subscriber，batch 寫入 staging
│   ├── pyproject.toml
│   ├── uv.lock
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── ingestor.py          # subscribe + buffer 100 筆 / 5 秒 flush
│   └── tests/               # pytest：parse_payload 邊界案例
├── airflow/
│   ├── Dockerfile           # Airflow 3.0.2
│   └── dags/
│       ├── ingest_thingspeak_dag.py   # 外部 IoT 平台抓取
│       ├── etl_pipeline_dag.py        # 核心 ETL（5 tasks）
│       ├── data_quality_dag.py        # 資料品質 DAG（7 threshold checks）
│       ├── cumulative_populate_dag.py # device_activity_cumulated 每日增量
│       ├── core/db.py                 # DB helper
│       └── sql/                       # Idempotent SQL files
├── api-server/              # Spring Boot + MyBatis
│   ├── src/main/java/com/iotplatform/
│   │   ├── controller/      # REST endpoints + GlobalExceptionHandler（RFC 7807）
│   │   ├── service/         # Interface + Impl pattern
│   │   ├── mapper/          # MyBatis mapper interfaces
│   │   ├── model/           # Entity classes
│   │   └── dto/             # Query params, summaries
│   ├── src/main/resources/
│   │   └── mapper/          # MyBatis XML（Dynamic SQL）
│   └── src/test/            # 33 tests（DAO + Service + Controller）
└── docker-compose.yml       # 10 services, secrets via .env
```
