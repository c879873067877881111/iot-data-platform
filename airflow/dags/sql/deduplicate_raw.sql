-- Step 1: Deduplicate & validate raw readings → fact_energy_readings
-- Strategy: ROW_NUMBER to pick latest reading per (site, device, time)
-- Idempotent: ON CONFLICT DO UPDATE

WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY site_id, device_id, collected_at
               ORDER BY ingested_at DESC
           ) AS rn
    FROM raw_device_readings
    WHERE is_processed = FALSE
      AND quality_flag != 'ANOMALY'
),
clean AS (
    SELECT * FROM ranked WHERE rn = 1
)
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
ON CONFLICT (site_id, device_id, reading_time)
DO UPDATE SET
    voltage_avg    = EXCLUDED.voltage_avg,
    current_avg    = EXCLUDED.current_avg,
    active_power   = EXCLUDED.active_power,
    reactive_power = EXCLUDED.reactive_power,
    power_factor   = EXCLUDED.power_factor,
    frequency      = EXCLUDED.frequency,
    energy_kwh     = EXCLUDED.energy_kwh,
    demand_kw      = EXCLUDED.demand_kw,
    raw_reading_id = EXCLUDED.raw_reading_id;

-- Mark processed
UPDATE raw_device_readings
SET is_processed = TRUE
WHERE is_processed = FALSE;
