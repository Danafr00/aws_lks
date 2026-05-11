#!/bin/bash
set -e

ACCOUNT_ID="547849081977"
REGION="us-east-1"
REPO_NAME="nusantara-shop"
IMAGE_TAG="1.0.0"
APP_DIR="$(dirname "$0")/../app"

echo "=== Layer 1: ECR + Docker Build + Push ==="

# Create ECR repository
echo "[1/4] Creating ECR repository..."
aws ecr create-repository \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --image-scanning-configuration scanOnPush=true \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  2>/dev/null || echo "  ECR repo already exists, skipping..."

ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

# Authenticate Docker to ECR
echo "[2/4] Authenticating Docker to ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# Build Docker image
echo "[3/4] Building Docker image..."
docker build \
  --build-arg APP_VERSION="$IMAGE_TAG" \
  -t "$REPO_NAME:$IMAGE_TAG" \
  -t "$REPO_NAME:latest" \
  "$APP_DIR"

# Tag and push
echo "[4/4] Tagging and pushing to ECR..."
docker tag "$REPO_NAME:$IMAGE_TAG" "$ECR_URI:$IMAGE_TAG"
docker tag "$REPO_NAME:latest" "$ECR_URI:latest"
docker push "$ECR_URI:$IMAGE_TAG"
docker push "$ECR_URI:latest"

echo ""
echo "=== Layer 1 Complete ==="
echo "ECR URI: $ECR_URI"
echo "Image tags: $IMAGE_TAG, latest"
echo ""
echo "Checkpoint:"
aws ecr describe-images \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --query 'imageDetails[*].{Tags:imageTags,Pushed:imagePushedAt}' \
  --output table
