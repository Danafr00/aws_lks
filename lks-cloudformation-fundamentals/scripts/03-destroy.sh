#!/bin/bash
# Delete the CloudFormation stack and all resources

STACK_NAME="lks-fundamentals"
REGION="us-east-1"

echo "WARNING: This deletes ALL resources in stack $STACK_NAME:"
echo "  - NAT Gateway, ALB, RDS, EC2, Lambda, DynamoDB, API Gateway"
echo ""
echo "Type 'yes' to confirm:"
read -r confirm
[ "$confirm" != "yes" ] && echo "Cancelled." && exit 0

aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "Waiting for deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "Stack deleted."
