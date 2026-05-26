-- =============================================
-- IoT Data Platform - Schema (iot_platform DB)
-- =============================================
-- 這支檔案「只」定義 iot_platform DB 的 schema，不包含 user / database 建立。
-- user / database bootstrap 走 db/01-create-users.sh（帳密從 .env 來）；
-- 那邊建好 iot_user 後會用 `psql -U $IOT_DB_USER -d $IOT_DB_NAME -f` 跑這支。
-- 所以這支的所有 CREATE TABLE / VIEW / FUNCTION ownership 都是 iot_user。
--
-- 重要設計：
--   1. dim 表用 SCD Type 2 + EXCLUDE constraint 硬擋時間區間重疊
--   2. 全部時間欄位用 TIMESTAMPTZ；日級切割用 'Asia/Taipei' 時區
--   3. fact / raw 月分區，UNIQUE 拿掉 site_id（同 device 同時刻不可能在兩 site）
--   4. dim 對下游用 view 暴露當前版本，舊 ETL/API 不用改 SQL

-- btree_gist 給 SCD EXCLUDE 用（natural key WITH = 需要 btree 算子）。
-- PG13+ btree_gist 是 trusted extension，iot_user 作為 DB owner 可直接建。
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =============================================
-- STAGING LAYER (PARTITIONED by month, 保留 90 天意圖)
-- =============================================
-- raw 表月分區：每月一個 partition + DEFAULT 兜底；
-- 保留 90 天的 cleanup 不寫成 function — 等真的要 production 再加 pg_cron。
--
-- ⚠️  PARTITION MAINTENANCE（raw_device_readings + fact_energy_readings 共通）
-- 下方 partition 預建到 2026-12。2027-01-01 起新資料會落到 *_default partition：
-- 功能正常、不會掉資料，但失去 partition pruning 優勢，且擋住 DETACH/ATTACH 維運。
-- 年底前要做（擇一）：
--   1. 手動補 12 個下一年的 partition（CREATE TABLE ... PARTITION OF ... FOR VALUES ...）
--   2. 接 pg_partman 或 pg_cron 排程自動建
-- default partition 是 safety net，沒做不會炸，但會越長越胖。

CREATE TABLE IF NOT EXISTS raw_device_readings (
    id              BIGSERIAL,
    site_id         VARCHAR(32)     NOT NULL,
    device_id       VARCHAR(64)     NOT NULL,
    collected_at    TIMESTAMPTZ     NOT NULL,
    ingested_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    voltage_avg     NUMERIC(8,2),
    current_avg     NUMERIC(10,3),
    active_power    NUMERIC(12,2),
    reactive_power  NUMERIC(12,2),
    power_factor    NUMERIC(5,4),
    frequency       NUMERIC(5,2),
    energy_kwh      NUMERIC(14,2),
    demand_kw       NUMERIC(10,2),
    is_processed    BOOLEAN         NOT NULL DEFAULT FALSE,
    quality_flag    VARCHAR(32)     DEFAULT 'RAW',
    PRIMARY KEY (id, collected_at)         -- partition key 必須在 PK 內
) PARTITION BY RANGE (collected_at);

-- 預建 2026-01 ~ 2026-12 + DEFAULT
CREATE TABLE raw_device_readings_2026_01 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE raw_device_readings_2026_02 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE raw_device_readings_2026_03 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE raw_device_readings_2026_04 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE raw_device_readings_2026_05 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE raw_device_readings_2026_06 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE raw_device_readings_2026_07 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE raw_device_readings_2026_08 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE raw_device_readings_2026_09 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE raw_device_readings_2026_10 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE raw_device_readings_2026_11 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE raw_device_readings_2026_12 PARTITION OF raw_device_readings FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE raw_device_readings_default  PARTITION OF raw_device_readings DEFAULT;

CREATE INDEX idx_raw_collected ON raw_device_readings(collected_at);
CREATE INDEX idx_raw_unprocessed ON raw_device_readings(is_processed) WHERE is_processed = FALSE;
CREATE INDEX idx_raw_site_device ON raw_device_readings(site_id, device_id, collected_at);

