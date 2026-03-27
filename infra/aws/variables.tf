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
