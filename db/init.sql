-- =============================================
-- IoT Data Platform - Database Initialization
-- =============================================

-- Create Airflow database and user
CREATE USER airflow WITH PASSWORD 'airflow';
CREATE DATABASE airflow OWNER airflow;
GRANT ALL PRIVILEGES ON DATABASE airflow TO airflow;

-- Create IoT Platform database and user
CREATE USER iot_user WITH PASSWORD 'iot_pass';
CREATE DATABASE iot_platform OWNER iot_user;
GRANT ALL PRIVILEGES ON DATABASE iot_platform TO iot_user;

-- Connect to iot_platform database
\c iot_platform iot_user

-- =============================================
-- STAGING LAYER
-- =============================================

CREATE TABLE IF NOT EXISTS raw_device_readings (
    id              BIGSERIAL       PRIMARY KEY,
    site_id         VARCHAR(32)     NOT NULL,
    device_id       VARCHAR(64)     NOT NULL,
    collected_at    TIMESTAMP       NOT NULL,
    ingested_at     TIMESTAMP       NOT NULL DEFAULT NOW(),
    voltage_avg     NUMERIC(8,2),
    current_avg     NUMERIC(10,3),
    active_power    NUMERIC(12,2),
    reactive_power  NUMERIC(12,2),
    power_factor    NUMERIC(5,4),
    frequency       NUMERIC(5,2),
    energy_kwh      NUMERIC(14,2),
    demand_kw       NUMERIC(10,2),
    is_processed    BOOLEAN         NOT NULL DEFAULT FALSE,
    quality_flag    VARCHAR(16)     DEFAULT 'RAW'
);

CREATE INDEX idx_raw_collected ON raw_device_readings(collected_at);
CREATE INDEX idx_raw_unprocessed ON raw_device_readings(is_processed) WHERE is_processed = FALSE;
CREATE INDEX idx_raw_site_device ON raw_device_readings(site_id, device_id, collected_at);

-- =============================================
-- DIMENSION TABLES
-- =============================================

