variable "name" {
  description = "ECR repository name"
  type        = string
}

resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = var.name
    Terraform = "true"
  }
}

output "repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.this.repository_url
}
