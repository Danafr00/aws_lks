#!/bin/bash

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
PASS=0
FAIL=0

RAW_BUCKET=lks-pipeline-raw-${ACCOUNT_ID}
PROCESSED_BUCKET=lks-pipeline-processed-${ACCOUNT_ID}
RESULTS_BUCKET=lks-pipeline-results-${ACCOUNT_ID}

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "==> [08] End-to-end validation"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo ""

# ── Layer 1: Storage ──────────────────────────────────────────────────────────
echo "--- Layer 1: Storage ---"

aws s3api head-bucket --bucket "$RAW_BUCKET" --region "$REGION" 2>/dev/null \
  && ok "S3 raw bucket exists: ${RAW_BUCKET}" \
  || fail "S3 raw bucket missing: ${RAW_BUCKET}"

aws s3api head-bucket --bucket "$PROCESSED_BUCKET" --region "$REGION" 2>/dev/null \
  && ok "S3 processed bucket exists: ${PROCESSED_BUCKET}" \
  || fail "S3 processed bucket missing: ${PROCESSED_BUCKET}"

aws s3api head-bucket --bucket "$RESULTS_BUCKET" --region "$REGION" 2>/dev/null \
  && ok "S3 results bucket exists: ${RESULTS_BUCKET}" \
  || fail "S3 results bucket missing: ${RESULTS_BUCKET}"

STREAM_STATUS=$(aws kinesis describe-stream-summary \
  --stream-name lks-pipeline-stream \
  --region "$REGION" \
  --query 'StreamDescriptionSummary.StreamStatus' \
  --output text 2>/dev/null || echo "MISSING")
[ "$STREAM_STATUS" = "ACTIVE" ] \
  && ok "Kinesis stream ACTIVE" \
  || fail "Kinesis stream status: ${STREAM_STATUS}"

DYNAMO_STATUS=$(aws dynamodb describe-table \
  --table-name lks-pipeline-orders \
  --region "$REGION" \
  --query 'Table.TableStatus' \
  --output text 2>/dev/null || echo "MISSING")
[ "$DYNAMO_STATUS" = "ACTIVE" ] \
  && ok "DynamoDB table ACTIVE" \
  || fail "DynamoDB table status: ${DYNAMO_STATUS}"

# ── Layer 2: Streaming Transform ─────────────────────────────────────────────
echo ""
echo "--- Layer 2: Streaming Transform ---"

LAMBDA_STATE=$(aws lambda get-function \
  --function-name lks-pipeline-transformer \
  --region "$REGION" \
  --query 'Configuration.State' \
  --output text 2>/dev/null || echo "MISSING")
[ "$LAMBDA_STATE" = "Active" ] \
  && ok "Lambda transformer Active" \
  || fail "Lambda state: ${LAMBDA_STATE}"

ESM_COUNT=$(aws lambda list-event-source-mappings \
  --function-name lks-pipeline-transformer \
  --region "$REGION" \
  --query 'length(EventSourceMappings)' \
  --output text 2>/dev/null || echo "0")
[ "$ESM_COUNT" -ge 1 ] \
  && ok "Kinesis event source mapping exists (${ESM_COUNT})" \
  || fail "No Kinesis event source mapping found"

FIREHOSE_STATUS=$(aws firehose describe-delivery-stream \
  --delivery-stream-name lks-pipeline-firehose \
  --region "$REGION" \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
  --output text 2>/dev/null || echo "MISSING")
[ "$FIREHOSE_STATUS" = "ACTIVE" ] \
  && ok "Firehose delivery stream ACTIVE" \
  || fail "Firehose status: ${FIREHOSE_STATUS}"

DYNAMO_COUNT=$(aws dynamodb scan \
  --table-name lks-pipeline-orders \
  --select COUNT \
  --region "$REGION" \
  --query 'Count' \
  --output text 2>/dev/null || echo "0")
[ "$DYNAMO_COUNT" -ge 1 ] \
  && ok "DynamoDB has ${DYNAMO_COUNT} items (Lambda is processing)" \
  || fail "DynamoDB has 0 items — Lambda may not have processed yet (run 07-generate-events.sh first)"

