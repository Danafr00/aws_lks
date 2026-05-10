# Step-by-Step Answer Key — CLI (AWS CLI)

## Layer Table

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | S3 zones + Kinesis stream + DynamoDB | `aws kinesis describe-stream-summary` → ACTIVE |
| **2** | Lambda transformer + Kinesis ESM + Firehose | Put records → DynamoDB items exist; S3 raw has JSON |
| **3** | Glue ETL + Glue Crawler + Athena workgroup | Athena query returns rows |
| **4** | Redshift cluster + table + COPY | `SELECT COUNT(*) FROM public.orders` returns correct count |
| **5** | CloudWatch alarms + SNS topic | 3 alarms created |
| **6** | Firehose → Redshift direct (Lambda fan-out) | `SELECT COUNT(*) FROM public.orders_direct` returns rows |

---

## Prerequisites

```bash
# Verify AWS CLI configured for us-east-1
aws sts get-caller-identity
export AWS_DEFAULT_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole
echo "Account: ${ACCOUNT_ID}"
echo "LabRole: ${LAB_ROLE_ARN}"
```

---

## Layer 1 — S3 Zones + Kinesis + DynamoDB

### Step 1.1 — Create S3 Buckets

```bash
for ZONE in raw processed results; do
  BUCKET=lks-pipeline-${ZONE}-${ACCOUNT_ID}
  aws s3api create-bucket --bucket $BUCKET --region us-east-1
  aws s3api put-bucket-encryption --bucket $BUCKET \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket $BUCKET \
    --public-access-block-configuration \
      'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  echo "Created: $BUCKET"
done
```

Enable EventBridge notifications on raw bucket (used for future integrations):

```bash
aws s3api put-bucket-notification-configuration \
  --bucket lks-pipeline-raw-${ACCOUNT_ID} \
  --notification-configuration '{"EventBridgeConfiguration":{}}'
```

### Step 1.2 — Create Kinesis Data Stream

```bash
aws kinesis create-stream \
  --stream-name lks-pipeline-stream \
  --shard-count 1

# Wait for ACTIVE
aws kinesis wait stream-exists --stream-name lks-pipeline-stream

# Extend retention to 24 hours
aws kinesis increase-stream-retention-period \
  --stream-name lks-pipeline-stream \
  --retention-period-hours 24

# Tag it
aws kinesis add-tags-to-stream \
  --stream-name lks-pipeline-stream \
  --tags Project=lks-streaming-pipeline,Environment=production,ManagedBy=LKS-Team
```

### Step 1.3 — Create DynamoDB Table

```bash
aws dynamodb create-table \
  --table-name lks-pipeline-orders \
  --attribute-definitions AttributeName=order_id,AttributeType=S \
  --key-schema AttributeName=order_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

aws dynamodb wait table-exists --table-name lks-pipeline-orders
echo "DynamoDB table active"
```

**Layer 1 checkpoint — verify before continuing:**
- [ ] `aws kinesis describe-stream-summary --stream-name lks-pipeline-stream --query 'StreamDescriptionSummary.StreamStatus' --output text` → `ACTIVE`
- [ ] `aws s3 ls | grep lks-pipeline` → shows 3 buckets
- [ ] `aws dynamodb describe-table --table-name lks-pipeline-orders --query 'Table.TableStatus' --output text` → `ACTIVE`

---

## Layer 2 — Lambda Transformer + Firehose

### Step 2.1 — Package and Deploy Lambda

```bash
cd lks-streaming-pipeline/app
zip /tmp/transformer.zip transformer.py

aws lambda create-function \
  --function-name lks-pipeline-transformer \
  --runtime python3.12 \
  --role ${LAB_ROLE_ARN} \
  --handler transformer.handler \
  --zip-file fileb:///tmp/transformer.zip \
  --timeout 60 \
  --memory-size 256 \
  --environment "Variables={
    DYNAMODB_TABLE=lks-pipeline-orders,
    FIREHOSE_STREAM=lks-pipeline-firehose
  }"

aws lambda wait function-active --function-name lks-pipeline-transformer
echo "Lambda deployed"
```

