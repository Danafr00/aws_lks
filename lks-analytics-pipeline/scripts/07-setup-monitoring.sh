#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
# ──────────────────────────────────────────────────────────────

if [[ -z "$ALERT_EMAIL" ]]; then
  echo "ERROR: Set ALERT_EMAIL before running this script."
  echo "  export ALERT_EMAIL=your@email.com"
  exit 1
fi

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo "==> Alert email: ${ALERT_EMAIL}"

# ── SNS Topic ─────────────────────────────────────────────────
echo ""
echo "==> Creating SNS topic: lks-analytics-alerts..."
SNS_ARN=$(aws sns create-topic \
  --region "$REGION" \
  --name lks-analytics-alerts \
  --tags '[
    {"Key":"Project","Value":"nusantara-analytics"},
    {"Key":"Environment","Value":"production"},
    {"Key":"ManagedBy","Value":"LKS-Team"}
  ]' \
  --query TopicArn --output text)

echo "  SNS ARN: ${SNS_ARN}"

echo "==> Subscribing ${ALERT_EMAIL} to SNS topic..."
aws sns subscribe \
  --region "$REGION" \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint "$ALERT_EMAIL" \
  2>/dev/null || echo "  (subscription may already exist)"

echo "  CHECK YOUR EMAIL and confirm the SNS subscription before continuing."

# ── CloudWatch Alarm: Glue Job Failure ────────────────────────
echo ""
echo "==> Creating CloudWatch alarm: lks-glue-job-failure..."
aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name lks-glue-job-failure \
  --alarm-description "Alert when Glue ETL job lks-etl-sales fails" \
  --namespace Glue \
  --metric-name glue.driver.aggregate.numFailedTasks \
  --dimensions Name=JobName,Value=lks-etl-sales \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_ARN" \
  --ok-actions "$SNS_ARN" \
  --treat-missing-data notBreaching

echo "  CloudWatch alarm ready"

# ── CloudWatch Alarm: Glue Job Duration ───────────────────────
echo ""
echo "==> Creating CloudWatch alarm: lks-glue-long-job..."
aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name lks-glue-long-job \
  --alarm-description "Alert when Glue ETL job runs > 8 minutes" \
  --namespace Glue \
  --metric-name glue.driver.ExecutorRunTime \
  --dimensions Name=JobName,Value=lks-etl-sales \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 8 \
  --threshold 60000 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching

echo "  Duration alarm ready"
echo ""
echo "==> Monitoring setup complete."
echo ""
echo "  SNS topic: ${SNS_ARN}"
echo "  Alarms:"
echo "    lks-glue-job-failure (triggers if any Glue task fails)"
echo "    lks-glue-long-job    (triggers if job runs > 8 min)"
echo ""
echo "  View alarms: aws cloudwatch describe-alarms --alarm-names lks-glue-job-failure lks-glue-long-job --region ${REGION}"
