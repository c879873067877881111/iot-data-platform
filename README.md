# IoT Data Platform

IoT 電力監控數據中台：數據採集 → Airflow ETL（清洗/去重/聚合）→ Star Schema 倉儲 → Spring Boot REST API。

> 本專案使用 Python 產生擬真電力數據（含髒資料），做為開發階段的資料來源，實際場景可替換為 MQTT / OPC-UA / HTTP 等協議對接實體設備。

## Architecture

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Data Source  │───▶│  PostgreSQL  │◀───│   Airflow    │    │  API Server  │
│  (Python)    │    │  (Raw/DW)    │    │   (ETL)      │    │ (Spring Boot)│
│              │    │              │    │              │    │              │
│ 6 sites      │    │ raw_readings │    │ deduplicate  │    │ GET /sites   │
│ 15 devices   │    │ dim_sites    │    │ mark_rejected│    │ GET /energy  │
│ 60s interval │    │ fact_*       │    │ compute Δ    │    │ GET /summary │
│              │    │              │    │ hourly agg   │    │              │
└─────────────┘    └─────────────┘    │ daily agg    │    └──────┬──────┘
                                       └─────────────┘           │
                                                                 ▼
                                                          jdbc:postgresql
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Data Ingestion | Python 3.11, psycopg2 |
| Database | PostgreSQL 16 (Star Schema) |
| ETL | Apache Airflow 3.0.2 (LocalExecutor) |
| API | Spring Boot 3.5, MyBatis 3, Java 17 |
| API Docs | Swagger UI (springdoc-openapi) |
| Infrastructure | Docker Compose (7 services) |

## Data Model (Star Schema)

```
dim_sites ──┐
             ├──▶ fact_energy_readings ──▶ fact_hourly_energy ──▶ fact_daily_energy
dim_devices ─┘
```

- **Staging**: `raw_device_readings` — 原始數據，包含 quality_flag
- **Dimensions**: `dim_sites` (6 sites), `dim_devices` (15 devices)
- **Facts**: 三層聚合 (readings → hourly → daily)
- **Metadata**: `data_quality_log` — 數據品質檢查記錄

## ETL Pipeline

```
deduplicate_raw → mark_rejected → compute_energy_delta → aggregate_hourly → aggregate_daily
```

- **Idempotent**: 所有 SQL 使用 `INSERT ... ON CONFLICT DO UPDATE`
- **Deduplication**: `ROW_NUMBER() OVER (PARTITION BY ...)` 去重策略
- **Data Cleaning**: 過濾 NULL power、負值、未來時間戳、ANOMALY flag，標記拒絕原因（REJECTED_NULL / REJECTED_NEGATIVE / REJECTED_FUTURE）
- **Bounded Queries**: 所有聚合 SQL 加上時間窗口，避免全表掃描
- **Data Quality**: 獨立 DAG 每小時檢查 NULL power、negative power、voltage 異常、未來時間戳、重複率、ingestion gap

## Data Quality

原始數據包含約 2% 的異常資料，ETL pipeline 負責清洗與標記：

| 類型 | 場景 | ETL 處理 |
|------|------|----------|
| NULL power | 感測器斷線 | `REJECTED_NULL` |
| 負值 power | 接線錯誤 | `REJECTED_NEGATIVE` |
| 未來時間戳 | 設備時鐘漂移 | `REJECTED_FUTURE` |
| 重複資料 | 重送/網路重試 | `ROW_NUMBER` 去重 |
| 異常讀數 | Z-score > 3 | `ANOMALY` flag |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/sites` | 列出所有場站 |
| GET | `/api/sites/{siteId}` | 場站詳情 |
| GET | `/api/sites/{siteId}/devices` | 場站設備列表 |
| GET | `/api/energy/hourly` | 小時用電查詢 |
| GET | `/api/energy/daily` | 日用電查詢 |
| GET | `/api/energy/summary` | 場站日用電摘要 |

Query parameters: `siteId`, `deviceId`, `startDate`, `endDate`

- **Success**: 直接回傳 JSON（無 envelope wrapper）
- **Error**: RFC 7807 ProblemDetail (`application/problem+json`)

Swagger UI: `http://localhost:8080/swagger-ui.html`

### MyBatis Dynamic SQL

XML Mapper 展示 `<if>`, `<where>`, `<choose>` 動態查詢：

```xml
<select id="findDaily" parameterType="EnergyQueryParam" resultType="DailyEnergy">
    SELECT * FROM fact_daily_energy
    <where>
        <if test="siteId != null">AND site_id = #{siteId}</if>
        <choose>
            <when test="startDate != null and endDate != null">
                AND reading_date BETWEEN #{startDate} AND #{endDate}
            </when>
            <when test="startDate != null">
                AND reading_date >= #{startDate}
            </when>
        </choose>
    </where>
</select>
```

## Quick Start

```bash
cp .env.example .env   # 修改密碼（開發環境可直接使用預設值）
docker compose up -d
```

| Service | URL |
|---------|-----|
| PostgreSQL | `localhost:5432` |
| Airflow UI | `http://localhost:8081` (admin/admin) |
| API Server | `http://localhost:8080` |
| Swagger UI | `http://localhost:8080/swagger-ui.html` |

啟動後自動 backfill 3 天歷史數據，Airflow ETL 每 10 分鐘執行一次。

```bash
# 查詢場站列表
curl http://localhost:8080/api/sites

# 查詢某場站的日用電
curl "http://localhost:8080/api/energy/daily?siteId=SITE_TPE_01&startDate=2026-03-25&endDate=2026-03-28"

# 查詢所有場站的每日摘要
curl "http://localhost:8080/api/energy/summary?startDate=2026-03-27"
```

## Tests

```bash
cd api-server && mvn test
```

| Layer | Framework | Tests |
|-------|-----------|-------|
| DAO | @MybatisTest + H2 (PostgreSQL mode) | 12 |
| Service | Mockito | 12 |
| Controller | @WebMvcTest + MockMvc | 9 |

## Project Structure

```
├── .env.example             # 環境變數模板
├── db/init.sql              # Schema + seed data
├── simulator/               # 數據來源（開發階段替代實體設備）
│   ├── generator.py         # 擬真電力數據產生器
│   ├── models.py            # DeviceReading, DeviceSpec dataclasses
│   └── writer.py            # PostgreSQL batch writer
├── airflow/
│   ├── Dockerfile           # Airflow 3.0.2
│   └── dags/
│       ├── etl_pipeline_dag.py    # Core ETL DAG (5 tasks)
│       ├── data_quality_dag.py    # Quality checks DAG (6 checks)
│       ├── core/db.py             # DB helper
│       └── sql/                   # Idempotent SQL files
├── api-server/              # Spring Boot + MyBatis
│   ├── src/main/java/com/iotplatform/
│   │   ├── controller/      # REST endpoints + GlobalExceptionHandler (RFC 7807)
│   │   ├── service/         # Interface + Impl pattern
│   │   ├── mapper/          # MyBatis mapper interfaces
│   │   ├── model/           # Entity classes
│   │   └── dto/             # Query params, summaries
│   ├── src/main/resources/
│   │   └── mapper/          # MyBatis XML (Dynamic SQL)
│   └── src/test/            # 33 tests (DAO + Service + Controller)
└── docker-compose.yml       # 7 services, secrets via .env
```
