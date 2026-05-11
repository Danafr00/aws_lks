#!/bin/bash
set -e

REGION="us-east-1"
VPC_ID="vpc-0afa6269969fc33d9"
PROJECT="nusantara-shop"

echo "=== Layer 2: Security Groups ==="

# ALB Security Group
echo "[1/3] Creating ALB security group..."
ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name "lks-nusantara-alb-sg" \
  --description "ALB SG for NusantaraShop" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=lks-nusantara-alb-sg},{Key=Project,Value=$PROJECT},{Key=Environment,Value=production},{Key=ManagedBy,Value=LKS-Team}]" \
  --query 'GroupId' --output text 2>/dev/null) || \
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lks-nusantara-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)

echo "  ALB SG: $ALB_SG_ID"

# ALB inbound: HTTP 80 from anywhere
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --region "$REGION" 2>/dev/null || true
# ALB inbound: test port 8080 for Blue/Green
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0 \
  --region "$REGION" 2>/dev/null || true

# ECS Task Security Group
echo "[2/3] Creating ECS task security group..."
ECS_SG_ID=$(aws ec2 create-security-group \
  --group-name "lks-nusantara-ecs-sg" \
  --description "ECS Task SG for NusantaraShop" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=lks-nusantara-ecs-sg},{Key=Project,Value=$PROJECT},{Key=Environment,Value=production},{Key=ManagedBy,Value=LKS-Team}]" \
  --query 'GroupId' --output text 2>/dev/null) || \
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lks-nusantara-ecs-sg" "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)

echo "  ECS SG: $ECS_SG_ID"

# ECS inbound: port 5000 from ALB only
aws ec2 authorize-security-group-ingress \
  --group-id "$ECS_SG_ID" \
  --protocol tcp --port 5000 \
  --source-group "$ALB_SG_ID" \
  --region "$REGION" 2>/dev/null || true

# ElastiCache Security Group
echo "[3/3] Creating ElastiCache security group..."
REDIS_SG_ID=$(aws ec2 create-security-group \
  --group-name "lks-nusantara-redis-sg" \
  --description "Redis SG for NusantaraShop" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=lks-nusantara-redis-sg},{Key=Project,Value=$PROJECT},{Key=Environment,Value=production},{Key=ManagedBy,Value=LKS-Team}]" \
  --query 'GroupId' --output text 2>/dev/null) || \
REDIS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lks-nusantara-redis-sg" "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)

echo "  Redis SG: $REDIS_SG_ID"

# Redis inbound: port 6379 from ECS only
aws ec2 authorize-security-group-ingress \
  --group-id "$REDIS_SG_ID" \
  --protocol tcp --port 6379 \
  --source-group "$ECS_SG_ID" \
  --region "$REGION" 2>/dev/null || true

echo ""
echo "=== Layer 2 Complete ==="
echo "ALB SG:   $ALB_SG_ID"
echo "ECS SG:   $ECS_SG_ID"
echo "Redis SG: $REDIS_SG_ID"
echo ""
echo "Save these for later scripts:"
echo "export ALB_SG_ID=$ALB_SG_ID"
echo "export ECS_SG_ID=$ECS_SG_ID"
echo "export REDIS_SG_ID=$REDIS_SG_ID"
