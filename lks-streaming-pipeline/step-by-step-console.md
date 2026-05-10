# Step-by-Step Answer Key — Console (AWS Management Console)

## Layer Table

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | S3 zones + Kinesis stream + DynamoDB | Kinesis stream shows ACTIVE in console |
| **2** | Lambda transformer + Kinesis ESM + Firehose | DynamoDB items visible after sending events |
| **3** | Glue ETL + Glue Crawler + Athena workgroup | Athena query returns rows |
| **4** | Redshift cluster + table + COPY | Redshift Query Editor shows row count |
| **5** | CloudWatch alarms + SNS topic | 3 alarms visible in CloudWatch console |

> All steps use **us-east-1 (N. Virginia)** region. Confirm region in the top-right of the console before each step.

---

## Layer 1 — S3 Zones + Kinesis + DynamoDB

### 1.1 — Create S3 Buckets

Create 3 buckets. Repeat for each:

1. Go to **S3** → **Create bucket**
2. Configure (same for all 3):

| Setting | Value |
|---|---|
| Bucket name | `lks-pipeline-raw-<ACCOUNT_ID>` (then `processed`, `results`) |
| AWS Region | us-east-1 |
| Object Ownership | ACLs disabled |
| Block all public access | ✅ checked |
| Default encryption | SSE-S3 (AES-256) |

3. Click **Create bucket**

For the **raw bucket only** — after creation:
- Open the bucket → **Properties** tab
- Scroll to **Amazon EventBridge** → **Edit** → Enable → **Save changes**

### 1.2 — Create Kinesis Data Stream

1. Go to **Kinesis** → **Data Streams** → **Create data stream**

| Setting | Value |
|---|---|
| Data stream name | `lks-pipeline-stream` |
| Capacity mode | Provisioned |
| Provisioned shards | 1 |

2. Click **Create data stream**
3. Wait for status **Active**
4. Open stream → **Configuration** tab → **Edit** → Change **Data retention period** to `24 hours` → **Save changes**

### 1.3 — Create DynamoDB Table

1. Go to **DynamoDB** → **Tables** → **Create table**

| Setting | Value |
|---|---|
| Table name | `lks-pipeline-orders` |
| Partition key | `order_id` (String) |
| Table class | DynamoDB Standard |
| Capacity mode | On-demand |

2. **Tags**: Add `Project=lks-streaming-pipeline`, `Environment=production`, `ManagedBy=LKS-Team`
3. Click **Create table** — wait for **Active**

**Layer 1 checkpoint:**
- Kinesis stream status shows **Active**
- 3 S3 buckets visible in S3 console
- DynamoDB table status shows **Active**

---

## Layer 2 — Lambda Transformer + Firehose

### 2.1 — Create Lambda Function

1. Go to **Lambda** → **Create function** → **Author from scratch**

| Setting | Value |
|---|---|
| Function name | `lks-pipeline-transformer` |
| Runtime | Python 3.12 |
| Architecture | x86_64 |
| Execution role | Use an existing role → `LabRole` |

2. Click **Create function**

3. In the **Code** tab, delete the default code and paste the contents of `app/transformer.py`

4. Click **Deploy**

5. Go to **Configuration** → **General configuration** → **Edit**:
   - Timeout: `1 min 0 sec`
   - Memory: `256 MB`
   - Click **Save**

6. Go to **Configuration** → **Environment variables** → **Edit** → **Add environment variable**:

| Key | Value |
|---|---|
| `DYNAMODB_TABLE` | `lks-pipeline-orders` |
| `FIREHOSE_STREAM` | `lks-pipeline-firehose` |

7. Click **Save**

### 2.2 — Add Kinesis Trigger

1. In the Lambda function page → **Add trigger**
2. Select **Kinesis**

| Setting | Value |
|---|---|
| Kinesis stream | `lks-pipeline-stream` |
| Batch size | 10 |
| Starting position | Trim horizon |
| Bisect batch on error | ✅ enabled |

3. Click **Add**

### 2.3 — Create Firehose Delivery Stream

1. Go to **Amazon Data Firehose** → **Create Firehose stream**

| Setting | Value |
|---|---|
| Source | Direct PUT |
| Destination | Amazon S3 |
| Firehose stream name | `lks-pipeline-firehose` |

**Destination settings:**
| Setting | Value |
|---|---|
| S3 bucket | `lks-pipeline-raw-<ACCOUNT_ID>` |
| S3 bucket prefix | `orders/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/` |
| S3 bucket error output prefix | `errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/` |

**Buffer hints:**
| Setting | Value |
|---|---|
| Buffer size | 5 MB |
| Buffer interval | 60 seconds |

**Permissions:**
- Under **Service role** → Select **Create or update IAM role** and select `LabRole`

**CloudWatch error logging** → Enable

5. Click **Create Firehose stream** — wait for **Active**

### 2.4 — Send Test Data

Run from terminal:

```bash
cd lks-streaming-pipeline
python3 app/order_generator.py --stream lks-pipeline-stream --region us-east-1
```

Or use the shell script:

```bash
bash scripts/07-generate-events.sh
```

