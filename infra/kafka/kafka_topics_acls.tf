locals {
  retention_ms_7d  = 7 * 24 * 60 * 60 * 1000
  retention_ms_30d = 30 * 24 * 60 * 60 * 1000
}

# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------

resource "kafka_topic" "iot_raw" {
  name               = var.kafka_topic_iot_raw
  partitions         = 12
  replication_factor = 3

  config = {
    "cleanup.policy"                 = "delete"
    "retention.ms"                   = tostring(local.retention_ms_7d)
    "min.insync.replicas"            = "2"
    "unclean.leader.election.enable" = "false"
    "segment.ms"                     = "3600000"
    "segment.bytes"                  = "1073741824"
  }
}

resource "kafka_topic" "iot_enriched" {
  name               = var.kafka_topic_iot_enriched
  partitions         = 12
  replication_factor = 3

  config = {
    "cleanup.policy"                 = "delete"
    "retention.ms"                   = tostring(local.retention_ms_30d)
    "min.insync.replicas"            = "2"
    "unclean.leader.election.enable" = "false"
    "segment.ms"                     = "3600000"
    "segment.bytes"                  = "1073741824"
  }
}

# ---------------------------------------------------------------------------
# ACLs – IoT Core producer (write to iot_raw)
# ---------------------------------------------------------------------------

resource "kafka_acl" "iot_raw_producer_write" {
  resource_name                = kafka_topic.iot_raw.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.iot_producer_principal
  acl_host            = "*"
  acl_operation       = "Write"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "iot_raw_producer_describe" {
  resource_name                = kafka_topic.iot_raw.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.iot_producer_principal
  acl_host            = "*"
  acl_operation       = "Describe"
  acl_permission_type = "Allow"
}

# ---------------------------------------------------------------------------
# ACLs – EKS processor (consumer on iot_raw, producer on iot_enriched)
# ---------------------------------------------------------------------------

resource "kafka_acl" "eks_consumer_read_iot_raw" {
  resource_name                = kafka_topic.iot_raw.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.eks_processor_principal
  acl_host            = "*"
  acl_operation       = "Read"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "eks_consumer_describe_iot_raw" {
  resource_name                = kafka_topic.iot_raw.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.eks_processor_principal
  acl_host            = "*"
  acl_operation       = "Describe"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "eks_consumer_group_iot_raw" {
  resource_name                = var.eks_processor_consumer_group
  resource_type                = "Group"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.eks_processor_principal
  acl_host            = "*"
  acl_operation       = "Read"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "eks_producer_write_iot_enriched" {
  resource_name                = kafka_topic.iot_enriched.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.eks_processor_principal
  acl_host            = "*"
  acl_operation       = "Write"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "eks_producer_describe_iot_enriched" {
  resource_name                = kafka_topic.iot_enriched.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.eks_processor_principal
  acl_host            = "*"
  acl_operation       = "Describe"
  acl_permission_type = "Allow"
}

# ---------------------------------------------------------------------------
# ACLs – Databricks consumer on iot_enriched
# ---------------------------------------------------------------------------

resource "kafka_acl" "databricks_read_iot_enriched" {
  resource_name                = kafka_topic.iot_enriched.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.databricks_principal
  acl_host            = "*"
  acl_operation       = "Read"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "databricks_describe_iot_enriched" {
  resource_name                = kafka_topic.iot_enriched.name
  resource_type                = "Topic"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.databricks_principal
  acl_host            = "*"
  acl_operation       = "Describe"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "databricks_consumer_group" {
  resource_name                = var.databricks_consumer_group
  resource_type                = "Group"
  resource_pattern_type_filter = "Literal"

  acl_principal       = var.databricks_principal
  acl_host            = "*"
  acl_operation       = "Read"
  acl_permission_type = "Allow"
}
