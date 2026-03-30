terraform {
  required_version = ">= 1.6.0"

  # bucket is passed via -backend-config="bucket=..." in CI (vars.STATE_BUCKET_NAME)
  backend "s3" {
    key            = "iot-eks-msk/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}