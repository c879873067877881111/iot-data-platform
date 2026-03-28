package com.iotplatform.controller;

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
    public List<Site> listSites() {
        return siteService.getAllSites();
    }

    @GetMapping("/{siteId}")
    public Site getSite(@PathVariable String siteId) {
        Site site = siteService.getSiteById(siteId);
        if (site == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Site not found: " + siteId);
        }
        return site;
    }

    @GetMapping("/{siteId}/devices")
    public List<Device> listDevices(@PathVariable String siteId) {
        return siteService.getDevicesBySiteId(siteId);
    }
}
