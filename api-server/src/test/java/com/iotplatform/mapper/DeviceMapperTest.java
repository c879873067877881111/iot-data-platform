package com.iotplatform.mapper;

import com.iotplatform.model.Device;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.boot.test.autoconfigure.MybatisTest;
import org.springframework.beans.factory.annotation.Autowired;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@MybatisTest
class DeviceMapperTest {

    @Autowired
    private DeviceMapper deviceMapper;

    @Test
    void findBySiteId_returnsDevices() {
        List<Device> devices = deviceMapper.findBySiteId("SITE_TPE_01");

        assertEquals(2, devices.size());
        assertEquals("DEV_TPE_01_HVAC", devices.get(0).getDeviceId());
        assertEquals("DEV_TPE_01_MAIN", devices.get(1).getDeviceId());
    }

    @Test
    void findBySiteId_noDevices_returnsEmpty() {
        List<Device> devices = deviceMapper.findBySiteId("SITE_NONE");

        assertTrue(devices.isEmpty());
    }

    @Test
    void findById_found() {
        Device device = deviceMapper.findById("DEV_TPE_01_MAIN");

        assertNotNull(device);
        assertEquals("SITE_TPE_01", device.getSiteId());
        assertEquals("主配電盤", device.getDeviceName());
        assertTrue(device.getIsActive());
    }

    @Test
    void findById_notFound_returnsNull() {
        Device device = deviceMapper.findById("NONEXISTENT");

        assertNull(device);
    }
}