Wait 90 seconds, then verify:
- **DynamoDB** → `lks-pipeline-orders` → **Explore table items** — should show records
- **S3** → `lks-pipeline-raw-<ACCOUNT_ID>` → browse `orders/` prefix — should show JSON files

**Layer 2 checkpoint:**
- DynamoDB table has items visible in Explore items
- S3 raw bucket has files under `orders/year=.../month=.../day=.../hour=.../`
- Lambda **Monitor** tab → **View CloudWatch logs** → no ERROR entries

---

## Layer 3 — Glue ETL + Crawler + Athena

### 3.1 — Upload Glue Script to S3

1. Go to **S3** → open `lks-pipeline-processed-<ACCOUNT_ID>` bucket
2. Click **Create folder** → name `scripts` → **Create folder**
3. Open the `scripts/` folder → **Upload** → upload `app/glue_etl.py`

### 3.2 — Create Glue Database

1. Go to **AWS Glue** → **Databases** → **Add database**
2. Name: `lks_pipeline_db` → **Create**

### 3.3 — Create Glue ETL Job

1. Go to **AWS Glue** → **ETL Jobs** → **Script editor**
2. Select **Upload and edit an existing script** → upload `app/glue_etl.py` → **Create script editor**
3. In the **Job details** tab, configure:

| Setting | Value |
|---|---|
| Name | `lks-pipeline-etl` |
| IAM Role | `LabRole` |
| Glue version | Glue 4.0 |
| Worker type | G.1X |
| Number of workers | 2 |
| Job timeout | 15 minutes |
| Script path | S3 path to the script (auto-filled or set to `s3://lks-pipeline-processed-<ACCOUNT_ID>/scripts/glue_etl.py`) |

4. In **Advanced properties** → **Job parameters** → add:

| Key | Value |
|---|---|
| `--S3_RAW_PATH` | `s3://lks-pipeline-raw-<ACCOUNT_ID>/orders/` |
| `--S3_PROCESSED_BUCKET` | `lks-pipeline-processed-<ACCOUNT_ID>` |
| `--S3_PROCESSED_PREFIX` | `orders` |
| `--enable-metrics` | `true` |
| `--enable-continuous-cloudwatch-log` | `true` |

5. Click **Save** then **Run**
6. Monitor under **Runs** tab — wait for **Succeeded** (~3 minutes)

### 3.4 — Create and Run Glue Crawler

1. Go to **AWS Glue** → **Crawlers** → **Create crawler**

| Step | Setting | Value |
|---|---|---|
| Name | Crawler name | `lks-pipeline-crawler` |
| Data source | S3 path | `s3://lks-pipeline-processed-<ACCOUNT_ID>/orders/` |
| IAM Role | IAM role | `LabRole` |
| Database | Target database | `lks_pipeline_db` |
| Schedule | Frequency | Hourly |

2. Click **Create crawler**
3. Select crawler → **Run crawler**
4. Wait for status **Ready**
5. Go to **Databases** → `lks_pipeline_db` → **Tables** — should show `orders` table

### 3.5 — Create Athena Workgroup and Query

1. Go to **Amazon Athena** → **Workgroups** → **Create workgroup**

| Setting | Value |
|---|---|
| Workgroup name | `lks-pipeline-wg` |
| Query result location | `s3://lks-pipeline-results-<ACCOUNT_ID>/athena-results/` |
| Enforce workgroup settings | ✅ |
| Publish query metrics to CloudWatch | ✅ |
| Engine version | Athena engine version 3 |

2. Click **Create workgroup**

3. Go to **Query editor** → top-right dropdown → select **lks-pipeline-wg**
4. Select database: `lks_pipeline_db`
5. Run this query:

```sql
SELECT
    region,
    category,
    COUNT(*) AS order_count,
    SUM(total_amount) AS revenue
FROM lks_pipeline_db.orders
GROUP BY region, category
ORDER BY revenue DESC;
```

**Layer 3 checkpoint:**
- Glue catalog shows `orders` table in `lks_pipeline_db`
- Athena query returns rows with region/category breakdown
- S3 processed bucket has Parquet files under `orders/year=.../`

---

## Layer 4 — Redshift Data Warehouse

### 4.1 — Create Redshift Cluster

1. Go to **Amazon Redshift** → **Clusters** → **Create cluster**

| Setting | Value |
|---|---|
| Cluster identifier | `lks-pipeline-cluster` |
| Node type | `ra3.xlplus` |
| Number of nodes | 1 (single-node) |
| Database name | `pipeline` |
| Admin user name | `admin` |
| Admin password | `LksPipeline2024!` |

**Cluster permissions:**
- Under **Cluster permissions** → **Manage IAM roles** → Associate `LabRole`

**Network settings:**
- Publicly accessible: **Turn on**

> ⚠️ Cost warning: `ra3.xlplus` costs ~$1.08/hr. Delete immediately after exam.

2. Click **Create cluster** — wait for status **Available** (~10-15 minutes)

### 4.2 — Create Table via Query Editor

