package com.iotplatform.controller;

import com.iotplatform.dto.ApiResponse;
import com.iotplatform.model.Device;
import com.iotplatform.model.Site;
import com.iotplatform.service.SiteService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/api/sites")
public class SiteController {

    private final SiteService siteService;

    public SiteController(SiteService siteService) {
        this.siteService = siteService;
    }

    @GetMapping
    public ApiResponse<List<Site>> listSites() {
        return ApiResponse.ok(siteService.getAllSites());
    }

    @GetMapping("/{siteId}")
    public ApiResponse<Site> getSite(@PathVariable String siteId) {
        Site site = siteService.getSiteById(siteId);
        if (site == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Site not found: " + siteId);
        }
        return ApiResponse.ok(site);
    }

    @GetMapping("/{siteId}/devices")
    public ApiResponse<List<Device>> listDevices(@PathVariable String siteId) {
        return ApiResponse.ok(siteService.getDevicesBySiteId(siteId));
    }
}
