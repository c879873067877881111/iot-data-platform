-- Cumulative populate：把昨天的 fact_daily_energy 增量併進 device_activity_cumulated
--
-- pattern：yesterday cumulative ⨝ today (D-1) fact → new cumulative
-- D-1 因為 etl_pipeline daily 聚合 02:00 前才會把昨日資料 ready；DAG 排 03:00 跑就會穩
--
-- 冪等性：ARRAY(SELECT DISTINCT unnest(...)) 去重，重跑同一天不會把日期塞兩次
--        ON CONFLICT (device_id) DO UPDATE 覆寫 row，不會炸 PK

WITH yesterday AS (
    SELECT * FROM device_activity_cumulated
),
today AS (
    -- 用台北 D-1 而不是 CURRENT_DATE - 1：fact_daily_energy.reading_date 是台北日（見 aggregate_daily.sql），
    -- CURRENT_DATE 跟 postgres session timezone 走 —— UTC session 在台北早上會慢一天。
    SELECT
        device_id,
        ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Taipei')::date - 1) AS today_date,
        BOOL_OR(avg_pf < 0.85)                                     AS had_low_pf
    FROM fact_daily_energy
    WHERE reading_date = ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Taipei')::date - 1)
    GROUP BY device_id
)
INSERT INTO device_activity_cumulated (
    device_id, first_seen_date, last_seen_date,
    dates_active, dates_low_pf, dates_anomaly, last_updated
)
SELECT
    COALESCE(t.device_id, y.device_id)                      AS device_id,
    COALESCE(y.first_seen_date, t.today_date)               AS first_seen_date,
    COALESCE(t.today_date, y.last_seen_date)                AS last_seen_date,
    ARRAY(
        SELECT DISTINCT unnest(
            COALESCE(y.dates_active, ARRAY[]::DATE[])
            || CASE WHEN t.device_id IS NOT NULL THEN ARRAY[t.today_date]
                    ELSE ARRAY[]::DATE[] END
        ) ORDER BY 1
    )                                                       AS dates_active,
    ARRAY(
        SELECT DISTINCT unnest(
            COALESCE(y.dates_low_pf, ARRAY[]::DATE[])
            || CASE WHEN t.had_low_pf THEN ARRAY[t.today_date]
                    ELSE ARRAY[]::DATE[] END
        ) ORDER BY 1
    )                                                       AS dates_low_pf,
    COALESCE(y.dates_anomaly, ARRAY[]::DATE[])              AS dates_anomaly,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Taipei')::date    AS last_updated
FROM yesterday y
FULL OUTER JOIN today t ON y.device_id = t.device_id
ON CONFLICT (device_id) DO UPDATE SET
    first_seen_date = EXCLUDED.first_seen_date,
    last_seen_date  = EXCLUDED.last_seen_date,
    dates_active    = EXCLUDED.dates_active,
    dates_low_pf    = EXCLUDED.dates_low_pf,
    dates_anomaly   = EXCLUDED.dates_anomaly,
    last_updated    = EXCLUDED.last_updated;
