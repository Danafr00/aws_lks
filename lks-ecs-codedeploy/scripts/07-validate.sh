#!/bin/bash

REGION="us-east-1"
ACCOUNT_ID="547849081977"
PASS=0
FAIL=0

green() { echo -e "\033[0;32m✓ $1\033[0m"; PASS=$((PASS+1)); }
red()   { echo -e "\033[0;31m✗ $1\033[0m"; FAIL=$((FAIL+1)); }
info()  { echo -e "\033[0;34m→ $1\033[0m"; }

echo "=== NusantaraShop End-to-End Validation ==="
echo ""

# ECR
info "Checking ECR..."
if aws ecr describe-repositories --repository-names "nusantara-shop" --region "$REGION" &>/dev/null; then
  IMAGE_COUNT=$(aws ecr describe-images --repository-name "nusantara-shop" --region "$REGION" \
    --query 'length(imageDetails)' --output text)
  green "ECR repo 'nusantara-shop' exists with $IMAGE_COUNT image(s)"
else
  red "ECR repo 'nusantara-shop' not found"
fi

# ElastiCache
info "Checking ElastiCache..."
REDIS_STATUS=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "lks-nusantara-redis" --region "$REGION" \
  --query 'CacheClusters[0].CacheClusterStatus' --output text 2>/dev/null)
if [ "$REDIS_STATUS" = "available" ]; then
  REDIS_HOST=$(aws elasticache describe-cache-clusters \
    --cache-cluster-id "lks-nusantara-redis" --show-cache-node-info \
    --region "$REGION" \
    --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text)
  green "ElastiCache Redis 'lks-nusantara-redis' is available at $REDIS_HOST"
else
  red "ElastiCache Redis status: $REDIS_STATUS (expected: available)"
fi

# ECS cluster
info "Checking ECS cluster..."
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "lks-nusantara-cluster" --region "$REGION" \
  --query 'clusters[0].status' --output text 2>/dev/null)
if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
  green "ECS cluster 'lks-nusantara-cluster' is ACTIVE"
else
  red "ECS cluster status: $CLUSTER_STATUS"
fi

# ECS service
info "Checking ECS service..."
SVC_STATUS=$(aws ecs describe-services \
  --cluster "lks-nusantara-cluster" --services "nusantara-shop-svc" \
  --region "$REGION" \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
  --output json 2>/dev/null)
RUNNING=$(echo "$SVC_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Running',0))" 2>/dev/null || echo 0)
DESIRED=$(echo "$SVC_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Desired',0))" 2>/dev/null || echo 0)
if [ "$RUNNING" -ge 1 ] && [ "$RUNNING" = "$DESIRED" ]; then
  green "ECS service running $RUNNING/$DESIRED tasks"
else
  red "ECS service: running=$RUNNING, desired=$DESIRED"
fi

# ALB health check
info "Checking ALB and HTTP endpoint..."
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "lks-nusantara-alb" --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS/health" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    HEALTH_RESP=$(curl -s --max-time 10 "http://$ALB_DNS/health" 2>/dev/null)
    green "ALB health check: HTTP 200 — $HEALTH_RESP"
  else
    red "ALB health check: HTTP $HTTP_CODE (expected 200) at http://$ALB_DNS/health"
  fi
else
  red "ALB 'lks-nusantara-alb' not found"
fi

# Products endpoint with cache test
info "Checking /products caching..."
if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  FIRST=$(curl -s --max-time 10 "http://$ALB_DNS/products" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source','err'))" 2>/dev/null)
  SECOND=$(curl -s --max-time 10 "http://$ALB_DNS/products" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source','err'))" 2>/dev/null)
  if [ "$FIRST" = "db" ] && [ "$SECOND" = "cache" ]; then
    green "Cache working: 1st call=db, 2nd call=cache"
  else
    red "Cache check: 1st=$FIRST, 2nd=$SECOND (expected db then cache)"
  fi
fi

# S3 frontend
info "Checking S3 frontend..."
BUCKET_NAME="lks-nusantara-frontend-$ACCOUNT_ID"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  WEBSITE_URL="http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"
  WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$WEBSITE_URL" 2>/dev/null)
  if [ "$WEB_CODE" = "200" ]; then
    green "S3 frontend accessible at $WEBSITE_URL"
  else
    red "S3 frontend: HTTP $WEB_CODE at $WEBSITE_URL"
  fi
else
  red "S3 frontend bucket '$BUCKET_NAME' not found"
fi

# CodeDeploy
info "Checking CodeDeploy..."
if aws deploy get-application --application-name "lks-nusantara-app" --region "$REGION" &>/dev/null; then
  green "CodeDeploy application 'lks-nusantara-app' exists"
  DG_STATUS=$(aws deploy get-deployment-group \
    --application-name "lks-nusantara-app" \
    --deployment-group-name "lks-nusantara-dg" \
    --region "$REGION" \
    --query 'deploymentGroupInfo.computePlatform' --output text 2>/dev/null)
  green "CodeDeploy deployment group platform: $DG_STATUS"
else
  red "CodeDeploy application 'lks-nusantara-app' not found"
fi

# CodePipeline
info "Checking CodePipeline..."
PIPELINE_STATUS=$(aws codepipeline get-pipeline-state \
  --name "lks-nusantara-pipeline" --region "$REGION" \
  --query 'stageStates[1].latestExecution.status' --output text 2>/dev/null)
if [ "$PIPELINE_STATUS" = "Succeeded" ]; then
  green "CodePipeline last Deploy stage: Succeeded"
elif [ -n "$PIPELINE_STATUS" ]; then
  red "CodePipeline Deploy stage status: $PIPELINE_STATUS (expected: Succeeded)"
else
  red "CodePipeline 'lks-nusantara-pipeline' not found or never run"
fi

# Summary
echo ""
echo "=============================="
echo "Validation: $PASS passed, $FAIL failed"
echo "=============================="
if [ "$FAIL" -eq 0 ]; then
  echo -e "\033[0;32mAll checks passed! NusantaraShop is fully deployed.\033[0m"
  echo ""
  echo "Access points:"
  echo "  API:      http://$ALB_DNS"
  echo "  Frontend: http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"
else
  echo -e "\033[0;31m$FAIL check(s) failed. Review the errors above.\033[0m"
  exit 1
fi
