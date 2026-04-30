#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

DATA_BUCKET="lks-sagemaker-data-${ACCOUNT_ID}"
MODEL_BUCKET="lks-sagemaker-models-${ACCOUNT_ID}"

TAGS='TagSet=[
  {Key=Project,Value=nusantara-fincredit},
  {Key=Environment,Value=production},
  {Key=ManagedBy,Value=LKS-Team}
]'

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"

for BUCKET in "$DATA_BUCKET" "$MODEL_BUCKET"; do
  echo ""
  echo "==> Creating bucket: ${BUCKET}"
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" \
    2>/dev/null || echo "  (already exists, skipping)"

  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "$TAGS"

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]
    }'

  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "  ${BUCKET} ready"
done

echo ""
echo "==> Uploading training and validation data..."
SCRIPT_DIR="$(dirname "$0")"
aws s3 cp "${SCRIPT_DIR}/../data/train.csv"      "s3://${DATA_BUCKET}/train/train.csv"
aws s3 cp "${SCRIPT_DIR}/../data/validation.csv" "s3://${DATA_BUCKET}/validation/validation.csv"

echo ""
echo "==> S3 setup complete."
echo "  Data bucket:   s3://${DATA_BUCKET}"
echo "  Model bucket:  s3://${MODEL_BUCKET}"
echo "  Train data:    s3://${DATA_BUCKET}/train/train.csv"
echo "  Val data:      s3://${DATA_BUCKET}/validation/validation.csv"
