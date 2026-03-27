variable "project" {
  description = "Project name, used as prefix in resource names"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, stage, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where MSK and IoT ENIs live"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for IoT VPC destination ENIs"
  type        = list(string)
}

variable "msk_bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers string for MSK (from MSK module output bootstrap_brokers_tls)"
  type        = string
}

variable "msk_security_group_id" {
  description = "Security group ID attached to MSK brokers"
  type        = string
}

variable "kafka_topic" {
  description = "Kafka topic name to which IoT Core should publish (e.g. iot_raw)"
  type        = string
}

variable "mqtt_rule_name" {
  description = "Name of the IoT topic rule (must be unique per region/account)"
  type        = string
}

variable "mqtt_rule_description" {
  description = "Description of the IoT Core topic rule"
  type        = string
  default     = "MQTT -> MSK bridge rule"
}

variable "mqtt_sql" {
  description = "IoT SQL query that selects messages from MQTT topics"
  type        = string
  default     = "SELECT * FROM 'sensors/#'"
}

variable "kafka_port" {
  description = "Kafka broker client port (TLS). MSK commonly uses 9094."
  type        = number
  default     = 9094
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}

# ----- Secrets Manager integration -----

variable "create_secret" {
  description = "If true, this module creates a Secrets Manager secret for MSK SASL credentials. If false, existing_secret_arn must be provided."
  type        = bool
  default     = false
}

variable "existing_secret_arn" {
  description = "ARN of an existing Secrets Manager secret containing JSON {\"username\": \"...\", \"password\": \"...\"} for MSK SASL. Used when create_secret = false."
  type        = string
  default     = null
}

variable "secret_name" {
  description = "Name for the secret when create_secret = true. Optional; default derived from project/environment."
  type        = string
  default     = null
}

variable "kafka_username" {
  description = "MSK SASL SCRAM username (only used if create_secret = true)."
  type        = string
  default     = null
  sensitive   = true
}

variable "kafka_password" {
  description = "MSK SASL SCRAM password (only used if create_secret = true)."
  type        = string
  default     = null
  sensitive   = true
}
