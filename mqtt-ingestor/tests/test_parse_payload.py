"""parse_payload — 純函式，沒外部依賴，直接 unit test。

我們在 broker / DB 邊界擋掉的事，這裡每一條都要有測試蓋住：
naive timestamp 直接 drop、malformed JSON 不能把整支 service 拖垮。
"""

import json

from ingestor import parse_payload


def _good_payload() -> bytes:
    return json.dumps({
        "site_id": "SITE_TPE_01",
        "device_id": "DEV_TPE01_L1",
        "collected_at": "2026-05-26T10:00:00+08:00",
        "voltage_avg": 220.5,
        "current_avg": 3.21,
        "active_power": 700.0,
        "reactive_power": 50.0,
        "power_factor": 0.95,
        "frequency": 60.0,
        "energy_kwh": 123.456,
        "demand_kw": 700.0,
    }).encode()


def test_happy_path_returns_full_tuple():
    row = parse_payload(_good_payload())
    assert row is not None
    assert row[0] == "SITE_TPE_01"
    assert row[1] == "DEV_TPE01_L1"
    # collected_at 必須是 tz-aware
    assert row[2].tzinfo is not None
    assert row[2].isoformat() == "2026-05-26T10:00:00+08:00"
    # default quality_flag
    assert row[-1] == "RAW"


def test_quality_flag_passthrough():
    """payload 帶 quality_flag 要原樣傳過去（模擬 simulator 的 ANOMALY 注入）。"""
    payload = json.loads(_good_payload())
    payload["quality_flag"] = "ANOMALY"
    row = parse_payload(json.dumps(payload).encode())
    assert row[-1] == "ANOMALY"


def test_naive_timestamp_is_dropped():
    """schema 是 TIMESTAMPTZ，naive datetime 進 DB 會被假設成 server local — 不可靠，直接 drop。"""
    payload = json.loads(_good_payload())
    payload["collected_at"] = "2026-05-26T10:00:00"  # 無 +08:00 / Z
    assert parse_payload(json.dumps(payload).encode()) is None


def test_malformed_json_returns_none():
    """壞 payload 不能讓 service crash —— 整支服務會吃所有設備的訊息，crash 一次全廠停。"""
    assert parse_payload(b"not a json") is None


def test_missing_required_key_returns_none():
    """缺 site_id / device_id / collected_at 都 drop（KeyError）。"""
    payload = json.loads(_good_payload())
    del payload["device_id"]
    assert parse_payload(json.dumps(payload).encode()) is None
