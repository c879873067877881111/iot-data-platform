package com.iotplatform.mapper;

import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.model.DailyEnergy;
import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.boot.test.autoconfigure.MybatisTest;
import org.springframework.beans.factory.annotation.Autowired;

import java.time.LocalDate;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@MybatisTest
class EnergyMapperTest {

    @Autowired
    private EnergyMapper energyMapper;

    @Test
    @Disabled("findHourly XML uses PostgreSQL ::timestamp cast, incompatible with H2")
    void findHourly_requiresPostgreSQL() {
        // Requires Testcontainers + PostgreSQL to test #{startDate}::timestamp
    }

    @Test
    void findDaily_withSiteFilter() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId("SITE_TPE_01");

        List<DailyEnergy> result = energyMapper.findDaily(param);

        assertEquals(2, result.size());
        result.forEach(r -> assertEquals("SITE_TPE_01", r.getSiteId()));
    }

    @Test
    void findDaily_withDateRange() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setStartDate(LocalDate.of(2026, 3, 27));
        param.setEndDate(LocalDate.of(2026, 3, 27));

        List<DailyEnergy> result = energyMapper.findDaily(param);

        assertEquals(2, result.size());
    }

    @Test
    void findDaily_noMatch_returnsEmpty() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId("NONEXISTENT");

        List<DailyEnergy> result = energyMapper.findDaily(param);

        assertTrue(result.isEmpty());
    }

    @Test
    void findSiteDailySummary_aggregatesCorrectly() {
        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId("SITE_TPE_01");

        List<SiteDailySummary> result = energyMapper.findSiteDailySummary(param);

        assertEquals(1, result.size());
        SiteDailySummary summary = result.get(0);
        assertEquals("SITE_TPE_01", summary.getSiteId());
        assertEquals("台北工廠A", summary.getSiteName());
        assertEquals(2, summary.getDeviceCount());
    }
}
