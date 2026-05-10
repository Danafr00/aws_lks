#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
STREAM_NAME=lks-pipeline-stream
SAMPLE_FILE="$(cd "$(dirname "$0")/../data" && pwd)/sample_orders.json"

echo "==> [07] Sending test orders to Kinesis stream: ${STREAM_NAME}"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"

COUNT=0
while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  ORDER_ID=$(echo "$LINE" | python3 -c "import sys,json; print(json.load(sys.stdin)['order_id'])")
  aws kinesis put-record \
    --stream-name "$STREAM_NAME" \
    --data "$(echo "$LINE" | base64)" \
    --partition-key "$ORDER_ID" \
    --region "$REGION" \
    --query 'SequenceNumber' \
    --output text > /dev/null
  COUNT=$((COUNT + 1))
  echo "  [${COUNT}] Sent: ${ORDER_ID}"
  sleep 0.2
done < "$SAMPLE_FILE"

echo ""
echo "==> Sent ${COUNT} records to Kinesis."
echo ""
echo "  Now wait ~90 seconds for Lambda to process and Firehose to buffer to S3."
echo "  Then check:"
echo "    DynamoDB items   : aws dynamodb scan --table-name lks-pipeline-orders --select COUNT --region ${REGION}"
echo "    S3 raw files     : aws s3 ls --recursive s3://lks-pipeline-raw-${ACCOUNT_ID}/orders/ --region ${REGION}"
echo "    Lambda logs      : aws logs tail /aws/lambda/lks-pipeline-transformer --since 5m --region ${REGION}"
