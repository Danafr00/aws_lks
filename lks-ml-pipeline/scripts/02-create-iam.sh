#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IAM_DIR="$(dirname "$0")/../iam"

create_role() {
  local NAME=$1 TRUST_FILE=$2 POLICY_FILE=$3
  echo "==> Creating role: $NAME"
  aws iam create-role \
    --role-name "$NAME" \
    --assume-role-policy-document "file://${TRUST_FILE}" \
    2>/dev/null || echo "  $NAME already exists, skipping"
  aws iam put-role-policy \
    --role-name "$NAME" \
    --policy-name "${NAME}Policy" \
    --policy-document "file://${POLICY_FILE}"
}

create_role LKS-FeatureLambdaRole \
  "${IAM_DIR}/lambda-feature-trust.json" \
  "${IAM_DIR}/lambda-feature-policy.json"

create_role LKS-GlueETLRole \
  "${IAM_DIR}/glue-role-trust.json" \
  "${IAM_DIR}/glue-role-policy.json"

aws iam attach-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole \
  2>/dev/null || true

create_role LKS-SageMakerRole \
  "${IAM_DIR}/sagemaker-role-trust.json" \
  "${IAM_DIR}/sagemaker-role-policy.json"

aws iam attach-role-policy \
  --role-name LKS-SageMakerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess \
  2>/dev/null || true

create_role LKS-ECSTaskRole \
  "${IAM_DIR}/ecs-task-role-trust.json" \
  "${IAM_DIR}/ecs-task-role-policy.json"

echo "==> Creating ECS Execution Role..."
aws iam create-role \
  --role-name LKS-ECSExecutionRole \
  --assume-role-policy-document "file://${IAM_DIR}/ecs-task-role-trust.json" \
  2>/dev/null || echo "  LKS-ECSExecutionRole already exists, skipping"

aws iam attach-role-policy \
  --role-name LKS-ECSExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
  2>/dev/null || true

echo ""
echo "==> 02 Complete!"
echo "LAMBDA_ROLE_ARN=$(aws iam get-role --role-name LKS-FeatureLambdaRole --query 'Role.Arn' --output text)"
echo "ECS_TASK_ROLE_ARN=$(aws iam get-role --role-name LKS-ECSTaskRole --query 'Role.Arn' --output text)"
echo "ECS_EXEC_ROLE_ARN=$(aws iam get-role --role-name LKS-ECSExecutionRole --query 'Role.Arn' --output text)"
