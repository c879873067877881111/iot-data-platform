package com.iotplatform.controller;

import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.model.DailyEnergy;
import com.iotplatform.model.HourlyEnergy;
import com.iotplatform.service.EnergyService;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;

import static org.hamcrest.Matchers.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(EnergyController.class)
class EnergyControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private EnergyService energyService;

    @Test
    void getHourly_returnsJson() throws Exception {
        HourlyEnergy hourly = new HourlyEnergy();
        hourly.setSiteId("SITE_TPE_01");
        hourly.setEnergyKwh(new BigDecimal("12.50"));
        when(energyService.getHourlyEnergy(any(EnergyQueryParam.class)))
                .thenReturn(List.of(hourly));

        mockMvc.perform(get("/api/energy/hourly").param("siteId", "SITE_TPE_01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].energyKwh", is(12.50)));
    }

    @Test
    void getDaily_verifiesParamBinding() throws Exception {
        DailyEnergy daily = new DailyEnergy();
        daily.setSiteId("SITE_TPE_01");
        daily.setTotalEnergyKwh(new BigDecimal("300.00"));
        daily.setReadingDate(LocalDate.of(2026, 3, 27));
        when(energyService.getDailyEnergy(any(EnergyQueryParam.class)))
                .thenReturn(List.of(daily));

        mockMvc.perform(get("/api/energy/daily")
                        .param("siteId", "SITE_TPE_01")
                        .param("startDate", "2026-03-25")
                        .param("endDate", "2026-03-28"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].totalEnergyKwh", is(300.00)));

        ArgumentCaptor<EnergyQueryParam> captor = ArgumentCaptor.forClass(EnergyQueryParam.class);
        verify(energyService).getDailyEnergy(captor.capture());
        assertEquals("SITE_TPE_01", captor.getValue().getSiteId());
        assertEquals(LocalDate.of(2026, 3, 25), captor.getValue().getStartDate());
        assertEquals(LocalDate.of(2026, 3, 28), captor.getValue().getEndDate());
    }

    @Test
    void getSummary_returnsSummary() throws Exception {
        SiteDailySummary summary = new SiteDailySummary();
        summary.setSiteId("SITE_TPE_01");
        summary.setSiteName("台北工廠A");
        summary.setDeviceCount(3);
        when(energyService.getSiteDailySummary(any(EnergyQueryParam.class)))
                .thenReturn(List.of(summary));

        mockMvc.perform(get("/api/energy/summary").param("siteId", "SITE_TPE_01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].deviceCount", is(3)));
    }

    @Test
    void getHourly_noParams_returnsEmptyArray() throws Exception {
        when(energyService.getHourlyEnergy(any(EnergyQueryParam.class)))
                .thenReturn(List.of());

        mockMvc.perform(get("/api/energy/hourly"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(0)));
    }
}
