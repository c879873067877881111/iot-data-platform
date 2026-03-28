-- Step 1b: Mark rejected dirty records as processed
-- Prevents them from being re-scanned every ETL run
-- Covers: ANOMALY flag, NULL/negative power, future timestamps, duplicates (rn > 1)

UPDATE raw_device_readings
SET is_processed = TRUE,
    quality_flag = CASE
        WHEN quality_flag = 'ANOMALY' THEN 'ANOMALY'
        WHEN active_power IS NULL THEN 'REJECTED_NULL'
        WHEN active_power < 0 THEN 'REJECTED_NEGATIVE'
        WHEN collected_at > NOW() THEN 'REJECTED_FUTURE'
        ELSE 'REJECTED_DUPLICATE'
    END
WHERE is_processed = FALSE
  AND (
      quality_flag = 'ANOMALY'
      OR active_power IS NULL
      OR active_power < 0
      OR collected_at > NOW()
      OR id NOT IN (
          SELECT DISTINCT ON (site_id, device_id, collected_at) id
          FROM raw_device_readings
          WHERE is_processed = FALSE
          ORDER BY site_id, device_id, collected_at, ingested_at DESC
      )
  );
