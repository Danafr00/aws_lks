#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"
QUEUE_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/lks-paytech-queue"
QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:lks-paytech-queue"
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name LKS-FeatureLambdaRole --query 'Role.Arn' --output text)
APP_DIR="$(dirname "$0")/../app/feature_lambda"

echo "==> Packaging Lambda..."
cd "$APP_DIR"
zip -q /tmp/lks-feature-trigger.zip handler.py
cd - > /dev/null

echo "==> Deploying Lambda function..."
aws lambda create-function \
  --function-name lks-feature-trigger \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$LAMBDA_ROLE_ARN" \
  --zip-file fileb:///tmp/lks-feature-trigger.zip \
  --timeout 300 \
  --memory-size 256 \
  --environment "Variables={FEATURES_BUCKET=${FEATURES_BUCKET}}" \
  --region "$AWS_REGION" \
  2>/dev/null || \
aws lambda update-function-code \
  --function-name lks-feature-trigger \
  --zip-file fileb:///tmp/lks-feature-trigger.zip \
  --region "$AWS_REGION" > /dev/null

echo "  Waiting for Lambda to be active..."
aws lambda wait function-active-v2 --function-name lks-feature-trigger --region "$AWS_REGION"

echo "==> Updating environment variables..."
aws lambda update-function-configuration \
  --function-name lks-feature-trigger \
  --environment "Variables={FEATURES_BUCKET=${FEATURES_BUCKET}}" \
  --region "$AWS_REGION" > /dev/null

echo "==> Adding SQS event source mapping..."
aws lambda create-event-source-mapping \
  --function-name lks-feature-trigger \
  --event-source-arn "$QUEUE_ARN" \
  --batch-size 10 \
  --region "$AWS_REGION" \
  2>/dev/null || echo "  Event source mapping already exists, skipping"

echo ""
echo "==> 03 Complete!"
echo "Lambda lks-feature-trigger deployed and connected to SQS"
