#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole

FIREHOSE_STREAM=lks-pipeline-firehose
RAW_BUCKET=lks-pipeline-raw-${ACCOUNT_ID}

echo "==> [03] Setting up Kinesis Firehose delivery stream"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo "    Target : s3://${RAW_BUCKET}/orders/"

# ── Create Firehose Delivery Stream ──────────────────────────────────────────
EXISTING=$(aws firehose describe-delivery-stream \
  --delivery-stream-name "$FIREHOSE_STREAM" \
  --region "$REGION" 2>&1 || true)

if echo "$EXISTING" | grep -q '"DeliveryStreamName"'; then
  echo "  Delivery stream already exists."
else
  echo "  Creating Firehose delivery stream..."
  aws firehose create-delivery-stream \
    --delivery-stream-name "$FIREHOSE_STREAM" \
    --delivery-stream-type DirectPut \
    --extended-s3-destination-configuration "
{
  \"RoleARN\": \"${LAB_ROLE_ARN}\",
  \"BucketARN\": \"arn:aws:s3:::${RAW_BUCKET}\",
  \"Prefix\": \"orders/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/\",
  \"ErrorOutputPrefix\": \"errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/\",
  \"BufferingHints\": {
    \"SizeInMBs\": 5,
    \"IntervalInSeconds\": 60
  },
  \"CompressionFormat\": \"UNCOMPRESSED\",
  \"EncryptionConfiguration\": {
    \"NoEncryptionConfig\": \"NoEncryption\"
  },
  \"CloudWatchLoggingOptions\": {
    \"Enabled\": true,
    \"LogGroupName\": \"/aws/kinesisfirehose/${FIREHOSE_STREAM}\",
    \"LogStreamName\": \"DestinationDelivery\"
  }
}
" \
    --region "$REGION" > /dev/null
fi

echo "  Waiting for Firehose ACTIVE..."
STATUS=""
while [ "$STATUS" != "ACTIVE" ]; do
  STATUS=$(aws firehose describe-delivery-stream \
    --delivery-stream-name "$FIREHOSE_STREAM" \
    --region "$REGION" \
    --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
    --output text)
  echo "    Status: ${STATUS}"
  [ "$STATUS" != "ACTIVE" ] && sleep 5
done

aws firehose tag-delivery-stream \
  --delivery-stream-name "$FIREHOSE_STREAM" \
  --tags "Key=Project,Value=lks-streaming-pipeline" "Key=Environment,Value=production" "Key=ManagedBy,Value=LKS-Team" \
  --region "$REGION" 2>/dev/null || true

echo ""
echo "==> [03] Layer 2 (Firehose) complete."
echo "    Stream  : ${FIREHOSE_STREAM}"
echo "    S3 path : s3://${RAW_BUCKET}/orders/year=YYYY/month=MM/day=DD/hour=HH/"
echo "    Buffer  : 5 MB or 60 seconds (whichever first)"
echo ""
echo "Checkpoint: aws firehose describe-delivery-stream --delivery-stream-name ${FIREHOSE_STREAM} --region ${REGION} --query 'DeliveryStreamDescription.DeliveryStreamStatus'"
