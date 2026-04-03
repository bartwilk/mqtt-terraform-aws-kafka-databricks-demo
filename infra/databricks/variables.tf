variable "databricks_host" {
  description = "Databricks workspace URL (e.g. https://dbc-xxxx.cloud.databricks.com)"
  type        = string
}

variable "databricks_token" {
  description = "Databricks personal access token"
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "Deployment environment (dev, stage, prod)"
  type        = string
  default     = "dev"
}

variable "notebook_base_dir" {
  description = "Databricks workspace path where notebooks are uploaded"
  type        = string
  default     = "/Shared/iot-pipeline"
}

variable "unity_catalog_role_arn" {
  description = "IAM role ARN for Databricks Unity Catalog cross-account S3 access"
  type        = string
}

variable "unity_catalog_s3_bucket" {
  description = "S3 bucket name for Unity Catalog managed storage"
  type        = string
}

variable "msk_bootstrap_brokers_sasl_iam" {
  description = "SASL/IAM bootstrap brokers for MSK (passed to Databricks secret scope)"
  type        = string
  sensitive   = true
}
