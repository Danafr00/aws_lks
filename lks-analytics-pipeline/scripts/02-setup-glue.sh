#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

PROCESSED_BUCKET="lks-analytics-processed-${ACCOUNT_ID}"

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── IAM Role ──────────────────────────────────────────────────
echo ""
echo "==> Creating IAM role LKS-GlueETLRole..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "glue.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name LKS-GlueETLRole \
  --assume-role-policy-document "$TRUST_POLICY" \
  2>/dev/null || echo "  (already exists, skipping)"

aws iam put-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-name LKS-GlueETLPolicy \
  --policy-document file://"$(dirname "$0")"/../iam/glue-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

echo "  LKS-GlueETLRole ready"

# ── Glue Database ─────────────────────────────────────────────
echo ""
echo "==> Creating Glue Data Catalog database: lks_analytics_db..."
aws glue create-database \
  --region "$REGION" \
  --database-input '{
    "Name": "lks_analytics_db",
    "Description": "Nusantara Retail Analytics data lake"
  }' \
  2>/dev/null || echo "  (already exists, skipping)"

# ── Glue ETL Job ──────────────────────────────────────────────
echo ""
echo "==> Creating Glue ETL job: lks-etl-sales..."
aws glue create-job \
  --region "$REGION" \
  --name lks-etl-sales \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole" \
  --command "{
    \"Name\": \"glueetl\",
    \"ScriptLocation\": \"s3://${PROCESSED_BUCKET}/scripts/etl_job.py\",
    \"PythonVersion\": \"3\"
  }" \
  --glue-version "4.0" \
  --worker-type "G.025X" \
  --number-of-workers 2 \
  --timeout 10 \
  --default-arguments "{
    \"--job-language\": \"python\",
    \"--enable-metrics\": \"true\",
    \"--enable-continuous-cloudwatch-log\": \"true\",
    \"--enable-spark-ui\": \"false\",
    \"--S3_PROCESSED_BUCKET\": \"${PROCESSED_BUCKET}\",
    \"--S3_PROCESSED_PREFIX\": \"sales\",
    \"--S3_RAW_PATH\": \"\"
  }" \
  --tags '{
    "Project": "nusantara-analytics",
    "Environment": "production",
    "ManagedBy": "LKS-Team"
  }' \
  2>/dev/null || echo "  (already exists, skipping)"

echo "  lks-etl-sales ready"

# ── Glue Crawler ──────────────────────────────────────────────
echo ""
echo "==> Creating Glue Crawler: lks-crawler-sales..."
aws glue create-crawler \
  --region "$REGION" \
  --name lks-crawler-sales \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole" \
  --database-name lks_analytics_db \
  --targets "{\"S3Targets\": [{\"Path\": \"s3://${PROCESSED_BUCKET}/sales/\"}]}" \
  --schedule "cron(0 * * * ? *)" \
  --configuration '{
    "Version": 1.0,
    "CrawlerOutput": {
      "Partitions": {"AddOrUpdateBehavior": "InheritFromTable"}
    },
    "Grouping": {"TableGroupingPolicy": "CombineCompatibleSchemas"}
  }' \
  --tags '{
    "Project": "nusantara-analytics",
    "Environment": "production",
    "ManagedBy": "LKS-Team"
  }' \
  2>/dev/null || echo "  (already exists, skipping)"

echo "  lks-crawler-sales ready (schedule: hourly)"
echo ""
echo "==> Glue setup complete."
