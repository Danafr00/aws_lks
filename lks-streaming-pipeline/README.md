# LKS Cloud Computing — Real-Time E-Commerce Analytics Pipeline

**Difficulty:** ★★★★☆  
**Estimated time:** 90–120 minutes  
**Region:** us-east-1

---

## Background

**Nusantara Shop** is a fast-growing e-commerce platform processing thousands of orders per day. The platform currently stores all order data in a relational database, but the analytics team cannot run reports without impacting production performance.

The engineering team has been asked to build a **decoupled, serverless analytics pipeline** that:

1. Captures order events in real-time without touching the production database
2. Enriches and transforms each event before storing it
3. Delivers raw events to a data lake for historical analysis
4. Makes the data queryable using standard SQL
5. Loads cleaned data into a data warehouse for BI reporting

---

## Architecture Overview

```
Order Events (CLI)
      │
      ▼
┌─────────────────────────────────────────────────┐
│  Kinesis Data Stream (lks-pipeline-stream)       │
│  1 shard, real-time ingestion                   │
└──────────────────────┬──────────────────────────┘
                       │  Event Source Mapping
                       ▼
┌─────────────────────────────────────────────────┐
│  Lambda Transformer (lks-pipeline-transformer)  │
│  • normalize category  • add processed_at       │
└────────┬──────────────┬──────────────────────────┘
         │              │                │
      PutItem        PutRecord        PutRecord
         │              │                │
         ▼              ▼                ▼
  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐
  │ DynamoDB │  │   Firehose   │  │    Firehose       │
  │ hot store│  │ lks-pipeline │  │ lks-pipeline-     │
  └──────────┘  │ -firehose    │  │ firehose-direct   │
                └──────┬───────┘  └────────┬──────────┘
                       │                   │
                 Batch delivery      S3 staging/redshift/
                       │             + auto COPY json auto
                       ▼                   │
              ┌─────────────────┐          ▼
              │  S3 Raw Zone    │  ┌────────────────────────┐
              │  (JSON, dated)  │  │ Redshift               │
              └────────┬────────┘  │ public.orders_direct   │
                       │           │ (Lambda-enriched JSON) │
                  Glue ETL         └────────────────────────┘
                  (PySpark)
                       │
                       ▼
              ┌─────────────────┐
              │  S3 Processed   │
              │  (Parquet)      │
              └────────┬────────┘
                       │  Glue Crawler
                       ▼
              ┌─────────────────┐     ┌──────────────────────┐
              │  Glue Catalog   │────▶│  Athena (lakehouse)   │
              └─────────────────┘     └──────────────────────┘
                                                 │
              ┌────────────────────────────────┐ │
              │ Redshift public.orders         │◀┘ COPY from Parquet
              │ (Lambda-enriched + Glue ETL)   │
              └────────────────────────────────┘
                         │
                         ▼
              CloudWatch Alarms + SNS Alerts
```

> **Two Redshift tables — what's the difference?**
> | | `public.orders` | `public.orders_direct` |
> |---|---|---|
> | **Source** | S3 Parquet via Glue ETL | S3 JSON via Firehose COPY |
> | **Lambda enrichment** | ✅ yes (`processed_at`, normalized `category`) | ✅ yes (same) |
> | **Glue ETL** | ✅ yes (deduped, typed, `event_ts`) | ❌ no |
> | **`event_ts` column** | ✅ `TIMESTAMP` | ❌ not present |
> | **Deduplication** | ✅ `dropDuplicates` in PySpark | ❌ no |

---

## Tasks

### Task 1 — Foundation Layer (20 pts)

Create the foundational storage and ingestion resources:

- Create **three S3 buckets** with SSE-S3 encryption and public access blocked:
  - `lks-pipeline-raw-<ACCOUNT_ID>` — raw JSON events
  - `lks-pipeline-processed-<ACCOUNT_ID>` — processed Parquet files
  - `lks-pipeline-results-<ACCOUNT_ID>` — Athena query results
- Create a **Kinesis Data Stream** named `lks-pipeline-stream` with 1 shard and 24-hour retention
- Create a **DynamoDB table** named `lks-pipeline-orders` with:
  - Partition key: `order_id` (String)
  - Billing mode: On-Demand (PAY_PER_REQUEST)

**Checkpoint:** Kinesis stream is ACTIVE, all 3 S3 buckets exist, DynamoDB table is ACTIVE.

