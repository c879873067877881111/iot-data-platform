"""Data models for simulated power meter readings."""

from dataclasses import dataclass
from datetime import datetime
from typing import Optional


@dataclass
class DeviceReading:
    site_id: str
    device_id: str
    collected_at: datetime
    voltage_avg: float
    current_avg: float
    active_power: float
    reactive_power: float
    power_factor: float
    frequency: float
    energy_kwh: float
    demand_kw: float
    quality_flag: str = "RAW"


@dataclass
class DeviceSpec:
    device_id: str
    site_id: str
    site_type: str
    rated_power_kw: float
    energy_accumulator: float = 0.0