RAW_FILE_COUNT=$(aws s3 ls --recursive "s3://${RAW_BUCKET}/orders/" --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')
[ "$RAW_FILE_COUNT" -ge 1 ] \
  && ok "S3 raw zone has ${RAW_FILE_COUNT} file(s)" \
  || fail "S3 raw zone has no files — wait 90s after sending events, then retry"

# ── Layer 3: Batch Analytics ──────────────────────────────────────────────────
echo ""
echo "--- Layer 3: Glue + Athena ---"

GLUE_JOB_STATE=$(aws glue get-job \
  --job-name lks-pipeline-etl \
  --region "$REGION" \
  --query 'Job.Name' \
  --output text 2>/dev/null || echo "MISSING")
[ "$GLUE_JOB_STATE" = "lks-pipeline-etl" ] \
  && ok "Glue ETL job exists" \
  || fail "Glue ETL job missing"

CRAWLER_STATE=$(aws glue get-crawler \
  --name lks-pipeline-crawler \
  --region "$REGION" \
  --query 'Crawler.Name' \
  --output text 2>/dev/null || echo "MISSING")
[ "$CRAWLER_STATE" = "lks-pipeline-crawler" ] \
  && ok "Glue crawler exists" \
  || fail "Glue crawler missing"

PROCESSED_COUNT=$(aws s3 ls --recursive "s3://${PROCESSED_BUCKET}/orders/" --region "$REGION" 2>/dev/null | grep -c '.parquet' || echo "0")
[ "$PROCESSED_COUNT" -ge 1 ] \
  && ok "S3 processed zone has ${PROCESSED_COUNT} Parquet file(s)" \
  || fail "S3 processed zone has no Parquet files — run Glue ETL job first"

TABLE_COUNT=$(aws glue get-tables \
  --database-name lks_pipeline_db \
  --region "$REGION" \
  --query 'length(TableList)' \
  --output text 2>/dev/null || echo "0")
[ "$TABLE_COUNT" -ge 1 ] \
  && ok "Glue catalog has ${TABLE_COUNT} table(s) in lks_pipeline_db" \
  || fail "Glue catalog empty — run crawler after Glue job"

ATHENA_WG=$(aws athena get-work-group \
  --work-group lks-pipeline-wg \
  --region "$REGION" \
  --query 'WorkGroup.Name' \
  --output text 2>/dev/null || echo "MISSING")
[ "$ATHENA_WG" = "lks-pipeline-wg" ] \
  && ok "Athena workgroup exists" \
  || fail "Athena workgroup missing"

# ── Layer 4: Redshift ─────────────────────────────────────────────────────────
echo ""
echo "--- Layer 4: Redshift ---"

CLUSTER_STATUS=$(aws redshift describe-clusters \
  --cluster-identifier lks-pipeline-cluster \
  --region "$REGION" \
  --query 'Clusters[0].ClusterStatus' \
  --output text 2>/dev/null || echo "MISSING")
[ "$CLUSTER_STATUS" = "available" ] \
  && ok "Redshift cluster available" \
  || fail "Redshift cluster status: ${CLUSTER_STATUS}"

# ── Layer 5: Monitoring ───────────────────────────────────────────────────────
echo ""
echo "--- Layer 5: Monitoring ---"

ALARM_COUNT=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix lks- \
  --region "$REGION" \
  --query 'length(MetricAlarms)' \
  --output text 2>/dev/null || echo "0")
[ "$ALARM_COUNT" -ge 3 ] \
  && ok "CloudWatch alarms: ${ALARM_COUNT} alarms created" \
  || fail "CloudWatch alarms: only ${ALARM_COUNT} found (expected 3)"

SNS_TOPIC=$(aws sns list-topics \
  --region "$REGION" \
  --query "Topics[?contains(TopicArn,'lks-pipeline-alerts')].TopicArn" \
  --output text 2>/dev/null || echo "")
[ -n "$SNS_TOPIC" ] \
  && ok "SNS topic exists: ${SNS_TOPIC}" \
  || fail "SNS topic lks-pipeline-alerts not found"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"
[ "$FAIL" -eq 0 ] && echo "  ALL CHECKS PASSED — pipeline is fully operational!" \
  || echo "  Fix failed checks above and re-run this script."
