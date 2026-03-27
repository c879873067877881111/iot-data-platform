package com.iotplatform.service;

import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.mapper.EnergyMapper;
import com.iotplatform.model.DailyEnergy;
import com.iotplatform.model.HourlyEnergy;
import com.iotplatform.service.impl.EnergyServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class EnergyServiceTest {

    @Mock
    private EnergyMapper energyMapper;

    private EnergyService energyService;

    @BeforeEach
    void setUp() {
        energyService = new EnergyServiceImpl(energyMapper);
    }

    @Test
    void getHourlyEnergy_withSiteFilter() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId("SITE_TPE_01");

        HourlyEnergy hourly = new HourlyEnergy();
        hourly.setSiteId("SITE_TPE_01");
        hourly.setEnergyKwh(new BigDecimal("12.50"));
        when(energyMapper.findHourly(param)).thenReturn(List.of(hourly));

        List<HourlyEnergy> result = energyService.getHourlyEnergy(param);

        assertEquals(1, result.size());
        assertEquals(new BigDecimal("12.50"), result.get(0).getEnergyKwh());
    }

    @Test
    void getHourlyEnergy_emptyResult() {
        EnergyQueryParam param = new EnergyQueryParam();
        when(energyMapper.findHourly(param)).thenReturn(Collections.emptyList());

        List<HourlyEnergy> result = energyService.getHourlyEnergy(param);

        assertTrue(result.isEmpty());
    }

    @Test
    void getDailyEnergy_withDateRange() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setStartDate(LocalDate.of(2026, 3, 25));
        param.setEndDate(LocalDate.of(2026, 3, 28));

        DailyEnergy daily = new DailyEnergy();
        daily.setTotalEnergyKwh(new BigDecimal("300.00"));
        when(energyMapper.findDaily(param)).thenReturn(List.of(daily));

        List<DailyEnergy> result = energyService.getDailyEnergy(param);

        assertEquals(1, result.size());
        assertEquals(new BigDecimal("300.00"), result.get(0).getTotalEnergyKwh());
    }

    @Test
    void getDailyEnergy_emptyResult() {
        EnergyQueryParam param = new EnergyQueryParam();
        when(energyMapper.findDaily(param)).thenReturn(Collections.emptyList());

        List<DailyEnergy> result = energyService.getDailyEnergy(param);

        assertTrue(result.isEmpty());
    }

    @Test
    void getSiteDailySummary_returnsSummary() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId("SITE_TPE_01");

        SiteDailySummary summary = new SiteDailySummary();
        summary.setSiteId("SITE_TPE_01");
        summary.setSiteName("台北工廠A");
        summary.setDeviceCount(3);
        when(energyMapper.findSiteDailySummary(param)).thenReturn(List.of(summary));

        List<SiteDailySummary> result = energyService.getSiteDailySummary(param);

        assertEquals(1, result.size());
        assertEquals(3, result.get(0).getDeviceCount());
    }

    @Test
    void getSiteDailySummary_emptyResult() {
        EnergyQueryParam param = new EnergyQueryParam();
        when(energyMapper.findSiteDailySummary(param)).thenReturn(Collections.emptyList());

        List<SiteDailySummary> result = energyService.getSiteDailySummary(param);

        assertTrue(result.isEmpty());
    }
}
