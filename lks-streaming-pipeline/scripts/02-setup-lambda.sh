#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole

STREAM_NAME=lks-pipeline-stream
DYNAMO_TABLE=lks-pipeline-orders
FIREHOSE_STREAM=lks-pipeline-firehose
FUNCTION_NAME=lks-pipeline-transformer
APP_DIR="$(cd "$(dirname "$0")/../app" && pwd)"

echo "==> [02] Setting up Lambda transformer"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── Package Lambda ────────────────────────────────────────────────────────────
echo "  Packaging Lambda function..."
cd "$APP_DIR"
zip -q /tmp/transformer.zip transformer.py
echo "  Package: /tmp/transformer.zip ($(du -sh /tmp/transformer.zip | cut -f1))"

# ── Get Kinesis Stream ARN ────────────────────────────────────────────────────
STREAM_ARN=$(aws kinesis describe-stream-summary \
  --stream-name "$STREAM_NAME" \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)
echo "  Stream ARN: ${STREAM_ARN}"

# ── Create / Update Lambda ────────────────────────────────────────────────────
EXISTING=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" 2>&1 || true)
if echo "$EXISTING" | grep -q '"FunctionName"'; then
  echo "  Updating existing function..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb:///tmp/transformer.zip \
    --region "$REGION" > /dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "Variables={DYNAMODB_TABLE=${DYNAMO_TABLE},FIREHOSE_STREAM=${FIREHOSE_STREAM},AWS_ACCOUNT_ID=${ACCOUNT_ID}}" \
    --region "$REGION" > /dev/null
else
  echo "  Creating Lambda function..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$LAB_ROLE_ARN" \
    --handler transformer.handler \
    --zip-file fileb:///tmp/transformer.zip \
    --timeout 60 \
    --memory-size 256 \
    --environment "Variables={DYNAMODB_TABLE=${DYNAMO_TABLE},FIREHOSE_STREAM=${FIREHOSE_STREAM},AWS_ACCOUNT_ID=${ACCOUNT_ID}}" \
    --region "$REGION" > /dev/null
  echo "  Waiting for Lambda active..."
  aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION"
fi

# Tag Lambda
FUNCTION_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)
aws lambda tag-resource --resource "$FUNCTION_ARN" \
  --tags "Project=lks-streaming-pipeline,Environment=production,ManagedBy=LKS-Team" \
  --region "$REGION" 2>/dev/null || true

echo "  Lambda function: OK (${FUNCTION_ARN})"

# ── Kinesis Event Source Mapping ──────────────────────────────────────────────
echo "  Creating Kinesis event source mapping..."
ESM_EXISTS=$(aws lambda list-event-source-mappings \
  --function-name "$FUNCTION_NAME" \
  --event-source-arn "$STREAM_ARN" \
  --region "$REGION" \
  --query 'EventSourceMappings[0].UUID' \
  --output text 2>/dev/null)

if [ "$ESM_EXISTS" = "None" ] || [ -z "$ESM_EXISTS" ]; then
  aws lambda create-event-source-mapping \
    --function-name "$FUNCTION_NAME" \
    --event-source-arn "$STREAM_ARN" \
    --batch-size 10 \
    --starting-position TRIM_HORIZON \
    --bisect-batch-on-function-error \
    --destination-config '{"OnFailure":{}}' \
    --region "$REGION" > /dev/null
  echo "  Event source mapping: created"
else
  echo "  Event source mapping: already exists (${ESM_EXISTS})"
fi

echo ""
echo "==> [02] Layer 2 (Lambda) complete."
echo "    Function: ${FUNCTION_NAME}"
echo "    Trigger : Kinesis (${STREAM_NAME}), batch=10"
echo ""
echo "Checkpoint: aws lambda get-function --function-name ${FUNCTION_NAME} --region ${REGION}"
