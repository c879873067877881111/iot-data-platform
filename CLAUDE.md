# CLAUDE.md — IoT Data Platform

> Project-level context。全域人格 / Karpathy 守則見 `~/.claude/CLAUDE.md`，這份只寫這個 repo 特有的東西。

## 專案身份

工業 IoT 製程能耗監控 demo platform —— **多源採集 → MQTT broker → Airflow ETL + SPC → Star Schema → REST API**。
詳細架構見 [`docs/architecture.md`](docs/architecture.md)，啟動見 [`README.md`](README.md)。

### Simulator = gateway 角色（不是「設備」）

對應現實工業現場「PLC / smart meter → modbus → MQTT 橋接程式」這一層。
所有跟 simulator 相關的文檔、命名、註解，要對齊「gateway 代設備上拋」這個身份 —— **不要寫成「模擬設備自己 publish MQTT」**（PLC / smart meter 多半只講 modbus / RS-485，沒 MQTT stack）。

## 硬規則（不要破）

1. **所有改動走 PR**，不能直接 push main
2. **commit message 不加 `Co-Authored-By: Claude`**
3. **`mosquitto/config/passwd` 是 secret**（bcrypt hash 等於明文密碼）—— 從 `passwd.example` bootstrap，不能 commit
4. **改 schema 必須 `docker compose down -v` 重建** —— postgres init script 只在 volume 為空時跑（流程見 README Quick Start）
5. **`docs/簡報.md` 不進 repo**（已 `.gitignore`）

## 架構約束（寫 SQL / 改 schema 前注意）

- **`fact_energy_readings` PK = `(device_id, reading_time)`** —— 沒有 `id` column。寫 SQL 用 `f.id = sub.id` 會 ERROR
- **`dim_sites` / `dim_devices` 是 view**，背後實表是 `dim_sites_scd` / `dim_devices_scd`（SCD Type 2 + `EXCLUDE USING gist` 擋區間重疊）
- **SCD update 走 `apply_device_change()` function**（原子操作），不要直接 UPDATE SCD 表
- **fact 表月分區**：`PARTITION BY RANGE`，retention 走 `DETACH PARTITION`
- **全鏈路 `TIMESTAMPTZ`**：日級聚合一律 `AT TIME ZONE 'Asia/Taipei'`，避免 UTC 切日造成「台灣 23:30 / 00:30 不同日」
- **Mosquitto 三個分權帳號**：`simulator`（publish only）/ `ingestor`（subscribe only）/ `healthcheck`（獨立 topic）。改 ACL 要對應改三邊
- **自家 Python service（`simulator/` / `mqtt-ingestor/`）的設定全是 module-level `os.environ[...]`**，缺 env 直接 `KeyError`。**不要加 fallback default** —— 改了 `.env` 密碼卻連上 default 密碼的 DB 這種 misconfig 會偷偷跑起來。三方框架（Airflow）依框架原生機制，不在此限
- **`raw_device_readings.quality_flag VARCHAR(32)`**：新增 flag 值要 ≤ 32 字元，否則靜默截斷（commit `1d23b55` 就是修這個）。目前最長 `REJECTED_NEGATIVE`(18)
- **跨 partition UPDATE 要在「外層」WHERE 顯式帶常量範圍**：用子查詢 join partition key 時，外層 `f.reading_time = sub.reading_time` 是 dynamic value，planner 不保證 prune。要另外補 `AND f.reading_time > NOW() - INTERVAL 'N days'` 才走 partition pruning

## 常見的「不是 bug」

- `postgres-1 | ERROR: relation "log" does not exist` 在 airflow-init 階段：Airflow `db migrate` 第一次寫 audit log 但 log 表還沒建。冷啟動 noise，正常
- Simulator backfill 模式跑完不退出：by design —— Dockerfile `CMD` 是 `--backfill 3`，語意是「先補 3 天歷史 → 進連續模式 publish MQTT」
- `cumulative_populate` DAG 看起來「重複」daily aggregation：兩個不重疊 —— 一個是按日聚合，一個是把 D-1 增量併進 `device_activity_cumulated` 累積陣列（DataExpert pattern）
- `docker-compose.yml` `AIRFLOW__CORE__FERNET_KEY: ''` 空字串：demo 設定，等於關閉 connections / variables 的加密。production 必改為從 secret manager 帶值
- 文件（`README.md` / `docs/architecture.md`）寫「6 項 Western Electric Rules → SPC」，但 `data_quality_dag.py` 實作是 7 項 **threshold-based health check**（NULL/NEGATIVE/VOLTAGE_RANGE/FUTURE_TIMESTAMP/DUPLICATE_RATE/INGESTION_GAP/DIM_SYNC），**沒做 mean/σ 控制圖統計**。文件用 SPC 字眼是包裝，找 control chart 程式碼找不到

## Workflow

- **動手前 inventory-first**：列要動的檔案 / 要洗的 volume / 要查的狀態，給 user 看再動
- **Destructive 動作必須先取得授權**：`docker compose down -v`、`rm -rf`、`git push -f`、`git reset --hard`
- **抽象要有 driver**：沒業務理由就直接寫，別硬造 layer（generator.py 的 module-level constants vs config.yaml 是這個原則的實例）
- **Markdown 全繁體中文 Taiwan 用語**：避免大陸繁中借詞（「探針」「視窗」「文件夹」），寫 `healthcheck` / `window` / `directory` 原文反而更清楚

## 常用指令

```bash
# 全鏈路冷啟動
docker compose down -v && docker compose up -d --build

# 訂閱看 simulator publish 什麼
docker run --rm --network data-platform_default eclipse-mosquitto:2.0 \
  mosquitto_sub -h mosquitto -t 'iot/sites/+/devices/+/telemetry' -v

# 驗 raw / fact 寫進度
docker compose exec postgres psql -U iot_user -d iot_platform \
  -c "SELECT COUNT(*) FROM raw_device_readings;" \
  -c "SELECT COUNT(*) FROM fact_energy_readings;"

# 看 Airflow DAG 狀態
open http://localhost:8081   # admin/admin
```