### Step 2.2 — Create Kinesis Event Source Mapping

```bash
STREAM_ARN=$(aws kinesis describe-stream-summary \
  --stream-name lks-pipeline-stream \
  --query 'StreamDescriptionSummary.StreamARN' \
  --output text)

aws lambda create-event-source-mapping \
  --function-name lks-pipeline-transformer \
  --event-source-arn ${STREAM_ARN} \
  --batch-size 10 \
  --starting-position TRIM_HORIZON \
  --bisect-batch-on-function-error
```

### Step 2.3 — Create Firehose Delivery Stream

```bash
aws firehose create-delivery-stream \
  --delivery-stream-name lks-pipeline-firehose \
  --delivery-stream-type DirectPut \
  --extended-s3-destination-configuration "{
    \"RoleARN\": \"${LAB_ROLE_ARN}\",
    \"BucketARN\": \"arn:aws:s3:::lks-pipeline-raw-${ACCOUNT_ID}\",
    \"Prefix\": \"orders/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/\",
    \"ErrorOutputPrefix\": \"errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/\",
    \"BufferingHints\": {\"SizeInMBs\": 5, \"IntervalInSeconds\": 60},
    \"CompressionFormat\": \"UNCOMPRESSED\",
    \"CloudWatchLoggingOptions\": {
      \"Enabled\": true,
      \"LogGroupName\": \"/aws/kinesisfirehose/lks-pipeline-firehose\",
      \"LogStreamName\": \"DestinationDelivery\"
    }
  }"

# Wait for ACTIVE
while true; do
  STATUS=$(aws firehose describe-delivery-stream \
    --delivery-stream-name lks-pipeline-firehose \
    --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text)
  echo "Firehose status: $STATUS"
  [ "$STATUS" = "ACTIVE" ] && break
  sleep 5
done
```

### Step 2.4 — Send Test Records

```bash
# Option A: use the generator script
python3 app/order_generator.py --stream lks-pipeline-stream --region us-east-1

# Option B: use the shell script
bash scripts/07-generate-events.sh
```

Wait 90 seconds, then verify:

```bash
# DynamoDB should have items
aws dynamodb scan --table-name lks-pipeline-orders --select COUNT

# S3 raw should have JSON files
aws s3 ls --recursive s3://lks-pipeline-raw-${ACCOUNT_ID}/orders/

# Lambda logs
aws logs tail /aws/lambda/lks-pipeline-transformer --since 5m
```

**Layer 2 checkpoint — verify before continuing:**
- [ ] `aws dynamodb scan --table-name lks-pipeline-orders --select COUNT --query 'Count'` ≥ 1
- [ ] `aws s3 ls --recursive s3://lks-pipeline-raw-${ACCOUNT_ID}/orders/` shows JSON files
- [ ] Lambda logs show no errors

---

## Layer 3 — Glue ETL + Crawler + Athena

### Step 3.1 — Upload Glue Script

```bash
aws s3 cp app/glue_etl.py \
  s3://lks-pipeline-processed-${ACCOUNT_ID}/scripts/glue_etl.py
```

### Step 3.2 — Create Glue Database and Job

```bash
aws glue create-database \
  --database-input '{"Name":"lks_pipeline_db","Description":"LKS streaming pipeline catalog"}'

aws glue create-job \
  --name lks-pipeline-etl \
  --role ${LAB_ROLE_ARN} \
  --command "{
    \"Name\": \"glueetl\",
    \"ScriptLocation\": \"s3://lks-pipeline-processed-${ACCOUNT_ID}/scripts/glue_etl.py\",
    \"PythonVersion\": \"3\"
  }" \
  --default-arguments "{
    \"--job-language\": \"python\",
    \"--enable-metrics\": \"true\",
    \"--enable-continuous-cloudwatch-log\": \"true\",
    \"--S3_RAW_PATH\": \"s3://lks-pipeline-raw-${ACCOUNT_ID}/orders/\",
    \"--S3_PROCESSED_BUCKET\": \"lks-pipeline-processed-${ACCOUNT_ID}\",
    \"--S3_PROCESSED_PREFIX\": \"orders\"
  }" \
  --glue-version "4.0" \
  --worker-type G.1X \
  --number-of-workers 2 \
  --timeout 15
```

