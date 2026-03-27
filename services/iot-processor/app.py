import json
import logging
import os
import time
from typing import Any, Dict

from confluent_kafka import Consumer, Producer, KafkaError

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

    risk_score = min(1.0, (max(0, temperature - 80) / 40.0) + (vibration / 10.0))

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
    consumer.subscribe([IN_TOPIC])
    log.info("Starting consumer loop; reading from %s", IN_TOPIC)

    while True:
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

    consumer.close()


if __name__ == "__main__":
    while True:
        try:
            main_loop()
        except Exception:
            log.exception("Fatal error in main loop, restarting in 5 seconds")
            time.sleep(5)
