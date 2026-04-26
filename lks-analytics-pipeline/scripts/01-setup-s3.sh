#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

RAW_BUCKET="lks-analytics-raw-${ACCOUNT_ID}"
PROCESSED_BUCKET="lks-analytics-processed-${ACCOUNT_ID}"
RESULTS_BUCKET="lks-analytics-results-${ACCOUNT_ID}"

TAGS='TagSet=[
  {Key=Project,Value=nusantara-analytics},
  {Key=Environment,Value=production},
  {Key=ManagedBy,Value=LKS-Team}
]'

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo ""

for BUCKET in "$RAW_BUCKET" "$PROCESSED_BUCKET" "$RESULTS_BUCKET"; do
  echo "==> Creating bucket: ${BUCKET}"
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" \
    2>/dev/null || echo "  (already exists, skipping)"

  aws s3api put-bucket-tagging \
    --bucket "$BUCKET" \
    --tagging "$TAGS"

  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
        "BucketKeyEnabled": true
      }]
    }'

  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "  ${BUCKET} ready"
done

echo ""
echo "==> Enabling EventBridge notifications on raw bucket..."
# This allows S3 Object Created events to flow into EventBridge automatically
aws s3api put-bucket-notification-configuration \
  --bucket "$RAW_BUCKET" \
  --notification-configuration '{"EventBridgeConfiguration": {}}'

echo "==> Uploading Glue ETL script to processed bucket..."
aws s3 cp "$(dirname "$0")/../glue/etl_job.py" \
  "s3://${PROCESSED_BUCKET}/scripts/etl_job.py"

echo "==> Uploading sample sales data for testing..."
aws s3 cp "$(dirname "$0")/../data/sample_sales.csv" \
  "s3://${RAW_BUCKET}/data/sales/2024/01/15/sample_sales.csv"

echo ""
echo "==> S3 setup complete."
echo ""
echo "  RAW_BUCKET:       s3://${RAW_BUCKET}"
echo "  PROCESSED_BUCKET: s3://${PROCESSED_BUCKET}"
echo "  RESULTS_BUCKET:   s3://${RESULTS_BUCKET}"
echo ""
echo "  Glue script:      s3://${PROCESSED_BUCKET}/scripts/etl_job.py"
