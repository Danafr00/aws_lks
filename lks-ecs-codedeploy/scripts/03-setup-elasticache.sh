#!/bin/bash
set -e

REGION="us-east-1"
PROJECT="nusantara-shop"
REDIS_SG_ID="${REDIS_SG_ID:-$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lks-nusantara-redis-sg" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)}"

echo "=== Layer 3: ElastiCache Redis ==="
echo "Using Redis SG: $REDIS_SG_ID"

# Create subnet group using first 2 AZs (1a, 1b)
echo "[1/3] Creating ElastiCache subnet group..."
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name "lks-nusantara-redis-subnet" \
  --cache-subnet-group-description "Redis subnet group for NusantaraShop" \
  --subnet-ids \
    "subnet-00baa17b56177ca53" \
    "subnet-06bd37455afbe4837" \
    "subnet-07de5176ed29efed0" \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  2>/dev/null || echo "  Subnet group already exists, skipping..."

# Create Redis cluster
echo "[2/3] Creating Redis cache cluster..."
aws elasticache create-cache-cluster \
  --cache-cluster-id "lks-nusantara-redis" \
  --cache-node-type "cache.t3.micro" \
  --engine "redis" \
  --engine-version "7.1" \
  --num-cache-nodes 1 \
  --cache-subnet-group-name "lks-nusantara-redis-subnet" \
  --security-group-ids "$REDIS_SG_ID" \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  2>/dev/null || echo "  Redis cluster already exists, skipping..."

# Wait for Redis to be available
echo "[3/3] Waiting for Redis cluster to be available (takes ~5 min)..."
aws elasticache wait cache-cluster-available \
  --cache-cluster-id "lks-nusantara-redis" \
  --region "$REGION"

# Get Redis endpoint
REDIS_ENDPOINT=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "lks-nusantara-redis" \
  --show-cache-node-info \
  --region "$REGION" \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' \
  --output text)

echo ""
echo "Redis endpoint: $REDIS_ENDPOINT"

# Store endpoint in SSM Parameter Store
echo "Storing Redis endpoint in SSM Parameter Store..."
aws ssm put-parameter \
  --name "/nusantara-shop/redis-host" \
  --value "$REDIS_ENDPOINT" \
  --type "String" \
  --overwrite \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team

echo ""
echo "=== Layer 3 Complete ==="
echo "Redis endpoint: $REDIS_ENDPOINT"
echo "SSM Parameter: /nusantara-shop/redis-host"
echo ""
echo "Checkpoint:"
aws elasticache describe-cache-clusters \
  --cache-cluster-id "lks-nusantara-redis" \
  --region "$REGION" \
  --query 'CacheClusters[0].{Status:CacheClusterStatus,Node:CacheNodes[0].Endpoint.Address}' \
  --output table