-- =============================================
-- DIMENSION TABLES (SCD TYPE 2)
-- =============================================
-- 設計決策：
--   1. surrogate key (device_sk / site_sk) 當 PK
--   2. EXCLUDE constraint 硬擋同一 natural key 的時間區間重疊 — 比 UNIQUE 更嚴格
--   3. 對下游用 view 暴露「當前版本」，舊 ETL/API 不用改 SQL
--   4. fact 表的 FK 拿掉 — IoT 高頻寫入用 FK 是 anti-pattern；用 ETL 保證一致性
--   5. metadata 欄位 change_reason/changed_by/version_number/updated_at 追責用

CREATE TABLE IF NOT EXISTS dim_sites_scd (
    site_sk         BIGSERIAL       PRIMARY KEY,
    site_id         VARCHAR(32)     NOT NULL,              -- natural key
    site_name       VARCHAR(128)    NOT NULL,
    site_type       VARCHAR(32)     NOT NULL,
    region          VARCHAR(64),
    city            VARCHAR(64),
    capacity_kw     NUMERIC(10,2),
    effective_from  DATE            NOT NULL,
    effective_to    DATE,                                  -- NULL = 當前生效中
    is_current      BOOLEAN         NOT NULL DEFAULT TRUE,
    version_number  SMALLINT        NOT NULL DEFAULT 1,    -- 同 site_id 的第幾版
    change_reason   VARCHAR(64),                           -- 'site_rename' / 'capacity_upgrade' / NULL=initial
    changed_by      VARCHAR(64),                           -- 工程師 / 系統 ID
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- 硬約束：同 site_id 的時間區間絕不重疊（含端點）
    EXCLUDE USING gist (
        site_id WITH =,
        daterange(effective_from, COALESCE(effective_to, 'infinity'::date), '[]') WITH &&
    )
);

CREATE INDEX idx_sites_scd_current ON dim_sites_scd(site_id) WHERE is_current = TRUE;
CREATE INDEX idx_sites_scd_range ON dim_sites_scd USING gist (
    site_id, daterange(effective_from, COALESCE(effective_to, 'infinity'::date), '[]')
);

CREATE TABLE IF NOT EXISTS dim_devices_scd (
    device_sk       BIGSERIAL       PRIMARY KEY,
    device_id       VARCHAR(64)     NOT NULL,              -- natural key
    site_id         VARCHAR(32)     NOT NULL,              -- 設備可能搬廠，故放在版本內
    device_name     VARCHAR(128)    NOT NULL,
    device_type     VARCHAR(32)     NOT NULL,              -- 不可變（trigger 保證）
    rated_power_kw  NUMERIC(10,2),
    -- 電壓規格：放 dim 是因為「每台設備的合理電壓區間不同」是設備規格本身，
    -- 不是 fact data，也不該 hardcode 在 quality_check SQL 裡。
    -- 例：simulator 工業 220V，PZEM-004T 監測家用 110V，硬塞同 threshold 永遠 FAIL。
    -- IEC 60038 工業/家用都規定 ±10% 為合格，這裡放 ±15% 留一點 simulator 噪音空間。
    voltage_nominal       DECIMAL(6,2),                          -- 標稱電壓 V（meter 銘牌規格）
    voltage_tolerance_pct DECIMAL(5,2) NOT NULL DEFAULT 15.00,   -- 容許偏差 %
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    effective_from  DATE            NOT NULL,
    effective_to    DATE,
    is_current      BOOLEAN         NOT NULL DEFAULT TRUE,
    version_number  SMALLINT        NOT NULL DEFAULT 1,
    change_reason   VARCHAR(64),                           -- 'site_migration' / 'spec_change' / 'decommission'
    changed_by      VARCHAR(64),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    EXCLUDE USING gist (
        device_id WITH =,
        daterange(effective_from, COALESCE(effective_to, 'infinity'::date), '[]') WITH &&
    )
);

CREATE INDEX idx_devices_scd_current ON dim_devices_scd(device_id) WHERE is_current = TRUE;
CREATE INDEX idx_devices_scd_range ON dim_devices_scd USING gist (
    device_id, daterange(effective_from, COALESCE(effective_to, 'infinity'::date), '[]')
);

