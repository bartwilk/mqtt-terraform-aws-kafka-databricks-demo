# Databricks notebook: Bronze to Silver ETL
#
# Reads from iot.bronze.sensor_events via Structured Streaming,
# applies type coercion and sanity-check filters,
# and writes clean events to iot.silver.sensor_clean.

from pyspark.sql.functions import col
from pyspark.sql.types import DoubleType

bronze = spark.readStream.table("iot.bronze.sensor_events")

clean = (
    bronze
    .filter(col("event_time_ts").isNotNull())
    .withColumn("temperature", col("temperature").cast(DoubleType()))
    .withColumn("vibration",   col("vibration").cast(DoubleType()))
    .withColumn("pressure",    col("pressure").cast(DoubleType()))
    .filter(col("temperature").between(-50, 200))
    .filter(col("vibration") >= 0)
    .filter(col("pressure") >= 0)
    .filter(col("device_id").isNotNull())
)

silver_table = "iot.silver.sensor_clean"
checkpoint = "/mnt/checkpoints/iot/silver/sensor_clean"

(
    clean.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", checkpoint)
    .trigger(availableNow=True)
    .toTable(silver_table)
)
