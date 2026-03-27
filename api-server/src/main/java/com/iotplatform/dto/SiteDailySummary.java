package com.iotplatform.dto;

import java.math.BigDecimal;
import java.time.LocalDate;

public class SiteDailySummary {
    private String siteId;
    private String siteName;
    private LocalDate readingDate;
    private BigDecimal totalEnergyKwh;
    private BigDecimal peakDemandKw;
    private BigDecimal avgPowerKw;
    private Integer deviceCount;

    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }
    public String getSiteName() { return siteName; }
    public void setSiteName(String siteName) { this.siteName = siteName; }
    public LocalDate getReadingDate() { return readingDate; }
    public void setReadingDate(LocalDate readingDate) { this.readingDate = readingDate; }
    public BigDecimal getTotalEnergyKwh() { return totalEnergyKwh; }
    public void setTotalEnergyKwh(BigDecimal totalEnergyKwh) { this.totalEnergyKwh = totalEnergyKwh; }
    public BigDecimal getPeakDemandKw() { return peakDemandKw; }
    public void setPeakDemandKw(BigDecimal peakDemandKw) { this.peakDemandKw = peakDemandKw; }
    public BigDecimal getAvgPowerKw() { return avgPowerKw; }
    public void setAvgPowerKw(BigDecimal avgPowerKw) { this.avgPowerKw = avgPowerKw; }
    public Integer getDeviceCount() { return deviceCount; }
    public void setDeviceCount(Integer deviceCount) { this.deviceCount = deviceCount; }
}
