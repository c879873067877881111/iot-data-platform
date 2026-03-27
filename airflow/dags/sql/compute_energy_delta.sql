-- Step 2: Compute energy_delta using LAG window function
-- energy_delta = current energy_kwh - previous energy_kwh per device

UPDATE fact_energy_readings f
SET energy_delta = sub.delta
FROM (
    SELECT id,
           energy_kwh - LAG(energy_kwh) OVER (
               PARTITION BY site_id, device_id
               ORDER BY reading_time
           ) AS delta
    FROM fact_energy_readings
    WHERE energy_delta IS NULL
) sub
WHERE f.id = sub.id
  AND sub.delta IS NOT NULL
  AND sub.delta >= 0;
