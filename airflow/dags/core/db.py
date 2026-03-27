"""Database helper — runs SQL files against the iot_platform connection."""

from pathlib import Path

from airflow.providers.postgres.hooks.postgres import PostgresHook

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

CONN_ID = "iot_platform_db"


def run_sql_file(filename: str, **context):
    sql = (SQL_DIR / filename).read_text()
    hook = PostgresHook(postgres_conn_id=CONN_ID)
    hook.run(sql)
