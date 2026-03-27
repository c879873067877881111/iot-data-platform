package com.iotplatform.service;

import com.iotplatform.model.Device;
import com.iotplatform.model.Site;

import java.util.List;

public interface SiteService {
    List<Site> getAllSites();
    Site getSiteById(String siteId);
    List<Device> getDevicesBySiteId(String siteId);
}
