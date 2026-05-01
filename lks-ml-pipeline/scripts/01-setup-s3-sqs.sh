#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

RAW_BUCKET="lks-paytech-raw-${ACCOUNT_ID}"
FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"
PROCESSED_BUCKET="lks-paytech-processed-${ACCOUNT_ID}"
RESULTS_BUCKET="lks-paytech-results-${ACCOUNT_ID}"
QUEUE_NAME="lks-paytech-queue"

echo "==> Creating S3 buckets..."
for BUCKET in $RAW_BUCKET $FEATURES_BUCKET $PROCESSED_BUCKET $RESULTS_BUCKET; do
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" \
    2>/dev/null || echo "  $BUCKET already exists, skipping"
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Suspended
done

echo "==> Creating SQS queue..."
QUEUE_URL=$(aws sqs create-queue \
  --queue-name "$QUEUE_NAME" \
  --attributes VisibilityTimeout=300,MessageRetentionPeriod=86400 \
  --query 'QueueUrl' --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

echo "==> Setting SQS policy to allow S3 to send messages..."
aws sqs set-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attributes "$(cat <<EOF
{
  "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"s3.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"${QUEUE_ARN}\",\"Condition\":{\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:s3:::${RAW_BUCKET}\"}}}]}"
}
EOF
)"

echo "==> Enabling S3 Event Notifications on raw bucket → SQS..."
aws s3api put-bucket-notification-configuration \
  --bucket "$RAW_BUCKET" \
  --notification-configuration "$(cat <<EOF
{
  "QueueConfigurations": [{
    "QueueArn": "${QUEUE_ARN}",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {
      "Key": {
        "FilterRules": [
          {"Name": "prefix", "Value": "data/"},
          {"Name": "suffix", "Value": ".csv"}
        ]
      }
    }
  }]
}
EOF
)"

echo ""
echo "==> 01 Complete!"
echo "RAW_BUCKET=$RAW_BUCKET"
echo "FEATURES_BUCKET=$FEATURES_BUCKET"
echo "PROCESSED_BUCKET=$PROCESSED_BUCKET"
echo "RESULTS_BUCKET=$RESULTS_BUCKET"
echo "QUEUE_URL=$QUEUE_URL"
echo "QUEUE_ARN=$QUEUE_ARN"
