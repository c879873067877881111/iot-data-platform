package com.iotplatform.model;

import java.math.BigDecimal;
import java.time.LocalDateTime;

public class Site {
    private String siteId;
    private String siteName;
    private String siteType;
    private String region;
    private String city;
    private BigDecimal capacityKw;
    private LocalDateTime createdAt;

    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }
    public String getSiteName() { return siteName; }
    public void setSiteName(String siteName) { this.siteName = siteName; }
    public String getSiteType() { return siteType; }
    public void setSiteType(String siteType) { this.siteType = siteType; }
    public String getRegion() { return region; }
    public void setRegion(String region) { this.region = region; }
    public String getCity() { return city; }
    public void setCity(String city) { this.city = city; }
    public BigDecimal getCapacityKw() { return capacityKw; }
    public void setCapacityKw(BigDecimal capacityKw) { this.capacityKw = capacityKw; }
    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }
}
