package com.iotplatform.mapper;

import com.iotplatform.model.Site;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.boot.test.autoconfigure.MybatisTest;
import org.springframework.beans.factory.annotation.Autowired;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@MybatisTest
class SiteMapperTest {

    @Autowired
    private SiteMapper siteMapper;

    @Test
    void findAll_returnsAllSites() {
        List<Site> sites = siteMapper.findAll();

        assertEquals(2, sites.size());
        assertEquals("SITE_TPE_01", sites.get(0).getSiteId());
        assertEquals("SITE_TPE_02", sites.get(1).getSiteId());
    }

    @Test
    void findById_found() {
        Site site = siteMapper.findById("SITE_TPE_01");

        assertNotNull(site);
        assertEquals("台北工廠A", site.getSiteName());
        assertEquals("factory", site.getSiteType());
        assertEquals("北部", site.getRegion());
    }

    @Test
    void findById_notFound_returnsNull() {
        Site site = siteMapper.findById("NONEXISTENT");

        assertNull(site);
    }
}
