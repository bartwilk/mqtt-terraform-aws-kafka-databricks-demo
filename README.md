# MQTT → AWS IoT Core → Kafka (MSK) → Databricks Demo

End-to-end IoT streaming and ML pipeline demo. Covers device data ingestion via MQTT/AWS IoT Core, real-time stream processing through Amazon MSK (Kafka), Kubernetes-based enrichment on EKS, and ETL/ML pipelines in Databricks — all provisioned with Terraform and automated via GitHub Actions.

---

## AWS Initial Setup (start here)

Bootstrap is a **one-time GitHub Actions workflow** (`bootstrap.yml`) that creates all the AWS resources the main pipeline depends on. It uses static AWS credentials for this single job only; everything after that uses OIDC.

### Step 1 — Create a bootstrap IAM user in AWS

In the AWS Console → **IAM → Users → Create user** (`github-bootstrap`):
- Attach policy: `AdministratorAccess` (needed to create IAM, S3, DynamoDB, OIDC provider)
- Create an **access key** (type: CLI) and save the key ID + secret

This user is only needed to run bootstrap once. You can delete it afterwards.

### Step 2 — Add GitHub secrets and variables

Repo → **Settings → Secrets and variables → Actions:**

**Secrets:**

| Secret | Value |
|--------|-------|
| `AWS_BOOTSTRAP_ACCESS_KEY_ID` | Access key ID from step 1 |
| `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` | Secret access key from step 1 |

**Variables** (not secrets — visible in logs):

| Variable | Value |
|----------|-------|
| `STATE_BUCKET_NAME` | A globally unique S3 bucket name, e.g. `mycompany-mqtt-tf-state` |

### Step 3 — Run the bootstrap workflow

Repo → **Actions → bootstrap → Run workflow.**

This provisions:
- S3 bucket (versioned, encrypted, public access blocked) for Terraform remote state
- DynamoDB table (`terraform-state-locks`) for state locking
- GitHub OIDC identity provider in IAM
- `github-actions-terraform-role` — assumed by `aws_infra` and `kafka_infra` jobs
- `github-actions-app-deploy-role` — assumed by the `app_deploy` job (ECR + EKS scoped)

### Step 4 — Add the role ARN secrets

The bootstrap workflow prints the role ARNs in its final step. Copy them and add two more secrets:

| Secret | Value |
|--------|-------|
| `AWS_TERRAFORM_ROLE_ARN` | `terraform_role_arn` output from bootstrap run |
| `AWS_APP_ROLE_ARN` | `app_deploy_role_arn` output from bootstrap run |

