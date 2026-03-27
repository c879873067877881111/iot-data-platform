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
import java.util.Collections;
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
    void listSites_returnsWrappedJson() throws Exception {
        Site site = new Site();
        site.setSiteId("SITE_TPE_01");
        site.setSiteName("台北工廠A");
        site.setSiteType("factory");
        when(siteService.getAllSites()).thenReturn(List.of(site));

        mockMvc.perform(get("/api/sites"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code", is(200)))
                .andExpect(jsonPath("$.message", is("success")))
                .andExpect(jsonPath("$.data", hasSize(1)))
                .andExpect(jsonPath("$.data[0].siteId", is("SITE_TPE_01")));
    }

    @Test
    void listSites_empty_returnsEmptyArray() throws Exception {
        when(siteService.getAllSites()).thenReturn(Collections.emptyList());

        mockMvc.perform(get("/api/sites"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code", is(200)))
                .andExpect(jsonPath("$.data", hasSize(0)));
    }

    @Test
    void getSite_found() throws Exception {
        Site site = new Site();
        site.setSiteId("SITE_TPE_01");
        site.setCapacityKw(new BigDecimal("500.00"));
        when(siteService.getSiteById("SITE_TPE_01")).thenReturn(site);

        mockMvc.perform(get("/api/sites/SITE_TPE_01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code", is(200)))
                .andExpect(jsonPath("$.data.siteId", is("SITE_TPE_01")))
                .andExpect(jsonPath("$.data.capacityKw", is(500.00)));
    }

    @Test
    void getSite_notFound_returns404() throws Exception {
        when(siteService.getSiteById("NONEXISTENT")).thenReturn(null);

        mockMvc.perform(get("/api/sites/NONEXISTENT"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code", is(404)))
                .andExpect(jsonPath("$.message", is("Site not found: NONEXISTENT")));
    }

    @Test
    void listDevices_returnsWrappedDevices() throws Exception {
        Device device = new Device();
        device.setDeviceId("DEV_TPE_01_MAIN");
        device.setSiteId("SITE_TPE_01");
        device.setRatedPowerKw(new BigDecimal("200.00"));
        when(siteService.getDevicesBySiteId("SITE_TPE_01")).thenReturn(List.of(device));

        mockMvc.perform(get("/api/sites/SITE_TPE_01/devices"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code", is(200)))
                .andExpect(jsonPath("$.data", hasSize(1)))
                .andExpect(jsonPath("$.data[0].deviceId", is("DEV_TPE_01_MAIN")));
    }
}