### Step 3.3 — Run Glue Job

```bash
RUN_ID=$(aws glue start-job-run \
  --job-name lks-pipeline-etl \
  --query 'JobRunId' --output text)
echo "Job run ID: ${RUN_ID}"

# Poll until completion
while true; do
  STATUS=$(aws glue get-job-run \
    --job-name lks-pipeline-etl \
    --run-id ${RUN_ID} \
    --query 'JobRun.JobRunState' --output text)
  echo "$(date +%H:%M:%S) Glue job: ${STATUS}"
  [ "$STATUS" = "SUCCEEDED" ] && break
  [ "$STATUS" = "FAILED" ] && { echo "Job FAILED"; break; }
  sleep 20
done
```

### Step 3.4 — Create Glue Crawler and Run

```bash
aws glue create-crawler \
  --name lks-pipeline-crawler \
  --role ${LAB_ROLE_ARN} \
  --database-name lks_pipeline_db \
  --targets "{\"S3Targets\":[{\"Path\":\"s3://lks-pipeline-processed-${ACCOUNT_ID}/orders/\"}]}" \
  --schedule "cron(0 * * * ? *)" \
  --schema-change-policy '{"UpdateBehavior":"UPDATE_IN_DATABASE","DeleteBehavior":"LOG"}'

# Run immediately
aws glue start-crawler --crawler-name lks-pipeline-crawler

# Wait for READY
while true; do
  STATUS=$(aws glue get-crawler --name lks-pipeline-crawler \
    --query 'Crawler.State' --output text)
  echo "Crawler: ${STATUS}"
  [ "$STATUS" = "READY" ] && break
  sleep 10
done

# Verify table discovered
aws glue get-tables --database-name lks_pipeline_db \
  --query 'TableList[*].[Name,StorageDescriptor.InputFormat]' --output table
```

### Step 3.5 — Create Athena Workgroup and Query

```bash
aws athena create-work-group \
  --name lks-pipeline-wg \
  --configuration "{
    \"ResultConfiguration\": {
      \"OutputLocation\": \"s3://lks-pipeline-results-${ACCOUNT_ID}/athena-results/\"
    },
    \"EnforceWorkGroupConfiguration\": true,
    \"PublishCloudWatchMetricsEnabled\": true,
    \"EngineVersion\": {\"SelectedEngineVersion\": \"Athena engine version 3\"}
  }" \
  --description "LKS streaming pipeline analytics workgroup"

# Run a query
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT region, category, COUNT(*) AS orders, SUM(total_amount) AS revenue FROM lks_pipeline_db.orders GROUP BY region, category ORDER BY revenue DESC" \
  --work-group lks-pipeline-wg \
  --query 'QueryExecutionId' --output text)

echo "Query ID: ${QUERY_ID}"

# Wait and get results
aws athena wait query-execution-complete --query-execution-id ${QUERY_ID}

aws athena get-query-results \
  --query-execution-id ${QUERY_ID} \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
  --output table
```

**Layer 3 checkpoint — verify before continuing:**
- [ ] `aws glue get-tables --database-name lks_pipeline_db --query 'length(TableList)'` ≥ 1
- [ ] `aws s3 ls --recursive s3://lks-pipeline-processed-${ACCOUNT_ID}/orders/ | grep parquet` shows files
- [ ] Athena query above returns rows with region/category breakdown

---

## Layer 4 — Redshift Data Warehouse

### Step 4.1 — Create Redshift Cluster

```bash
aws redshift create-cluster \
  --cluster-identifier lks-pipeline-cluster \
  --node-type ra3.large \
  --master-username admin \
  --master-user-password 'LksPipeline2024!' \
  --cluster-type single-node \
  --db-name pipeline \
  --publicly-accessible \
  --iam-roles ${LAB_ROLE_ARN}

echo "Cluster creating... wait ~10-15 minutes"

# Poll until available
while true; do
  STATUS=$(aws redshift describe-clusters \
    --cluster-identifier lks-pipeline-cluster \
    --query 'Clusters[0].ClusterStatus' --output text)
  echo "$(date +%H:%M:%S) Cluster: ${STATUS}"
  [ "$STATUS" = "available" ] && break
  sleep 30
done

ENDPOINT=$(aws redshift describe-clusters \
  --cluster-identifier lks-pipeline-cluster \
  --query 'Clusters[0].Endpoint.Address' --output text)
echo "Endpoint: ${ENDPOINT}"
```

