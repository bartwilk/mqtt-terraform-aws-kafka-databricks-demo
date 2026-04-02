output "msk_bootstrap_brokers_tls" {
  description = "SASL/SCRAM bootstrap brokers for MSK (port 9096, used by IoT bridge and EKS)"
  value       = aws_msk_cluster.msk.bootstrap_brokers_sasl_scram
}

output "msk_bootstrap_brokers_sasl_iam" {
  description = "SASL/IAM bootstrap brokers for MSK (used by Kafka Terraform provider)"
  value       = aws_msk_cluster.msk.bootstrap_brokers_sasl_iam
}

output "iot_processor_ecr_repository_url" {
  description = "ECR repository URL for the iot-processor container image"
  value       = module.iot_processor_ecr.repository_url
}

output "eks_cluster_name" {
  description = "EKS cluster name for kubectl/kubeconfig"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "iot_topic_rule_name" {
  description = "Name of the IoT Core topic rule bridging MQTT to MSK"
  value       = module.iot_msk_bridge.iot_topic_rule_name
}
