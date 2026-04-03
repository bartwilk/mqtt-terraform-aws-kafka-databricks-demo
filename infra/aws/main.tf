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

  tags = {
    Name        = "${var.project}-${var.environment}-msk"
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_vpc_security_group_ingress_rule" "msk_tls" {
  security_group_id = aws_security_group.msk.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 9094
  to_port           = 9094
  ip_protocol       = "tcp"
  description       = "Kafka TLS from VPC"
}

resource "aws_vpc_security_group_ingress_rule" "msk_sasl_scram" {
  security_group_id = aws_security_group.msk.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 9096
  to_port           = 9096
  ip_protocol       = "tcp"
  description       = "Kafka SASL/SCRAM from VPC"
}

resource "aws_vpc_security_group_ingress_rule" "msk_sasl_iam" {
  security_group_id = aws_security_group.msk.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 9098
  to_port           = 9098
  ip_protocol       = "tcp"
  description       = "Kafka SASL/IAM from VPC"
}

resource "aws_vpc_security_group_egress_rule" "msk_vpc" {
  security_group_id = aws_security_group.msk.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "Allow all outbound within VPC"
}

resource "aws_vpc_security_group_egress_rule" "msk_dns" {
  security_group_id = aws_security_group.msk.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  description       = "Allow DNS resolution"
}

resource "aws_kms_key" "msk" {
  description         = "KMS key for MSK encryption at rest"
  enable_key_rotation = true

  tags = {
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
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn
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
  # MSK with SASL/SCRAM enabled populates bootstrap_brokers_sasl_scram (port 9096),
  # not bootstrap_brokers_tls (port 9094, TLS-only). Use sasl_scram for IoT bridge.
  msk_bootstrap_brokers_tls      = aws_msk_cluster.msk.bootstrap_brokers_sasl_scram
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
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.large"]
      min_size       = 2
      max_size       = 10
      desired_size   = 3
    }
  }

  enable_irsa = true

  access_entries = {
    app_deploy = {
      principal_arn = var.app_deploy_role_arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

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
# Actions Runner Controller (ARC) — self-hosted runners inside the VPC
# Allows kafka_infra Terraform to reach private MSK brokers directly.
# ---------------------------------------------------------------------------

resource "helm_release" "arc_controller" {
  name             = "arc"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = "0.9.3"
  namespace        = "arc-systems"
  create_namespace = true

  depends_on = [module.eks]
}

resource "helm_release" "arc_runner_set" {
  name             = "kafka-infra-runner"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = "0.9.3"
  namespace        = "arc-runners"
  create_namespace = true

  set {
    name  = "githubConfigUrl"
    value = "https://github.com/${var.github_repo}"
  }

  set_sensitive {
    name  = "githubConfigSecret.github_token"
    value = var.arc_github_token
  }

  set {
    name  = "runnerScaleSetName"
    value = "kafka-infra-runner"
  }

  set {
    name  = "minRunners"
    value = "0"
  }

  set {
    name  = "maxRunners"
    value = "3"
  }

  depends_on = [helm_release.arc_controller]
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
  kafka_port            = 9096
  mqtt_rule_name        = replace("${var.project}_${var.environment}_mqtt_to_msk", "-", "_")
  mqtt_rule_description = "MQTT sensors/# to MSK topic iot_raw"
  mqtt_sql              = "SELECT * FROM 'sensors/#'"

  create_secret   = true
  msk_cluster_arn = aws_msk_cluster.msk.arn
  msk_kms_key_arn = aws_kms_key.msk.arn
  kafka_username  = var.msk_scram_username
  kafka_password  = var.msk_scram_password

  tags = {
    CostCenter      = "iot-streaming"
    Owner           = "data-platform"
    Confidentiality = "internal"
  }
}

# ---------------------------------------------------------------------------
# Unity Catalog — S3 bucket + IAM role for Databricks managed storage
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "unity_catalog" {
  bucket        = "${var.project}-${var.environment}-unity-catalog"
  force_destroy = false

  tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_s3_bucket_versioning" "unity_catalog" {
  bucket = aws_s3_bucket.unity_catalog.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "unity_catalog" {
  bucket = aws_s3_bucket.unity_catalog.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.msk.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "unity_catalog" {
  bucket                  = aws_s3_bucket.unity_catalog.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "databricks_unity_catalog" {
  name = "${var.project}-${var.environment}-databricks-uc"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::414351767826:root" # Databricks AWS account
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.databricks_account_id
          }
        }
      },
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-${var.environment}-databricks-uc"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_iam_role_policy" "databricks_unity_catalog" {
  name = "${var.project}-${var.environment}-databricks-uc"
  role = aws_iam_role.databricks_unity_catalog.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketNotification",
          "s3:PutBucketNotification"
        ]
        Resource = [
          aws_s3_bucket.unity_catalog.arn,
          "${aws_s3_bucket.unity_catalog.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = [aws_kms_key.msk.arn]
      }
    ]
  })
}
