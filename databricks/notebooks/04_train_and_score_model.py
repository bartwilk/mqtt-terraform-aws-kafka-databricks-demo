# Databricks notebook: Train and score IoT anomaly model
#
# - Reads features from iot.gold.device_metrics
# - Trains a RandomForestClassifier with simple hyperparameter search
# - Logs metrics / params to MLflow and registers model in Unity Catalog
# - Updates alias 'champion' for the best version
# - Scores all current gold metrics into iot.gold.device_anomalies via MERGE

import pyspark.sql.functions as F
from pyspark.sql import DataFrame

from pyspark.ml.feature import VectorAssembler
from pyspark.ml.classification import RandomForestClassifier
from pyspark.ml.evaluation import BinaryClassificationEvaluator
from pyspark.ml.tuning import CrossValidator, ParamGridBuilder

from delta.tables import DeltaTable
import mlflow
from mlflow.models import infer_signature
from mlflow.tracking import MlflowClient

# ---------------------------------------------------------------------------
# Configuration via widgets (for reuse across environments)
# ---------------------------------------------------------------------------

dbutils.widgets.text("env", "dev", "Environment")
dbutils.widgets.text("catalog", "iot", "Unity Catalog name")
dbutils.widgets.text("schema_gold", "gold", "Gold schema name")
dbutils.widgets.text("label_threshold", "0.7", "Risk threshold for anomaly label (0-1)")
dbutils.widgets.text("train_window_days", "7", "Training window in days (0 = all data)")

env = dbutils.widgets.get("env")
CATALOG = dbutils.widgets.get("catalog")
SCHEMA_GOLD = dbutils.widgets.get("schema_gold")
LABEL_THRESHOLD = float(dbutils.widgets.get("label_threshold"))
TRAIN_WINDOW_DAYS = int(dbutils.widgets.get("train_window_days"))

GOLD_METRICS_TABLE = f"{CATALOG}.{SCHEMA_GOLD}.device_metrics"
PREDICTIONS_TABLE = f"{CATALOG}.{SCHEMA_GOLD}.device_anomalies"

# Registered model name in Unity Catalog (3-level name: catalog.schema.model_name)
MODEL_NAME = f"{CATALOG}.{SCHEMA_GOLD}.iot_anomaly_model"

# Explicitly target Unity Catalog model registry
mlflow.set_registry_uri("databricks-uc")

EXPERIMENT_NAME = f"/Shared/iot-pipeline/{env}/iot_anomaly_rf"
mlflow.set_experiment(EXPERIMENT_NAME)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------


def load_training_data() -> DataFrame:
    """
    Load gold metrics table and construct a binary label column 'label'
    from risk_max_5m and training window.
    """
    df = spark.table(GOLD_METRICS_TABLE)

    if TRAIN_WINDOW_DAYS > 0:
        df = df.filter(
            F.col("window_end")
            >= F.current_timestamp() - F.expr(f"INTERVAL {TRAIN_WINDOW_DAYS} DAYS")
        )

    required_cols = [
        "device_id",
        "window_start",
        "window_end",
        "temp_avg_5m",
        "temp_std_5m",
        "vib_avg_5m",
        "pressure_avg_5m",
        "risk_max_5m",
    ]

    missing = [c for c in required_cols if c not in df.columns]
    if missing:
        raise ValueError(
            f"Expected columns {missing} to exist in {GOLD_METRICS_TABLE}, "
            "but they were missing."
        )

    df = df.withColumn(
        "label", (F.col("risk_max_5m") > F.lit(LABEL_THRESHOLD)).cast("int")
    )

    df = df.dropna(
        subset=[
            "temp_avg_5m",
            "temp_std_5m",
            "vib_avg_5m",
            "pressure_avg_5m",
            "risk_max_5m",
        ]
    )

    return df


def add_class_weights(df: DataFrame) -> DataFrame:
    """
    Compute inverse-frequency class weights to handle imbalance.
    """
    counts = df.groupBy("label").count().toPandas()

    if counts.empty or len(counts) == 1:
        raise ValueError(
            "Training data does not contain both positive and negative examples; "
            "cannot train a binary classifier."
        )

    pos_count = int(counts[counts["label"] == 1]["count"].iloc[0]) if (counts["label"] == 1).any() else 0
    neg_count = int(counts[counts["label"] == 0]["count"].iloc[0]) if (counts["label"] == 0).any() else 0

    if pos_count == 0 or neg_count == 0:
        raise ValueError(
            f"Found only one class in label distribution (pos={pos_count}, neg={neg_count}); "
            "need both for training."
        )

    pos_weight = float(neg_count) / float(pos_count)

    df_weighted = df.withColumn(
        "class_weight",
        F.when(F.col("label") == 1, F.lit(pos_weight)).otherwise(F.lit(1.0)),
    )

    return df_weighted


