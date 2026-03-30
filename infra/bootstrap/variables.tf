variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "mqtt-iot-pipeline"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for Terraform remote state"
}

variable "lock_table_name" {
  type    = string
  default = "terraform-state-locks"
}

variable "terraform_role_name" {
  type    = string
  default = "github-actions-terraform-role"
}

variable "app_deploy_role_name" {
  type    = string
  default = "github-actions-app-deploy-role"
}
