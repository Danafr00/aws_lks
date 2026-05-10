#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1

STREAM_NAME=lks-pipeline-stream
FUNCTION_NAME=lks-pipeline-transformer
SNS_TOPIC=lks-pipeline-alerts
ALERT_EMAIL="${1:-}"

echo "==> [06] Setting up CloudWatch alarms and SNS"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── SNS Topic ─────────────────────────────────────────────────────────────────
echo "  Creating SNS topic: ${SNS_TOPIC}"
TOPIC_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC" \
  --region "$REGION" \
  --query 'TopicArn' \
  --output text)
echo "  SNS topic: ${TOPIC_ARN}"

aws sns tag-resource \
  --resource-arn "$TOPIC_ARN" \
  --tags "Key=Project,Value=lks-streaming-pipeline" "Key=ManagedBy,Value=LKS-Team" \
  --region "$REGION" 2>/dev/null || true

if [ -n "$ALERT_EMAIL" ]; then
  echo "  Subscribing ${ALERT_EMAIL} to SNS topic..."
  aws sns subscribe \
    --topic-arn "$TOPIC_ARN" \
    --protocol email \
    --notification-endpoint "$ALERT_EMAIL" \
    --region "$REGION" > /dev/null
  echo "  Check your email to confirm the subscription."
fi

# ── CloudWatch Alarm: Kinesis Iterator Age ────────────────────────────────────
echo "  Creating alarm: Kinesis high iterator age"
aws cloudwatch put-metric-alarm \
  --alarm-name "lks-kinesis-iterator-age-high" \
  --alarm-description "Kinesis consumer falling behind — Lambda not keeping up" \
  --metric-name GetRecords.IteratorAgeMilliseconds \
  --namespace AWS/Kinesis \
  --dimensions "Name=StreamName,Value=${STREAM_NAME}" \
  --statistic Maximum \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 60000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" \
  --region "$REGION" > /dev/null

# ── CloudWatch Alarm: Lambda Errors ──────────────────────────────────────────
echo "  Creating alarm: Lambda transformer errors"
aws cloudwatch put-metric-alarm \
  --alarm-name "lks-lambda-transformer-errors" \
  --alarm-description "Lambda transformer function errors detected" \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" \
  --region "$REGION" > /dev/null

# ── CloudWatch Alarm: Lambda Duration ────────────────────────────────────────
echo "  Creating alarm: Lambda transformer high duration"
aws cloudwatch put-metric-alarm \
  --alarm-name "lks-lambda-transformer-duration" \
  --alarm-description "Lambda transformer taking too long (>45 of 60s timeout)" \
  --metric-name Duration \
  --namespace AWS/Lambda \
  --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
  --statistic p99 \
  --extended-statistic p99 \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 45000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" \
  --region "$REGION" > /dev/null 2>&1 || \
  aws cloudwatch put-metric-alarm \
    --alarm-name "lks-lambda-transformer-duration" \
    --alarm-description "Lambda transformer taking too long" \
    --metric-name Duration \
    --namespace AWS/Lambda \
    --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
    --statistic Average \
    --period 300 \
    --evaluation-periods 2 \
    --threshold 45000 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN" \
    --region "$REGION" > /dev/null

echo ""
echo "==> [06] Layer 5 (Monitoring) complete."
echo "    SNS     : ${TOPIC_ARN}"
echo "    Alarms  : lks-kinesis-iterator-age-high"
echo "              lks-lambda-transformer-errors"
echo "              lks-lambda-transformer-duration"
echo ""
if [ -n "$ALERT_EMAIL" ]; then
  echo "  Alert email: ${ALERT_EMAIL} (confirm subscription in inbox)"
else
  echo "  To add email alerts:"
  echo "    bash 06-setup-monitoring.sh your@email.com"
fi
echo ""
echo "Checkpoint: aws cloudwatch describe-alarms --alarm-name-prefix lks- --region ${REGION} --query 'MetricAlarms[*].[AlarmName,StateValue]' --output table"
