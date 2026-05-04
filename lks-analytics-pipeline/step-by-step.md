# Kunci Jawaban – Serverless Data Analytics Pipeline

---

## Task 1 – Setup S3 Buckets

### Step 1: Create three S3 buckets

**Console:**
1. S3 → Create bucket
2. Create **three** buckets (replace `{ACCOUNT_ID}` with your 12-digit account ID):
   - `lks-analytics-raw-{ACCOUNT_ID}`
   - `lks-analytics-processed-{ACCOUNT_ID}`
   - `lks-analytics-results-{ACCOUNT_ID}`
3. Region: `ap-southeast-1`
4. Block all public access: **Enabled**
5. Server-side encryption: **SSE-S3 (AES256)**
6. Versioning: **Enabled** (raw and processed buckets)
7. Add tags to all buckets: `Project=nusantara-analytics`, `Environment=production`, `ManagedBy=LKS-Team`

**CLI (faster):**
```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
bash scripts/01-setup-s3.sh
```

### Step 2: Enable EventBridge notifications on the raw bucket

This is required so that S3 Object Created events flow automatically into Amazon EventBridge.

**Console:**
1. S3 → `lks-analytics-raw-{ACCOUNT_ID}` → Properties
2. Scroll to **Event notifications**
3. Under **Amazon EventBridge** → Enable: **On**

**CLI:**
```bash
aws s3api put-bucket-notification-configuration \
  --bucket "lks-analytics-raw-${ACCOUNT_ID}" \
  --notification-configuration '{"EventBridgeConfiguration": {}}'
```

### Step 3: Upload Glue ETL script and sample data

```bash
aws s3 cp glue/etl_job.py \
  s3://lks-analytics-processed-${ACCOUNT_ID}/scripts/etl_job.py

aws s3 cp data/sample_sales.csv \
  s3://lks-analytics-raw-${ACCOUNT_ID}/data/sales/2024/01/15/sample_sales.csv
```

---

## Task 2 – Create IAM Roles

### Step 1: Create LKS-GlueETLRole

**Console:**
1. IAM → Roles → Create role
2. Trusted entity: **AWS service → Glue**
3. Role name: `LKS-GlueETLRole`
4. Attach managed policy: `AWSGlueServiceRole`
5. Add inline policy → paste contents of `iam/glue-role-policy.json` → name: `LKS-GlueETLPolicy`
6. Add tags: `Project=nusantara-analytics`, `Environment=production`, `ManagedBy=LKS-Team`

**CLI:**
```bash
aws iam create-role \
  --role-name LKS-GlueETLRole \
  --assume-role-policy-document file://iam/glue-role-trust.json

aws iam put-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-name LKS-GlueETLPolicy \
  --policy-document file://iam/glue-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
```

### Step 2: Create LKS-LambdaGlueTriggerRole

**Console:**
1. IAM → Roles → Create role
2. Trusted entity: **AWS service → Lambda**
3. Role name: `LKS-LambdaGlueTriggerRole`
4. Attach managed policy: `AWSLambdaBasicExecutionRole`
5. Add inline policy → paste `iam/lambda-role-policy.json` → name: `LKS-LambdaGlueTriggerPolicy`

**CLI:**
```bash
aws iam create-role \
  --role-name LKS-LambdaGlueTriggerRole \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }'

aws iam put-role-policy \
  --role-name LKS-LambdaGlueTriggerRole \
  --policy-name LKS-LambdaGlueTriggerPolicy \
  --policy-document file://iam/lambda-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-LambdaGlueTriggerRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### Step 3: Create LKS-AthenaAnalystRole

**CLI:**
```bash
aws iam create-role \
  --role-name LKS-AthenaAnalystRole \
  --assume-role-policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${ACCOUNT_ID}:root\"},\"Action\":\"sts:AssumeRole\"}]
  }"

aws iam put-role-policy \
  --role-name LKS-AthenaAnalystRole \
  --policy-name LKS-AthenaAnalystPolicy \
  --policy-document file://iam/athena-analyst-policy.json
