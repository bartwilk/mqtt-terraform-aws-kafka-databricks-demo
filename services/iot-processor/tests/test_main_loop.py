"""
Tests for main_loop() in app.py.

Strategy: consumer.poll is given a side_effect list so the loop processes
a controlled sequence of messages, then raises _LoopExit (a custom sentinel)
so the infinite while-True can be broken without patching the loop itself.
"""
import json
import sys
from unittest.mock import MagicMock, call, patch

import pytest

# conftest.py already patched env vars and confluent_kafka before this import
import app


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class _LoopExit(Exception):
    """Raised by the last consumer.poll side_effect to break the infinite loop."""


def _make_msg(payload: dict | None = None, *, error=None, raw: bytes | None = None):
    """Return a mock Kafka message."""
    msg = MagicMock()
    msg.error.return_value = error
    if raw is not None:
        msg.value.return_value = raw
    elif payload is not None:
        msg.value.return_value = json.dumps(payload).encode()
    else:
        msg.value.return_value = b"{}"
    return msg


def _good_payload(device_id="dev-1", ts="2024-01-01T00:00:00Z",
                  temperature=25.0, vibration=1.0, pressure=101.0):
    return {
        "device_id": device_id,
        "ts": ts,
        "temperature": temperature,
        "vibration": vibration,
        "pressure": pressure,
    }


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def reset_mocks():
    """Reset consumer and producer mocks before every test."""
    app.consumer.reset_mock()
    app.producer.reset_mock()
    yield


# ---------------------------------------------------------------------------
# Subscription
# ---------------------------------------------------------------------------

def test_subscribes_to_in_topic_on_start():
    app.consumer.poll.side_effect = [_LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    app.consumer.subscribe.assert_called_once_with([app.IN_TOPIC])


# ---------------------------------------------------------------------------
# None poll result (no message available)
# ---------------------------------------------------------------------------

def test_none_poll_result_is_skipped():
    """poll() returning None must not call producer.produce."""
    app.consumer.poll.side_effect = [None, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    app.producer.produce.assert_not_called()


# ---------------------------------------------------------------------------
# Happy-path: valid message processed and forwarded
# ---------------------------------------------------------------------------

def test_valid_message_produces_enriched_event():
    payload = _good_payload(temperature=100.0, vibration=0.0)
    msg = _make_msg(payload)
    app.consumer.poll.side_effect = [msg, _LoopExit]

    with pytest.raises(_LoopExit):
        app.main_loop()

    assert app.producer.produce.call_count == 1
    topic, raw = app.producer.produce.call_args[0]
    assert topic == app.OUT_TOPIC
    enriched = json.loads(raw.decode())
    assert enriched["device_id"] == "dev-1"
    assert enriched["ingest_source"] == "eks-iot-processor"
    # temperature=100 → (100-80)/40 = 0.5
    assert enriched["risk_score"] == pytest.approx(0.5)


def test_producer_poll_called_after_each_message():
    msg = _make_msg(_good_payload())
    app.consumer.poll.side_effect = [msg, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    app.producer.poll.assert_called_with(0)


def test_multiple_valid_messages_all_forwarded():
    msgs = [_make_msg(_good_payload(device_id=f"dev-{i}")) for i in range(3)]
    app.consumer.poll.side_effect = msgs + [_LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    assert app.producer.produce.call_count == 3


# ---------------------------------------------------------------------------
# Kafka error handling
# ---------------------------------------------------------------------------

def test_partition_eof_error_is_silently_skipped():
    from confluent_kafka import KafkaError
    eof_error = MagicMock()
    eof_error.code.return_value = KafkaError._PARTITION_EOF
    msg = _make_msg(error=eof_error)
    app.consumer.poll.side_effect = [msg, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    app.producer.produce.assert_not_called()


def test_non_eof_kafka_error_is_logged_and_skipped(caplog):
    from confluent_kafka import KafkaError
    import logging
    kafka_err = MagicMock()
    kafka_err.code.return_value = KafkaError.UNKNOWN  # not _PARTITION_EOF
    msg = _make_msg(error=kafka_err)
    app.consumer.poll.side_effect = [msg, _LoopExit]
    with caplog.at_level(logging.ERROR, logger="iot-processor"):
        with pytest.raises(_LoopExit):
            app.main_loop()
    app.producer.produce.assert_not_called()
    assert any("Kafka error" in r.message for r in caplog.records)


# ---------------------------------------------------------------------------
# Malformed message handling (exceptions must NOT propagate)
# ---------------------------------------------------------------------------

def test_invalid_json_does_not_crash_loop():
    bad_msg = _make_msg(raw=b"not valid json{{")
    good_msg = _make_msg(_good_payload())
    app.consumer.poll.side_effect = [bad_msg, good_msg, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    # The good message after the bad one must still be forwarded
    assert app.producer.produce.call_count == 1


def test_missing_device_id_does_not_crash_loop():
    bad_msg = _make_msg({"ts": "2024-01-01T00:00:00Z", "temperature": 25.0})
    good_msg = _make_msg(_good_payload())
    app.consumer.poll.side_effect = [bad_msg, good_msg, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    assert app.producer.produce.call_count == 1


def test_non_numeric_sensor_value_does_not_crash_loop(caplog):
    """Coercion via float() will raise ValueError for non-numeric strings."""
    import logging
    bad_msg = _make_msg({"device_id": "d", "ts": "t", "temperature": "hot"})
    app.consumer.poll.side_effect = [bad_msg, _LoopExit]
    with caplog.at_level(logging.ERROR, logger="iot-processor"):
        with pytest.raises(_LoopExit):
            app.main_loop()
    app.producer.produce.assert_not_called()


# ---------------------------------------------------------------------------
# Risk score boundary values (integration: message → produce → enriched)
# ---------------------------------------------------------------------------

def test_risk_score_at_temp_boundary_80_produces_zero():
    msg = _make_msg(_good_payload(temperature=80.0, vibration=0.0))
    app.consumer.poll.side_effect = [msg, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    _, raw = app.producer.produce.call_args[0]
    assert json.loads(raw)["risk_score"] == pytest.approx(0.0)


def test_risk_score_capped_at_one_in_produced_event():
    msg = _make_msg(_good_payload(temperature=200.0, vibration=50.0))
    app.consumer.poll.side_effect = [msg, _LoopExit]
    with pytest.raises(_LoopExit):
        app.main_loop()
    _, raw = app.producer.produce.call_args[0]
    assert json.loads(raw)["risk_score"] == pytest.approx(1.0)
