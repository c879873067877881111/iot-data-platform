-- Step 2: Compute energy_delta using LAG window function
-- Only processes readings from the last 2 hours to avoid full table scan

UPDATE fact_energy_readings f
SET energy_delta = sub.delta
FROM (
    SELECT id,
           energy_kwh - LAG(energy_kwh) OVER (
               PARTITION BY site_id, device_id
               ORDER BY reading_time
           ) AS delta
    FROM fact_energy_readings
    WHERE reading_time > NOW() - INTERVAL '2 hours'
) sub
WHERE f.id = sub.id
  AND f.energy_delta IS NULL
  AND sub.delta IS NOT NULL
  AND sub.delta >= 0;
