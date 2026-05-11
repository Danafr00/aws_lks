#!/bin/bash
set -e

ACCOUNT_ID="547849081977"
REGION="us-east-1"
PROJECT="nusantara-shop"
BUCKET_NAME="lks-nusantara-frontend-$ACCOUNT_ID"
STATIC_DIR="$(dirname "$0")/../app/static"

ALB_DNS="${ALB_DNS:-$(aws elbv2 describe-load-balancers \
  --names "lks-nusantara-alb" \
  --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)}"

echo "=== Layer 5: S3 Static Website (Frontend CDN) ==="
echo "ALB DNS: $ALB_DNS"

# Create S3 bucket
echo "[1/5] Creating S3 bucket..."
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  2>/dev/null || echo "  Bucket already exists, skipping..."

# Enable static website hosting
echo "[2/5] Enabling static website hosting..."
aws s3api put-bucket-website \
  --bucket "$BUCKET_NAME" \
  --website-configuration '{
    "IndexDocument": {"Suffix": "index.html"},
    "ErrorDocument": {"Key": "index.html"}
  }'

# Disable block public access
echo "[3/5] Enabling public access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Set bucket policy for public read
aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"PublicReadGetObject\",
      \"Effect\": \"Allow\",
      \"Principal\": \"*\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::$BUCKET_NAME/*\"
    }]
  }"

# Inject ALB URL into index.html and upload
echo "[4/5] Injecting API URL and uploading frontend..."
TEMP_DIR=$(mktemp -d)
cp "$STATIC_DIR/index.html" "$TEMP_DIR/index.html"

# Replace the API base URL placeholder
sed -i.bak "s|const API = '';|const API = 'http://$ALB_DNS';|g" "$TEMP_DIR/index.html"

aws s3 cp "$TEMP_DIR/index.html" "s3://$BUCKET_NAME/index.html" \
  --content-type "text/html" \
  --region "$REGION"
rm -rf "$TEMP_DIR"

# Tag bucket
echo "[5/5] Tagging bucket..."
aws s3api put-bucket-tagging \
  --bucket "$BUCKET_NAME" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT},{Key=Environment,Value=production},{Key=ManagedBy,Value=LKS-Team}]"

WEBSITE_URL="http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"

echo ""
echo "=== Layer 5 Complete ==="
echo "S3 Website URL: $WEBSITE_URL"
echo "API URL injected: http://$ALB_DNS"
echo ""
echo "Checkpoint: Open $WEBSITE_URL in browser"
echo "Expected: NusantaraShop UI loads, products visible on click"