### Step 4.2 — Create Table via Data API

```bash
STMT_ID=$(aws redshift-data execute-statement \
  --cluster-identifier lks-pipeline-cluster \
  --database pipeline \
  --db-user admin \
  --sql "
    CREATE TABLE IF NOT EXISTS public.orders (
      order_id        VARCHAR(50)    NOT NULL,
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
  --query 'Id' --output text)

sleep 10
STATUS=$(aws redshift-data describe-statement --id ${STMT_ID} --query 'Status' --output text)
echo "DDL status: ${STATUS}"
```

### Step 4.3 — COPY from S3 Processed

```bash
COPY_ID=$(aws redshift-data execute-statement \
  --cluster-identifier lks-pipeline-cluster \
  --database pipeline \
  --db-user admin \
  --sql "
    COPY public.orders
    FROM 's3://lks-pipeline-processed-${ACCOUNT_ID}/orders/'
    IAM_ROLE '${LAB_ROLE_ARN}'
    FORMAT AS PARQUET
    ACCEPTINVCHARS;
  " \
  --query 'Id' --output text)

echo "COPY statement: ${COPY_ID}"

# Wait for completion
for i in $(seq 1 24); do
  STATUS=$(aws redshift-data describe-statement --id ${COPY_ID} --query 'Status' --output text)
  echo "$(date +%H:%M:%S) COPY: ${STATUS}"
  [ "$STATUS" = "FINISHED" ] && break
  [ "$STATUS" = "FAILED" ] && break
  sleep 10
done
```

### Step 4.4 — Verify and Query

```bash
# Row count
COUNT_ID=$(aws redshift-data execute-statement \
  --cluster-identifier lks-pipeline-cluster \
  --database pipeline \
  --db-user admin \
  --sql "SELECT COUNT(*) AS row_count FROM public.orders;" \
  --query 'Id' --output text)

sleep 5
aws redshift-data get-statement-result --id ${COUNT_ID} \
  --query 'Records[0][0]' --output text

# Revenue by region
REVENUE_ID=$(aws redshift-data execute-statement \
  --cluster-identifier lks-pipeline-cluster \
  --database pipeline \
  --db-user admin \
  --sql "SELECT region, SUM(total_amount) AS revenue, COUNT(*) AS orders FROM public.orders GROUP BY region ORDER BY revenue DESC;" \
  --query 'Id' --output text)

sleep 5
aws redshift-data get-statement-result --id ${REVENUE_ID} \
  --query 'Records[*]' --output json
```

**Layer 4 checkpoint — verify before continuing:**
- [ ] `aws redshift describe-clusters --cluster-identifier lks-pipeline-cluster --query 'Clusters[0].ClusterStatus' --output text` → `available`
- [ ] Row count query returns value > 0

---

## Layer 5 — CloudWatch + SNS Monitoring

### Step 5.1 — Create SNS Topic

```bash
TOPIC_ARN=$(aws sns create-topic \
  --name lks-pipeline-alerts \
  --query 'TopicArn' --output text)
echo "SNS topic: ${TOPIC_ARN}"

# Optional: subscribe email
# aws sns subscribe --topic-arn ${TOPIC_ARN} --protocol email \
#   --notification-endpoint your@email.com
```

### Step 5.2 — Create CloudWatch Alarms

