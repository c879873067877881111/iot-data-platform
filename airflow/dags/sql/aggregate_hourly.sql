-- Step 3: Aggregate fact_energy_readings → fact_hourly_energy
-- Only processes the last 3 hours to avoid full table scan
-- Idempotent: ON CONFLICT DO UPDATE

INSERT INTO fact_hourly_energy (
    site_id, device_id, hour_start,
    avg_power_kw, max_power_kw, min_power_kw,
    energy_kwh, avg_pf, avg_voltage, reading_count
)
SELECT
    site_id,
    device_id,
    DATE_TRUNC('hour', reading_time)    AS hour_start,
    ROUND(AVG(active_power), 2)         AS avg_power_kw,
    ROUND(MAX(active_power), 2)         AS max_power_kw,
    ROUND(MIN(active_power), 2)         AS min_power_kw,
    ROUND(SUM(COALESCE(energy_delta, 0)), 4) AS energy_kwh,
    ROUND(AVG(power_factor), 4)         AS avg_pf,
    ROUND(AVG(voltage_avg), 2)          AS avg_voltage,
    COUNT(*)                            AS reading_count
FROM fact_energy_readings
WHERE reading_time > NOW() - INTERVAL '3 hours'
GROUP BY site_id, device_id, DATE_TRUNC('hour', reading_time)
ON CONFLICT (site_id, device_id, hour_start)
DO UPDATE SET
    avg_power_kw  = EXCLUDED.avg_power_kw,
    max_power_kw  = EXCLUDED.max_power_kw,
    min_power_kw  = EXCLUDED.min_power_kw,
    energy_kwh    = EXCLUDED.energy_kwh,
    avg_pf        = EXCLUDED.avg_pf,
    avg_voltage   = EXCLUDED.avg_voltage,
    reading_count = EXCLUDED.reading_count;
