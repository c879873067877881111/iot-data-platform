package com.iotplatform.service.impl;

import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.mapper.EnergyMapper;
import com.iotplatform.model.DailyEnergy;
import com.iotplatform.model.HourlyEnergy;
import com.iotplatform.service.EnergyService;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class EnergyServiceImpl implements EnergyService {

    private final EnergyMapper energyMapper;

    public EnergyServiceImpl(EnergyMapper energyMapper) {
        this.energyMapper = energyMapper;
    }

    @Override
    public List<HourlyEnergy> getHourlyEnergy(EnergyQueryParam param) {
        return energyMapper.findHourly(param);
    }

    @Override
    public List<DailyEnergy> getDailyEnergy(EnergyQueryParam param) {
        return energyMapper.findDaily(param);
    }

    @Override
    public List<SiteDailySummary> getSiteDailySummary(EnergyQueryParam param) {
        return energyMapper.findSiteDailySummary(param);
    }
}
