#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(dirname "$0")"
echo "==> Account: ${ACCOUNT_ID}"

# ── SageMaker Execution Role ──────────────────────────────────
echo ""
echo "==> Creating IAM role: LKS-SageMakerRole..."
aws iam create-role \
  --role-name LKS-SageMakerRole \
  --assume-role-policy-document file://"${SCRIPT_DIR}"/../iam/sagemaker-role-trust.json \
  2>/dev/null || echo "  (already exists, skipping)"

aws iam put-role-policy \
  --role-name LKS-SageMakerRole \
  --policy-name LKS-SageMakerS3Policy \
  --policy-document file://"${SCRIPT_DIR}"/../iam/sagemaker-role-policy.json

# AmazonSageMakerFullAccess includes CloudWatch, EC2 describe, etc. required by training/deployment
aws iam attach-role-policy \
  --role-name LKS-SageMakerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

echo "  LKS-SageMakerRole ready"

# ── Lambda Execution Role ─────────────────────────────────────
echo ""
echo "==> Creating IAM role: LKS-LoanRiskLambdaRole..."
TRUST='{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
aws iam create-role \
  --role-name LKS-LoanRiskLambdaRole \
  --assume-role-policy-document "$TRUST" \
  2>/dev/null || echo "  (already exists, skipping)"

aws iam put-role-policy \
  --role-name LKS-LoanRiskLambdaRole \
  --policy-name LKS-LoanRiskLambdaPolicy \
  --policy-document file://"${SCRIPT_DIR}"/../iam/lambda-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-LoanRiskLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

echo "  LKS-LoanRiskLambdaRole ready"
echo ""
echo "==> IAM setup complete."
