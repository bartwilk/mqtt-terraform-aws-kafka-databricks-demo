# Databricks notebook: Silver to Gold feature aggregation
#
# Reads from iot.silver.sensor_clean via Structured Streaming,
# computes 5-minute rolling metrics per device using watermarking,
# and writes to iot.gold.device_metrics.

from pyspark.sql.functions import window, avg, stddev, max as spark_max
from pyspark.sql import functions as F

silver = (
    spark.readStream
    .table("iot.silver.sensor_clean")
    .withWatermark("event_time_ts", "10 minutes")
)

# 5-minute rolling metrics per device (1-minute slide)
agg = (
    silver
    .groupBy(
        "device_id",
        window("event_time_ts", "5 minutes", "1 minute").alias("w")
    )
    .agg(
        avg("temperature").alias("temp_avg_5m"),
        stddev("temperature").alias("temp_std_5m"),
        avg("vibration").alias("vib_avg_5m"),
        avg("pressure").alias("pressure_avg_5m"),
        spark_max("risk_score").alias("risk_max_5m"),
    )
    .withColumn("window_start", F.col("w.start"))
    .withColumn("window_end",   F.col("w.end"))
    .drop("w")
)

gold_table = "iot.gold.device_metrics"
checkpoint = "/mnt/checkpoints/iot/gold/device_metrics"

(
    agg.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", checkpoint)
    .trigger(availableNow=True)
    .toTable(gold_table)
)
