variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, stage, prod)"
}

variable "project" {
  type    = string
  default = "mqtt-iot-pipeline"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "github_repo" {
  description = "GitHub repo for the ARC runner scale set (e.g. 'myorg/myrepo')"
  type        = string
}

variable "arc_github_token" {
  description = "GitHub Personal Access Token with repo scope for ARC runner registration"
  type        = string
  sensitive   = true
}