```

---

## Task 3 – Configure Glue ETL Job and Crawler

### Step 1: Create Glue Data Catalog Database

**Console:**
1. AWS Glue → Data Catalog → Databases → Add database
2. Name: `lks_analytics_db`
3. Description: `Nusantara Retail Analytics data lake`

**CLI:**
```bash
aws glue create-database \
  --region ap-southeast-1 \
  --database-input '{"Name":"lks_analytics_db","Description":"Nusantara Retail Analytics data lake"}'
```

### Step 2: Create Glue ETL Job

**Console:**
1. AWS Glue → ETL Jobs → Script editor
2. Select **Spark** → **Upload and edit an existing script** → upload `glue/etl_job.py`
3. Job name: `lks-etl-sales`
4. IAM Role: `LKS-GlueETLRole`
5. Glue version: `Glue 4.0`
6. Worker type: `G.025X`
7. Number of workers: `2`
8. Job timeout: `10` minutes
9. Script path: `s3://lks-analytics-processed-{ACCOUNT_ID}/scripts/etl_job.py`
10. Job parameters (Advanced properties → Job parameters):
    - `--S3_PROCESSED_BUCKET` = `lks-analytics-processed-{ACCOUNT_ID}`
    - `--S3_PROCESSED_PREFIX` = `sales`
    - `--enable-metrics` = `true`
    - `--enable-continuous-cloudwatch-log` = `true`

**CLI:**
```bash
aws glue create-job \
  --region ap-southeast-1 \
  --name lks-etl-sales \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole" \
  --command "{
    \"Name\": \"glueetl\",
    \"ScriptLocation\": \"s3://lks-analytics-processed-${ACCOUNT_ID}/scripts/etl_job.py\",
    \"PythonVersion\": \"3\"
  }" \
  --glue-version "4.0" \
  --worker-type "G.025X" \
  --number-of-workers 2 \
  --timeout 10 \
  --default-arguments "{
    \"--enable-metrics\": \"true\",
    \"--enable-continuous-cloudwatch-log\": \"true\",
    \"--S3_PROCESSED_BUCKET\": \"lks-analytics-processed-${ACCOUNT_ID}\",
    \"--S3_PROCESSED_PREFIX\": \"sales\",
    \"--S3_RAW_PATH\": \"\"
  }"
```

### Step 3: Create Glue Crawler

**Console:**
1. AWS Glue → Crawlers → Create crawler
2. Name: `lks-crawler-sales`
3. Data source: S3 → `s3://lks-analytics-processed-{ACCOUNT_ID}/sales/`
4. IAM role: `LKS-GlueETLRole`
5. Target database: `lks_analytics_db`
6. Schedule: **Hourly** (`cron(0 * * * ? *)`)

**CLI:**
```bash
aws glue create-crawler \
  --region ap-southeast-1 \
  --name lks-crawler-sales \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole" \
  --database-name lks_analytics_db \
  --targets "{\"S3Targets\": [{\"Path\": \"s3://lks-analytics-processed-${ACCOUNT_ID}/sales/\"}]}" \
  --schedule "cron(0 * * * ? *)" \
  --configuration '{"Version":1.0,"Grouping":{"TableGroupingPolicy":"CombineCompatibleSchemas"}}'
```

---

## Task 4 – Configure Lake Formation

> **Critical note**: After setting LF admin and disabling default IAM permissions, **all Glue catalog access goes through Lake Formation**. Missing a grant = access denied error.

### Step 1: Set Data Lake Administrator

**Console:**
1. Lake Formation console → Welcome screen → **Add myself** (if first time)
2. Or: Administration → Administrators → Add → select your IAM user/role

### Step 2: Disable IAM default permissions on catalog

**Console:**
1. Lake Formation → Administration → Data Catalog settings
2. Uncheck: **"Use only IAM access control for new databases"**
3. Uncheck: **"Use only IAM access control for new tables in new databases"**
4. Save

### Step 3: Register S3 processed bucket

**Console:**
1. Lake Formation → Data lake locations → Register location
2. S3 path: `s3://lks-analytics-processed-{ACCOUNT_ID}`
3. IAM role: Service-linked role → `AWSServiceRoleForLakeFormationDataAccess`