---

### Task 2 — Streaming Transform Layer (25 pts)

Build the real-time event processing pipeline:

- Deploy a **Lambda function** named `lks-pipeline-transformer`:
  - Runtime: Python 3.12
  - Timeout: 60 seconds, Memory: 256 MB
  - Execution role: `LabRole`
  - The function must:
    1. Decode and parse each Kinesis record
    2. Normalize `category` to lowercase (replace spaces with underscores)
    3. Add a `processed_at` timestamp (UTC ISO 8601)
    4. Write the enriched record to DynamoDB (`lks-pipeline-orders`)
    5. Forward the record to Firehose for S3 delivery
    6. Return `batchItemFailures` for proper error handling
  - Environment variables: `DYNAMODB_TABLE`, `FIREHOSE_STREAM`
- Create a **Kinesis Event Source Mapping** from `lks-pipeline-stream` to the Lambda function:
  - Batch size: 10
  - Starting position: TRIM_HORIZON
  - Bisect batch on error: enabled
- Create a **Kinesis Firehose** delivery stream named `lks-pipeline-firehose`:
  - Type: Direct PUT
  - Destination: S3 Raw bucket, prefix `orders/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/`
  - Buffer: 5 MB or 60 seconds
  - Delivery role: `LabRole`

**Checkpoint:** Send 20 sample records. After 90 seconds: DynamoDB has items, S3 raw has JSON files.

---

### Task 3 — Batch Analytics Layer (25 pts)

Transform raw data for analytics:

- Create a **Glue ETL Job** named `lks-pipeline-etl`:
  - Glue version: 4.0, Worker type: G.1X, Workers: 2
  - Script: `app/glue_etl.py` (uploaded to S3 processed bucket under `scripts/`)
  - Job role: `LabRole`
  - The script must:
    1. Read JSON files from S3 raw (`orders/` prefix)
    2. Normalize text columns (lowercase, trim)
    3. Cast `quantity` to INT, `unit_price` and `total_amount` to DOUBLE
    4. Parse `timestamp` and extract `year`, `month`, `day` partition columns
    5. Drop duplicates by `order_id`
    6. Write Parquet partitioned by `year/month/day` to S3 processed
- Create a **Glue Crawler** named `lks-pipeline-crawler`:
  - Target: S3 processed bucket `orders/` prefix
  - Database: `lks_pipeline_db`
  - Schedule: hourly
  - Role: `LabRole`
- Create an **Athena workgroup** named `lks-pipeline-wg`:
  - Results location: `s3://lks-pipeline-results-<ACCOUNT_ID>/athena-results/`
  - Athena engine version 3

**Checkpoint:** After running the Glue job and crawler, this Athena query returns rows:
```sql
SELECT region, COUNT(*) AS orders, SUM(total_amount) AS revenue
FROM lks_pipeline_db.orders
GROUP BY region ORDER BY revenue DESC;
```

---

### Task 4 — Data Warehouse Layer (20 pts)

Load processed data into Redshift for BI queries:

- Create a **Redshift provisioned cluster** named `lks-pipeline-cluster`:
  - Node type: `ra3.large`
  - Type: single-node
  - Database: `pipeline`, Master username: `admin`
  - IAM role: `LabRole` (for S3 COPY access)
  - Publicly accessible: yes
- Create the `public.orders` table in Redshift with appropriate column types, `DISTKEY(region)`, and `SORTKEY(event_ts)`
- Run a `COPY` command to load Parquet files from S3 processed bucket into `public.orders`
- Verify with a row count query using the Redshift Data API

> **Cost warning:** `ra3.large` costs ~$0.145/hr. Delete the cluster immediately after the exam.

**Checkpoint:** `SELECT COUNT(*) FROM public.orders` returns the correct row count via Data API.

---

### Task 5 — Monitoring Layer (10 pts)

Create observability for the pipeline:

- Create an **SNS topic** named `lks-pipeline-alerts`
- Create **3 CloudWatch alarms** that trigger on the SNS topic:
  1. `lks-kinesis-iterator-age-high` — Kinesis `GetRecords.IteratorAgeMilliseconds` > 60,000 ms
  2. `lks-lambda-transformer-errors` — Lambda `Errors` ≥ 5 in 5 minutes
  3. `lks-lambda-transformer-duration` — Lambda `Duration` average > 45,000 ms

