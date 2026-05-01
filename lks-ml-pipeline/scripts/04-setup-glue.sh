#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"
PROCESSED_BUCKET="lks-paytech-processed-${ACCOUNT_ID}"
GLUE_ROLE_ARN=$(aws iam get-role --role-name LKS-GlueETLRole --query 'Role.Arn' --output text)
GLUE_DIR="$(dirname "$0")/../glue"

echo "==> Uploading Glue ETL script to S3..."
aws s3 cp "${GLUE_DIR}/etl_job.py" \
  "s3://${PROCESSED_BUCKET}/scripts/etl_job.py" \
  --region "$AWS_REGION"

echo "==> Creating Glue Database..."
aws glue create-database \
  --database-input '{"Name":"lks_paytech_db","Description":"PayTech fraud detection data catalog"}' \
  2>/dev/null || echo "  Database already exists"

echo "==> Creating Glue ETL Job..."
aws glue create-job \
  --name lks-etl-paytech \
  --role "$GLUE_ROLE_ARN" \
  --command "Name=glueetl,ScriptLocation=s3://${PROCESSED_BUCKET}/scripts/etl_job.py,PythonVersion=3" \
  --default-arguments "{
    \"--JOB_NAME\": \"lks-etl-paytech\",
    \"--S3_FEATURES_PATH\": \"s3://${FEATURES_BUCKET}/features/\",
    \"--S3_OUTPUT_PATH\": \"s3://${PROCESSED_BUCKET}/parquet/\",
    \"--enable-metrics\": \"\",
    \"--enable-continuous-cloudwatch-log\": \"true\"
  }" \
  --glue-version "4.0" \
  --worker-type G.025X \
  --number-of-workers 2 \
  2>/dev/null || echo "  Glue job already exists"

echo "==> Creating Glue Crawler..."
aws glue create-crawler \
  --name lks-crawler-paytech \
  --role "$GLUE_ROLE_ARN" \
  --database-name lks_paytech_db \
  --targets "S3Targets=[{Path: \"s3://${PROCESSED_BUCKET}/parquet/\"}]" \
  --schedule "cron(0 * * * ? *)" \
  2>/dev/null || echo "  Crawler already exists"

echo "==> Creating Athena Workgroup..."
aws athena create-work-group \
  --name lks-paytech-wg \
  --configuration "ResultConfiguration={OutputLocation=s3://${PROCESSED_BUCKET}/athena-results/}" \
  2>/dev/null || echo "  Workgroup already exists"

echo ""
echo "==> 04 Complete!"
echo "Run Glue ETL (after uploading features):"
echo "  aws glue start-job-run --job-name lks-etl-paytech"
echo "Run Crawler after ETL:"
echo "  aws glue start-crawler --name lks-crawler-paytech"
