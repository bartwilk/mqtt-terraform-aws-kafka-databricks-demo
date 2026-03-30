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
# MSK (Kafka) — direct resources (no module, avoids AWS provider < 6.0 cap)
# ---------------------------------------------------------------------------

resource "aws_security_group" "msk" {
  name        = "${var.project}-${var.environment}-msk"
  description = "MSK broker security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka TLS from VPC"
  }

  ingress {
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka SASL/IAM from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-${var.environment}-msk"
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_msk_cluster" "msk" {
  cluster_name           = "${var.project}-${var.environment}-msk"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    sasl {
      scram = true
      iam   = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.msk.arn
    revision = aws_msk_configuration.msk.latest_revision
  }

  tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_msk_configuration" "msk" {
  name           = "${var.project}-${var.environment}-msk-config"
  kafka_versions = ["3.6.0"]

  server_properties = <<-EOF
    auto.create.topics.enable=false
    default.replication.factor=3
    min.insync.replicas=2
    num.partitions=12
    log.retention.hours=168
  EOF
}

locals {
  msk_bootstrap_brokers_tls      = aws_msk_cluster.msk.bootstrap_brokers_tls
  msk_bootstrap_brokers_sasl_iam = aws_msk_cluster.msk.bootstrap_brokers_sasl_iam
  msk_security_group_id          = aws_security_group.msk.id
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

  msk_bootstrap_brokers_tls = local.msk_bootstrap_brokers_tls
  msk_security_group_id     = local.msk_security_group_id

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
