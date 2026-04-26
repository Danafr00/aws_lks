#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

RAW_BUCKET="lks-analytics-raw-${ACCOUNT_ID}"
PROCESSED_BUCKET="lks-analytics-processed-${ACCOUNT_ID}"
LAMBDA_DIR="$(dirname "$0")/../lambda"

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── IAM: Lambda Role ──────────────────────────────────────────
echo ""
echo "==> Creating IAM role LKS-LambdaGlueTriggerRole..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name LKS-LambdaGlueTriggerRole \
  --assume-role-policy-document "$TRUST_POLICY" \
  2>/dev/null || echo "  (already exists, skipping)"

aws iam put-role-policy \
  --role-name LKS-LambdaGlueTriggerRole \
  --policy-name LKS-LambdaGlueTriggerPolicy \
  --policy-document file://"$(dirname "$0")"/../iam/lambda-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-LambdaGlueTriggerRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

echo "  LKS-LambdaGlueTriggerRole ready"
echo "  Waiting 10s for IAM role propagation..."
sleep 10

# ── Lambda: Package and Deploy ────────────────────────────────
echo ""
echo "==> Packaging Lambda function..."
cd "$LAMBDA_DIR"
zip -q function.zip trigger_glue.py
echo "  function.zip created"

echo "==> Deploying Lambda function: lks-glue-trigger..."
LAMBDA_ARN=$(aws lambda create-function \
  --region "$REGION" \
  --function-name lks-glue-trigger \
  --runtime python3.12 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-LambdaGlueTriggerRole" \
  --handler trigger_glue.handler \
  --zip-file fileb://function.zip \
  --memory-size 128 \
  --timeout 60 \
  --environment "Variables={
    GLUE_JOB_NAME=lks-etl-sales,
    S3_PROCESSED_BUCKET=${PROCESSED_BUCKET},
    S3_PROCESSED_PREFIX=sales
  }" \
  --tags '{
    "Project": "nusantara-analytics",
    "Environment": "production",
    "ManagedBy": "LKS-Team"
  }' \
  --query FunctionArn --output text \
  2>/dev/null) || {
    echo "  (already exists — updating code and config...)"
    aws lambda update-function-code \
      --region "$REGION" \
      --function-name lks-glue-trigger \
      --zip-file fileb://function.zip \
      --query FunctionArn --output text > /dev/null
    LAMBDA_ARN=$(aws lambda get-function \
      --region "$REGION" \
      --function-name lks-glue-trigger \
      --query Configuration.FunctionArn --output text)
  }

rm -f function.zip
cd - > /dev/null

echo "  Lambda ARN: ${LAMBDA_ARN}"

# ── EventBridge: Rule ─────────────────────────────────────────
echo ""
echo "==> Creating EventBridge rule: lks-s3-sales-upload..."

EVENT_PATTERN="{
  \"source\": [\"aws.s3\"],
  \"detail-type\": [\"Object Created\"],
  \"detail\": {
    \"bucket\": {\"name\": [\"${RAW_BUCKET}\"]},
    \"object\": {\"key\": [{\"prefix\": \"data/sales/\"}]}
  }
}"

aws events put-rule \
  --region "$REGION" \
  --name lks-s3-sales-upload \
  --event-pattern "$EVENT_PATTERN" \
  --state ENABLED \
  --description "Trigger Glue ETL when CSV lands in raw analytics bucket" \
  2>/dev/null || echo "  (already exists, updating...)"

echo "  EventBridge rule ready"

# ── EventBridge: Add Lambda permission ───────────────────────
echo ""
echo "==> Granting EventBridge permission to invoke Lambda..."
aws lambda add-permission \
  --region "$REGION" \
  --function-name lks-glue-trigger \
  --statement-id EventBridgeS3SalesUpload \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/lks-s3-sales-upload" \
  2>/dev/null || echo "  (permission already exists, skipping)"

# ── EventBridge: Set Lambda as Target ────────────────────────
echo ""
echo "==> Setting Lambda as EventBridge target..."
aws events put-targets \
  --region "$REGION" \
  --rule lks-s3-sales-upload \
  --targets "[{\"Id\": \"LambdaTarget\", \"Arn\": \"${LAMBDA_ARN}\"}]"

echo ""
echo "==> Lambda & EventBridge setup complete."
echo ""
echo "  Function:    lks-glue-trigger"
echo "  Rule:        lks-s3-sales-upload"
echo "  Trigger:     s3://${RAW_BUCKET}/data/sales/**/*.csv"
