-- Step 1b: Mark rejected dirty records as processed
-- Covers: ANOMALY flag, NULL/negative power, future timestamps
-- Duplicates are already handled by deduplicate_raw.sql (ROW_NUMBER picks one)

UPDATE raw_device_readings
SET is_processed = TRUE,
    quality_flag = CASE
        WHEN quality_flag = 'ANOMALY' THEN 'ANOMALY'
        WHEN active_power IS NULL THEN 'REJECTED_NULL'
        WHEN active_power < 0 THEN 'REJECTED_NEGATIVE'
        WHEN collected_at > NOW() THEN 'REJECTED_FUTURE'
        ELSE quality_flag
    END
WHERE is_processed = FALSE
  AND (
      quality_flag = 'ANOMALY'
      OR active_power IS NULL
      OR active_power < 0
      OR collected_at > NOW()
  );
