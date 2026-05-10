#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
PROJECT=lks-streaming-pipeline
STREAM_NAME=lks-pipeline-stream
DYNAMO_TABLE=lks-pipeline-orders

RAW_BUCKET=lks-pipeline-raw-${ACCOUNT_ID}
PROCESSED_BUCKET=lks-pipeline-processed-${ACCOUNT_ID}
RESULTS_BUCKET=lks-pipeline-results-${ACCOUNT_ID}

echo "==> [01] Setting up storage: S3, Kinesis, DynamoDB"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── S3 Buckets ────────────────────────────────────────────────────────────────
for BUCKET in "$RAW_BUCKET" "$PROCESSED_BUCKET" "$RESULTS_BUCKET"; do
  echo "  Creating bucket: ${BUCKET}"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null \
    || echo "    (already exists)"

  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    2>/dev/null || true

  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
      'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' \
    2>/dev/null || true
done

# Enable EventBridge on raw bucket
aws s3api put-bucket-notification-configuration \
  --bucket "$RAW_BUCKET" \
  --notification-configuration '{"EventBridgeConfiguration":{}}' 2>/dev/null || true

echo "  S3 buckets: OK"

# ── Kinesis Data Stream ───────────────────────────────────────────────────────
echo "  Creating Kinesis stream: ${STREAM_NAME}"
aws kinesis create-stream \
  --stream-name "$STREAM_NAME" \
  --shard-count 1 \
  --region "$REGION" 2>/dev/null || echo "    (already exists)"

echo "  Waiting for stream ACTIVE..."
aws kinesis wait stream-exists --stream-name "$STREAM_NAME" --region "$REGION"

# Retention 24h
aws kinesis increase-stream-retention-period \
  --stream-name "$STREAM_NAME" \
  --retention-period-hours 24 \
  --region "$REGION" 2>/dev/null || true

# Tag stream
aws kinesis add-tags-to-stream \
  --stream-name "$STREAM_NAME" \
  --tags "Project=${PROJECT},Environment=production,ManagedBy=LKS-Team" \
  --region "$REGION" 2>/dev/null || true

echo "  Kinesis stream: OK"

# ── DynamoDB Table ────────────────────────────────────────────────────────────
echo "  Creating DynamoDB table: ${DYNAMO_TABLE}"
aws dynamodb create-table \
  --table-name "$DYNAMO_TABLE" \
  --attribute-definitions AttributeName=order_id,AttributeType=S \
  --key-schema AttributeName=order_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" 2>/dev/null || echo "    (already exists)"

echo "  Waiting for table ACTIVE..."
aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$REGION"

aws dynamodb tag-resource \
  --resource-arn "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DYNAMO_TABLE}" \
  --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=production" "Key=ManagedBy,Value=LKS-Team" \
  --region "$REGION" 2>/dev/null || true

echo "  DynamoDB table: OK"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> [01] Layer 1 complete."
echo "    Buckets : ${RAW_BUCKET}"
echo "             ${PROCESSED_BUCKET}"
echo "             ${RESULTS_BUCKET}"
echo "    Stream  : ${STREAM_NAME}"
echo "    DynamoDB: ${DYNAMO_TABLE}"
echo ""
echo "Checkpoint: aws kinesis describe-stream-summary --stream-name ${STREAM_NAME} --region ${REGION}"
