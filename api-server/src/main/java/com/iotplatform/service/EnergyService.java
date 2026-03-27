package com.iotplatform.service;

import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.model.DailyEnergy;
import com.iotplatform.model.HourlyEnergy;

import java.util.List;

public interface EnergyService {
    List<HourlyEnergy> getHourlyEnergy(EnergyQueryParam param);
    List<DailyEnergy> getDailyEnergy(EnergyQueryParam param);
    List<SiteDailySummary> getSiteDailySummary(EnergyQueryParam param);
}
