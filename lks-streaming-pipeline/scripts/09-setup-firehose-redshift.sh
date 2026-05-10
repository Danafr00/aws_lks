#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole

FIREHOSE_NAME=lks-pipeline-firehose-direct
RAW_BUCKET=lks-pipeline-raw-${ACCOUNT_ID}
CLUSTER_ID=lks-pipeline-cluster
CLUSTER_DB=pipeline
CLUSTER_USER=admin
CLUSTER_PASS=LksPipeline2024!
TARGET_TABLE=public.orders_direct
FUNCTION_NAME=lks-pipeline-transformer
DYNAMO_TABLE=lks-pipeline-orders
FIREHOSE_STREAM=lks-pipeline-firehose

echo "==> [09] Setting up Firehose → Redshift direct delivery"
echo "    Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo ""
echo "  Flow: Lambda ──(PutRecord)──> Firehose ──> S3 staging ──COPY──> Redshift"
echo "  (Lambda already enriches data; same enriched JSON goes to both Firehoses)"
echo ""

# ── Verify Redshift cluster is available ─────────────────────────────────────
echo "  Checking Redshift cluster..."
CLUSTER_STATUS=$(aws redshift describe-clusters \
  --cluster-identifier "$CLUSTER_ID" \
  --region "$REGION" \
  --query 'Clusters[0].ClusterStatus' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CLUSTER_STATUS" != "available" ]; then
  echo "  ERROR: Redshift cluster not available (status: ${CLUSTER_STATUS})."
  echo "  Run script 05-setup-redshift.sh first and wait for cluster to be available."
  exit 1
fi

CLUSTER_ENDPOINT=$(aws redshift describe-clusters \
  --cluster-identifier "$CLUSTER_ID" \
  --region "$REGION" \
  --query 'Clusters[0].Endpoint.Address' \
  --output text)
echo "  Cluster endpoint: ${CLUSTER_ENDPOINT}"

# ── Create public.orders_direct table ────────────────────────────────────────
# Includes processed_at — Lambda adds this before PutRecord to Firehose.
# No event_ts — that is derived by Glue ETL only (not part of raw JSON).
echo "  Creating table: ${TARGET_TABLE}..."
STMT_ID=$(aws redshift-data execute-statement \
  --cluster-identifier "$CLUSTER_ID" \
  --database "$CLUSTER_DB" \
  --db-user "$CLUSTER_USER" \
  --sql "
    CREATE TABLE IF NOT EXISTS public.orders_direct (
      order_id        VARCHAR(50),
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
      \"timestamp\"     VARCHAR(50),
      processed_at    VARCHAR(50)
    )
    DISTSTYLE KEY DISTKEY(region)
    SORTKEY(\"timestamp\");
  " \
  --region "$REGION" \
  --query 'Id' \
  --output text)

echo "  DDL statement ID: ${STMT_ID}"
aws redshift-data wait statement-finished --id "$STMT_ID" --region "$REGION" 2>/dev/null || true
echo "  Table ready: ${TARGET_TABLE}"

# ── Write Firehose Redshift config to temp file ───────────────────────────────
cat > /tmp/lks-firehose-redshift-config.json << EOF
{
  "RoleARN": "${LAB_ROLE_ARN}",
  "ClusterJDBCURL": "jdbc:redshift://${CLUSTER_ENDPOINT}:5439/${CLUSTER_DB}",
  "CopyCommand": {
    "DataTableName": "${TARGET_TABLE}",
    "CopyOptions": "json 'auto' ACCEPTINVCHARS TRUNCATECOLUMNS"
  },
  "Username": "${CLUSTER_USER}",
  "Password": "${CLUSTER_PASS}",
  "S3Configuration": {
    "RoleARN": "${LAB_ROLE_ARN}",
    "BucketARN": "arn:aws:s3:::${RAW_BUCKET}",
    "Prefix": "staging/redshift/",
    "ErrorOutputPrefix": "errors/redshift/",
    "BufferingHints": {
      "SizeInMBs": 5,
      "IntervalInSeconds": 60
    },
    "CompressionFormat": "UNCOMPRESSED"
  },
  "CloudWatchLoggingOptions": {
    "Enabled": true,
    "LogGroupName": "/aws/kinesisfirehose/${FIREHOSE_NAME}",
    "LogStreamName": "RedshiftDelivery"
  }
}
EOF

# ── Create Firehose delivery stream (Direct PUT) ──────────────────────────────
echo "  Creating Firehose: ${FIREHOSE_NAME} (source: Direct PUT)..."

EXISTING=$(aws firehose describe-delivery-stream \
  --delivery-stream-name "$FIREHOSE_NAME" \
  --region "$REGION" 2>&1 || true)

if echo "$EXISTING" | grep -q '"DeliveryStreamName"'; then
  echo "  Firehose already exists, skipping creation."
else
  aws firehose create-delivery-stream \
    --delivery-stream-name "$FIREHOSE_NAME" \
    --delivery-stream-type DirectPut \
    --redshift-destination-configuration "file:///tmp/lks-firehose-redshift-config.json" \
    --tags "Key=Project,Value=lks-streaming-pipeline" \
           "Key=Environment,Value=production" \
           "Key=ManagedBy,Value=LKS-Team" \
    --region "$REGION" > /dev/null
  echo "  Firehose created."
fi

rm -f /tmp/lks-firehose-redshift-config.json

# ── Wait for ACTIVE ───────────────────────────────────────────────────────────
echo "  Waiting for Firehose to become ACTIVE..."
for i in $(seq 1 18); do
  FS=$(aws firehose describe-delivery-stream \
    --delivery-stream-name "$FIREHOSE_NAME" \
    --region "$REGION" \
    --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
    --output text 2>/dev/null || echo "CREATING")
  echo "    $(date +%H:%M:%S) [${i}/18] Status: ${FS}"
  [ "$FS" = "ACTIVE" ] && break
  sleep 10
done

# ── Update Lambda env var to activate the direct path ────────────────────────
echo "  Updating Lambda env var FIREHOSE_DIRECT_STREAM=${FIREHOSE_NAME}..."
aws lambda update-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --environment "Variables={DYNAMODB_TABLE=${DYNAMO_TABLE},FIREHOSE_STREAM=${FIREHOSE_STREAM},FIREHOSE_DIRECT_STREAM=${FIREHOSE_NAME},AWS_ACCOUNT_ID=${ACCOUNT_ID}}" \
  --region "$REGION" > /dev/null
aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
echo "  Lambda updated — direct path active."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> [09] Layer 6 (Firehose → Redshift direct) complete."
echo ""
echo "  Architecture:"
echo "    Kinesis → Lambda"
echo "      ├── DynamoDB (hot store)"
echo "      ├── Firehose (${FIREHOSE_STREAM}) → S3 raw → Glue ETL → Parquet → public.orders"
echo "      └── Firehose (${FIREHOSE_NAME}) → S3 staging → COPY → public.orders_direct"
echo ""
echo "  Key difference:"
echo "    public.orders       = Lambda-enriched JSON → Glue ETL (Parquet, deduped, has event_ts)"
echo "    public.orders_direct = Lambda-enriched JSON → Firehose COPY directly (no Glue, no event_ts)"
echo "    Both tables have processed_at (Lambda adds it)."
echo ""
echo "  Send events:"
echo "    python3 app/order_generator.py --stream lks-pipeline-stream --region ${REGION}"
echo ""
echo "  Wait ~60 seconds, then verify:"
echo "    SID=\$(aws redshift-data execute-statement \\"
echo "      --cluster-identifier ${CLUSTER_ID} --database ${CLUSTER_DB} \\"
echo "      --db-user ${CLUSTER_USER} --region ${REGION} \\"
echo "      --sql 'SELECT COUNT(*) FROM public.orders_direct' \\"
echo "      --query 'Id' --output text)"
echo "    sleep 5"
echo "    aws redshift-data get-statement-result --id \$SID --region ${REGION} \\"
echo "      --query 'Records[0][0]' --output text"
