#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
EMAIL="${ALERT_EMAIL:-}"
# ──────────────────────────────────────────────────────────────

RAW_BUCKET="lks-analytics-raw-${ACCOUNT_ID}"
PROCESSED_BUCKET="lks-analytics-processed-${ACCOUNT_ID}"
RESULTS_BUCKET="lks-analytics-results-${ACCOUNT_ID}"

PASS=0
FAIL=0

check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  [PASS] ${label}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${label}"
    FAIL=$((FAIL + 1))
  fi
}

echo "================================================================"
echo " LKS Analytics Pipeline – End-to-End Validation"
echo " Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo "================================================================"

# ── Step 1: S3 Buckets ────────────────────────────────────────
echo ""
echo "[1/6] S3 Buckets"
check "Raw bucket exists"       "aws s3api head-bucket --bucket ${RAW_BUCKET} --region ${REGION}"
check "Processed bucket exists"  "aws s3api head-bucket --bucket ${PROCESSED_BUCKET} --region ${REGION}"
check "Results bucket exists"    "aws s3api head-bucket --bucket ${RESULTS_BUCKET} --region ${REGION}"
check "ETL script uploaded"      "aws s3api head-object --bucket ${PROCESSED_BUCKET} --key scripts/etl_job.py --region ${REGION}"

# ── Step 2: Trigger the pipeline ─────────────────────────────
echo ""
echo "[2/6] Uploading test CSV to trigger pipeline..."
TIMESTAMP=$(date +%Y%m%d%H%M%S)
KEY="data/sales/2024/01/16/test_${TIMESTAMP}.csv"
aws s3 cp "$(dirname "$0")/../data/sample_sales.csv" "s3://${RAW_BUCKET}/${KEY}"
echo "  Uploaded: s3://${RAW_BUCKET}/${KEY}"
echo "  Waiting 15s for Lambda → Glue trigger..."
sleep 15

# ── Step 3: Glue Job ─────────────────────────────────────────
echo ""
echo "[3/6] Glue ETL Job"
check "Glue job exists" \
  "aws glue get-job --job-name lks-etl-sales --region ${REGION}"

LATEST_RUN_STATE=$(aws glue get-job-runs \
  --job-name lks-etl-sales \
  --region "$REGION" \
  --max-results 1 \
  --query 'JobRuns[0].JobRunState' \
  --output text 2>/dev/null || echo "NONE")

echo "  Latest Glue job run state: ${LATEST_RUN_STATE}"
if [[ "$LATEST_RUN_STATE" == "RUNNING" || "$LATEST_RUN_STATE" == "SUCCEEDED" ]]; then
  echo "  [PASS] Glue job was triggered"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Glue job not triggered (state: ${LATEST_RUN_STATE})"
  echo "         Check Lambda logs: aws logs tail /aws/lambda/lks-glue-trigger --since 5m"
  FAIL=$((FAIL + 1))
fi

echo "  Waiting 90s for Glue job to complete (G.025X workers are slow to start)..."
sleep 90

# ── Step 4: S3 Parquet Output ─────────────────────────────────
echo ""
echo "[4/6] Parquet output in processed bucket"
PARQUET_COUNT=$(aws s3 ls "s3://${PROCESSED_BUCKET}/sales/" --recursive \
  | grep -c "\.parquet" 2>/dev/null || echo "0")
echo "  Parquet files found: ${PARQUET_COUNT}"
if [[ "$PARQUET_COUNT" -gt 0 ]]; then
  echo "  [PASS] Parquet files exist"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] No Parquet files in s3://${PROCESSED_BUCKET}/sales/"
  echo "         Glue job may still be running. Check: aws glue get-job-runs --job-name lks-etl-sales --region ${REGION}"
  FAIL=$((FAIL + 1))
fi

# ── Step 5: Glue Crawler + Data Catalog ──────────────────────
echo ""
echo "[5/6] Glue Crawler and Data Catalog"
echo "  Starting Glue Crawler manually..."
aws glue start-crawler --name lks-crawler-sales --region "$REGION" 2>/dev/null || echo "  (crawler already running)"
echo "  Waiting 60s for crawler to complete..."
sleep 60

check "Glue database exists" \
  "aws glue get-database --name lks_analytics_db --region ${REGION}"
check "Sales table in catalog" \
  "aws glue get-table --database-name lks_analytics_db --name sales --region ${REGION}"

# ── Step 6: Athena Query ──────────────────────────────────────
echo ""
echo "[6/6] Athena Query via lks-analytics-wg"
QUERY_ID=$(aws athena start-query-execution \
  --region "$REGION" \
  --query-string "SELECT COUNT(*) AS row_count FROM lks_analytics_db.sales;" \
  --work-group lks-analytics-wg \
  --query QueryExecutionId \
  --output text 2>/dev/null || echo "")

if [[ -n "$QUERY_ID" ]]; then
  echo "  Query submitted: ${QUERY_ID}"
  echo "  Waiting 15s for query to complete..."
  sleep 15
  QUERY_STATE=$(aws athena get-query-execution \
    --region "$REGION" \
    --query-execution-id "$QUERY_ID" \
    --query QueryExecution.Status.State \
    --output text 2>/dev/null || echo "UNKNOWN")
  echo "  Query state: ${QUERY_STATE}"
  if [[ "$QUERY_STATE" == "SUCCEEDED" ]]; then
    echo "  [PASS] Athena query succeeded"
    PASS=$((PASS + 1))
    echo "  Result:"
    aws athena get-query-results \
      --region "$REGION" \
      --query-execution-id "$QUERY_ID" \
      --query 'ResultSet.Rows[].Data[].VarCharValue' \
      --output text
  else
    echo "  [FAIL] Athena query state: ${QUERY_STATE}"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  [FAIL] Could not submit Athena query (check workgroup and LF permissions)"
  FAIL=$((FAIL + 1))
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " VALIDATION SUMMARY"
echo "================================================================"
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  STATUS: ALL CHECKS PASSED"
else
  echo "  STATUS: ${FAIL} CHECK(S) FAILED — review output above"
fi
echo "================================================================"
