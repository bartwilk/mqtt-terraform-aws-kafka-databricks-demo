import json
import logging
import os
import signal
import threading
import time
from typing import Any, Dict

from confluent_kafka import Consumer, Producer, KafkaError
from fastapi import FastAPI
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("iot-processor")

KAFKA_BOOTSTRAP_SERVERS = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
IN_TOPIC  = os.environ.get("KAFKA_IN_TOPIC", "iot_raw")
OUT_TOPIC = os.environ.get("KAFKA_OUT_TOPIC", "iot_enriched")

common_conf = {
    "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
    "security.protocol": "SASL_SSL",
    "sasl.mechanism": "SCRAM-SHA-512",
    "sasl.username": os.environ["KAFKA_USERNAME"],
    "sasl.password": os.environ["KAFKA_PASSWORD"],
}

consumer = Consumer({
    **common_conf,
    "group.id": os.environ.get("KAFKA_GROUP_ID", "iot-processor"),
    "auto.offset.reset": "latest",
})
producer = Producer(common_conf)

# ---------------------------------------------------------------------------
# Shutdown coordination
# ---------------------------------------------------------------------------

_shutdown = threading.Event()


def _handle_signal(signum, _frame):
    log.info("Received signal %s, shutting down gracefully", signum)
    _shutdown.set()


# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------

health_app = FastAPI()
_healthy = False


@health_app.get("/healthz")
def healthz():
    if _healthy:
        return {"status": "ok"}
    return JSONResponse({"status": "starting"}, status_code=503)


# ---------------------------------------------------------------------------
# Business logic
# ---------------------------------------------------------------------------

TEMP_THRESHOLD = 80.0
TEMP_SCALE = 40.0
VIB_SCALE = 10.0


def normalize_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Simple schema enforcement + enrichment.
    Expected input:
    {
      "device_id": "...",
      "ts": "...",
      "temperature": ...,
      "vibration": ...,
      "pressure": ...
    }
    """
    device_id = event.get("device_id")
    ts        = event.get("ts")

    if not device_id or not ts:
        raise ValueError("Missing device_id or ts")

    temperature = float(event.get("temperature", 0.0))
    vibration   = float(event.get("vibration", 0.0))
    pressure    = float(event.get("pressure", 0.0))

    risk_score = min(
        1.0,
        (max(0, temperature - TEMP_THRESHOLD) / TEMP_SCALE) + (vibration / VIB_SCALE),
    )

    return {
        "device_id": device_id,
        "event_time": ts,
        "temperature": temperature,
        "vibration": vibration,
        "pressure": pressure,
        "risk_score": risk_score,
        "ingest_source": "eks-iot-processor",
    }


def main_loop():
    global _healthy
    consumer.subscribe([IN_TOPIC])
    log.info("Starting consumer loop; reading from %s", IN_TOPIC)

    _healthy = True

    while not _shutdown.is_set():
        msg = consumer.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() != KafkaError._PARTITION_EOF:
                log.error("Kafka error: %s", msg.error())
            continue

        try:
            payload = msg.value().decode("utf-8")
            event = json.loads(payload)

            enriched = normalize_event(event)
            producer.produce(OUT_TOPIC, json.dumps(enriched).encode("utf-8"))
        except Exception as e:
            log.exception("Failed to process message: %s", e)

        producer.poll(0)

    _healthy = False
    log.info("Flushing producer...")
    producer.flush(timeout=10)
    consumer.close()
    log.info("Shutdown complete")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # Start health endpoint in a daemon thread
    import uvicorn
    server_thread = threading.Thread(
        target=uvicorn.run,
        args=(health_app,),
        kwargs={"host": "0.0.0.0", "port": 8080, "log_level": "warning"},
        daemon=True,
    )
    server_thread.start()

    main_loop()
