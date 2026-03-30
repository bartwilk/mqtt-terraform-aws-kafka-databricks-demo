output "state_bucket_name" {
  value       = aws_s3_bucket.tf_state.bucket
  description = "S3 bucket name — update backend.tf files with this value"
}

output "lock_table_name" {
  value       = aws_dynamodb_table.tf_state_locks.name
  description = "DynamoDB table name for Terraform state locking"
}

output "terraform_role_arn" {
  value       = aws_iam_role.terraform.arn
  description = "Set as AWS_TERRAFORM_ROLE_ARN GitHub secret"
}

output "app_deploy_role_arn" {
  value       = aws_iam_role.app_deploy.arn
  description = "Set as AWS_APP_ROLE_ARN GitHub secret"
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "GitHub OIDC provider ARN"
}