-- =============================================
-- TRIGGER: device_type 不可變
-- =============================================
-- SCD 表追蹤「會變的 attribute」；device_type 是物理屬性（sub_meter 不會變成 main_meter）
-- 加 trigger 擋 — 否則同 device_id 不同版本 device_type 不一致是髒資料，DB 不擋。
-- INSERT + UPDATE 都要擋：apply_device_change() 走 INSERT 新版本不會踩到 UPDATE 分支，
-- 但手動修補時一條 UPDATE 就能繞過 — 所以兩條路徑都鎖。

CREATE OR REPLACE FUNCTION enforce_device_type_immutable()
RETURNS trigger AS $$
DECLARE
    existing_type VARCHAR(32);
BEGIN
    -- UPDATE：如果 device_type 改了就直接擋（NEW vs OLD 比對）
    IF TG_OP = 'UPDATE' AND NEW.device_type <> OLD.device_type THEN
        RAISE EXCEPTION
            'device_type is immutable for device_id=% (sk=%); got %, was %',
            NEW.device_id, NEW.device_sk, NEW.device_type, OLD.device_type;
    END IF;
    -- INSERT：跟同 device_id 的其他版本比對
    IF TG_OP = 'INSERT' THEN
        SELECT device_type INTO existing_type
        FROM dim_devices_scd
        WHERE device_id = NEW.device_id
        LIMIT 1;
        IF existing_type IS NOT NULL AND existing_type <> NEW.device_type THEN
            RAISE EXCEPTION
                'device_type is immutable for device_id=%; got %, expected %',
                NEW.device_id, NEW.device_type, existing_type;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_device_type_immutable
BEFORE INSERT OR UPDATE OF device_type ON dim_devices_scd
FOR EACH ROW EXECUTE FUNCTION enforce_device_type_immutable();

-- updated_at 自動更新（OPERATION 1 SCD update 時 close 舊版本會被觸發）
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_devices_touch_updated BEFORE UPDATE ON dim_devices_scd
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_sites_touch_updated   BEFORE UPDATE ON dim_sites_scd
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- =============================================
-- FUNCTION: apply_device_change — 設備異動 SCD update
-- =============================================
-- 把「close 舊版本 + 開新版本」包成原子操作，避免 caller copy-paste 出錯。
-- 語意：p_new_* 參數傳 NULL = 保留舊值；非 NULL = 用新值。
-- 限制：若真要把欄位「明確改成 NULL」（極少見），請繞過 function 直接 INSERT。
--
-- 範例 1：DEV_TPE01_L1 在 2026-06-01 搬到 SITE_HSC_01，rated_power 從 800 改 900
--   SELECT apply_device_change(
--       'DEV_TPE01_L1',           -- device_id
--       DATE '2026-06-01',        -- effective_date（新版本生效起算日）
--       'SITE_HSC_01',            -- new_site_id（NULL = 不改）
--       900.00,                   -- new_rated_power_kw（NULL = 不改）
--       NULL,                     -- new_is_active（NULL = 不改）
--       NULL,                     -- new_voltage_nominal（NULL = 不改）
--       NULL,                     -- new_voltage_tolerance_pct（NULL = 不改）
--       'site_migration',         -- reason
--       'engineer_eric'           -- changed_by
--   );
--
-- 範例 2：只改 rated_power（其他不動）
--   SELECT apply_device_change(
--       'DEV_HSC01_FAB', DATE '2026-07-01',
--       NULL, 2800.00, NULL, NULL, NULL,
--       'spec_change', 'engineer_eric'
--   );
--
-- 範例 3：停用設備
--   SELECT apply_device_change(
--       'DEV_KHH01_MAIN', DATE '2026-08-15',
--       NULL, NULL, FALSE, NULL, NULL,
--       'decommission', 'ops_team'
--   );
--
-- 範例 4：把家用 110V 監測模組改成寬容度 20%（漂移嚴重）
--   SELECT apply_device_change(
--       'DEV_EXT_PZEM', DATE '2026-09-01',
--       NULL, NULL, NULL, NULL, 20.00,
--       'spec_change', 'engineer_eric'
--   );