def upsert_predictions(scored_df: DataFrame):
    """
    UPSERT scored anomalies into the predictions table using Delta MERGE
    on (device_id, window_start, window_end).
    """
    scored_df = scored_df.withColumn("scored_at", F.current_timestamp())

    if spark._jsparkSession.catalog().tableExists(PREDICTIONS_TABLE):
        target = DeltaTable.forName(spark, PREDICTIONS_TABLE)

        (
            target.alias("t")
            .merge(
                scored_df.alias("s"),
                "t.device_id = s.device_id "
                "AND t.window_start = s.window_start "
                "AND t.window_end = s.window_end",
            )
            .whenMatchedUpdateAll()
            .whenNotMatchedInsertAll()
            .execute()
        )
    else:
        (
            scored_df.write.format("delta")
            .mode("overwrite")
            .saveAsTable(PREDICTIONS_TABLE)
        )


# ---------------------------------------------------------------------------
# Main training logic
# ---------------------------------------------------------------------------

df_raw = load_training_data()
df = add_class_weights(df_raw)

feature_cols = [
    "temp_avg_5m",
    "temp_std_5m",
    "vib_avg_5m",
    "pressure_avg_5m",
]

assembler = VectorAssembler(
    inputCols=feature_cols,
    outputCol="features",
)

df_vec = assembler.transform(df)

train_df, test_df = df_vec.randomSplit([0.8, 0.2], seed=42)

evaluator = BinaryClassificationEvaluator(
    labelCol="label",
    rawPredictionCol="rawPrediction",
    metricName="areaUnderROC",
)

rf = RandomForestClassifier(
    labelCol="label",
    featuresCol="features",
    weightCol="class_weight",
    seed=42,
)

param_grid = (
    ParamGridBuilder()
    .addGrid(rf.numTrees, [50, 100])
    .addGrid(rf.maxDepth, [5, 10])
    .build()
)

cv = CrossValidator(
    estimator=rf,
    estimatorParamMaps=param_grid,
    evaluator=evaluator,
    numFolds=3,
    parallelism=2,
)

with mlflow.start_run(run_name=f"rf_anomaly_{env}") as run:
    cv_model = cv.fit(train_df)
    best_model = cv_model.bestModel

    test_preds = best_model.transform(test_df)
    auc = evaluator.evaluate(test_preds)

    tp = test_preds.filter("label = 1 AND prediction = 1").count()
    fp = test_preds.filter("label = 0 AND prediction = 1").count()
    tn = test_preds.filter("label = 0 AND prediction = 0").count()
    fn = test_preds.filter("label = 1 AND prediction = 0").count()

    total = tp + tn + fp + fn
    accuracy  = (tp + tn) / total if total > 0 else 0.0
    precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    recall    = tp / (tp + fn) if (tp + fn) > 0 else 0.0

    mlflow.log_metric("auc", auc)
    mlflow.log_metric("accuracy", accuracy)
    mlflow.log_metric("precision", precision)
    mlflow.log_metric("recall", recall)

    label_dist = df.groupBy("label").count().orderBy("label").toPandas()
    for _, row in label_dist.iterrows():
        mlflow.log_metric(f"label_{int(row['label'])}_count", int(row["count"]))

    mlflow.log_param("best_numTrees", best_model.getNumTrees)
    mlflow.log_param("best_maxDepth", best_model.getMaxDepth)
    mlflow.log_param("label_threshold", LABEL_THRESHOLD)
    mlflow.log_param("train_window_days", TRAIN_WINDOW_DAYS)
    mlflow.log_param("env", env)

    sample_features = df_vec.select(feature_cols).limit(500).toPandas()
    sample_preds = (
        best_model.transform(
            df_vec.select(feature_cols, "label").limit(500)
        )
        .select("prediction")
        .toPandas()
    )

    signature = infer_signature(sample_features, sample_preds)

    model_info = mlflow.spark.log_model(
        best_model,
        artifact_path="model",
        registered_model_name=MODEL_NAME,
        signature=signature,
    )

    run_id = run.info.run_id
    print(f"Logged run_id: {run_id}, model_uri: {model_info.model_uri}")

    client = MlflowClient()
    versions = client.search_model_versions(f"name='{MODEL_NAME}'")
    if not versions:
        raise RuntimeError(f"No model versions found for registered model {MODEL_NAME}")

    latest_version = max(versions, key=lambda m: int(m.version))

    client.set_model_version_alias(
        name=MODEL_NAME,
        version=latest_version.version,
        alias="champion",
    )

    print(
        f"Set alias 'champion' for model {MODEL_NAME} "
        f"to version {latest_version.version}"
    )

# ---------------------------------------------------------------------------
# Scoring using the champion model
# ---------------------------------------------------------------------------

model_uri = f"models:/{MODEL_NAME}@champion"
scoring_model = mlflow.spark.load_model(model_uri)

features_for_scoring = assembler.transform(
    spark.table(GOLD_METRICS_TABLE)
)

scored = (
    scoring_model.transform(features_for_scoring)
    .select(
        "device_id",
        "window_start",
        "window_end",
        *feature_cols,
        "risk_max_5m",
        F.col("prediction").cast("int").alias("is_anomaly"),
        F.col("probability")[1].alias("anomaly_score"),
    )
)

upsert_predictions(scored)

print(f"Scoring completed and upserted into {PREDICTIONS_TABLE}")
