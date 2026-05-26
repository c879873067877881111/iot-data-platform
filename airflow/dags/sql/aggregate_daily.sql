-- Step 4：把 hourly 再聚合成 daily（per-hour → per-day）
--
-- 為什麼要再聚合一層：查一年的用電趨勢，掃 daily 表（一年 365 筆）秒回；
--                     掃 hourly 表要 8760 筆、per-minute 要 50 萬筆。
-- 為什麼從 hourly 算 ：不從 per-minute 直接算，是因為 hourly 已經聚合過、資料量少 60 倍，更快。
-- 只處理今天 + 昨天   ：跨日資料可能晚到，多算昨天一遍補資料；其他天不動
-- 冪等性             ：ON CONFLICT DO UPDATE，重跑會覆蓋

INSERT INTO fact_daily_energy (
    site_id, device_id, reading_date,
    total_energy_kwh, peak_demand_kw,
    avg_power_kw, max_power_kw, min_power_kw,
    avg_pf, avg_voltage, reading_count
)
SELECT
    site_id,
    device_id,
    -- 「日」邊界用台北時區算（台灣 23:30 跟 00:30 屬於同一日 vs 不同日，跟 UTC 切會差一天）
    (hour_start AT TIME ZONE 'Asia/Taipei')::date  AS reading_date,
    ROUND(SUM(energy_kwh), 4)               AS total_energy_kwh, -- 一天總用電 = 24 小時加總
    ROUND(MAX(max_power_kw), 2)             AS peak_demand_kw,   -- 整天最高峰功率（電費計算用）
    ROUND(AVG(avg_power_kw), 2)             AS avg_power_kw,     -- 平均功率
    ROUND(MAX(max_power_kw), 2)             AS max_power_kw,     -- 同 peak_demand_kw，保留兩個欄位讓 API 語意清楚
    ROUND(MIN(min_power_kw), 2)             AS min_power_kw,     -- 整天最低功率
    ROUND(AVG(avg_pf), 4)                   AS avg_pf,
    ROUND(AVG(avg_voltage), 2)              AS avg_voltage,
    SUM(reading_count)                       AS reading_count    -- 一天樣本總數（正常 1440 筆/天）
FROM fact_hourly_energy
-- 3 days 而非 2 days：DAG 在台北早上跑時，NOW() (UTC) 兩天前 = 台北兩天前同時刻，
-- 「前天」邊界貼太緊 → 晚到 > 24h 會被遺漏。3 days cost 微乎其微但邊界乾淨。
WHERE hour_start > NOW() - INTERVAL '3 days'
GROUP BY site_id, device_id, (hour_start AT TIME ZONE 'Asia/Taipei')::date
ON CONFLICT (device_id, reading_date)
DO UPDATE SET
    -- 重新聚合會把新算的值覆蓋上去（補晚到的資料時很重要）
    total_energy_kwh = EXCLUDED.total_energy_kwh,
    peak_demand_kw   = EXCLUDED.peak_demand_kw,
    avg_power_kw     = EXCLUDED.avg_power_kw,
    max_power_kw     = EXCLUDED.max_power_kw,
    min_power_kw     = EXCLUDED.min_power_kw,
    avg_pf           = EXCLUDED.avg_pf,
    avg_voltage      = EXCLUDED.avg_voltage,
    reading_count    = EXCLUDED.reading_count;
