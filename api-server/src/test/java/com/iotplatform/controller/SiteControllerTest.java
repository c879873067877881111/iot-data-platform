package com.iotplatform.controller;

import com.iotplatform.model.Device;
import com.iotplatform.model.Site;
import com.iotplatform.service.SiteService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.List;

import static org.hamcrest.Matchers.*;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(SiteController.class)
class SiteControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private SiteService siteService;

    @Test
    void listSites_returnsJson() throws Exception {
        Site site = new Site();
        site.setSiteId("SITE_TPE_01");
        site.setSiteName("台北工廠A");
        site.setSiteType("factory");
        when(siteService.getAllSites()).thenReturn(List.of(site));

        mockMvc.perform(get("/api/sites"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].siteId", is("SITE_TPE_01")));
    }

    @Test
    void getSite_returnsDetail() throws Exception {
        Site site = new Site();
        site.setSiteId("SITE_TPE_01");
        site.setCapacityKw(new BigDecimal("500.00"));
        when(siteService.getSiteById("SITE_TPE_01")).thenReturn(site);

        mockMvc.perform(get("/api/sites/SITE_TPE_01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.siteId", is("SITE_TPE_01")))
                .andExpect(jsonPath("$.capacityKw", is(500.00)));
    }

    @Test
    void listDevices_returnsDevices() throws Exception {
        Device device = new Device();
        device.setDeviceId("DEV_TPE_01_MAIN");
        device.setSiteId("SITE_TPE_01");
        device.setRatedPowerKw(new BigDecimal("200.00"));
        when(siteService.getDevicesBySiteId("SITE_TPE_01")).thenReturn(List.of(device));

        mockMvc.perform(get("/api/sites/SITE_TPE_01/devices"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].deviceId", is("DEV_TPE_01_MAIN")));
    }
}