1. Open the cluster → **Query data** → **Query editor v2**
2. Connect with:
   - Authentication: Temporary credentials
   - Database: `pipeline`
   - User: `admin`
3. Run DDL:

```sql
CREATE TABLE IF NOT EXISTS public.orders (
    order_id        VARCHAR(50)     NOT NULL,
    customer_id     VARCHAR(50),
    product_id      VARCHAR(50),
    product_name    VARCHAR(200),
    category        VARCHAR(100),
    quantity        INTEGER,
    unit_price      DECIMAL(15,2),
    total_amount    DECIMAL(15,2),
    order_status    VARCHAR(50),
    payment_method  VARCHAR(50),
    region          VARCHAR(50),
    timestamp       TIMESTAMP,
    processed_at    TIMESTAMP,
    year            VARCHAR(4),
    month           VARCHAR(2),
    day             VARCHAR(2),
    PRIMARY KEY (order_id)
)
DISTSTYLE KEY DISTKEY(region)
SORTKEY(timestamp);
```

### 4.3 — COPY from S3

Get the LabRole ARN first:
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
```

In Redshift Query Editor v2:

```sql
COPY public.orders
FROM 's3://lks-pipeline-processed-<ACCOUNT_ID>/orders/'
IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/LabRole'
FORMAT AS PARQUET
ACCEPTINVCHARS;
```

Replace `<ACCOUNT_ID>` with your actual account ID.

### 4.4 — Verify and Query

```sql
-- Row count
SELECT COUNT(*) AS row_count FROM public.orders;

-- Revenue by region
SELECT
    region,
    SUM(total_amount) AS revenue,
    COUNT(*) AS orders
FROM public.orders
GROUP BY region
ORDER BY revenue DESC;
```

**Layer 4 checkpoint:**
- Cluster status shows **Available**
- `SELECT COUNT(*)` returns the correct number of rows

---

## Layer 5 — CloudWatch + SNS Monitoring

### 5.1 — Create SNS Topic

1. Go to **Amazon SNS** → **Topics** → **Create topic**

| Setting | Value |
|---|---|
| Type | Standard |
| Name | `lks-pipeline-alerts` |

2. Click **Create topic**
3. (Optional) Click **Create subscription** → Protocol: Email → enter your email → **Create subscription** → confirm in inbox

Copy the **Topic ARN** (needed for alarms).

### 5.2 — Create CloudWatch Alarms

Go to **CloudWatch** → **Alarms** → **Create alarm** (repeat 3 times):

**Alarm 1: Kinesis Iterator Age**
- Metric: Kinesis → Per-Stream Metrics → `lks-pipeline-stream` → `GetRecords.IteratorAgeMilliseconds`
- Statistic: Maximum, Period: 5 minutes
- Threshold: Greater than 60000
- Evaluation periods: 2
- Missing data: Treat as Not Breaching
- Action: Send notification to `lks-pipeline-alerts`
- Alarm name: `lks-kinesis-iterator-age-high`

**Alarm 2: Lambda Errors**
- Metric: Lambda → By Function Name → `lks-pipeline-transformer` → `Errors`
- Statistic: Sum, Period: 5 minutes
- Threshold: Greater than or equal to 5
- Evaluation periods: 1
- Missing data: Treat as Not Breaching
- Action: Send notification to `lks-pipeline-alerts`
- Alarm name: `lks-lambda-transformer-errors`

**Alarm 3: Lambda Duration**
- Metric: Lambda → By Function Name → `lks-pipeline-transformer` → `Duration`
- Statistic: Average, Period: 5 minutes
- Threshold: Greater than 45000
- Evaluation periods: 2
- Missing data: Treat as Not Breaching
- Action: Send notification to `lks-pipeline-alerts`
- Alarm name: `lks-lambda-transformer-duration`

**Layer 5 checkpoint:**
- CloudWatch Alarms console shows 3 alarms with `lks-` prefix
- All alarms show **Insufficient data** or **OK** state

---

## Full Validation

Run the validation script to check all layers:

```bash
bash scripts/08-validate.sh
```

---

## Cleanup (Console)

Delete resources in this order to minimize cost:

1. **Redshift** → Clusters → `lks-pipeline-cluster` → Actions → Delete → Skip final snapshot → **Delete**
2. **Kinesis** → Data Streams → `lks-pipeline-stream` → Delete
3. **Lambda** → Functions → `lks-pipeline-transformer` → Actions → Delete
4. **Firehose** → `lks-pipeline-firehose` → Delete
5. **Glue** → Jobs → `lks-pipeline-etl` → Delete
6. **Glue** → Crawlers → `lks-pipeline-crawler` → Delete
7. **Glue** → Databases → `lks_pipeline_db` → Delete
8. **Athena** → Workgroups → `lks-pipeline-wg` → Delete (check recursive delete)
9. **CloudWatch** → Alarms → select all 3 `lks-*` alarms → Delete
10. **SNS** → Topics → `lks-pipeline-alerts` → Delete
11. **DynamoDB** → Tables → `lks-pipeline-orders` → Delete
12. **S3** → empty each bucket (select all → Delete) then delete the bucket