**Checkpoint:** `aws cloudwatch describe-alarms --alarm-name-prefix lks-` shows 3 alarms.

---

### Task 6 — Direct Streaming to Redshift (Bonus, 10 pts)

Demonstrate Kinesis fan-out: a single stream feeding two separate consumers simultaneously.

- Create a second **Kinesis Firehose** named `lks-pipeline-firehose-direct`:
  - Source: **Kinesis stream** `lks-pipeline-stream` (KinesisStreamAsSource — not Direct PUT)
  - Destination: Redshift cluster `lks-pipeline-cluster`, database `pipeline`
  - Target table: `public.orders_direct`
  - S3 intermediate: `lks-pipeline-raw-<ACCOUNT_ID>/staging/redshift/`
  - COPY options: `json 'auto' ACCEPTINVCHARS TRUNCATECOLUMNS`
  - Buffer: 5 MB or 60 seconds
  - Role: `LabRole`
- Create table `public.orders_direct` in Redshift:
  - Raw order fields only — no `processed_at` (Lambda enrichment), no `event_ts` (Glue ETL)
  - `DISTKEY(region)`, `SORTKEY("timestamp")`

> **Compare the two Redshift tables:**
> | Table | Source | Enrichment |
> |---|---|---|
> | `public.orders` | S3 Parquet via Glue ETL | Lambda + Glue (enriched, deduplicated) |
> | `public.orders_direct` | Kinesis via Firehose | None — raw JSON as-is |

**Checkpoint:** After sending events and waiting ~60 seconds, `SELECT COUNT(*) FROM public.orders_direct` returns rows.

---

## Resource Naming Summary

| Resource | Name |
|---|---|
| S3 Raw | `lks-pipeline-raw-<ACCOUNT_ID>` |
| S3 Processed | `lks-pipeline-processed-<ACCOUNT_ID>` |
| S3 Results | `lks-pipeline-results-<ACCOUNT_ID>` |
| Kinesis Stream | `lks-pipeline-stream` |
| DynamoDB | `lks-pipeline-orders` |
| Lambda | `lks-pipeline-transformer` |
| Firehose | `lks-pipeline-firehose` |
| Glue Job | `lks-pipeline-etl` |
| Glue Crawler | `lks-pipeline-crawler` |
| Glue DB | `lks_pipeline_db` |
| Athena WG | `lks-pipeline-wg` |
| Redshift Cluster | `lks-pipeline-cluster` |
| Firehose Direct | `lks-pipeline-firehose-direct` |
| SNS Topic | `lks-pipeline-alerts` |

## Required Tags (all resources)

```
Project     = lks-streaming-pipeline
Environment = production
ManagedBy   = LKS-Team
```

---

## Provided Files

| File | Description |
|---|---|
| `data/sample_orders.json` | 20 sample order events (NDJSON format) |
| `app/transformer.py` | Lambda handler code |
| `app/glue_etl.py` | PySpark ETL script |
| `app/order_generator.py` | CLI tool to send events to Kinesis |
| `scripts/01-09-*.sh` | Step-by-step setup scripts |

---

## Cleanup

> Run after the exam to avoid unnecessary charges.

```bash
# Redshift (most expensive — ~$0.145/hr)
aws redshift delete-cluster --cluster-identifier lks-pipeline-cluster \
  --skip-final-cluster-snapshot --region us-east-1

# Kinesis (~$0.015/hr)
aws kinesis delete-stream --stream-name lks-pipeline-stream --region us-east-1

# Lambda, Firehose, Glue, Athena, CloudWatch, SNS
aws lambda delete-function --function-name lks-pipeline-transformer --region us-east-1
aws firehose delete-delivery-stream --delivery-stream-name lks-pipeline-firehose --region us-east-1
aws firehose delete-delivery-stream --delivery-stream-name lks-pipeline-firehose-direct --region us-east-1
aws glue delete-job --job-name lks-pipeline-etl --region us-east-1
aws glue delete-crawler --name lks-pipeline-crawler --region us-east-1

# S3 (empty first)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
for BUCKET in lks-pipeline-raw lks-pipeline-processed lks-pipeline-results; do
  aws s3 rm s3://${BUCKET}-${ACCOUNT_ID} --recursive --region us-east-1
  aws s3api delete-bucket --bucket ${BUCKET}-${ACCOUNT_ID} --region us-east-1
done
```
