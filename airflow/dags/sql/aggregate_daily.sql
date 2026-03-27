-- Step 4: Aggregate fact_hourly_energy → fact_daily_energy
-- Only processes today and yesterday to avoid full table scan
-- Idempotent: ON CONFLICT DO UPDATE

INSERT INTO fact_daily_energy (
    site_id, device_id, reading_date,
    total_energy_kwh, peak_demand_kw,
    avg_power_kw, max_power_kw, min_power_kw,
    avg_pf, avg_voltage, reading_count
)
SELECT
    site_id,
    device_id,
    DATE(hour_start)                        AS reading_date,
    ROUND(SUM(energy_kwh), 4)               AS total_energy_kwh,
    ROUND(MAX(max_power_kw), 2)             AS peak_demand_kw,
    ROUND(AVG(avg_power_kw), 2)             AS avg_power_kw,
    ROUND(MAX(max_power_kw), 2)             AS max_power_kw,
    ROUND(MIN(min_power_kw), 2)             AS min_power_kw,
    ROUND(AVG(avg_pf), 4)                   AS avg_pf,
    ROUND(AVG(avg_voltage), 2)              AS avg_voltage,
    SUM(reading_count)                       AS reading_count
FROM fact_hourly_energy
WHERE hour_start > NOW() - INTERVAL '2 days'
GROUP BY site_id, device_id, DATE(hour_start)
ON CONFLICT (site_id, device_id, reading_date)
DO UPDATE SET
    total_energy_kwh = EXCLUDED.total_energy_kwh,
    peak_demand_kw   = EXCLUDED.peak_demand_kw,
    avg_power_kw     = EXCLUDED.avg_power_kw,
    max_power_kw     = EXCLUDED.max_power_kw,
    min_power_kw     = EXCLUDED.min_power_kw,
    avg_pf           = EXCLUDED.avg_pf,
    avg_voltage      = EXCLUDED.avg_voltage,
    reading_count    = EXCLUDED.reading_count;
