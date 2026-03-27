package com.iotplatform.mapper;

import com.iotplatform.model.Site;
import org.apache.ibatis.annotations.Mapper;

import java.util.List;

@Mapper
public interface SiteMapper {
    List<Site> findAll();
    Site findById(String siteId);
}
