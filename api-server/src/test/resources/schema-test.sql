CREATE TABLE dim_sites (
    site_id    VARCHAR(20) PRIMARY KEY,
    site_name  VARCHAR(100) NOT NULL,
    site_type  VARCHAR(20)  NOT NULL,
    region     VARCHAR(20),
    city       VARCHAR(20),
    capacity_kw DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE dim_devices (
    device_id     VARCHAR(30) PRIMARY KEY,
    site_id       VARCHAR(20) NOT NULL,
    device_name   VARCHAR(100) NOT NULL,
    device_type   VARCHAR(30)  NOT NULL,
    rated_power_kw DECIMAL(10,2),
    is_active     BOOLEAN DEFAULT TRUE,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (site_id) REFERENCES dim_sites(site_id)
);

CREATE TABLE fact_daily_energy (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    site_id         VARCHAR(20) NOT NULL,
    device_id       VARCHAR(30) NOT NULL,
    reading_date    DATE NOT NULL,
    total_energy_kwh DECIMAL(12,4),
    peak_demand_kw   DECIMAL(10,2),
    avg_power_kw     DECIMAL(10,2),
    max_power_kw     DECIMAL(10,2),
    min_power_kw     DECIMAL(10,2),
    avg_pf           DECIMAL(6,4),
    avg_voltage      DECIMAL(8,2),
    reading_count    INT
);
