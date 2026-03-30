terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.73"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Intentionally no remote backend — this is the config that creates it.
  # State file is kept locally: infra/bootstrap/terraform.tfstate
}

provider "aws" {
  region = var.aws_region
}
