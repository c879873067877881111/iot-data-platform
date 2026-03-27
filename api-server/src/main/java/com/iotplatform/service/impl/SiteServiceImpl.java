package com.iotplatform.service.impl;

import com.iotplatform.mapper.DeviceMapper;
import com.iotplatform.mapper.SiteMapper;
import com.iotplatform.model.Device;
import com.iotplatform.model.Site;
import com.iotplatform.service.SiteService;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class SiteServiceImpl implements SiteService {

    private final SiteMapper siteMapper;
    private final DeviceMapper deviceMapper;

    public SiteServiceImpl(SiteMapper siteMapper, DeviceMapper deviceMapper) {
        this.siteMapper = siteMapper;
        this.deviceMapper = deviceMapper;
    }

    @Override
    public List<Site> getAllSites() {
        return siteMapper.findAll();
    }

    @Override
    public Site getSiteById(String siteId) {
        return siteMapper.findById(siteId);
    }

    @Override
    public List<Device> getDevicesBySiteId(String siteId) {
        return deviceMapper.findBySiteId(siteId);
    }
}
