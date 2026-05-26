#!/bin/bash
# =============================================
# Bootstrap：airflow / iot_platform 兩個 DB + user
# =============================================
# 為什麼用 shell 而不直接寫死 SQL：docker-compose 的 ${AIRFLOW_DB_USER} /
# ${IOT_DB_PASSWORD} 是 runtime env，寫死帳密在 .sql 等於 broken userspace ——
# 用戶改 .env，service 就連不上。
#
# 這個 script 由 postgres 官方 image 的 entrypoint 在第一次起容器（資料 volume
# 還空的時候）跑一次，之後 volume 已存在不會重跑。要改 schema 必須 down -v 重建。
#
# 變數用 psql 的 :"var"（identifier，會自動 double-quote）/ :'var'（literal，
# 會自動 single-quote 並 escape），避免帳密含特殊字元時 SQL 解析爆炸。

set -euo pipefail

: "${POSTGRES_USER:?must be set by postgres image}"
: "${AIRFLOW_DB_USER:?must be set in .env}"
: "${AIRFLOW_DB_PASSWORD:?must be set in .env}"
: "${IOT_DB_USER:?must be set in .env}"
: "${IOT_DB_PASSWORD:?must be set in .env}"
: "${IOT_DB_NAME:?must be set in .env}"

# Step 1: 用 superuser 建 user + database
psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname postgres \
  -v airflow_user="$AIRFLOW_DB_USER" \
  -v airflow_pass="$AIRFLOW_DB_PASSWORD" \
  -v iot_user="$IOT_DB_USER" \
  -v iot_pass="$IOT_DB_PASSWORD" \
  -v iot_db="$IOT_DB_NAME" <<-'EOSQL'
    CREATE USER :"airflow_user" WITH PASSWORD :'airflow_pass';
    CREATE DATABASE airflow OWNER :"airflow_user";
    GRANT ALL PRIVILEGES ON DATABASE airflow TO :"airflow_user";

    CREATE USER :"iot_user" WITH PASSWORD :'iot_pass';
    CREATE DATABASE :"iot_db" OWNER :"iot_user";
    GRANT ALL PRIVILEGES ON DATABASE :"iot_db" TO :"iot_user";
EOSQL

# Step 2: 切成 iot_user 跑 schema，物件 ownership 直接是 iot_user。
# init.sql 被 mount 到 /opt/db-schema/（不在 initdb.d，所以 entrypoint 不會自己跑）。
psql -v ON_ERROR_STOP=1 \
  --username "$IOT_DB_USER" \
  --dbname "$IOT_DB_NAME" \
  -f /opt/db-schema/init.sql
