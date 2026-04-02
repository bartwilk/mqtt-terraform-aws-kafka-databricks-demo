resource "databricks_catalog" "iot" {
  name             = "iot"
  comment          = "IoT streaming data catalog"
  isolation_mode   = "ISOLATED"
  storage_root     = var.catalog_storage_root
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