**CLI:**
```bash
aws lakeformation register-resource \
  --region ap-southeast-1 \
  --resource-arn "arn:aws:s3:::lks-analytics-processed-${ACCOUNT_ID}" \
  --use-service-linked-role
```

### Step 4: Grant permissions to Glue ETL role

**Console:**
1. Lake Formation → Permissions → Grant
2. Principal: `LKS-GlueETLRole`
3. LF-Tags or catalog resources: Database `lks_analytics_db` → permissions: `Create table`, `Describe`
4. Grant again: Table wildcard → permissions: `Select`, `Insert`, `Delete`, `Describe`, `Alter`
5. Grant again: Data location → `s3://lks-analytics-processed-{ACCOUNT_ID}` → `Data location access`

**CLI:**
```bash
# Data location access
aws lakeformation grant-permissions \
  --region ap-southeast-1 \
  --principal "{\"DataLakePrincipalIdentifier\": \"arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole\"}" \
  --resource "{\"DataLocation\": {\"ResourceArn\": \"arn:aws:s3:::lks-analytics-processed-${ACCOUNT_ID}\"}}" \
  --permissions DATA_LOCATION_ACCESS

# Database permissions
aws lakeformation grant-permissions \
  --region ap-southeast-1 \
  --principal "{\"DataLakePrincipalIdentifier\": \"arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole\"}" \
  --resource "{\"Database\": {\"Name\": \"lks_analytics_db\"}}" \
  --permissions CREATE_TABLE DESCRIBE

# Table permissions
aws lakeformation grant-permissions \
  --region ap-southeast-1 \
  --principal "{\"DataLakePrincipalIdentifier\": \"arn:aws:iam::${ACCOUNT_ID}:role/LKS-GlueETLRole\"}" \
  --resource "{\"Table\": {\"DatabaseName\": \"lks_analytics_db\", \"TableWildcard\": {}}}" \
  --permissions SELECT INSERT DELETE DESCRIBE ALTER
```

### Step 5: Grant permissions to Athena Analyst role

**CLI:**
```bash
# Database describe
aws lakeformation grant-permissions \
  --region ap-southeast-1 \
  --principal "{\"DataLakePrincipalIdentifier\": \"arn:aws:iam::${ACCOUNT_ID}:role/LKS-AthenaAnalystRole\"}" \
  --resource "{\"Database\": {\"Name\": \"lks_analytics_db\"}}" \
  --permissions DESCRIBE

# Table SELECT
aws lakeformation grant-permissions \
  --region ap-southeast-1 \
  --principal "{\"DataLakePrincipalIdentifier\": \"arn:aws:iam::${ACCOUNT_ID}:role/LKS-AthenaAnalystRole\"}" \
  --resource "{\"Table\": {\"DatabaseName\": \"lks_analytics_db\", \"TableWildcard\": {}}}" \
  --permissions SELECT DESCRIBE
```

---

## Task 5 – Deploy Lambda and EventBridge Rule

### Step 1: Deploy Lambda function

**Console:**
1. Lambda → Create function → Author from scratch
2. Name: `lks-glue-trigger`
3. Runtime: **Python 3.12**
4. Execution role: **Use an existing role** → `LKS-LambdaGlueTriggerRole`
5. Memory: `128 MB`, Timeout: `1 min`
6. Upload `lambda/trigger_glue.py` (or paste code directly)
7. Environment variables:
   - `GLUE_JOB_NAME` = `lks-etl-sales`
   - `S3_PROCESSED_BUCKET` = `lks-analytics-processed-{ACCOUNT_ID}`
   - `S3_PROCESSED_PREFIX` = `sales`
8. Add tags

