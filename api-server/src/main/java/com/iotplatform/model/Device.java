package com.iotplatform.model;

import java.math.BigDecimal;
import java.time.LocalDateTime;

public class Device {
    private String deviceId;
    private String siteId;
    private String deviceName;
    private String deviceType;
    private BigDecimal ratedPowerKw;
    private Boolean isActive;
    private LocalDateTime createdAt;

    public String getDeviceId() { return deviceId; }
    public void setDeviceId(String deviceId) { this.deviceId = deviceId; }
    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }
    public String getDeviceName() { return deviceName; }
    public void setDeviceName(String deviceName) { this.deviceName = deviceName; }
    public String getDeviceType() { return deviceType; }
    public void setDeviceType(String deviceType) { this.deviceType = deviceType; }
    public BigDecimal getRatedPowerKw() { return ratedPowerKw; }
    public void setRatedPowerKw(BigDecimal ratedPowerKw) { this.ratedPowerKw = ratedPowerKw; }
    public Boolean getIsActive() { return isActive; }
    public void setIsActive(Boolean isActive) { this.isActive = isActive; }
    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }
}
