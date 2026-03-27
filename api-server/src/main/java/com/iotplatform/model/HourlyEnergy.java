package com.iotplatform.model;

import java.math.BigDecimal;
import java.time.LocalDateTime;

public class HourlyEnergy {
    private Long id;
    private String siteId;
    private String deviceId;
    private LocalDateTime hourStart;
    private BigDecimal avgPowerKw;
    private BigDecimal maxPowerKw;
    private BigDecimal minPowerKw;
    private BigDecimal energyKwh;
    private BigDecimal avgPf;
    private BigDecimal avgVoltage;
    private Integer readingCount;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }
    public String getDeviceId() { return deviceId; }
    public void setDeviceId(String deviceId) { this.deviceId = deviceId; }
    public LocalDateTime getHourStart() { return hourStart; }
    public void setHourStart(LocalDateTime hourStart) { this.hourStart = hourStart; }
    public BigDecimal getAvgPowerKw() { return avgPowerKw; }
    public void setAvgPowerKw(BigDecimal avgPowerKw) { this.avgPowerKw = avgPowerKw; }
    public BigDecimal getMaxPowerKw() { return maxPowerKw; }
    public void setMaxPowerKw(BigDecimal maxPowerKw) { this.maxPowerKw = maxPowerKw; }
    public BigDecimal getMinPowerKw() { return minPowerKw; }
    public void setMinPowerKw(BigDecimal minPowerKw) { this.minPowerKw = minPowerKw; }
    public BigDecimal getEnergyKwh() { return energyKwh; }
    public void setEnergyKwh(BigDecimal energyKwh) { this.energyKwh = energyKwh; }
    public BigDecimal getAvgPf() { return avgPf; }
    public void setAvgPf(BigDecimal avgPf) { this.avgPf = avgPf; }
    public BigDecimal getAvgVoltage() { return avgVoltage; }
    public void setAvgVoltage(BigDecimal avgVoltage) { this.avgVoltage = avgVoltage; }
    public Integer getReadingCount() { return readingCount; }
    public void setReadingCount(Integer readingCount) { this.readingCount = readingCount; }
}