**CLI:**
```bash
cd lambda
zip function.zip trigger_glue.py

aws lambda create-function \
  --region ap-southeast-1 \
  --function-name lks-glue-trigger \
  --runtime python3.12 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-LambdaGlueTriggerRole" \
  --handler trigger_glue.handler \
  --zip-file fileb://function.zip \
  --memory-size 128 \
  --timeout 60 \
  --environment "Variables={GLUE_JOB_NAME=lks-etl-sales,S3_PROCESSED_BUCKET=lks-analytics-processed-${ACCOUNT_ID},S3_PROCESSED_PREFIX=sales}"

rm function.zip
cd ..
```

### Step 2: Create EventBridge rule

**Console:**
1. EventBridge → Rules → Create rule
2. Name: `lks-s3-sales-upload`
3. Event bus: **default**
4. Rule type: **Rule with an event pattern**
5. Event source: **AWS events or EventBridge partner events**
6. Event pattern:
   - Service: **Simple Storage Service (S3)**
   - Event type: **Amazon S3 Event Notification → Object Created**
   - Specific bucket: `lks-analytics-raw-{ACCOUNT_ID}`
   - Prefix filter: `data/sales/`
7. Target: Lambda function → `lks-glue-trigger`

**CLI:**
```bash
# Create rule
aws events put-rule \
  --region ap-southeast-1 \
  --name lks-s3-sales-upload \
  --event-pattern "{
    \"source\":[\"aws.s3\"],
    \"detail-type\":[\"Object Created\"],
    \"detail\":{
      \"bucket\":{\"name\":[\"lks-analytics-raw-${ACCOUNT_ID}\"]},
      \"object\":{\"key\":[{\"prefix\":\"data/sales/\"}]}
    }
  }" \
  --state ENABLED

# Allow EventBridge to invoke Lambda
aws lambda add-permission \
  --region ap-southeast-1 \
  --function-name lks-glue-trigger \
  --statement-id EventBridgeS3SalesUpload \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:ap-southeast-1:${ACCOUNT_ID}:rule/lks-s3-sales-upload"

# Set Lambda as target
LAMBDA_ARN=$(aws lambda get-function \
  --function-name lks-glue-trigger \
  --query Configuration.FunctionArn --output text)

aws events put-targets \
  --region ap-southeast-1 \
  --rule lks-s3-sales-upload \
  --targets "[{\"Id\":\"LambdaTarget\",\"Arn\":\"${LAMBDA_ARN}\"}]"
```

---

## Task 6 – Configure Athena Workgroup

**Console:**
1. Athena → Workgroups → Create workgroup
2. Name: `lks-analytics-wg`
3. Query result location: `s3://lks-analytics-results-{ACCOUNT_ID}/`
4. Encryption: **SSE_S3**
5. **Enforce workgroup settings**: Enabled (prevents analysts from writing results elsewhere)
6. Bytes scanned per query limit: `1 GB` (cost protection)
7. Publish CloudWatch metrics: Enabled
8. Add tags

**CLI:**
```bash
aws athena create-work-group \
  --region ap-southeast-1 \
  --name lks-analytics-wg \
  --configuration "{
    \"ResultConfiguration\": {
      \"OutputLocation\": \"s3://lks-analytics-results-${ACCOUNT_ID}/\",
      \"EncryptionConfiguration\": {\"EncryptionOption\": \"SSE_S3\"}
    },
    \"EnforceWorkGroupConfiguration\": true,
    \"PublishCloudWatchMetricsEnabled\": true,
    \"BytesScannedCutoffPerQuery\": 1073741824
  }"
```

---

## Task 7 – Setup Monitoring

### Step 1: Create SNS topic and subscribe email

**Console:**
1. SNS → Topics → Create topic → Standard
2. Name: `lks-analytics-alerts`
3. Add tags
4. Create subscription: Protocol = Email, Endpoint = your email
5. **Confirm the subscription** from your email inbox

**CLI:**
```bash
SNS_ARN=$(aws sns create-topic \
  --region ap-southeast-1 \
  --name lks-analytics-alerts \
  --query TopicArn --output text)

aws sns subscribe \
  --region ap-southeast-1 \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint "your@email.com"
```

### Step 2: Create CloudWatch alarm for Glue job failure

