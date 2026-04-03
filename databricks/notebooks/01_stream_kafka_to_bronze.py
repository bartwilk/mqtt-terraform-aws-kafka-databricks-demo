# Databricks notebook: Stream Kafka (iot_enriched) to bronze Delta table
#
# Reads enriched IoT events from MSK via Kafka connector and writes to
# iot.bronze.sensor_events using Structured Streaming.

from pyspark.sql.functions import col, from_json, current_timestamp
from pyspark.sql.types import (
    StructType, StructField, StringType, DoubleType, TimestampType
)

kafka_servers = dbutils.secrets.get("msk", "bootstrap_servers")
topic = "iot_enriched"

schema = StructType([
    StructField("device_id",     StringType(),  False),
    StructField("event_time",    StringType(),  False),
    StructField("temperature",   DoubleType(),  True),
    StructField("vibration",     DoubleType(),  True),
    StructField("pressure",      DoubleType(),  True),
    StructField("risk_score",    DoubleType(),  True),
    StructField("ingest_source", StringType(),  True),
])

kafka_options = {
    "kafka.bootstrap.servers": kafka_servers,
    "kafka.sasl.mechanism": "AWS_MSK_IAM",
    "kafka.security.protocol": "SASL_SSL",
    "kafka.sasl.jaas.config":
        "shadedmskiam.software.amazon.msk.auth.iam.IAMLoginModule required;",
    "kafka.sasl.client.callback.handler.class":
        "shadedmskiam.software.amazon.msk.auth.iam.IAMClientCallbackHandler",
    "subscribe": topic,
    "startingOffsets": "latest",
}

raw = (
    spark.readStream
    .format("kafka")
    .options(**kafka_options)
    .load()
)

parsed = (
    raw.selectExpr("CAST(value AS STRING) as json_str")
       .select(from_json(col("json_str"), schema).alias("data"))
       .select("data.*")
       .withColumn("event_time_ts", col("event_time").cast(TimestampType()))
       .withColumn("ingest_ts", current_timestamp())
)

bronze_table = "iot.bronze.sensor_events"
checkpoint = "/Volumes/iot/bronze/checkpoints/sensor_events"

(
    parsed
    .writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", checkpoint)
    .trigger(availableNow=True)
    .toTable(bronze_table)
)
