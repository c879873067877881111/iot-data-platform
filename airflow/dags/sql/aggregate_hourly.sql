-- Step 3：把每分鐘的 fact 聚合成每小時（per-minute → per-hour）
--
-- 為什麼要預聚合：查一個月的用電，掃 hourly 表（一個月約 1 萬筆）遠快於
--                 掃 per-minute 表（一個月約 60 萬筆）。空間換時間。
-- 窗口 3 天     ：跟 compute_energy_delta / aggregate_daily 對稱，fresh start 後 backfill
--                  的歷史能一次補完。ON CONFLICT DO UPDATE 讓重算冪等。
-- 冪等性        ：ON CONFLICT DO UPDATE，重跑會用新算的值覆蓋舊聚合值

INSERT INTO fact_hourly_energy (
    site_id, device_id, hour_start,
    avg_power_kw, max_power_kw, min_power_kw,
    energy_kwh, avg_pf, avg_voltage, reading_count
)
SELECT
    site_id,
    device_id,
    DATE_TRUNC('hour', reading_time)    AS hour_start,    -- 把時間切到整點，作為聚合 key
    ROUND(AVG(active_power), 2)         AS avg_power_kw,  -- 平均功率
    ROUND(MAX(active_power), 2)         AS max_power_kw,  -- 尖峰功率（算契約容量用）
    ROUND(MIN(active_power), 2)         AS min_power_kw,  -- 谷底功率
    ROUND(SUM(COALESCE(energy_delta, 0)), 4) AS energy_kwh, -- 一小時總用電；NULL 視為 0 不會炸 SUM
    ROUND(AVG(power_factor), 4)         AS avg_pf,        -- 平均功率因數
    ROUND(AVG(voltage_avg), 2)          AS avg_voltage,
    COUNT(*)                            AS reading_count  -- 樣本數，方便判斷資料是否完整（正常 60 筆/小時）
FROM fact_energy_readings
WHERE reading_time > NOW() - INTERVAL '3 days'
GROUP BY site_id, device_id, DATE_TRUNC('hour', reading_time)
ON CONFLICT (device_id, hour_start)            -- 拿掉 site_id：同 device 同小時不可能在兩 site
DO UPDATE SET
    avg_power_kw  = EXCLUDED.avg_power_kw, -- 就用新算出來的值蓋過去
    max_power_kw  = EXCLUDED.max_power_kw,
    min_power_kw  = EXCLUDED.min_power_kw,
    energy_kwh    = EXCLUDED.energy_kwh,
    avg_pf        = EXCLUDED.avg_pf,
    avg_voltage   = EXCLUDED.avg_voltage,
    reading_count = EXCLUDED.reading_count;
