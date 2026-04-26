#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

RESULTS_BUCKET="lks-analytics-results-${ACCOUNT_ID}"

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo ""
echo "==> Creating Athena workgroup: lks-analytics-wg..."

aws athena create-work-group \
  --region "$REGION" \
  --name lks-analytics-wg \
  --configuration "{
    \"ResultConfiguration\": {
      \"OutputLocation\": \"s3://${RESULTS_BUCKET}/\",
      \"EncryptionConfiguration\": {\"EncryptionOption\": \"SSE_S3\"}
    },
    \"EnforceWorkGroupConfiguration\": true,
    \"PublishCloudWatchMetricsEnabled\": true,
    \"BytesScannedCutoffPerQuery\": 1073741824
  }" \
  --description "Nusantara Retail Analytics Athena workgroup" \
  --tags '[
    {"Key":"Project","Value":"nusantara-analytics"},
    {"Key":"Environment","Value":"production"},
    {"Key":"ManagedBy","Value":"LKS-Team"}
  ]' \
  2>/dev/null || echo "  (already exists, skipping)"

echo "  lks-analytics-wg ready"
echo "  Query results: s3://${RESULTS_BUCKET}/"
echo "  Bytes scanned cutoff per query: 1 GB (cost protection)"
echo ""
echo "==> Athena setup complete."
echo ""
echo "  Open Athena console and select workgroup: lks-analytics-wg"
echo "  Then run:"
echo "    SELECT * FROM lks_analytics_db.sales LIMIT 10;"
