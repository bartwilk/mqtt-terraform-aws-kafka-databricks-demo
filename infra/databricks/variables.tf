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
