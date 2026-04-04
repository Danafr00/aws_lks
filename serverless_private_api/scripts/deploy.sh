#!/bin/bash
set -e

STACK_NAME="lks-vpc-rds-lambda"
REGION="ap-southeast-1"
TEMPLATE="template.yaml"

# ── Required: set these before running ─────────────────────────
DB_PASSWORD="${DB_PASSWORD:-ChangeMe123!}"
BASTION_KEY="${BASTION_KEY_NAME:-your-key-pair-name}"
# ───────────────────────────────────────────────────────────────

echo "==> Deploying stack: $STACK_NAME in $REGION"

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ProjectName=lks-app \
      DBName=lksdb \
      DBUsername=admin \
      DBPassword="$DB_PASSWORD" \
      BastionKeyName="$BASTION_KEY" \
      BastionAllowedCIDR="0.0.0.0/0" \
  --no-fail-on-empty-changeset

echo ""
echo "==> Stack deployed. Outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table
