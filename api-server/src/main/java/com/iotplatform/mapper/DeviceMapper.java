package com.iotplatform.mapper;

import com.iotplatform.model.Device;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface DeviceMapper {
    List<Device> findBySiteId(@Param("siteId") String siteId);
    Device findById(@Param("deviceId") String deviceId);
}
