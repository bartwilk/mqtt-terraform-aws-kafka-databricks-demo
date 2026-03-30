terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    kafka = {
      source  = "Mongey/kafka"
      version = "~> 0.13.1"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region (e.g. us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, stage, prod)"
  type        = string
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "mqtt-iot-pipeline"
}

# Comma-separated SASL/IAM bootstrap brokers from MSK
# e.g. "b-1....amazonaws.com:9098,b-2....amazonaws.com:9098"
variable "kafka_bootstrap_brokers_iam" {
  description = "Comma-separated bootstrap brokers using SASL/IAM for the MSK cluster (bootstrap_brokers_sasl_iam)."
  type        = string
}

variable "iot_producer_principal" {
  description = "Kafka principal for IoT Core producer (e.g. 'User:iot_msk_producer')."
  type        = string
}

variable "eks_processor_principal" {
  description = "Kafka principal for EKS processor app (e.g. 'User:eks_iot_processor')."
  type        = string
}

variable "eks_processor_consumer_group" {
  description = "Consumer group ID used by the EKS processor when consuming from iot_raw."
  type        = string
  default     = "iot-processor"
}

variable "databricks_principal" {
  description = "Kafka principal for Databricks streaming job, usually an IAM role ARN: e.g. 'User:arn:aws:iam::123456789012:role/databricks-msk-role'."
  type        = string
}

variable "databricks_consumer_group" {
  description = "Consumer group ID used by Databricks when consuming from iot_enriched."
  type        = string
  default     = "databricks-iot-stream"
}

variable "kafka_topic_iot_raw" {
  description = "Kafka topic name for raw IoT events."
  type        = string
  default     = "iot_raw"
}

variable "kafka_topic_iot_enriched" {
  description = "Kafka topic name for enriched IoT events."
  type        = string
  default     = "iot_enriched"
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

provider "kafka" {
  bootstrap_servers = split(",", var.kafka_bootstrap_brokers_iam)

  tls_enabled     = true
  sasl_mechanism  = "aws-iam"
  sasl_aws_region = var.aws_region
}
