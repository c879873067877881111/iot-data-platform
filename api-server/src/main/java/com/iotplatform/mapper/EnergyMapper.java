package com.iotplatform.mapper;

import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.model.DailyEnergy;
import com.iotplatform.model.HourlyEnergy;
import org.apache.ibatis.annotations.Mapper;

import java.util.List;

@Mapper
public interface EnergyMapper {
    List<HourlyEnergy> findHourly(EnergyQueryParam param);
    List<DailyEnergy> findDaily(EnergyQueryParam param);
    List<SiteDailySummary> findSiteDailySummary(EnergyQueryParam param);
}