```bash
# Alarm 1: Kinesis iterator age
aws cloudwatch put-metric-alarm \
  --alarm-name lks-kinesis-iterator-age-high \
  --alarm-description "Kinesis consumer falling behind" \
  --metric-name GetRecords.IteratorAgeMilliseconds \
  --namespace AWS/Kinesis \
  --dimensions Name=StreamName,Value=lks-pipeline-stream \
  --statistic Maximum \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 60000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions ${TOPIC_ARN}

# Alarm 2: Lambda errors
aws cloudwatch put-metric-alarm \
  --alarm-name lks-lambda-transformer-errors \
  --alarm-description "Lambda transformer errors" \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --dimensions Name=FunctionName,Value=lks-pipeline-transformer \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions ${TOPIC_ARN}

# Alarm 3: Lambda duration
aws cloudwatch put-metric-alarm \
  --alarm-name lks-lambda-transformer-duration \
  --alarm-description "Lambda transformer high duration" \
  --metric-name Duration \
  --namespace AWS/Lambda \
  --dimensions Name=FunctionName,Value=lks-pipeline-transformer \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 45000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions ${TOPIC_ARN}
```

**Layer 5 checkpoint — verify before continuing:**
- [ ] `aws cloudwatch describe-alarms --alarm-name-prefix lks- --query 'MetricAlarms[*].AlarmName' --output table` shows 3 alarms

---

## Layer 6 — Firehose → Redshift Direct

**Concept:** Lambda already enriches records and puts them to `lks-pipeline-firehose` (→ S3). This layer adds a second Firehose (`lks-pipeline-firehose-direct`) that Lambda also PutRecords to — delivering the same enriched JSON directly to Redshift, bypassing Glue ETL.

Both Firehoses are **Direct PUT** (Lambda is the fan-out point, not Kinesis).

### 6.1 — Create Table in Redshift

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_ID=lks-pipeline-cluster
CLUSTER_DB=pipeline
CLUSTER_USER=admin

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
  --region us-east-1 \
  --query 'Id' --output text)

aws redshift-data wait statement-finished --id "$STMT_ID" --region us-east-1 2>/dev/null || true
echo "Table created: public.orders_direct"
```

> Includes `processed_at` — Lambda adds this before PutRecord to both Firehoses.
> No `event_ts` — that is derived by Glue ETL only (parses `timestamp` to TimestampType).

### 6.2 — Create Firehose (Direct PUT) + Update Lambda Env Var

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
LAB_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/LabRole
RAW_BUCKET=lks-pipeline-raw-${ACCOUNT_ID}

CLUSTER_ENDPOINT=$(aws redshift describe-clusters \
  --cluster-identifier lks-pipeline-cluster \
  --region "$REGION" \
  --query 'Clusters[0].Endpoint.Address' \
  --output text)

cat > /tmp/lks-fh-rs-config.json << EOF
{
  "RoleARN": "${LAB_ROLE_ARN}",
  "ClusterJDBCURL": "jdbc:redshift://${CLUSTER_ENDPOINT}:5439/pipeline",
  "CopyCommand": {
    "DataTableName": "public.orders_direct",
    "CopyOptions": "json 'auto' ACCEPTINVCHARS TRUNCATECOLUMNS"
  },
  "Username": "admin",
  "Password": "LksPipeline2024!",
  "S3Configuration": {
    "RoleARN": "${LAB_ROLE_ARN}",
    "BucketARN": "arn:aws:s3:::${RAW_BUCKET}",
    "Prefix": "staging/redshift/",
    "ErrorOutputPrefix": "errors/redshift/",
    "BufferingHints": {"SizeInMBs": 5, "IntervalInSeconds": 60},
    "CompressionFormat": "UNCOMPRESSED"
  }
}
EOF

aws firehose create-delivery-stream \
  --delivery-stream-name lks-pipeline-firehose-direct \
  --delivery-stream-type DirectPut \
  --redshift-destination-configuration "file:///tmp/lks-fh-rs-config.json" \
  --region "$REGION"

rm -f /tmp/lks-fh-rs-config.json
```

Wait for ACTIVE:

```bash
aws firehose describe-delivery-stream \
  --delivery-stream-name lks-pipeline-firehose-direct \
  --region us-east-1 \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
  --output text
# Expected: ACTIVE
```

