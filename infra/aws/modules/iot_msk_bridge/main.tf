locals {
  name_prefix = "${var.project}-${var.environment}"

  kafka_secret_arn = coalesce(
    try(aws_secretsmanager_secret.msk_sasl[0].arn, null),
    var.existing_secret_arn
  )

  kafka_secret_id = local.kafka_secret_arn
}

# --------------------------
# Security group for IoT ENIs
# --------------------------

resource "aws_security_group" "iot_msk_enis" {
  name        = "${local.name_prefix}-iot-msk-enis"
  description = "Security group for AWS IoT Core VPC destination ENIs connecting to MSK"
  vpc_id      = var.vpc_id

  egress {
    from_port       = var.kafka_port
    to_port         = var.kafka_port
    protocol        = "tcp"
    security_groups = [var.msk_security_group_id]
    description     = "Allow IoT ENIs to reach MSK brokers"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS to Secrets Manager"
  }

  tags = merge(
    {
      Name        = "${local.name_prefix}-iot-msk-enis"
      Project     = var.project
      Environment = var.environment
      Terraform   = "true"
    },
    var.tags
  )
}

# Allow inbound from IoT ENIs to MSK brokers on the Kafka TLS port
resource "aws_security_group_rule" "msk_inbound_from_iot" {
  type                     = "ingress"
  from_port                = var.kafka_port
  to_port                  = var.kafka_port
  protocol                 = "tcp"
  security_group_id        = var.msk_security_group_id
  source_security_group_id = aws_security_group.iot_msk_enis.id
  description              = "Allow IoT VPC destination ENIs to connect to MSK brokers on TLS port"
}

# --------------------------
# IAM role for VPC destination ENIs
# --------------------------

resource "aws_iam_role" "iot_vpc_destination" {
  name = "${local.name_prefix}-iot-vpc-destination"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "iot.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "iot_vpc_destination" {
  name = "${local.name_prefix}-iot-vpc-destination"
  role = aws_iam_role.iot_vpc_destination.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeSecurityGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# --------------------------
# VPC Destination for IoT rule (for Kafka action)
# --------------------------

resource "aws_iot_topic_rule_destination" "iot_msk_vpc_dest" {
  vpc_configuration {
    role_arn        = aws_iam_role.iot_vpc_destination.arn
    vpc_id          = var.vpc_id
    subnet_ids      = var.private_subnet_ids
    security_groups = [aws_security_group.iot_msk_enis.id]
  }
}

# --------------------------
# Optional: Secrets Manager secret for MSK SASL credentials
# --------------------------

resource "aws_secretsmanager_secret" "msk_sasl" {
  count = var.create_secret ? 1 : 0

  name = coalesce(
    var.secret_name,
    "${local.name_prefix}-msk-sasl"
  )

  description = "MSK SASL SCRAM credentials for IoT Kafka rule"

  recovery_window_in_days = 7

  tags = merge(
    {
      Name        = "${local.name_prefix}-msk-sasl"
      Project     = var.project
      Environment = var.environment
      Terraform   = "true"
    },
    var.tags
  )
}

resource "aws_secretsmanager_secret_version" "msk_sasl" {
  count = var.create_secret ? 1 : 0

  secret_id = aws_secretsmanager_secret.msk_sasl[0].id

  secret_string = jsonencode({
    username = var.kafka_username
    password = var.kafka_password
  })
}

# --------------------------
# IAM role for Secrets Manager get_secret()
# --------------------------

resource "aws_iam_role" "iot_kafka_secrets" {
  name = "${local.name_prefix}-iot-kafka-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "iot.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "iot_kafka_secrets" {
  name = "${local.name_prefix}-iot-kafka-secrets"
  role = aws_iam_role.iot_kafka_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.kafka_secret_arn
      }
    ]
  })
}

# --------------------------
# IoT Topic Rule with Kafka action -> MSK
# --------------------------

resource "aws_iot_topic_rule" "iot_to_msk" {
  name        = var.mqtt_rule_name
  description = var.mqtt_rule_description
  enabled     = true
  sql         = var.mqtt_sql
  sql_version = "2016-03-23"

  kafka {
    destination_arn = aws_iot_topic_rule_destination.iot_msk_vpc_dest.arn
    topic           = var.kafka_topic
    key             = "$${topic()}"

    client_properties = {
      "bootstrap.servers" = var.msk_bootstrap_brokers_tls
      "security.protocol" = "SASL_SSL"
      "sasl.mechanism"    = "SCRAM-SHA-512"
      "acks"              = "1"
      "compression.type"  = "lz4"

      "sasl.scram.username" = format(
        "$${get_secret('%s', 'SecretString', 'username', '%s')}",
        local.kafka_secret_id,
        aws_iam_role.iot_kafka_secrets.arn
      )

      "sasl.scram.password" = format(
        "$${get_secret('%s', 'SecretString', 'password', '%s')}",
        local.kafka_secret_id,
        aws_iam_role.iot_kafka_secrets.arn
      )
    }
  }

  depends_on = [
    aws_iot_topic_rule_destination.iot_msk_vpc_dest,
    aws_iam_role_policy.iot_kafka_secrets
  ]
}
