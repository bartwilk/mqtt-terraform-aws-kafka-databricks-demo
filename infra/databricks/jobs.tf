data "databricks_current_user" "me" {}

# ---------------------------------------------------------------------------
# Upload notebooks
# ---------------------------------------------------------------------------

resource "databricks_notebook" "stream_kafka_to_bronze" {
  path     = "${var.notebook_base_dir}/01_stream_kafka_to_bronze"
  language = "PYTHON"
  source   = "../../databricks/notebooks/01_stream_kafka_to_bronze.py"
}

resource "databricks_notebook" "bronze_to_silver" {
  path     = "${var.notebook_base_dir}/02_bronze_to_silver"
  language = "PYTHON"
  source   = "../../databricks/notebooks/02_bronze_to_silver.py"
}

resource "databricks_notebook" "silver_to_gold_features" {
  path     = "${var.notebook_base_dir}/03_silver_to_gold_features"
  language = "PYTHON"
  source   = "../../databricks/notebooks/03_silver_to_gold_features.py"
}

resource "databricks_notebook" "train_and_score_model" {
  path     = "${var.notebook_base_dir}/04_train_and_score_model"
  language = "PYTHON"
  source   = "../../databricks/notebooks/04_train_and_score_model.py"
}

# ---------------------------------------------------------------------------
# Orchestrated multi-task job
# ---------------------------------------------------------------------------

resource "databricks_job" "iot_pipeline" {
  name = "iot-streaming-etl-ml"

  task {
    task_key            = "stream_kafka_to_bronze"
    existing_cluster_id = databricks_cluster.iot_streaming.id

    notebook_task {
      notebook_path = databricks_notebook.stream_kafka_to_bronze.path
    }
  }

  task {
    task_key            = "bronze_to_silver"
    existing_cluster_id = databricks_cluster.iot_streaming.id

    depends_on {
      task_key = "stream_kafka_to_bronze"
    }

    notebook_task {
      notebook_path = databricks_notebook.bronze_to_silver.path
    }
  }

  task {
    task_key            = "silver_to_gold_features"
    existing_cluster_id = databricks_cluster.iot_streaming.id

    depends_on {
      task_key = "bronze_to_silver"
    }

    notebook_task {
      notebook_path = databricks_notebook.silver_to_gold_features.path
    }
  }

  task {
    task_key            = "train_and_score_model"
    existing_cluster_id = databricks_cluster.iot_streaming.id

    depends_on {
      task_key = "silver_to_gold_features"
    }

    notebook_task {
      notebook_path = databricks_notebook.train_and_score_model.path

      base_parameters = {
        env               = var.environment
        catalog           = "iot"
        schema_gold       = "gold"
        label_threshold   = "0.7"
        train_window_days = "7"
      }
    }
  }

  schedule {
    quartz_cron_expression = "0 0/10 * * * ?"
    timezone_id            = "UTC"
  }
}
