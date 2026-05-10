#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole

RAW_BUCKET=lks-pipeline-raw-${ACCOUNT_ID}
PROCESSED_BUCKET=lks-pipeline-processed-${ACCOUNT_ID}
RESULTS_BUCKET=lks-pipeline-results-${ACCOUNT_ID}
GLUE_JOB=lks-pipeline-etl
GLUE_DB=lks_pipeline_db
CRAWLER_NAME=lks-pipeline-crawler
ATHENA_WG=lks-pipeline-wg
SCRIPT_S3=s3://${PROCESSED_BUCKET}/scripts/glue_etl.py
APP_DIR="$(cd "$(dirname "$0")/../app" && pwd)"

echo "==> [04] Setting up Glue ETL, Crawler, and Athena"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── Upload Glue Script ────────────────────────────────────────────────────────
echo "  Uploading Glue ETL script to S3..."
aws s3 cp "${APP_DIR}/glue_etl.py" "$SCRIPT_S3" --region "$REGION"
echo "  Script: ${SCRIPT_S3}"

# ── Create Glue Database ──────────────────────────────────────────────────────
echo "  Creating Glue database: ${GLUE_DB}"
aws glue create-database \
  --database-input "{\"Name\":\"${GLUE_DB}\",\"Description\":\"LKS streaming pipeline catalog\"}" \
  --region "$REGION" 2>/dev/null || echo "    (already exists)"

# ── Create Glue ETL Job ───────────────────────────────────────────────────────
echo "  Creating Glue ETL job: ${GLUE_JOB}"
JOB_EXISTS=$(aws glue get-job --job-name "$GLUE_JOB" --region "$REGION" 2>&1 || true)
if echo "$JOB_EXISTS" | grep -q '"Name"'; then
  echo "    (already exists)"
else
  aws glue create-job \
    --name "$GLUE_JOB" \
    --role "$LAB_ROLE_ARN" \
    --command "{
      \"Name\": \"glueetl\",
      \"ScriptLocation\": \"${SCRIPT_S3}\",
      \"PythonVersion\": \"3\"
    }" \
    --default-arguments "{
      \"--job-language\": \"python\",
      \"--enable-metrics\": \"true\",
      \"--enable-continuous-cloudwatch-log\": \"true\",
      \"--S3_RAW_PATH\": \"s3://${RAW_BUCKET}/orders/\",
      \"--S3_PROCESSED_BUCKET\": \"${PROCESSED_BUCKET}\",
      \"--S3_PROCESSED_PREFIX\": \"orders\"
    }" \
    --glue-version "4.0" \
    --worker-type "G.1X" \
    --number-of-workers 2 \
    --timeout 15 \
    --region "$REGION" > /dev/null
fi
echo "  Glue job: OK"

# ── Create Glue Crawler ───────────────────────────────────────────────────────
echo "  Creating Glue crawler: ${CRAWLER_NAME}"
CRAWLER_EXISTS=$(aws glue get-crawler --name "$CRAWLER_NAME" --region "$REGION" 2>&1 || true)
if echo "$CRAWLER_EXISTS" | grep -q '"Name"'; then
  echo "    (already exists)"
else
  aws glue create-crawler \
    --name "$CRAWLER_NAME" \
    --role "$LAB_ROLE_ARN" \
    --database-name "$GLUE_DB" \
    --targets "{\"S3Targets\":[{\"Path\":\"s3://${PROCESSED_BUCKET}/orders/\"}]}" \
    --schedule "cron(0 * * * ? *)" \
    --schema-change-policy "{\"UpdateBehavior\":\"UPDATE_IN_DATABASE\",\"DeleteBehavior\":\"LOG\"}" \
    --region "$REGION" > /dev/null
fi
echo "  Glue crawler: OK"

# ── Create Athena Workgroup ───────────────────────────────────────────────────
echo "  Creating Athena workgroup: ${ATHENA_WG}"
ATHENA_EXISTS=$(aws athena get-work-group --work-group "$ATHENA_WG" --region "$REGION" 2>&1 || true)
if echo "$ATHENA_EXISTS" | grep -q '"Name"'; then
  echo "    (already exists)"
else
  aws athena create-work-group \
    --name "$ATHENA_WG" \
    --configuration "{
      \"ResultConfiguration\": {
        \"OutputLocation\": \"s3://${RESULTS_BUCKET}/athena-results/\"
      },
      \"EnforceWorkGroupConfiguration\": true,
      \"PublishCloudWatchMetricsEnabled\": true,
      \"EngineVersion\": {\"SelectedEngineVersion\": \"Athena engine version 3\"}
    }" \
    --description "LKS streaming pipeline analytics workgroup" \
    --region "$REGION" > /dev/null
fi
echo "  Athena workgroup: OK"

echo ""
echo "==> [04] Layer 3 (Glue + Athena) complete."
echo ""
echo "  To run the Glue ETL job manually:"
echo "    aws glue start-job-run --job-name ${GLUE_JOB} --region ${REGION}"
echo ""
echo "  After job completes, run the crawler:"
echo "    aws glue start-crawler --crawler-name ${CRAWLER_NAME} --region ${REGION}"
echo ""
echo "  Athena sample query (after crawler):"
cat <<'EOF'
    SELECT region, category, COUNT(*) AS order_count, SUM(total_amount) AS revenue
    FROM lks_pipeline_db.orders
    GROUP BY region, category
    ORDER BY revenue DESC;
EOF
echo ""
echo "Checkpoint: aws glue get-tables --database-name ${GLUE_DB} --region ${REGION}"
