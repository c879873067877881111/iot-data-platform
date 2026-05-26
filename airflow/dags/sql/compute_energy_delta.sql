-- Step 2：用 LAG 計算「這一分鐘相對上一分鐘多用了多少電」（energy_delta）
--
-- 為什麼要算 delta：energy_kwh 是電表累計值（只會一直增加），
--                   要算「這分鐘的用電量」就得用「本期累計 - 上期累計」。
-- LAG 視窗函數  ：PARTITION BY device_id（**不**帶 site_id）。fact PK 就是 (device_id, reading_time)，
--                  device 搬廠（SCD 設計允許跨時段不同 site）時，delta 應該跨 site 連續算，
--                  不該被搬廠那一刻切斷。
-- 窗口 3 天     ：跟 aggregate_hourly / aggregate_daily 對稱，fresh start 後 backfill
--                  的 3 天歷史一次補完。`energy_delta IS NULL` 過濾保證重跑不會重算。
-- 過濾條件      ：
--   - energy_delta IS NULL  → 只算還沒算過的，已算過的不重算（讓窗口拉大也不會重複工）
--   - delta IS NOT NULL     → 第一筆沒有「上一筆」，LAG 回傳 NULL，跳過
--   - delta >= 0            → 電表計數應該只增不減，負值代表電表重置或異常，先不寫入
--
-- Partition pruning：外層 WHERE 必須**顯式**補常量範圍 `f.reading_time > NOW() - INTERVAL '3 days'`。
--                    僅靠 `f.reading_time = sub.reading_time` 是 dynamic join key，planner
--                    不保證 prune，會去掃所有歷史 partition（CLAUDE.md 架構約束）。

UPDATE fact_energy_readings f
SET energy_delta = sub.delta
FROM (
    SELECT device_id,
           reading_time,
           energy_kwh - LAG(energy_kwh) OVER (
               PARTITION BY device_id            -- device 為單位算 delta；搬廠不切開
               ORDER BY reading_time             -- 時間順序，才能取到「上一筆」
           ) AS delta
    FROM fact_energy_readings
    WHERE reading_time > NOW() - INTERVAL '3 days'
) sub
WHERE f.device_id    = sub.device_id
  AND f.reading_time = sub.reading_time
  AND f.reading_time > NOW() - INTERVAL '3 days'   -- 外層 partition pruning（dynamic join key 不夠）
  AND f.energy_delta IS NULL
  AND sub.delta IS NOT NULL
  AND sub.delta >= 0;