CREATE TABLE IF NOT EXISTS dim_sites (
    site_id         VARCHAR(32)     PRIMARY KEY,
    site_name       VARCHAR(128)    NOT NULL,
    site_type       VARCHAR(32)     NOT NULL,
    region          VARCHAR(64),
    city            VARCHAR(64),
    capacity_kw     NUMERIC(10,2),
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dim_devices (
    device_id       VARCHAR(64)     PRIMARY KEY,
    site_id         VARCHAR(32)     NOT NULL REFERENCES dim_sites(site_id),
    device_name     VARCHAR(128)    NOT NULL,
    device_type     VARCHAR(32)     NOT NULL,
    rated_power_kw  NUMERIC(10,2),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- =============================================
-- FACT TABLES
-- =============================================

CREATE TABLE IF NOT EXISTS fact_energy_readings (
    id              BIGSERIAL       PRIMARY KEY,
    site_id         VARCHAR(32)     NOT NULL REFERENCES dim_sites(site_id),
    device_id       VARCHAR(64)     NOT NULL REFERENCES dim_devices(device_id),
    reading_time    TIMESTAMP       NOT NULL,
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
    UNIQUE(site_id, device_id, reading_time)
);

CREATE INDEX idx_fact_readings_time ON fact_energy_readings(site_id, device_id, reading_time);

CREATE TABLE IF NOT EXISTS fact_hourly_energy (
    id              BIGSERIAL       PRIMARY KEY,
    site_id         VARCHAR(32)     NOT NULL REFERENCES dim_sites(site_id),
    device_id       VARCHAR(64)     NOT NULL REFERENCES dim_devices(device_id),
    hour_start      TIMESTAMP       NOT NULL,
    avg_power_kw    NUMERIC(12,2),
    max_power_kw    NUMERIC(12,2),
    min_power_kw    NUMERIC(12,2),
    energy_kwh      NUMERIC(12,4),
    avg_pf          NUMERIC(5,4),
    avg_voltage     NUMERIC(8,2),
    reading_count   INTEGER,
    UNIQUE(site_id, device_id, hour_start)
);

CREATE TABLE IF NOT EXISTS fact_daily_energy (
    id              BIGSERIAL       PRIMARY KEY,
    site_id         VARCHAR(32)     NOT NULL REFERENCES dim_sites(site_id),
    device_id       VARCHAR(64)     NOT NULL REFERENCES dim_devices(device_id),
    reading_date    DATE            NOT NULL,
    total_energy_kwh NUMERIC(14,4),
    peak_demand_kw  NUMERIC(10,2),
    avg_power_kw    NUMERIC(12,2),
    max_power_kw    NUMERIC(12,2),
    min_power_kw    NUMERIC(12,2),
    avg_pf          NUMERIC(5,4),
    avg_voltage     NUMERIC(8,2),
    reading_count   INTEGER,
    UNIQUE(site_id, device_id, reading_date)
);

-- =============================================
-- METADATA TABLES
-- =============================================

CREATE TABLE IF NOT EXISTS data_quality_log (
    id              BIGSERIAL       PRIMARY KEY,
    check_time      TIMESTAMP       NOT NULL DEFAULT NOW(),
    check_type      VARCHAR(32)     NOT NULL,
    site_id         VARCHAR(32),
    device_id       VARCHAR(64),
    status          VARCHAR(16)     NOT NULL,
    metric_value    NUMERIC(14,4),
    threshold_value NUMERIC(14,4),
    message         TEXT
);

-- =============================================
-- SEED DATA
-- =============================================

INSERT INTO dim_sites (site_id, site_name, site_type, region, city, capacity_kw) VALUES
('SITE_TPE_01', '台北信義廠區',     'factory',   '北區', '台北市', 2000.00),
('SITE_TPE_02', '台北內湖辦公室',   'office',    '北區', '台北市',  500.00),
('SITE_HSC_01', '新竹科學園區廠',   'factory',   '北區', '新竹市', 5000.00),
('SITE_TXG_01', '台中工業區廠房',   'factory',   '中區', '台中市', 3000.00),
('SITE_KHH_01', '高雄前鎮倉儲',     'warehouse', '南區', '高雄市', 1000.00),
('SITE_KHH_02', '高雄楠梓加工區',   'factory',   '南區', '高雄市', 4000.00),
('SITE_EXT_01', '外部感測站（PZEM-004T）', 'external', '外部', 'Remote', NULL);

INSERT INTO dim_devices (device_id, site_id, device_name, device_type, rated_power_kw) VALUES
('DEV_TPE01_MAIN', 'SITE_TPE_01', '主電錶',       'main_meter', 2000.00),
('DEV_TPE01_L1',   'SITE_TPE_01', '產線一電錶',   'sub_meter',   800.00),
('DEV_TPE01_L2',   'SITE_TPE_01', '產線二電錶',   'sub_meter',   800.00),
('DEV_TPE01_AC',   'SITE_TPE_01', '空調總錶',     'sub_meter',   400.00),
('DEV_TPE02_MAIN', 'SITE_TPE_02', '主電錶',       'main_meter',  500.00),
('DEV_TPE02_FL3',  'SITE_TPE_02', '3F辦公區',     'sub_meter',   200.00),
('DEV_TPE02_SRV',  'SITE_TPE_02', '機房電錶',     'sub_meter',   150.00),
('DEV_HSC01_MAIN', 'SITE_HSC_01', '主電錶',       'main_meter', 5000.00),
('DEV_HSC01_FAB',  'SITE_HSC_01', '無塵室電錶',   'sub_meter',  2500.00),
('DEV_HSC01_CHL',  'SITE_HSC_01', '冰水主機電錶', 'sub_meter',  1500.00),
('DEV_TXG01_MAIN', 'SITE_TXG_01', '主電錶',       'main_meter', 3000.00),
('DEV_TXG01_CNC',  'SITE_TXG_01', 'CNC加工區',    'sub_meter',  1800.00),
('DEV_KHH01_MAIN', 'SITE_KHH_01', '主電錶',       'main_meter', 1000.00),
('DEV_KHH02_MAIN', 'SITE_KHH_02', '主電錶',       'main_meter', 4000.00),
('DEV_KHH02_SMT',  'SITE_KHH_02', 'SMT產線電錶',  'sub_meter',  2000.00),
('DEV_EXT_PZEM',   'SITE_EXT_01', 'PZEM-004T 電力監測模組', 'iot_sensor', NULL);
