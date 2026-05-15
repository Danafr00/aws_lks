#!/bin/bash
# Deploy the CloudFormation stack

set -e

STACK_NAME="lks-fundamentals"
TEMPLATE="$(dirname "$0")/../templates/main.yaml"
REGION="us-east-1"

echo "Enter DB password (min 8 chars):"
read -rs DB_PASSWORD

echo ""
echo "--- Validating template ---"
aws cloudformation validate-template \
  --template-body file://"$TEMPLATE" \
  --region "$REGION"

echo ""
echo "--- Deploying stack: $STACK_NAME ---"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --parameter-overrides DBPassword="$DB_PASSWORD" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"

echo ""
echo "--- Stack outputs ---"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
  --output table