Activate the direct path in Lambda by setting `FIREHOSE_DIRECT_STREAM`:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws lambda update-function-configuration \
  --function-name lks-pipeline-transformer \
  --environment "Variables={
    DYNAMODB_TABLE=lks-pipeline-orders,
    FIREHOSE_STREAM=lks-pipeline-firehose,
    FIREHOSE_DIRECT_STREAM=lks-pipeline-firehose-direct,
    AWS_ACCOUNT_ID=${ACCOUNT_ID}
  }" \
  --region us-east-1
aws lambda wait function-updated --function-name lks-pipeline-transformer --region us-east-1
```

> Until this env var is set, Lambda skips the direct Firehose (`FIREHOSE_DIRECT_STREAM` defaults to empty string — the path is a no-op). Script `09-setup-firehose-redshift.sh` does this automatically.

### 6.3 — Send Test Events and Verify

```bash
# Send 20 orders (records include \n delimiter — required for Firehose json auto COPY)
python3 app/order_generator.py --stream lks-pipeline-stream --region us-east-1
```

Wait ~60 seconds (Firehose buffer interval), then query:

```bash
SID=$(aws redshift-data execute-statement \
  --cluster-identifier lks-pipeline-cluster \
  --database pipeline \
  --db-user admin \
  --sql "SELECT COUNT(*) FROM public.orders_direct;" \
  --region us-east-1 \
  --query 'Id' --output text)

sleep 5

aws redshift-data get-statement-result \
  --id "$SID" \
  --region us-east-1 \
  --query 'Records[0][0]' \
  --output text
# Expected: 20 (or more if events were sent multiple times)
```

Compare both tables:

```bash
SID=$(aws redshift-data execute-statement \
  --cluster-identifier lks-pipeline-cluster \
  --database pipeline \
  --db-user admin \
  --sql "
    SELECT 'orders (Parquet/Glue)' AS source, COUNT(*) AS rows FROM public.orders
    UNION ALL
    SELECT 'orders_direct (Firehose)' AS source, COUNT(*) AS rows FROM public.orders_direct;
  " \
  --region us-east-1 \
  --query 'Id' --output text)

sleep 5

aws redshift-data get-statement-result \
  --id "$SID" \
  --region us-east-1 \
  --query 'Records[*][*]' \
  --output text
```

**Layer 6 checkpoint — verify before continuing:**
- [ ] `aws firehose describe-delivery-stream --delivery-stream-name lks-pipeline-firehose-direct` → status `ACTIVE`
- [ ] `SELECT COUNT(*) FROM public.orders_direct` returns rows after ~60s

---

## Full Validation

```bash
bash scripts/08-validate.sh
```

Expected output: `Results: N passed, 0 failed — ALL CHECKS PASSED`

---

## Cleanup

```bash
# Redshift (most expensive — delete first)
aws redshift delete-cluster --cluster-identifier lks-pipeline-cluster \
  --skip-final-cluster-snapshot

# Kinesis stream
aws kinesis delete-stream --stream-name lks-pipeline-stream

# Lambda
aws lambda delete-function --function-name lks-pipeline-transformer

# Firehose
aws firehose delete-delivery-stream --delivery-stream-name lks-pipeline-firehose
aws firehose delete-delivery-stream --delivery-stream-name lks-pipeline-firehose-direct

# Glue
aws glue delete-job --job-name lks-pipeline-etl
aws glue delete-crawler --name lks-pipeline-crawler
aws glue delete-database --name lks_pipeline_db

# Athena workgroup
aws athena delete-work-group --work-group lks-pipeline-wg --recursive-delete-option

# CloudWatch alarms
aws cloudwatch delete-alarms --alarm-names \
  lks-kinesis-iterator-age-high \
  lks-lambda-transformer-errors \
  lks-lambda-transformer-duration

# SNS
aws sns delete-topic --topic-arn ${TOPIC_ARN}

# DynamoDB
aws dynamodb delete-table --table-name lks-pipeline-orders

# S3 (empty then delete)
for ZONE in raw processed results; do
  BUCKET=lks-pipeline-${ZONE}-${ACCOUNT_ID}
  aws s3 rm s3://${BUCKET} --recursive
  aws s3api delete-bucket --bucket ${BUCKET}
done
```
