locals {
  github_org  = "bartwilk"
  github_repo = "mqtt-terraform-aws-kafka-databricks-demo"
  oidc_url    = "token.actions.githubusercontent.com"
}

# ---------------------------------------------------------------------------
# S3 bucket for Terraform remote state
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tf_state" {
  bucket        = var.state_bucket_name
  force_destroy = false

  tags = {
    Project     = var.project
    ManagedBy   = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB table for Terraform state locking
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "tf_state_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform-bootstrap"
  }
}

# ---------------------------------------------------------------------------
# GitHub OIDC identity provider
# ---------------------------------------------------------------------------
data "tls_certificate" "github_oidc" {
  url = "https://${local.oidc_url}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://${local.oidc_url}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_oidc.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------------------------
# IAM role — Terraform (aws_infra, kafka_infra, databricks_infra jobs)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_url}:sub"
      values   = ["repo:${local.github_org}/${local.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = var.terraform_role_name
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------------------------
# IAM role — App deploy (app_deploy job: ECR push + EKS rollout)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "app_deploy" {
  name               = var.app_deploy_role_name
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform-bootstrap"
  }
}

data "aws_iam_policy_document" "app_deploy" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:*"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "app_deploy" {
  name   = "${var.app_deploy_role_name}-policy"
  policy = data.aws_iam_policy_document.app_deploy.json
}

resource "aws_iam_role_policy_attachment" "app_deploy" {
  role       = aws_iam_role.app_deploy.name
  policy_arn = aws_iam_policy.app_deploy.arn
}
