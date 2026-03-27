package com.iotplatform.controller;

import com.iotplatform.dto.ApiResponse;
import com.iotplatform.dto.EnergyQueryParam;
import com.iotplatform.dto.SiteDailySummary;
import com.iotplatform.model.DailyEnergy;
import com.iotplatform.model.HourlyEnergy;
import com.iotplatform.service.EnergyService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.List;

@RestController
@RequestMapping("/api/energy")
public class EnergyController {

    private final EnergyService energyService;

    public EnergyController(EnergyService energyService) {
        this.energyService = energyService;
    }

    @GetMapping("/hourly")
    public ApiResponse<List<HourlyEnergy>> getHourly(
            @RequestParam(required = false) String siteId,
            @RequestParam(required = false) String deviceId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate startDate,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate endDate) {

        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId(siteId);
        param.setDeviceId(deviceId);
        param.setStartDate(startDate);
        param.setEndDate(endDate);
        return ApiResponse.ok(energyService.getHourlyEnergy(param));
    }

    @GetMapping("/daily")
    public ApiResponse<List<DailyEnergy>> getDaily(
            @RequestParam(required = false) String siteId,
            @RequestParam(required = false) String deviceId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate startDate,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate endDate) {

        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId(siteId);
        param.setDeviceId(deviceId);
        param.setStartDate(startDate);
        param.setEndDate(endDate);
        return ApiResponse.ok(energyService.getDailyEnergy(param));
    }

    @GetMapping("/summary")
    public ApiResponse<List<SiteDailySummary>> getSummary(
            @RequestParam(required = false) String siteId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate startDate,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate endDate) {

        EnergyQueryParam param = new EnergyQueryParam();
        param.setSiteId(siteId);
        param.setStartDate(startDate);
        param.setEndDate(endDate);
        return ApiResponse.ok(energyService.getSiteDailySummary(param));
    }
}
