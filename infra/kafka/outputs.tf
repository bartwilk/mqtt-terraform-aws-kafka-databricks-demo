output "kafka_topic_iot_raw_name" {
  value       = kafka_topic.iot_raw.name
  description = "Kafka topic for raw IoT ingestion"
}

output "kafka_topic_iot_enriched_name" {
  value       = kafka_topic.iot_enriched.name
  description = "Kafka topic for enriched events"
}
