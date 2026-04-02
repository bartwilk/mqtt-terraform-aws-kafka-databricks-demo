variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, stage, prod)"

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "project" {
  type    = string
  default = "mqtt-iot-pipeline"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "github_repo" {
  description = "GitHub repo for the ARC runner scale set (e.g. 'myorg/myrepo')"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be in the format 'owner/repo'."
  }
}

variable "arc_github_token" {
  description = "GitHub Personal Access Token with repo scope for ARC runner registration"
  type        = string
  sensitive   = true
}
