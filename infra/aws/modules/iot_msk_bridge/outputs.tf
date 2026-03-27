output "iot_topic_rule_name" {
  description = "Name of the AWS IoT topic rule that bridges MQTT to MSK"
  value       = aws_iot_topic_rule.iot_to_msk.name
}

output "iot_topic_rule_arn" {
  description = "ARN of the AWS IoT topic rule that bridges MQTT to MSK"
  value       = aws_iot_topic_rule.iot_to_msk.arn
}

output "iot_topic_rule_destination_arn" {
  description = "ARN of the IoT VPC destination used by the Kafka action"
  value       = aws_iot_topic_rule_destination.iot_msk_vpc_dest.arn
}

output "iot_vpc_security_group_id" {
  description = "Security group ID attached to IoT VPC destination ENIs"
  value       = aws_security_group.iot_msk_enis.id
}

output "msk_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing MSK SASL credentials"
  value       = local.kafka_secret_arn
}
