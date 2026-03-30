data "aws_availability_zones" "available" {}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.project}-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

# ---------------------------------------------------------------------------
# MSK (Kafka)
# ---------------------------------------------------------------------------

module "msk" {
  source  = "terraform-aws-modules/msk-kafka-cluster/aws"
  version = "~> 3.1"

  name                   = "${var.project}-${var.environment}-msk"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 3

  broker_node_client_subnets = module.vpc.private_subnets
  broker_node_instance_type  = "kafka.m5.large"

  encryption_in_transit_client_broker = "TLS"
  encryption_at_rest_kms_key_arn      = null

  tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "${var.project}-${var.environment}-eks"
  cluster_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.large"]
      min_size       = 2
      max_size       = 10
      desired_size   = 3
    }
  }

  enable_irsa = true

  tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

# ---------------------------------------------------------------------------
# ECR – iot-processor image repository
# ---------------------------------------------------------------------------

module "iot_processor_ecr" {
  source = "./modules/ecr"
  name   = "${var.project}/iot-processor"
}

# ---------------------------------------------------------------------------
# IoT Core → MSK bridge
# ---------------------------------------------------------------------------

module "iot_msk_bridge" {
  source = "./modules/iot_msk_bridge"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  msk_bootstrap_brokers_tls = module.msk.bootstrap_brokers_tls
  msk_security_group_id     = module.msk.security_group_id

  kafka_topic           = "iot_raw"
  mqtt_rule_name        = "${var.project}-${var.environment}-mqtt-to-msk"
  mqtt_rule_description = "MQTT sensors/# to MSK topic iot_raw"
  mqtt_sql              = "SELECT * FROM 'sensors/#'"

  # Recommended: manage secret outside Terraform and pass ARN here.
  # Set create_secret = true and supply kafka_username/kafka_password for first-time setup.
  create_secret       = false
  existing_secret_arn = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}-${var.environment}-msk-sasl"

  tags = {
    CostCenter      = "iot-streaming"
    Owner           = "data-platform"
    Confidentiality = "internal"
  }
}