**Console:**
1. CloudWatch → Alarms → Create alarm
2. Metric: **Glue → By Job Name** → `lks-etl-sales` → `glue.driver.aggregate.numFailedTasks`
3. Statistic: **Sum**, Period: **5 minutes**
4. Threshold: **>= 1** for **1 consecutive period**
5. Actions: In alarm → SNS → `lks-analytics-alerts`
6. Alarm name: `lks-glue-job-failure`

**CLI:**
```bash
aws cloudwatch put-metric-alarm \
  --region ap-southeast-1 \
  --alarm-name lks-glue-job-failure \
  --namespace Glue \
  --metric-name "glue.driver.aggregate.numFailedTasks" \
  --dimensions Name=JobName,Value=lks-etl-sales \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching
```

---

## Task 8 – End-to-End Testing and Validation

### Step 1: Upload test data to S3 (trigger the pipeline)

Upload `data/sample_sales.csv` to the raw bucket under the `data/sales/` prefix. This fires the EventBridge rule → Lambda → Glue job chain.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3 cp data/sample_sales.csv \
  s3://lks-analytics-raw-${ACCOUNT_ID}/data/sales/2024/01/15/sample_sales.csv
```

**Console alternative:**
1. S3 → `lks-analytics-raw-{ACCOUNT_ID}` → Upload
2. Create folder path: `data/sales/2024/01/15/`
3. Upload `sample_sales.csv` into that folder

### Step 2: Verify Lambda was triggered

Wait ~10 seconds, then check Lambda logs to confirm it received the S3 event and started the Glue job:

```bash
aws logs tail /aws/lambda/lks-glue-trigger --since 2m
```

**Expected log output:**
```
Starting Glue job lks-etl-sales for s3://lks-analytics-raw-.../data/sales/2024/01/15/sample_sales.csv
Glue job started. JobRunId: jr_...
```

If the log is empty, the EventBridge rule is not routing to Lambda — recheck Step 2 of Task 5.

### Step 3: Monitor the Glue job run

```bash
aws glue get-job-runs \
  --job-name lks-etl-sales \
  --region ap-southeast-1 \
  --max-results 1 \
  --query 'JobRuns[0].{State:JobRunState,Started:StartedOn,Duration:ExecutionTime}' \
  --output table
```

**Expected states (in order):** `STARTING` → `RUNNING` → `SUCCEEDED`

G.025X workers take 2–4 minutes to spin up. Wait for `SUCCEEDED` before proceeding.

```bash
# Poll until done (check every 30s)
watch -n 30 "aws glue get-job-runs --job-name lks-etl-sales --region ap-southeast-1 \
  --max-results 1 --query 'JobRuns[0].JobRunState' --output text"
```

### Step 4: Verify Parquet output in processed bucket

```bash
aws s3 ls s3://lks-analytics-processed-${ACCOUNT_ID}/sales/ --recursive
```

**Expected output** — Parquet files partitioned by year/month/day:
```
2024-01-15 ...  sales/year=2024/month=01/day=15/part-00000-....parquet
```

If no files appear, the Glue job failed. Check full error:
```bash
aws glue get-job-runs --job-name lks-etl-sales --region ap-southeast-1 \
  --max-results 1 --query 'JobRuns[0].ErrorMessage' --output text
```

### Step 5: Run Glue Crawler to register table in Data Catalog

```bash
aws glue start-crawler --name lks-crawler-sales --region ap-southeast-1

# Wait ~60s, then verify the table was created
aws glue get-table \
  --database-name lks_analytics_db \
  --name sales \
  --region ap-southeast-1 \
  --query 'Table.{Name:Name,Location:StorageDescriptor.Location,Columns:StorageDescriptor.Columns[*].Name}' \
  --output json
```

**Expected:** a `sales` table with columns `transaction_id, store_id, product_id, product_name, category, quantity, unit_price, amount, sale_date, payment_method, year, month, day`.

### Step 6: Query with Athena (workgroup: `lks-analytics-wg`)

Open Athena → switch to workgroup `lks-analytics-wg` → run these queries one by one.

**Query 1 — Total row count**
```sql
SELECT COUNT(*) AS row_count FROM lks_analytics_db.sales;
```
> **Expected:** `10`

---

**Query 2 — Check partitions**
```sql
SHOW PARTITIONS lks_analytics_db.sales;
```
> **Expected:** `year=2024/month=01/day=15`

---

**Query 3 — Revenue by store (highest first)**
```sql
SELECT store_id,
       SUM(amount)  AS total_revenue,
       COUNT(*)     AS tx_count
