#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

PROCESSED_BUCKET="lks-analytics-processed-${ACCOUNT_ID}"
GLUE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole"
ANALYST_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LKS-AthenaAnalystRole"

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── IAM: Athena Analyst Role ───────────────────────────────────
echo ""
echo "==> Creating IAM role LKS-AthenaAnalystRole..."

TRUST_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": {\"AWS\": \"arn:aws:iam::${ACCOUNT_ID}:root\"},
    \"Action\": \"sts:AssumeRole\"
  }]
}"

aws iam create-role \
  --role-name LKS-AthenaAnalystRole \
  --assume-role-policy-document "$TRUST_POLICY" \
  2>/dev/null || echo "  (already exists, skipping)"

aws iam put-role-policy \
  --role-name LKS-AthenaAnalystRole \
  --policy-name LKS-AthenaAnalystPolicy \
  --policy-document file://"$(dirname "$0")"/../iam/athena-analyst-policy.json

echo "  LKS-AthenaAnalystRole ready"

# ── Lake Formation: Set Admin ──────────────────────────────────
echo ""
echo "==> Setting Lake Formation data lake administrator..."
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)

aws lakeformation put-data-lake-settings \
  --region "$REGION" \
  --data-lake-settings "{
    \"DataLakeAdmins\": [{\"DataLakePrincipalIdentifier\": \"${CALLER_ARN}\"}],
    \"CreateTableDefaultPermissions\": [],
    \"CreateDatabaseDefaultPermissions\": []
  }"

echo "  LF admin set to: ${CALLER_ARN}"
echo "  IMPORTANT: Default IAM permissions are now disabled — Lake Formation governs access."

# ── Lake Formation: Register S3 Location ──────────────────────
echo ""
echo "==> Registering S3 processed bucket with Lake Formation..."
aws lakeformation register-resource \
  --region "$REGION" \
  --resource-arn "arn:aws:s3:::${PROCESSED_BUCKET}" \
  --use-service-linked-role \
  2>/dev/null || echo "  (already registered, skipping)"

# ── Lake Formation: Grant Glue Role Permissions ───────────────
echo ""
echo "==> Granting LF permissions to LKS-GlueETLRole..."

# Allow Glue to write data to S3 via Lake Formation
aws lakeformation grant-permissions \
  --region "$REGION" \
  --principal "{\"DataLakePrincipalIdentifier\": \"${GLUE_ROLE_ARN}\"}" \
  --resource "{\"DataLocation\": {\"ResourceArn\": \"arn:aws:s3:::${PROCESSED_BUCKET}\"}}" \
  --permissions DATA_LOCATION_ACCESS \
  2>/dev/null || echo "  (DATA_LOCATION_ACCESS already granted)"

# Allow Glue to create tables in the catalog database
aws lakeformation grant-permissions \
  --region "$REGION" \
  --principal "{\"DataLakePrincipalIdentifier\": \"${GLUE_ROLE_ARN}\"}" \
  --resource "{\"Database\": {\"Name\": \"lks_analytics_db\"}}" \
  --permissions CREATE_TABLE DESCRIBE \
  2>/dev/null || echo "  (Database permissions already granted)"

# Allow Glue to alter (add partitions) the sales table
aws lakeformation grant-permissions \
  --region "$REGION" \
  --principal "{\"DataLakePrincipalIdentifier\": \"${GLUE_ROLE_ARN}\"}" \
  --resource "{\"Table\": {\"DatabaseName\": \"lks_analytics_db\", \"TableWildcard\": {}}}" \
  --permissions SELECT INSERT DELETE DESCRIBE ALTER \
  2>/dev/null || echo "  (Table permissions already granted)"

echo "  Glue role permissions granted"

# ── Lake Formation: Grant Analyst Role Permissions ────────────
echo ""
echo "==> Granting LF permissions to LKS-AthenaAnalystRole..."

aws lakeformation grant-permissions \
  --region "$REGION" \
  --principal "{\"DataLakePrincipalIdentifier\": \"${ANALYST_ROLE_ARN}\"}" \
  --resource "{\"Database\": {\"Name\": \"lks_analytics_db\"}}" \
  --permissions DESCRIBE \
  2>/dev/null || echo "  (Database DESCRIBE already granted)"

aws lakeformation grant-permissions \
  --region "$REGION" \
  --principal "{\"DataLakePrincipalIdentifier\": \"${ANALYST_ROLE_ARN}\"}" \
  --resource "{\"Table\": {\"DatabaseName\": \"lks_analytics_db\", \"TableWildcard\": {}}}" \
  --permissions SELECT DESCRIBE \
  2>/dev/null || echo "  (Table SELECT already granted)"

echo "  Analyst role permissions granted"
echo ""
echo "==> Lake Formation setup complete."
echo ""
echo "  Verify in console: Lake Formation → Permissions → Data lake permissions"
