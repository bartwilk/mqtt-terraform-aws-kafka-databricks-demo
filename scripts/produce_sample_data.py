#!/usr/bin/env python3
"""
Produce sample IoT events to the iot_raw Kafka topic.

Usage:
    export KAFKA_BOOTSTRAP_SERVERS="broker1:9098,broker2:9098"
    export KAFKA_SASL_USERNAME="..."
    export KAFKA_SASL_PASSWORD="..."
    python scripts/produce_sample_data.py [--count 100] [--topic iot_raw]

Generates realistic sensor readings with varying risk profiles:
  - Normal operation (70%): temp 20-75, vibration 0-3
  - Elevated risk  (20%): temp 80-110, vibration 3-7
  - High risk      (10%): temp 110-150, vibration 7-15

Messages use the raw IoT schema (device_id, ts, temperature, vibration,
pressure). The EKS iot-processor enriches them with risk_score and forwards
to iot_enriched.
"""

import argparse
import json
import os
import random
import sys
import time
from datetime import datetime, timezone

from confluent_kafka import Producer

DEVICE_IDS = [f"sensor-{i:03d}" for i in range(1, 21)]


def generate_event() -> dict:
    roll = random.random()
    if roll < 0.70:
        temp = random.uniform(20.0, 75.0)
        vib = random.uniform(0.0, 3.0)
    elif roll < 0.90:
        temp = random.uniform(80.0, 110.0)
        vib = random.uniform(3.0, 7.0)
    else:
        temp = random.uniform(110.0, 150.0)
        vib = random.uniform(7.0, 15.0)

    pressure = random.uniform(95.0, 105.0)
    device_id = random.choice(DEVICE_IDS)

    return {
        "device_id": device_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "temperature": round(temp, 2),
        "vibration": round(vib, 2),
        "pressure": round(pressure, 2),
    }


def delivery_report(err, msg):
    if err:
        print(f"  FAILED: {err}", file=sys.stderr)
    else:
        print(f"  -> {msg.topic()} [{msg.partition()}] @ {msg.offset()}")


def main():
    parser = argparse.ArgumentParser(description="Produce sample IoT events to Kafka")
    parser.add_argument("--count", type=int, default=100, help="Number of events (default: 100)")
    parser.add_argument("--topic", default="iot_raw", help="Kafka topic (default: iot_raw)")
    parser.add_argument("--delay", type=float, default=0.1, help="Seconds between messages (default: 0.1)")
    args = parser.parse_args()

    bootstrap = os.environ.get("KAFKA_BOOTSTRAP_SERVERS")
    username = os.environ.get("KAFKA_SASL_USERNAME")
    password = os.environ.get("KAFKA_SASL_PASSWORD")

    if not bootstrap:
        print("Error: KAFKA_BOOTSTRAP_SERVERS not set", file=sys.stderr)
        sys.exit(1)

    conf = {
        "bootstrap.servers": bootstrap,
        "client.id": "sample-data-producer",
    }

    if username and password:
        conf.update({
            "security.protocol": "SASL_SSL",
            "sasl.mechanism": "SCRAM-SHA-512",
            "sasl.username": username,
            "sasl.password": password,
        })

    producer = Producer(conf)

    print(f"Producing {args.count} events to '{args.topic}' ...")
    for i in range(args.count):
        event = generate_event()
        producer.produce(
            args.topic,
            key=event["device_id"],
            value=json.dumps(event).encode("utf-8"),
            callback=delivery_report,
        )
        if (i + 1) % 10 == 0:
            producer.flush()
            print(f"  [{i + 1}/{args.count}]")
        if args.delay > 0:
            time.sleep(args.delay)

    producer.flush()
    print(f"Done. {args.count} events produced.")


if __name__ == "__main__":
    main()
