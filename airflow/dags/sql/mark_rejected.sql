-- Step 1b：把髒資料貼標籤並標記 processed，避免下次重掃
--
-- 為什麼要這一步：deduplicate_raw.sql 只搬「乾淨」資料到 fact 表，
--                 髒資料若留在 is_processed = FALSE，下次跑 ETL 會被重新檢查（浪費）。
-- 處理對象    ：ANOMALY、NULL power、負值 power、未來時間戳
-- 重複資料    ：已由 deduplicate_raw.sql 的 ROW_NUMBER 挑一筆，其他自然不會進 fact
-- 保留原資料  ：只更新 flag，不刪除，方便日後追查感測器問題

UPDATE raw_device_readings
SET is_processed = TRUE,
    quality_flag = CASE
        -- 順序重要：先檢查既有的 ANOMALY，保留原標籤不被後面覆蓋
        WHEN quality_flag = 'ANOMALY' THEN 'ANOMALY'
        WHEN active_power IS NULL THEN 'REJECTED_NULL' -- 斷線
        WHEN active_power < 0 THEN 'REJECTED_NEGATIVE' -- 接反
        WHEN collected_at > NOW() THEN 'REJECTED_FUTURE' -- 時間飄移
        ELSE quality_flag
    END
WHERE is_processed = FALSE
  AND (
      quality_flag = 'ANOMALY'
      OR active_power IS NULL
      OR active_power < 0
      OR collected_at > NOW()
  );
