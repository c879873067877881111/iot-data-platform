-- Step 1：去重 + 過濾髒資料，把 raw_device_readings 搬進 fact_energy_readings
--
-- 過濾條件：排除 ANOMALY、NULL/負值 active_power、未來時間戳、重複資料
-- 去重策略：同一個 (site, device, collected_at) 可能因網路重送出現多筆，
--           用 ROW_NUMBER 依 ingested_at 取最新的一筆
-- 冪等性  ：ON CONFLICT DO UPDATE，重跑不會產生重複，會用新值覆蓋
-- 三個 CTE 串成一個 query 的好處：raw → fact → 標記 is_processed 全部原子化，
--                                  不會出現「搬完但忘了標記」的中間狀態

WITH ranked AS (
    -- 先過濾髒資料，並標號（同一 key 的重複資料 rn = 1, 2, 3 ...）
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY site_id, device_id, collected_at  -- 同一裝置同一時間視為重複
               ORDER BY ingested_at DESC                      -- 取最晚進來的那筆
           ) AS rn
    FROM raw_device_readings
    WHERE is_processed = FALSE       -- 只處理還沒搬過的
      AND quality_flag != 'ANOMALY'  -- ANOMALY 由 mark_rejected.sql 處理
      AND active_power IS NOT NULL   -- 排除斷線
      AND active_power >= 0          -- 排除接線錯誤
      AND collected_at <= NOW()      -- 排除時鐘漂移
),
clean AS (
    -- 只保留每組的第一筆（最新的那筆）
    SELECT * FROM ranked WHERE rn = 1
),
inserted AS (
    -- 寫入 fact 表，回傳成功寫入的 raw_reading_id 給下一步用
    INSERT INTO fact_energy_readings (
        site_id, device_id, reading_time,
        voltage_avg, current_avg, active_power, reactive_power,
        power_factor, frequency, energy_kwh, demand_kw,
        raw_reading_id
    )
    SELECT
        site_id, device_id, collected_at,
        voltage_avg, current_avg, active_power, reactive_power,
        power_factor, frequency, energy_kwh, demand_kw,
        id
    FROM clean
    ON CONFLICT (device_id, reading_time)              -- 拿掉 site_id：同 device 同時刻不可能在兩 site
    DO UPDATE SET
        -- 已存在就用新值覆蓋（補資料 / 重跑安全）
        voltage_avg    = EXCLUDED.voltage_avg,
        current_avg    = EXCLUDED.current_avg,
        active_power   = EXCLUDED.active_power,
        reactive_power = EXCLUDED.reactive_power,
        power_factor   = EXCLUDED.power_factor,
        frequency      = EXCLUDED.frequency,
        energy_kwh     = EXCLUDED.energy_kwh,
        demand_kw      = EXCLUDED.demand_kw,
        raw_reading_id = EXCLUDED.raw_reading_id
)
-- 標所有「進來這一輪」的 raw row 為 processed —— 含 rn>1 的重複。
-- 注意：必須從 ranked 而非 inserted 來標，否則 rn>1 那些重複永遠不會被標掉，
-- 每跑都會被重新 ROW_NUMBER 一次（無效工作 + raw 表脹大）。
--
-- Partition pruning：raw 表月分區，`r.collected_at = ranked.collected_at` 是 dynamic
-- join key，planner 不保證 prune。額外補常量範圍 `r.collected_at > NOW() - INTERVAL`
-- 才會走 partition pruning（CLAUDE.md 架構約束）。
-- 7 天足夠覆蓋 etl_pipeline 排程（10 分鐘）+ 偶發回補的窗口。
UPDATE raw_device_readings r
SET is_processed = TRUE
FROM ranked
WHERE r.id = ranked.id
  AND r.collected_at = ranked.collected_at
  AND r.collected_at > NOW() - INTERVAL '7 days';
