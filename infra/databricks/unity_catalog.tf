# --------------------------
# Storage credential — cross-account IAM role for S3 access
# --------------------------

resource "databricks_storage_credential" "unity_catalog" {
  name    = "unity-catalog-s3"
  comment = "Cross-account IAM role for Unity Catalog managed storage"

  aws_iam_role {
    role_arn = var.unity_catalog_role_arn
  }
}

# --------------------------
# Catalog + schemas (medallion architecture)
# Uses the existing "workspace" external location for managed storage
# --------------------------

resource "databricks_catalog" "iot" {
  name    = "iot"
  comment = "IoT streaming data catalog"

  storage_root = "s3://${var.unity_catalog_s3_bucket}/iot-catalog"
}

resource "databricks_schema" "bronze" {
  catalog_name = databricks_catalog.iot.name
  name         = "bronze"
  comment      = "Raw IoT sensor events from Kafka"
}

resource "databricks_schema" "silver" {
  catalog_name = databricks_catalog.iot.name
  name         = "silver"
  comment      = "Cleaned and conformed sensor events"
}

resource "databricks_schema" "gold" {
  catalog_name = databricks_catalog.iot.name
  name         = "gold"
  comment      = "Aggregates, features, and ML outputs"
}

# --------------------------
# Volumes — streaming checkpoint storage
# --------------------------

resource "databricks_volume" "bronze_checkpoints" {
  catalog_name = databricks_catalog.iot.name
  schema_name  = databricks_schema.bronze.name
  name         = "checkpoints"
  volume_type  = "MANAGED"
  comment      = "Streaming checkpoints for bronze layer"
}

resource "databricks_volume" "silver_checkpoints" {
  catalog_name = databricks_catalog.iot.name
  schema_name  = databricks_schema.silver.name
  name         = "checkpoints"
  volume_type  = "MANAGED"
  comment      = "Streaming checkpoints for silver layer"
}

resource "databricks_volume" "gold_checkpoints" {
  catalog_name = databricks_catalog.iot.name
  schema_name  = databricks_schema.gold.name
  name         = "checkpoints"
  volume_type  = "MANAGED"
  comment      = "Streaming checkpoints for gold layer"
}
