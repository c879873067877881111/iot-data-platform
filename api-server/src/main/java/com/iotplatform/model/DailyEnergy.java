package com.iotplatform.model;

import java.math.BigDecimal;
import java.time.LocalDate;

public class DailyEnergy {
    private Long id;
    private String siteId;
    private String deviceId;
    private LocalDate readingDate;
    private BigDecimal totalEnergyKwh;
    private BigDecimal peakDemandKw;
    private BigDecimal avgPowerKw;
    private BigDecimal maxPowerKw;
    private BigDecimal minPowerKw;
    private BigDecimal avgPf;
    private BigDecimal avgVoltage;
    private Integer readingCount;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }
    public String getDeviceId() { return deviceId; }
    public void setDeviceId(String deviceId) { this.deviceId = deviceId; }
    public LocalDate getReadingDate() { return readingDate; }
    public void setReadingDate(LocalDate readingDate) { this.readingDate = readingDate; }
    public BigDecimal getTotalEnergyKwh() { return totalEnergyKwh; }
    public void setTotalEnergyKwh(BigDecimal totalEnergyKwh) { this.totalEnergyKwh = totalEnergyKwh; }
    public BigDecimal getPeakDemandKw() { return peakDemandKw; }
    public void setPeakDemandKw(BigDecimal peakDemandKw) { this.peakDemandKw = peakDemandKw; }
    public BigDecimal getAvgPowerKw() { return avgPowerKw; }
    public void setAvgPowerKw(BigDecimal avgPowerKw) { this.avgPowerKw = avgPowerKw; }
    public BigDecimal getMaxPowerKw() { return maxPowerKw; }
    public void setMaxPowerKw(BigDecimal maxPowerKw) { this.maxPowerKw = maxPowerKw; }
    public BigDecimal getMinPowerKw() { return minPowerKw; }
    public void setMinPowerKw(BigDecimal minPowerKw) { this.minPowerKw = minPowerKw; }
    public BigDecimal getAvgPf() { return avgPf; }
    public void setAvgPf(BigDecimal avgPf) { this.avgPf = avgPf; }
    public BigDecimal getAvgVoltage() { return avgVoltage; }
    public void setAvgVoltage(BigDecimal avgVoltage) { this.avgVoltage = avgVoltage; }
    public Integer getReadingCount() { return readingCount; }
    public void setReadingCount(Integer readingCount) { this.readingCount = readingCount; }
}
