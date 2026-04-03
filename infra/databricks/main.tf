data "databricks_node_type" "small" {
  local_disk = true
}

data "databricks_spark_version" "lts" {
  long_term_support = true
}

resource "databricks_cluster" "iot_streaming" {
  cluster_name            = "iot-streaming-cluster"
  spark_version           = data.databricks_spark_version.lts.id
  node_type_id            = "m5.large"
  num_workers             = 1
  autotermination_minutes = 60
  data_security_mode      = "SINGLE_USER"
  single_user_name        = data.databricks_current_user.me.user_name

  spark_conf = {
    "spark.databricks.delta.preview.enabled" = "true"
  }

  library {
    maven {
      coordinates = "org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.0"
    }
  }
}
