#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole

CLUSTER_ID=lks-pipeline-cluster
CLUSTER_DB=pipeline
CLUSTER_USER=admin
CLUSTER_PASS=LksPipeline2024!
PROCESSED_BUCKET=lks-pipeline-processed-${ACCOUNT_ID}

echo "==> [05] Setting up Redshift provisioned cluster"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo "    NOTE: Cluster creation takes ~10-15 minutes."

# ── Create Cluster ────────────────────────────────────────────────────────────
EXISTING=$(aws redshift describe-clusters \
  --cluster-identifier "$CLUSTER_ID" \
  --region "$REGION" 2>&1 || true)

if echo "$EXISTING" | grep -q '"ClusterIdentifier"'; then
  echo "  Cluster already exists."
  STATUS=$(echo "$EXISTING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Clusters'][0]['ClusterStatus'])" 2>/dev/null || echo "unknown")
  echo "  Current status: ${STATUS}"
else
  echo "  Creating Redshift cluster: ${CLUSTER_ID}"
  aws redshift create-cluster \
    --cluster-identifier "$CLUSTER_ID" \
    --node-type ra3.xlplus \
    --master-username "$CLUSTER_USER" \
    --master-user-password "$CLUSTER_PASS" \
    --cluster-type single-node \
    --db-name "$CLUSTER_DB" \
    --publicly-accessible \
    --iam-roles "$LAB_ROLE_ARN" \
    --region "$REGION" > /dev/null
  echo "  Cluster creation started. Waiting for AVAILABLE (~10-15 min)..."
fi

# ── Wait for AVAILABLE ────────────────────────────────────────────────────────
echo "  Polling cluster status..."
while true; do
  STATUS=$(aws redshift describe-clusters \
    --cluster-identifier "$CLUSTER_ID" \
    --region "$REGION" \
    --query 'Clusters[0].ClusterStatus' \
    --output text 2>/dev/null || echo "creating")
  echo "    $(date +%H:%M:%S) Status: ${STATUS}"
  [ "$STATUS" = "available" ] && break
  sleep 30
done

CLUSTER_ENDPOINT=$(aws redshift describe-clusters \
  --cluster-identifier "$CLUSTER_ID" \
  --region "$REGION" \
  --query 'Clusters[0].Endpoint.Address' \
  --output text)

echo "  Cluster available: ${CLUSTER_ENDPOINT}"

# ── Create Table via Data API ─────────────────────────────────────────────────
echo "  Creating orders table via Redshift Data API..."
STMT_ID=$(aws redshift-data execute-statement \
  --cluster-identifier "$CLUSTER_ID" \
  --database "$CLUSTER_DB" \
  --db-user "$CLUSTER_USER" \
  --sql "
    CREATE TABLE IF NOT EXISTS public.orders (
      order_id        VARCHAR(50)     NOT NULL,
      customer_id     VARCHAR(50),
      product_id      VARCHAR(50),
      product_name    VARCHAR(200),
      category        VARCHAR(100),
      quantity        INTEGER,
      unit_price      DOUBLE PRECISION,
      total_amount    DOUBLE PRECISION,
      order_status    VARCHAR(50),
      payment_method  VARCHAR(50),
      region          VARCHAR(50),
      "timestamp"     VARCHAR(50),
      processed_at    VARCHAR(50),
      event_ts        TIMESTAMP,
      PRIMARY KEY (order_id)
    )
    DISTSTYLE KEY DISTKEY(region)
    SORTKEY(event_ts);
  " \
  --region "$REGION" \
  --query 'Id' \
  --output text)

echo "  DDL statement ID: ${STMT_ID}"
aws redshift-data wait statement-finished --id "$STMT_ID" --region "$REGION" 2>/dev/null || true
echo "  Table created: public.orders"

# ── COPY from S3 Processed ────────────────────────────────────────────────────
echo "  Running COPY from S3 processed (Parquet)..."
COPY_ID=$(aws redshift-data execute-statement \
  --cluster-identifier "$CLUSTER_ID" \
  --database "$CLUSTER_DB" \
  --db-user "$CLUSTER_USER" \
  --sql "
    COPY public.orders
    FROM 's3://${PROCESSED_BUCKET}/orders/'
    IAM_ROLE '${LAB_ROLE_ARN}'
    FORMAT AS PARQUET
    ACCEPTINVCHARS;
  " \
  --region "$REGION" \
  --query 'Id' \
  --output text)

echo "  COPY statement ID: ${COPY_ID}. Waiting..."

for i in $(seq 1 24); do
  COPY_STATUS=$(aws redshift-data describe-statement \
    --id "$COPY_ID" \
    --region "$REGION" \
    --query 'Status' \
    --output text)
  echo "    $(date +%H:%M:%S) [${i}/24] COPY status: ${COPY_STATUS}"
  [ "$COPY_STATUS" = "FINISHED" ] && break
  [ "$COPY_STATUS" = "FAILED" ] && { echo "  ERROR: COPY failed."; break; }
  sleep 10
done

# ── Verify Row Count ──────────────────────────────────────────────────────────
echo "  Verifying row count..."
COUNT_ID=$(aws redshift-data execute-statement \
  --cluster-identifier "$CLUSTER_ID" \
  --database "$CLUSTER_DB" \
  --db-user "$CLUSTER_USER" \
  --sql "SELECT COUNT(*) AS row_count FROM public.orders;" \
  --region "$REGION" \
  --query 'Id' \
  --output text)
sleep 5
aws redshift-data get-statement-result --id "$COUNT_ID" --region "$REGION" \
  --query 'Records[0][0]' --output text 2>/dev/null && echo " rows in public.orders"

echo ""
echo "==> [05] Layer 4 (Redshift) complete."
echo "    Cluster : ${CLUSTER_ID}"
echo "    Endpoint: ${CLUSTER_ENDPOINT}"
echo "    DB/User : ${CLUSTER_DB} / ${CLUSTER_USER}"
echo ""
echo "  Sample analytics query:"
echo "    aws redshift-data execute-statement \\"
echo "      --cluster-identifier ${CLUSTER_ID} \\"
echo "      --database ${CLUSTER_DB} \\"
echo "      --db-user ${CLUSTER_USER} \\"
echo "      --sql \"SELECT region, SUM(total_amount) FROM public.orders GROUP BY region ORDER BY 2 DESC\" \\"
echo "      --region ${REGION}"
echo ""
echo "  IMPORTANT: Delete cluster after exam to avoid cost (~\$1.08/hr):"
echo "    aws redshift delete-cluster --cluster-identifier ${CLUSTER_ID} --skip-final-cluster-snapshot --region ${REGION}"
