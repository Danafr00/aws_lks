#!/bin/bash
# IAM roles cannot be created in this Vocareum lab environment (iam:CreateRole is denied).
# All services use the pre-existing LabRole.
# This script just prints the LabRole ARN for reference.

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole

echo "==> [02] IAM: Using LabRole for all services"
echo "    LAB_ROLE_ARN=${LAB_ROLE_ARN}"
echo ""
echo "  LabRole is used as:"
echo "    - Lambda execution role"
echo "    - Glue ETL job role"
echo "    - SageMaker training + endpoint execution role"
echo "    - ECS task role + execution role"
echo ""
echo "==> 02 Complete! (no new roles created)"
