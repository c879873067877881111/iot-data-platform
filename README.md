# IoT Data Platform

模擬 IoT 電力數據的完整數據中台：數據採集 → Airflow ETL → Star Schema 倉儲 → Spring Boot API。

## Architecture

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Simulator   │───▶│  PostgreSQL  │◀───│   Airflow    │    │  API Server  │
│  (Python)    │    │  (Staging)   │    │   (ETL)      │    │ (Spring Boot)│
│              │    │              │    │              │    │              │
│ 15 devices   │    │ raw_readings │    │ deduplicate  │    │ GET /sites   │
│ 6 sites      │    │ dim_sites    │    │ compute Δ    │    │ GET /energy  │
│ 60s interval │    │ fact_*       │    │ hourly agg   │    │ GET /summary │
└─────────────┘    └─────────────┘    │ daily agg    │    └──────┬──────┘
                                       └─────────────┘           │
                                                                 ▼
                                                          jdbc:postgresql
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Data Simulation | Python 3.11, psycopg2 |
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
deduplicate_raw → compute_energy_delta → aggregate_hourly → aggregate_daily
```

- **Idempotent**: 所有 SQL 使用 `INSERT ... ON CONFLICT DO UPDATE`
- **Deduplication**: `ROW_NUMBER() OVER (PARTITION BY ...)` 去重策略
- **Bounded Queries**: 所有聚合 SQL 加上時間窗口，避免全表掃描
- **Data Quality**: 獨立 DAG 每小時檢查 null、voltage 異常、ingestion gap

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
docker compose up -d
```

| Service | URL |
|---------|-----|
| PostgreSQL | `localhost:5432` |
| Airflow UI | `http://localhost:8081` (admin/admin) |
| API Server | `http://localhost:8080` |
| Swagger UI | `http://localhost:8080/swagger-ui.html` |

Simulator 啟動時自動 backfill 3 天歷史數據，Airflow ETL 每 10 分鐘執行一次。

```bash
# 查詢場站列表
curl http://localhost:8080/api/sites

# 查詢某場站的日用電
curl "http://localhost:8080/api/energy/daily?siteId=SITE_TPE_01&startDate=2026-03-25&endDate=2026-03-28"

# 查詢所有場站的每日摘要
curl "http://localhost:8080/api/energy/summary?startDate=2026-03-27"
```

## Project Structure

```
├── db/init.sql              # Schema + seed data
├── simulator/               # Python IoT data generator
│   ├── generator.py         # Main simulator (backfill + continuous)
│   ├── models.py            # DeviceReading, DeviceSpec dataclasses
│   └── writer.py            # PostgreSQL batch writer
├── airflow/
│   ├── Dockerfile           # Airflow 3.0.2
│   ├── config/airflow.cfg   # Shared config (secret keys)
│   └── dags/
│       ├── etl_pipeline_dag.py    # Core ETL DAG
│       ├── data_quality_dag.py    # Quality checks DAG
│       ├── core/db.py             # DB helper
│       └── sql/                   # Idempotent SQL files
├── api-server/              # Spring Boot + MyBatis
│   ├── src/main/java/com/iotplatform/
│   │   ├── controller/      # REST endpoints
│   │   ├── service/         # Interface + Impl pattern
│   │   ├── mapper/          # MyBatis mapper interfaces
│   │   ├── model/           # Entity classes
│   │   └── dto/             # Query params, summaries
│   ├── src/main/resources/
│   │   └── mapper/          # MyBatis XML (Dynamic SQL)
│   └── src/test/java/       # Unit tests (Mockito + MockMvc)
└── docker-compose.yml       # 7 services
```
