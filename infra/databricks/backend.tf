terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    bucket         = "mycompany-terraform-state"
    key            = "iot-eks-msk/databricks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-locks"
    encrypt        = true
  }
}
