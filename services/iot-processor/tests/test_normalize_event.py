import pytest

# conftest.py patches env + confluent_kafka before this import
from app import normalize_event


# ---------------------------------------------------------------------------
# Happy-path tests
# ---------------------------------------------------------------------------

def test_returns_all_expected_keys():
    event = {"device_id": "dev-1", "ts": "2024-01-01T00:00:00Z",
             "temperature": 25.0, "vibration": 0.5, "pressure": 101.0}
    result = normalize_event(event)
    assert set(result.keys()) == {
        "device_id", "event_time", "temperature", "vibration",
        "pressure", "risk_score", "ingest_source",
    }


def test_passthrough_fields():
    event = {"device_id": "dev-42", "ts": "2024-06-15T12:00:00Z",
             "temperature": 20.0, "vibration": 1.0, "pressure": 99.5}
    result = normalize_event(event)
    assert result["device_id"] == "dev-42"
    assert result["event_time"] == "2024-06-15T12:00:00Z"
    assert result["temperature"] == 20.0
    assert result["vibration"] == 1.0
    assert result["pressure"] == 99.5
    assert result["ingest_source"] == "eks-iot-processor"


def test_risk_score_zero_when_temp_below_threshold_and_no_vibration():
    # temperature <= 80 and vibration == 0 → risk_score == 0
    event = {"device_id": "d", "ts": "t", "temperature": 80.0, "vibration": 0.0, "pressure": 0.0}
    result = normalize_event(event)
    assert result["risk_score"] == 0.0


def test_risk_score_temp_contribution():
    # temperature=120, vibration=0 → (120-80)/40 = 1.0, capped at 1.0
    event = {"device_id": "d", "ts": "t", "temperature": 120.0, "vibration": 0.0, "pressure": 0.0}
    result = normalize_event(event)
    assert result["risk_score"] == pytest.approx(1.0)


def test_risk_score_vibration_contribution():
    # temperature=0 (no temp contribution), vibration=5 → 5/10 = 0.5
    event = {"device_id": "d", "ts": "t", "temperature": 0.0, "vibration": 5.0, "pressure": 0.0}
    result = normalize_event(event)
    assert result["risk_score"] == pytest.approx(0.5)


def test_risk_score_combined_capped_at_one():
    # temperature=200, vibration=100 → would exceed 1.0, must be capped
    event = {"device_id": "d", "ts": "t", "temperature": 200.0, "vibration": 100.0, "pressure": 0.0}
    result = normalize_event(event)
    assert result["risk_score"] == pytest.approx(1.0)


def test_risk_score_never_negative():
    # temperature well below 80 → max(0, ...) floor applies
    event = {"device_id": "d", "ts": "t", "temperature": -100.0, "vibration": 0.0, "pressure": 0.0}
    result = normalize_event(event)
    assert result["risk_score"] >= 0.0


def test_missing_sensor_fields_default_to_zero():
    # temperature/vibration/pressure are optional; should default to 0.0
    event = {"device_id": "d", "ts": "t"}
    result = normalize_event(event)
    assert result["temperature"] == 0.0
    assert result["vibration"] == 0.0
    assert result["pressure"] == 0.0


def test_sensor_values_coerced_from_strings():
    event = {"device_id": "d", "ts": "t",
             "temperature": "25.5", "vibration": "1.5", "pressure": "100.0"}
    result = normalize_event(event)
    assert result["temperature"] == pytest.approx(25.5)
    assert result["vibration"] == pytest.approx(1.5)


# ---------------------------------------------------------------------------
# Validation / error-path tests
# ---------------------------------------------------------------------------

def test_missing_device_id_raises():
    event = {"ts": "2024-01-01T00:00:00Z", "temperature": 20.0}
    with pytest.raises(ValueError, match="device_id"):
        normalize_event(event)


def test_missing_ts_raises():
    event = {"device_id": "dev-1", "temperature": 20.0}
    with pytest.raises(ValueError, match="ts"):
        normalize_event(event)


def test_empty_device_id_raises():
    event = {"device_id": "", "ts": "2024-01-01T00:00:00Z"}
    with pytest.raises(ValueError):
        normalize_event(event)


def test_empty_ts_raises():
    event = {"device_id": "dev-1", "ts": ""}
    with pytest.raises(ValueError):
        normalize_event(event)
