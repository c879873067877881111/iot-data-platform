package com.iotplatform.service;

import com.iotplatform.mapper.DeviceMapper;
import com.iotplatform.mapper.SiteMapper;
import com.iotplatform.model.Device;
import com.iotplatform.model.Site;
import com.iotplatform.service.impl.SiteServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SiteServiceTest {

    @Mock
    private SiteMapper siteMapper;

    @Mock
    private DeviceMapper deviceMapper;

    private SiteService siteService;

    @BeforeEach
    void setUp() {
        siteService = new SiteServiceImpl(siteMapper, deviceMapper);
    }

    @Test
    void getAllSites_returnsList() {
        Site site = new Site();
        site.setSiteId("SITE_TPE_01");
        site.setSiteName("台北工廠A");
        when(siteMapper.findAll()).thenReturn(List.of(site));

        List<Site> result = siteService.getAllSites();

        assertEquals(1, result.size());
        assertEquals("SITE_TPE_01", result.get(0).getSiteId());
        verify(siteMapper).findAll();
    }

    @Test
    void getAllSites_emptyList() {
        when(siteMapper.findAll()).thenReturn(Collections.emptyList());

        List<Site> result = siteService.getAllSites();

        assertTrue(result.isEmpty());
    }

    @Test
    void getSiteById_found() {
        Site site = new Site();
        site.setSiteId("SITE_TPE_01");
        site.setCapacityKw(new BigDecimal("500.00"));
        when(siteMapper.findById("SITE_TPE_01")).thenReturn(site);

        Site result = siteService.getSiteById("SITE_TPE_01");

        assertNotNull(result);
        assertEquals("SITE_TPE_01", result.getSiteId());
    }

    @Test
    void getSiteById_notFound() {
        when(siteMapper.findById("NONEXISTENT")).thenReturn(null);

        Site result = siteService.getSiteById("NONEXISTENT");

        assertNull(result);
    }

    @Test
    void getDevicesBySiteId_returnsList() {
        Device device = new Device();
        device.setDeviceId("DEV_TPE_01_MAIN");
        device.setSiteId("SITE_TPE_01");
        when(deviceMapper.findBySiteId("SITE_TPE_01")).thenReturn(List.of(device));

        List<Device> result = siteService.getDevicesBySiteId("SITE_TPE_01");

        assertEquals(1, result.size());
        assertEquals("DEV_TPE_01_MAIN", result.get(0).getDeviceId());
    }

    @Test
    void getDevicesBySiteId_emptyList() {
        when(deviceMapper.findBySiteId("SITE_NONE")).thenReturn(Collections.emptyList());

        List<Device> result = siteService.getDevicesBySiteId("SITE_NONE");

        assertTrue(result.isEmpty());
    }
}