CREATE OR REPLACE FUNCTION apply_device_change(
    p_device_id              VARCHAR(64),
    p_effective_date         DATE,
    p_new_site_id            VARCHAR(32),    -- NULL = 保留舊值
    p_new_rated_power        NUMERIC(10,2),  -- NULL = 保留舊值
    p_new_is_active          BOOLEAN,        -- NULL = 保留舊值
    p_new_voltage_nominal    DECIMAL(6,2),   -- NULL = 保留舊值
    p_new_voltage_tolerance  DECIMAL(5,2),   -- NULL = 保留舊值
    p_change_reason          VARCHAR(64),
    p_changed_by             VARCHAR(64)
) RETURNS VOID AS $$
DECLARE
    v_old RECORD;
BEGIN
    -- FOR UPDATE 鎖住舊版本：阻擋並發 apply_device_change 對同 device 競態
    SELECT * INTO v_old
    FROM dim_devices_scd
    WHERE device_id = p_device_id AND is_current = TRUE
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No current row for device_id=%', p_device_id;
    END IF;

    IF p_effective_date <= v_old.effective_from THEN
        RAISE EXCEPTION
            'p_effective_date (%) must be after current version''s effective_from (%)',
            p_effective_date, v_old.effective_from;
    END IF;

    -- a. 關閉舊版本
    UPDATE dim_devices_scd
    SET effective_to  = p_effective_date - INTERVAL '1 day',
        is_current    = FALSE,
        change_reason = p_change_reason,
        changed_by    = p_changed_by
    WHERE device_id = p_device_id AND is_current = TRUE;

    -- b. 開新版本（COALESCE 處理 NULL = 保留舊值）
    INSERT INTO dim_devices_scd (
        device_id, site_id, device_name, device_type, rated_power_kw,
        voltage_nominal, voltage_tolerance_pct, is_active,
        effective_from, effective_to, is_current,
        version_number, change_reason, changed_by
    ) VALUES (
        v_old.device_id,
        COALESCE(p_new_site_id,            v_old.site_id),
        v_old.device_name,
        v_old.device_type,
        COALESCE(p_new_rated_power,        v_old.rated_power_kw),
        COALESCE(p_new_voltage_nominal,    v_old.voltage_nominal),
        COALESCE(p_new_voltage_tolerance,  v_old.voltage_tolerance_pct),
        COALESCE(p_new_is_active,          v_old.is_active),
        p_effective_date,
        NULL,
        TRUE,
        v_old.version_number + 1,
        p_change_reason,
        p_changed_by
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================
-- BACKWARD-COMPAT VIEWS (look like old dim tables)
-- =============================================
-- 99% query 拿當前版本，view 用短名字 — ergonomic 上勝過 _current 後綴。
-- 需歷史版本直接 query dim_devices_scd / dim_sites_scd。

CREATE OR REPLACE VIEW dim_sites AS
SELECT
    site_id, site_name, site_type, region, city, capacity_kw, created_at
FROM dim_sites_scd
WHERE is_current = TRUE;

CREATE OR REPLACE VIEW dim_devices AS
SELECT
    device_id, site_id, device_name, device_type, rated_power_kw,
    voltage_nominal, voltage_tolerance_pct,
    is_active, created_at
FROM dim_devices_scd
WHERE is_current = TRUE;

-- =============================================
-- FACT TABLES (per-minute fact PARTITIONED by month)
-- =============================================
-- 注意：
--   1. 沒 FK — IoT 高頻寫入 FK 會卡 lock + view 也不能當 FK target
--   2. UNIQUE 不含 site_id — 同 device 同時刻不可能在兩 site，site_id 是 denormalized
--   3. PK = (device_id, reading_time)，無 surrogate id（partition table 用 natural PK 更乾淨）

CREATE TABLE IF NOT EXISTS fact_energy_readings (
    site_id         VARCHAR(32)     NOT NULL,
    device_id       VARCHAR(64)     NOT NULL,
    reading_time    TIMESTAMPTZ     NOT NULL,
    voltage_avg     NUMERIC(8,2),
    current_avg     NUMERIC(10,3),
    active_power    NUMERIC(12,2),
    reactive_power  NUMERIC(12,2),
    power_factor    NUMERIC(5,4),
    frequency       NUMERIC(5,2),
    energy_kwh      NUMERIC(14,2),
    energy_delta    NUMERIC(10,4),
    demand_kw       NUMERIC(10,2),
    raw_reading_id  BIGINT,
    PRIMARY KEY (device_id, reading_time)
) PARTITION BY RANGE (reading_time);

CREATE TABLE fact_energy_readings_2026_01 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE fact_energy_readings_2026_02 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE fact_energy_readings_2026_03 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE fact_energy_readings_2026_04 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE fact_energy_readings_2026_05 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_energy_readings_2026_06 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE fact_energy_readings_2026_07 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE fact_energy_readings_2026_08 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE fact_energy_readings_2026_09 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE fact_energy_readings_2026_10 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE fact_energy_readings_2026_11 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE fact_energy_readings_2026_12 PARTITION OF fact_energy_readings FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE fact_energy_readings_default  PARTITION OF fact_energy_readings DEFAULT;

CREATE INDEX idx_fact_readings_site_dev ON fact_energy_readings(site_id, device_id, reading_time);

-- fact_hourly / fact_daily 量小（每設備每小時 / 每天 1 筆），不分區。
CREATE TABLE IF NOT EXISTS fact_hourly_energy (
    device_id       VARCHAR(64)     NOT NULL,
    site_id         VARCHAR(32)     NOT NULL,
    hour_start      TIMESTAMPTZ     NOT NULL,
    avg_power_kw    NUMERIC(12,2),
    max_power_kw    NUMERIC(12,2),
    min_power_kw    NUMERIC(12,2),
    energy_kwh      NUMERIC(12,4),
    avg_pf          NUMERIC(5,4),
    avg_voltage     NUMERIC(8,2),
    reading_count   INTEGER,
    PRIMARY KEY (device_id, hour_start)
);

CREATE INDEX idx_fact_hourly_site ON fact_hourly_energy(site_id, hour_start);

CREATE TABLE IF NOT EXISTS fact_daily_energy (
    device_id        VARCHAR(64)     NOT NULL,
    site_id          VARCHAR(32)     NOT NULL,
    reading_date     DATE            NOT NULL,             -- Asia/Taipei 時區算的日
    total_energy_kwh NUMERIC(14,4),
    peak_demand_kw   NUMERIC(10,2),
    avg_power_kw     NUMERIC(12,2),
    max_power_kw     NUMERIC(12,2),
    min_power_kw     NUMERIC(12,2),
    avg_pf           NUMERIC(5,4),
    avg_voltage      NUMERIC(8,2),
    reading_count    INTEGER,
    PRIMARY KEY (device_id, reading_date)
);

CREATE INDEX idx_fact_daily_site ON fact_daily_energy(site_id, reading_date);

-- =============================================
-- CUMULATIVE TABLE (Module 2 - Fact Modeling pattern)
-- =============================================

CREATE TABLE IF NOT EXISTS device_activity_cumulated (
    device_id            VARCHAR(64) PRIMARY KEY,
    first_seen_date      DATE        NOT NULL,
    last_seen_date       DATE        NOT NULL,
    dates_active         DATE[]      NOT NULL DEFAULT '{}',
    dates_low_pf         DATE[]      NOT NULL DEFAULT '{}',
    dates_anomaly        DATE[]      NOT NULL DEFAULT '{}',
    last_updated         DATE        NOT NULL DEFAULT CURRENT_DATE
);

CREATE INDEX idx_dac_last_seen ON device_activity_cumulated(last_seen_date);

-- =============================================
-- METADATA TABLES
-- =============================================

CREATE TABLE IF NOT EXISTS data_quality_log (
    id              BIGSERIAL       PRIMARY KEY,
    check_time      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    check_type      VARCHAR(32)     NOT NULL,
    site_id         VARCHAR(32),
    device_id       VARCHAR(64),
    status          VARCHAR(16)     NOT NULL,
    metric_value    NUMERIC(14,4),
    threshold_value NUMERIC(14,4),
    message         TEXT
);

CREATE INDEX idx_dql_check_time ON data_quality_log(check_time);
CREATE INDEX idx_dql_device ON data_quality_log(device_id, check_time) WHERE device_id IS NOT NULL;

-- =============================================
-- SEED DATA (SCD Type 2 initial load)
-- =============================================
-- effective_from = '2026-01-01' 表示「追蹤起始日」，並非真實設備安裝日。
-- 真實安裝日請從 OT/廠務系統匯入時補正。

INSERT INTO dim_sites_scd (
    site_id, site_name, site_type, region, city, capacity_kw,
    effective_from, effective_to, is_current, version_number, change_reason, changed_by
) VALUES
('SITE_TPE_01', '台北信義廠區',     'factory',   '北區', '台北市', 2000.00, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('SITE_TPE_02', '台北內湖辦公室',   'office',    '北區', '台北市',  500.00, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('SITE_HSC_01', '新竹科學園區廠',   'factory',   '北區', '新竹市', 5000.00, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('SITE_TXG_01', '台中工業區廠房',   'factory',   '中區', '台中市', 3000.00, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('SITE_KHH_01', '高雄前鎮倉儲',     'warehouse', '南區', '高雄市', 1000.00, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('SITE_KHH_02', '高雄楠梓加工區',   'factory',   '南區', '高雄市', 4000.00, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('SITE_EXT_01', '外部感測站（PZEM-004T）', 'external', '外部', 'Remote', NULL, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init');

-- voltage_nominal：simulator 工業 220V / PZEM 監測家用 110V
-- voltage_tolerance_pct：預設 15.00（schema 層 DEFAULT），這裡顯式寫一次方便日後改不同 device
INSERT INTO dim_devices_scd (
    device_id, site_id, device_name, device_type, rated_power_kw,
    voltage_nominal, voltage_tolerance_pct,
    is_active, effective_from, effective_to, is_current, version_number, change_reason, changed_by
) VALUES
('DEV_TPE01_MAIN', 'SITE_TPE_01', '主電錶',       'main_meter', 2000.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TPE01_L1',   'SITE_TPE_01', '產線一電錶',   'sub_meter',   800.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TPE01_L2',   'SITE_TPE_01', '產線二電錶',   'sub_meter',   800.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TPE01_AC',   'SITE_TPE_01', '空調總錶',     'sub_meter',   400.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TPE02_MAIN', 'SITE_TPE_02', '主電錶',       'main_meter',  500.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TPE02_FL3',  'SITE_TPE_02', '3F辦公區',     'sub_meter',   200.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TPE02_SRV',  'SITE_TPE_02', '機房電錶',     'sub_meter',   150.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_HSC01_MAIN', 'SITE_HSC_01', '主電錶',       'main_meter', 5000.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_HSC01_FAB',  'SITE_HSC_01', '無塵室電錶',   'sub_meter',  2500.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_HSC01_CHL',  'SITE_HSC_01', '冰水主機電錶', 'sub_meter',  1500.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TXG01_MAIN', 'SITE_TXG_01', '主電錶',       'main_meter', 3000.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_TXG01_CNC',  'SITE_TXG_01', 'CNC加工區',    'sub_meter',  1800.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_KHH01_MAIN', 'SITE_KHH_01', '主電錶',       'main_meter', 1000.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_KHH02_MAIN', 'SITE_KHH_02', '主電錶',       'main_meter', 4000.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_KHH02_SMT',  'SITE_KHH_02', 'SMT產線電錶',  'sub_meter',  2000.00, 220.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init'),
('DEV_EXT_PZEM',   'SITE_EXT_01', 'PZEM-004T 電力監測模組', 'iot_sensor', NULL, 110.00, 15.00, TRUE, '2026-01-01', NULL, TRUE, 1, NULL, 'system_init');