FROM lks_analytics_db.sales
WHERE year = '2024' AND month = '01'
GROUP BY store_id
ORDER BY total_revenue DESC;
```

> **Expected results:**
>
> | store_id     | total_revenue | tx_count |
> |---|---|---|
> | STORE-SBY-01 | 165000        | 2        |
> | STORE-JKT-02 | 112500        | 2        |
> | STORE-MDN-01 | 52000         | 2        |
> | STORE-JKT-01 | 27500         | 2        |
> | STORE-BDG-01 | 25500         | 2        |

---

**Query 4 — Revenue by category**
```sql
SELECT category,
       SUM(amount)   AS revenue,
       SUM(quantity) AS units_sold
FROM lks_analytics_db.sales
GROUP BY category
ORDER BY revenue DESC;
```

> **Expected results:**
>
> | category      | revenue | units_sold |
> |---|---|---|
> | food          | 165000  | 23         |
> | staple        | 165000  | 3          |
> | personal_care | 17000   | 2          |
> | beverage      | 23500   | 5          |
> | snack         | 12000   | 1          |

---

**Query 5 — Payment method breakdown**
```sql
SELECT payment_method, COUNT(*) AS tx_count, SUM(amount) AS total
FROM lks_analytics_db.sales
GROUP BY payment_method
ORDER BY tx_count DESC;
```

> **Expected results:**
>
> | payment_method | tx_count | total  |
> |---|---|---|
> | cash           | 4        | 102000 |
> | qris           | 3        | 62000  |
> | debit_card     | 2        | 88500  |
> | transfer       | 1        | 130000 |

### Step 7: Run automated validation script

```bash
bash scripts/06-validate.sh
```

**Expected final output:**
```
================================================================
 VALIDATION SUMMARY
================================================================
  PASS: 8
  FAIL: 0
  STATUS: ALL CHECKS PASSED
================================================================
```

---

## Summary Checklist

| Task | Resource | Free Tier |
|---|---|---|
| S3 raw bucket | `lks-analytics-raw-{account}` | ✓ |
| S3 processed bucket | `lks-analytics-processed-{account}` | ✓ |
| S3 results bucket | `lks-analytics-results-{account}` | ✓ |
| IAM role — Glue | `LKS-GlueETLRole` | ✓ |
| IAM role — Lambda | `LKS-LambdaGlueTriggerRole` | ✓ |
| IAM role — Analyst | `LKS-AthenaAnalystRole` | ✓ |
| Glue Data Catalog database | `lks_analytics_db` | ✓ |
| Glue ETL job | `lks-etl-sales` (G.025X) | ⚠️ ~$0.004/run |
| Glue Crawler | `lks-crawler-sales` (hourly) | ⚠️ ~$0.01/run |
| Lake Formation — LF admin | current IAM user | ✓ |
| Lake Formation — S3 registered | `lks-analytics-processed-{account}` | ✓ |
| Lake Formation — Glue permissions | CREATE_TABLE, DATA_LOCATION_ACCESS | ✓ |
| Lake Formation — Analyst permissions | SELECT on `sales` table | ✓ |
| Lambda function | `lks-glue-trigger` (Python 3.12) | ✓ |
| EventBridge rule | `lks-s3-sales-upload` | ✓ |
| Athena workgroup | `lks-analytics-wg` | ⚠️ $5/TB scanned |
| SNS topic | `lks-analytics-alerts` | ✓ |
| CloudWatch alarm | `lks-glue-job-failure` | ✓ |

> **Cost-saving tips**: Disable the Glue Crawler schedule when not practicing (`aws glue update-crawler --name lks-crawler-sales --schedule ""`) and delete all resources after the exam.
