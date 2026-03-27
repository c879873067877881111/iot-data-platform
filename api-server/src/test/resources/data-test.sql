INSERT INTO dim_sites (site_id, site_name, site_type, region, city, capacity_kw) VALUES
('SITE_TPE_01', '台北工廠A', 'factory', '北部', '台北', 500.00),
('SITE_TPE_02', '台北辦公室B', 'office', '北部', '台北', 200.00);

INSERT INTO dim_devices (device_id, site_id, device_name, device_type, rated_power_kw) VALUES
('DEV_TPE_01_MAIN', 'SITE_TPE_01', '主配電盤', 'main_meter', 200.00),
('DEV_TPE_01_HVAC', 'SITE_TPE_01', '空調系統', 'hvac', 150.00),
('DEV_TPE_02_MAIN', 'SITE_TPE_02', '主配電盤', 'main_meter', 100.00);

INSERT INTO fact_daily_energy (site_id, device_id, reading_date, total_energy_kwh, peak_demand_kw, avg_power_kw, max_power_kw, min_power_kw, avg_pf, avg_voltage, reading_count) VALUES
('SITE_TPE_01', 'DEV_TPE_01_MAIN', '2026-03-27', 480.5000, 25.30, 20.02, 25.30, 12.10, 0.9200, 220.50, 1440),
('SITE_TPE_01', 'DEV_TPE_01_HVAC', '2026-03-27', 360.2000, 18.50, 15.01, 18.50, 8.20, 0.8800, 219.80, 1440);