The remaining secrets (`DATABRICKS_HOST`, `DATABRICKS_TOKEN`, etc.) are listed in the [Required GitHub Secrets](#required-github-secrets) section below.

> **Note:** The `STATE_BUCKET_NAME` variable is read by all pipeline jobs via `vars.STATE_BUCKET_NAME` and passed to `terraform init -backend-config="bucket=..."` — no bucket name is hardcoded in the backend files.

---

## Architecture

```
IoT Devices
    │  MQTT (TLS + certs)
    ▼
AWS IoT Core
    │  Topic Rule: SELECT * FROM 'sensors/#'
    │  Kafka Action → VPC Destination → MSK
    ▼
Amazon MSK ─────────────── topic: iot_raw
    │                       (12 partitions, RF=3, 7-day retention)
    ▼
EKS Pod: iot-processor (3 replicas)
    │  Validate + enrich + risk_score
    ▼
Amazon MSK ─────────────── topic: iot_enriched
    │                       (12 partitions, RF=3, 30-day retention)
    ▼
Databricks Structured Streaming
    ├── Bronze: iot.bronze.sensor_events    (raw ingest, append)
    ├── Silver: iot.silver.sensor_clean     (validated, filtered)
    └── Gold:   iot.gold.device_metrics     (5-min aggregates)
                    │
                    ▼
            ML: RandomForestClassifier (MLflow → Unity Catalog)
            Model: iot.gold.iot_anomaly_model@champion
                    │  Batch scoring via MERGE
                    ▼
            iot.gold.device_anomalies
                    │
                    ▼
            Databricks AI/BI Dashboards (4 SQL views)
```

---

## Technology Stack

| Category | Technology |
|----------|-----------|
| Ingestion | AWS IoT Core (MQTT), Confluent Kafka Python client |
| Streaming | Apache Kafka (Amazon MSK 3.6.0) |
| Compute | AWS EKS 1.32, Kubernetes, Docker |
| Analytics | Databricks, Delta Lake, Spark Structured Streaming |
| ML | MLflow, RandomForestClassifier, Unity Catalog model registry |
| IaC | Terraform ~1.9, Mongey Kafka provider, terraform-aws-modules |
| CI/CD | GitHub Actions, GitHub OIDC |
| Languages | Python 3.11, HCL2, SQL, Bash, YAML |

---

## Repository Structure

```
mqtt-terraform-aws-kafka-databricks-demo/
├── .github/workflows/
│   └── main-pipeline.yml               # Full 5-job CI/CD pipeline
├── infra/
│   ├── aws/
│   │   ├── backend.tf                  # S3 state backend + DynamoDB locking
│   │   ├── providers.tf                # AWS provider configuration
│   │   ├── variables.tf                # aws_region, environment, project, vpc_cidr
│   │   ├── main.tf                     # Module calls: vpc, msk, eks, ecr, iot_msk_bridge
│   │   ├── outputs.tf                  # MSK brokers, ECR URL, EKS cluster name
│   │   ├── envs/
│   │   │   ├── dev.tfvars
│   │   │   └── prod.tfvars
│   │   └── modules/
│   │       ├── ecr/main.tf             # ECR repository resource
│   │       └── iot_msk_bridge/         # IoT Core → MSK bridge (SG, IAM, topic rule)
│   ├── kafka/
│   │   ├── backend.tf                  # Separate S3 state backend
│   │   ├── providers.tf                # AWS + Mongey kafka provider (~0.13.1)
│   │   ├── kafka_topics_acls.tf        # Topics: iot_raw, iot_enriched + ACLs
│   │   └── outputs.tf
│   └── databricks/
│       ├── backend.tf                  # Separate S3 state backend
│       ├── providers.tf                # Databricks provider (~1.62.0)
│       ├── variables.tf
│       ├── unity_catalog.tf            # iot catalog + bronze/silver/gold schemas
│       ├── main.tf                     # Streaming cluster (LTS runtime, 2 workers)
│       └── jobs.tf                     # 4 notebook uploads + orchestrated job
├── databricks/
│   ├── notebooks/
│   │   ├── 01_stream_kafka_to_bronze.py    # Kafka → Delta bronze (Structured Streaming)
│   │   ├── 02_bronze_to_silver.py          # Type coercion + sanity filters
│   │   ├── 03_silver_to_gold_features.py   # 5-min windowed aggregates per device
│   │   └── 04_train_and_score_model.py     # RF training, MLflow, UC registry, scoring
│   └── sql/
│       └── iot_dashboard_views.sql         # 4 AI/BI dashboard views
├── services/
│   └── iot-processor/
│       ├── app.py                      # Confluent Kafka consumer/producer
│       ├── Dockerfile                  # python:3.11-slim, non-root UID 1000
│       ├── requirements.txt
│       ├── requirements-dev.txt        # runtime deps + pytest==8.3.5
│       └── tests/
│           ├── conftest.py             # env var patches + confluent_kafka mock
│           ├── test_normalize_event.py # 13 cases: schema, risk formula, validation
│           └── test_main_loop.py       # 12 cases: poll pipeline, errors, resilience
├── k8s/
│   ├── namespace.yaml
│   ├── iot-processor-configmap.yaml
│   ├── iot-processor-serviceaccount.yaml   # IRSA annotation
│   └── iot-processor-deployment.yaml       # 3 replicas, secrets + configmap refs
└── createproject.sh                    # Original scaffolding script (reference only)
```

---

## Infrastructure Components

| Component | Service | Config |
|-----------|---------|--------|
| Network | AWS VPC | 10.0.0.0/16 (dev), 10.1.0.0/16 (prod), 3 AZs, 1 NAT GW |
| Compute | AWS EKS 1.32 | Managed node group, t3.large, 2–10 nodes, IRSA enabled |
| Streaming | Amazon MSK | 3 brokers, m5.large, Kafka 3.6.0, TLS + SCRAM, private subnets |
| Ingestion | AWS IoT Core | Topic rule `sensors/#`, Kafka action, VPC destination |
| Registry | AWS ECR | Scan-on-push, mutable tags |
| Secrets | AWS Secrets Manager | MSK SASL creds, 7-day recovery window |
| Catalog | Databricks Unity Catalog | `iot` catalog, bronze/silver/gold schemas |
| State | S3 + DynamoDB | 3 separate state files: aws / kafka / databricks |
| CI Kafka runner | ARC on EKS | Self-hosted GitHub Actions runner inside the VPC — runs `infra/kafka` Terraform against private MSK brokers (scales to 0 when idle) |

---

## CI/CD Pipeline

Five GitHub Actions jobs with explicit dependency chain:

```
aws_infra
    ├── kafka_infra ──────────────────┐
    │       └── databricks_infra      │
    │               └── databricks_sql│
    └────────────────────────────────app_deploy
```

| Job | Runner | Description |
|-----|--------|-------------|
| `aws_infra` | `ubuntu-latest` | `terraform apply` in `infra/aws` — provisions VPC, EKS, MSK, IoT Core, ECR, and installs the ARC self-hosted runner into EKS via Helm |
| `kafka_infra` | `kafka-infra-runner` (self-hosted, inside VPC) | Resolves MSK bootstrap brokers via AWS CLI, then `terraform apply` in `infra/kafka` — runs inside the EKS cluster so it can reach private MSK brokers directly |
| `databricks_infra` | `ubuntu-latest` | `terraform apply` in `infra/databricks` — cluster, Unity Catalog, notebooks, job |
| `databricks_sql` | `ubuntu-latest` | Runs each SQL view via Databricks Statement Execution API 2.0 |
| `app_deploy` | `ubuntu-latest` | Docker build → ECR push → `kubectl apply` + rollout wait |

> **Why a self-hosted runner for `kafka_infra`?** The Mongey Kafka Terraform provider connects directly to MSK broker ports (`:9098`) using the Kafka protocol — not the AWS API. MSK brokers live in private subnets with no public access, so a standard GitHub-hosted runner cannot reach them. The ARC runner runs as a pod inside the EKS cluster (same VPC), giving it direct network access to MSK.

---

## Databricks Medallion Pipeline

| Layer | Table | Description |
|-------|-------|-------------|
| Bronze | `iot.bronze.sensor_events` | Raw Kafka ingest via Structured Streaming |
| Silver | `iot.silver.sensor_clean` | Validated + filtered (type coercion, range checks) |
| Gold | `iot.gold.device_metrics` | 5-min tumbling window aggregates per device |
| Gold | `iot.gold.device_anomalies` | ML anomaly scores, updated via Delta MERGE |

**ML model:** `RandomForestClassifier` with cross-validation (grid: `numTrees=[50,100]`, `maxDepth=[5,10]`, 3 folds). Logged to MLflow, registered to Unity Catalog as `iot.gold.iot_anomaly_model@champion`.

**AI/BI Dashboard views:**

| View | Purpose |
|------|---------|
| `vw_iot_anomaly_rate_hourly` | Hourly anomaly rate (line chart) |
| `vw_iot_top_risky_devices_24h` | Top 50 devices by avg anomaly score (bar chart) |
| `vw_iot_recent_anomalies_24h` | Drill-down detail, last 500 rows (table) |
| `vw_iot_temp_vs_anomaly` | Temperature vs anomaly score scatter (scatter plot) |

---

## Security

- TLS in transit everywhere (IoT Core → MSK, EKS → MSK, Databricks → MSK)
- SASL/SCRAM-SHA-512 Kafka authentication for IoT and EKS clients
- MSK IAM auth for Databricks (no static credentials)
- IRSA (IAM Roles for Service Accounts) — no static credentials in EKS pods
- GitHub OIDC — no long-lived AWS access keys in CI secrets
- Non-root container (UID 1000)
- VPC isolation — MSK and EKS in private subnets only
- Secrets Manager for SASL credential storage
- Kafka ACLs enforce least-privilege per principal

---

## Deployment

### Prerequisites

- AWS account with permissions to create VPC, EKS, MSK, IoT Core, ECR, IAM, Secrets Manager
- Databricks workspace (AWS-hosted) with Unity Catalog enabled
- Terraform >= 1.6.0 installed locally
- `kubectl` and `aws` CLI configured
- GitHub repository with Actions enabled

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `AWS_TERRAFORM_ROLE_ARN` | IAM role for Terraform (OIDC-assumed) |
| `AWS_APP_ROLE_ARN` | IAM role for app deploy (ECR push, EKS rollout) |
| `ARC_GITHUB_TOKEN` | GitHub PAT with `repo` scope — used by ARC to register the self-hosted runner |
| `DATABRICKS_HOST` | Databricks workspace URL |
| `DATABRICKS_TOKEN` | Databricks personal access token |
| `DATABRICKS_SQL_WAREHOUSE_ID` | Warehouse ID for SQL view execution |
| `KAFKA_IOT_PRINCIPAL` | Kafka ACL principal for IoT Core producer, e.g. `User:iot_msk_producer` — must match the SCRAM username in the MSK Secrets Manager secret |
| `KAFKA_EKS_PRINCIPAL` | Kafka ACL principal for EKS processor, e.g. `User:eks_iot_processor` — must match the SCRAM username used by the `kafka-connection` K8s Secret |
| `KAFKA_DATABRICKS_PRINCIPAL` | Kafka ACL principal for Databricks, e.g. `User:arn:aws:iam::123456789012:role/databricks-msk-role` |

### Pre-Deployment Checklist

- [ ] Complete the AWS initial setup (bootstrap workflow) above — sets up S3, DynamoDB, OIDC, IAM roles
- [ ] Add `STATE_BUCKET_NAME` GitHub variable — injected at `terraform init`, no edits to `backend.tf` needed
- [ ] Create a GitHub PAT with `repo` scope and add as `ARC_GITHUB_TOKEN` — used by ARC to register the self-hosted runner into your repo
- [ ] Create the MSK SASL secret in Secrets Manager before applying `infra/aws` (or set `create_secret = true` in the `iot_msk_bridge` module)
- [ ] Set `KAFKA_IOT_PRINCIPAL`, `KAFKA_EKS_PRINCIPAL`, and `KAFKA_DATABRICKS_PRINCIPAL` GitHub Secrets — Terraform reads these to configure Kafka ACLs. The `User:` prefix is required. The username in `KAFKA_IOT_PRINCIPAL` and `KAFKA_EKS_PRINCIPAL` must match the SCRAM credentials in Secrets Manager / the `kafka-connection` K8s Secret respectively
- [ ] Run `terraform init` in `infra/aws`, `infra/kafka`, and `infra/databricks`; commit the generated `.terraform.lock.hcl` files for reproducible provider versions
- [ ] Create a `kafka-connection` Kubernetes Secret in the `iot` namespace after the EKS cluster is up (keys: `bootstrap_servers`, `username`, `password`)

### Local Test

```bash
pip install -r services/iot-processor/requirements-dev.txt
pytest services/iot-processor/tests/ -v
```

25 tests across two files:

| File | Cases | Covers |
|------|-------|--------|
| `test_normalize_event.py` | 13 | Schema enforcement, risk-score formula, field coercion, `ValueError` on missing required fields |
| `test_main_loop.py` | 12 | Consumer subscription, `None` poll (no-op), valid message → produce pipeline, `_PARTITION_EOF` (silent skip), non-EOF Kafka errors (logged + skipped), invalid JSON / missing fields / non-numeric values (all caught, loop continues), risk-score boundary values in produced payload |

### Estimated Deployment Time

| Run | Duration |
|-----|----------|
| First run (cold) | ~40 minutes |
| Subsequent runs | ~20 minutes |

---

## Kafka ACL Matrix

| Principal | Topic | Permissions |
|-----------|-------|-------------|
| IoT producer | `iot_raw` | Write, Describe |
| EKS processor | `iot_raw` | Read, Describe, Group Read |
| EKS processor | `iot_enriched` | Write, Describe |
| Databricks | `iot_enriched` | Read, Describe, Group Read |
