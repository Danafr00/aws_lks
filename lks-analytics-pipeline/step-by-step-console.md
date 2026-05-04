# Kunci Jawaban – Serverless Data Analytics Pipeline (Console Guide)

> **Panduan ini 100% via AWS Management Console.** Tidak ada perintah CLI yang diperlukan.
> Buka semua layanan di region **ap-southeast-1 (Singapore)**.

---

## Layer Overview

| Layer | Yang Dibangun | Checkpoint |
|---|---|---|
| **1** | S3 Buckets + EventBridge notification | Upload file → event muncul di EventBridge |
| **2** | IAM Roles | Role tampil di IAM console |
| **3** | Glue Database + ETL Job + Crawler | Job dapat dijalankan manual |
| **4** | Lake Formation permissions | Glue ETL bisa tulis ke processed bucket |
| **5** | Lambda + EventBridge Rule | Upload file → Lambda log tampil |
| **6** | Athena Workgroup | Query berhasil dijalankan |
| **7** | SNS + CloudWatch Alarm | Alarm aktif, email dikonfirmasi |
| **8** | End-to-End Test | Athena query mengembalikan 10 baris |

---

## Task 1 – Setup S3 Buckets

### Step 1: Buat tiga S3 bucket

Ulangi langkah ini **tiga kali** untuk membuat ketiga bucket berikut (ganti `{ACCOUNT_ID}` dengan 12 digit account ID kamu):
- `lks-analytics-raw-{ACCOUNT_ID}`
- `lks-analytics-processed-{ACCOUNT_ID}`
- `lks-analytics-results-{ACCOUNT_ID}`

**Cara menemukan Account ID:** Klik nama akun di pojok kanan atas console → salin 12 digit angka.

**Langkah membuat setiap bucket:**
1. Buka **S3** → klik **Create bucket**
2. **Bucket name:** isi sesuai nama di atas
3. **AWS Region:** `ap-southeast-1`
4. **Block Public Access:** biarkan semua dicentang (default)
5. **Bucket Versioning:**
   - Raw bucket → **Enable**
   - Processed bucket → **Enable**
   - Results bucket → **Disable** (hasil query tidak perlu versioning)
6. **Default encryption:** `SSE-S3 (AES-256)` (biasanya sudah default)
7. **Tags:** klik **Add tag**, isi:
   - `Project` = `nusantara-analytics`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
8. Klik **Create bucket**

### Step 2: Aktifkan EventBridge notification pada raw bucket

Ini memungkinkan S3 mengirim event "Object Created" ke EventBridge secara otomatis.

1. S3 → klik bucket `lks-analytics-raw-{ACCOUNT_ID}`
2. Tab **Properties** → scroll ke bawah ke **Event notifications**
3. Di bagian **Amazon EventBridge** → klik **Edit**
4. Pilih **On** → klik **Save changes**

### Step 3: Upload ETL script ke processed bucket

1. S3 → klik bucket `lks-analytics-processed-{ACCOUNT_ID}`
2. Klik **Create folder** → nama folder: `scripts` → klik **Create folder**
3. Masuk ke folder `scripts` → klik **Upload**
4. Klik **Add files** → pilih file `glue/etl_job.py` dari repo ini
5. Klik **Upload**

Pastikan file ada di path: `s3://lks-analytics-processed-{ACCOUNT_ID}/scripts/etl_job.py`

**Layer 1 checkpoint:**
- [ ] Tiga bucket muncul di S3 console
- [ ] Tab Properties raw bucket → EventBridge: **On**
- [ ] `scripts/etl_job.py` ada di processed bucket

---

## Task 2 – Create IAM Roles

### Step 1: Buat LKS-GlueETLRole

1. Buka **IAM** → **Roles** → klik **Create role**
2. **Trusted entity type:** AWS service
3. **Use case:** pilih **Glue** → klik **Next**
4. Di halaman Add permissions:
   - Cari `AWSGlueServiceRole` → centang
   - Klik **Next**
5. **Role name:** `LKS-GlueETLRole`
6. **Tags:**
   - `Project` = `nusantara-analytics`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
7. Klik **Create role**

**Tambahkan inline policy:**
1. IAM → Roles → klik `LKS-GlueETLRole`
2. Tab **Permissions** → **Add permissions** → **Create inline policy**
3. Klik tab **JSON** → hapus isi yang ada → paste JSON berikut:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3DataLakeReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::lks-analytics-raw-*",
        "arn:aws:s3:::lks-analytics-raw-*/*",
        "arn:aws:s3:::lks-analytics-processed-*",
        "arn:aws:s3:::lks-analytics-processed-*/*"
      ]
    },
    {
      "Sid": "GlueCatalogAccess",
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:CreateDatabase",
        "glue:GetTable",
        "glue:CreateTable",
        "glue:UpdateTable",
        "glue:GetPartitions",
        "glue:BatchCreatePartition",
        "glue:GetCrawler",
        "glue:StartCrawler"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LakeFormationDataAccess",
      "Effect": "Allow",
      "Action": [
        "lakeformation:GetDataAccess",
        "lakeformation:GrantPermissions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:/aws-glue/*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*"
    }
  ]
}
```

4. Klik **Next** → **Policy name:** `LKS-GlueETLPolicy` → klik **Create policy**

### Step 2: Buat LKS-LambdaGlueTriggerRole

1. IAM → **Roles** → **Create role**
2. **Trusted entity type:** AWS service
3. **Use case:** pilih **Lambda** → klik **Next**
4. Cari dan centang `AWSLambdaBasicExecutionRole` → **Next**
5. **Role name:** `LKS-LambdaGlueTriggerRole`
6. Klik **Create role**

**Tambahkan inline policy:**
1. IAM → Roles → klik `LKS-LambdaGlueTriggerRole`
2. **Add permissions** → **Create inline policy** → tab **JSON** → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GlueTrigger",
      "Effect": "Allow",
      "Action": [
        "glue:StartJobRun",
        "glue:GetJobRun",
        "glue:GetJobRuns"
      ],
      "Resource": "arn:aws:glue:ap-southeast-1:*:job/lks-etl-sales"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

3. **Policy name:** `LKS-LambdaGlueTriggerPolicy` → **Create policy**

### Step 3: Buat LKS-AthenaAnalystRole

1. IAM → **Roles** → **Create role**
2. **Trusted entity type:** AWS account
3. **An AWS account:** pilih **This account** → klik **Next**
4. Skip halaman Add permissions (jangan attach dulu) → **Next**
5. **Role name:** `LKS-AthenaAnalystRole` → **Create role**

**Tambahkan inline policy:**
1. IAM → Roles → klik `LKS-AthenaAnalystRole`
2. **Add permissions** → **Create inline policy** → tab **JSON** → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AthenaWorkgroupAccess",
      "Effect": "Allow",
      "Action": [
        "athena:StartQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:StopQueryExecution",
        "athena:GetWorkGroup",
        "athena:ListWorkGroups",
        "athena:ListDatabases",
        "athena:ListTableMetadata",
        "athena:GetTableMetadata"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3ResultsBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::lks-analytics-results-*",
        "arn:aws:s3:::lks-analytics-results-*/*"
      ]
    },
    {
      "Sid": "S3ProcessedDataRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::lks-analytics-processed-*",
        "arn:aws:s3:::lks-analytics-processed-*/*"
      ]
    },
    {
      "Sid": "GlueCatalogRead",
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartitions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LakeFormationDataAccess",
      "Effect": "Allow",
      "Action": [
        "lakeformation:GetDataAccess"
      ],
      "Resource": "*"
    }
  ]
}
```

3. **Policy name:** `LKS-AthenaAnalystPolicy` → **Create policy**

**Layer 2 checkpoint:**
- [ ] `LKS-GlueETLRole` ada di IAM → memiliki `AWSGlueServiceRole` + `LKS-GlueETLPolicy`
- [ ] `LKS-LambdaGlueTriggerRole` ada di IAM → memiliki `AWSLambdaBasicExecutionRole` + `LKS-LambdaGlueTriggerPolicy`
- [ ] `LKS-AthenaAnalystRole` ada di IAM → memiliki `LKS-AthenaAnalystPolicy`

---

## Task 3 – Configure Glue ETL Job and Crawler

### Step 1: Buat Glue Data Catalog Database

1. Buka **AWS Glue** → menu kiri **Data Catalog** → **Databases**
2. Klik **Add database**
3. **Database name:** `lks_analytics_db`
4. **Description:** `Nusantara Retail Analytics data lake`
5. Klik **Create database**

### Step 2: Buat Glue ETL Job

1. AWS Glue → menu kiri **ETL jobs** → klik **Script editor**
2. **Engine:** Spark
3. **Options:** pilih **Upload and edit an existing script**
4. Klik **Choose file** → pilih `glue/etl_job.py` dari repo ini
5. Klik **Create**
6. Di halaman editor, klik **Job details** (tab di atas)
7. Isi konfigurasi:
   - **Name:** `lks-etl-sales`
   - **IAM Role:** `LKS-GlueETLRole`
   - **Glue version:** `Glue 4.0`
   - **Language:** Python 3
   - **Worker type:** `G.025X`
   - **Requested number of workers:** `2`
   - **Job timeout (minutes):** `10`
   - **Script path:** `s3://lks-analytics-processed-{ACCOUNT_ID}/scripts/etl_job.py`
8. Scroll ke bawah ke **Advanced properties** → **Job parameters**
9. Klik **Add new parameter** empat kali, isi:
   | Key | Value |
   |---|---|
   | `--S3_PROCESSED_BUCKET` | `lks-analytics-processed-{ACCOUNT_ID}` |
   | `--S3_PROCESSED_PREFIX` | `sales` |
   | `--enable-metrics` | `true` |
   | `--enable-continuous-cloudwatch-log` | `true` |
10. Klik **Save** (pojok kanan atas)

### Step 3: Buat Glue Crawler

1. AWS Glue → menu kiri **Crawlers** → klik **Create crawler**
2. **Crawler name:** `lks-crawler-sales` → **Next**
3. **Is your data already mapped to Glue tables?** → No, not yet → **Next**
4. Klik **Add a data source**:
   - **Data source:** S3
   - **S3 path:** `s3://lks-analytics-processed-{ACCOUNT_ID}/sales/`
   - **Subsequent crawler runs:** Crawl all sub-folders
   - Klik **Add an S3 data source**
5. Klik **Next**
6. **IAM role:** pilih **Choose an existing IAM role** → `LKS-GlueETLRole` → **Next**
7. **Target database:** `lks_analytics_db`
8. **Table name prefix:** (kosongkan)
9. **Crawler schedule:** Hourly → **Next**
10. Review → klik **Create crawler**

**Layer 3 checkpoint:**
- [ ] `lks_analytics_db` muncul di Glue → Databases
- [ ] `lks-etl-sales` muncul di Glue → ETL jobs
- [ ] `lks-crawler-sales` muncul di Glue → Crawlers, status **Ready**

---

## Task 4 – Configure Lake Formation

> **Penting:** Setelah mengaktifkan Lake Formation admin dan menonaktifkan default IAM permissions, **semua akses ke Glue Data Catalog dikendalikan oleh Lake Formation**. Jika lupa grant = access denied.

### Step 1: Set Data Lake Administrator

1. Buka **Lake Formation**
2. Jika muncul halaman "Welcome to Lake Formation" → centang **Add myself** → klik **Get started**
3. Jika sudah pernah setup: menu kiri **Administration** → **Administrators** → **Edit**
4. Pastikan IAM user/role yang kamu gunakan sekarang ada di daftar → **Save**

### Step 2: Nonaktifkan default IAM permissions

1. Lake Formation → **Administration** → **Data Catalog settings**
2. **Uncheck** keduanya:
   - ☐ Use only IAM access control for new databases
   - ☐ Use only IAM access control for new tables in new databases
3. Klik **Save**

### Step 3: Daftarkan S3 processed bucket

1. Lake Formation → menu kiri **Data lake locations** → klik **Register location**
2. **Amazon S3 path:** `s3://lks-analytics-processed-{ACCOUNT_ID}`
3. **IAM role:** pilih `AWSServiceRoleForLakeFormationDataAccess` (service-linked role)
   - Jika tidak ada, pilih **Create a new role**
4. Klik **Register location**

### Step 4: Grant permissions ke LKS-GlueETLRole

Lakukan **tiga kali** Grant (untuk data location, database, dan table):

**Grant 1 — Data location access:**
1. Lake Formation → **Permissions** → **Data lake permissions** → klik **Grant**
2. **IAM users and roles:** pilih `LKS-GlueETLRole`
3. **LF-Tags or catalog resources:** pilih **Named Data Catalog resources**
4. **Storage locations:** pilih `s3://lks-analytics-processed-{ACCOUNT_ID}`
5. **Storage location permissions:** centang **Data location**
6. Klik **Grant**

**Grant 2 — Database permissions:**
1. Lake Formation → **Permissions** → **Data lake permissions** → klik **Grant**
2. **IAM users and roles:** pilih `LKS-GlueETLRole`
3. **Named Data Catalog resources:**
   - **Databases:** pilih `lks_analytics_db`
4. **Database permissions:** centang `Create table` dan `Describe`
5. Klik **Grant**

**Grant 3 — Table permissions:**
1. Lake Formation → **Permissions** → **Data lake permissions** → klik **Grant**
2. **IAM users and roles:** pilih `LKS-GlueETLRole`
3. **Named Data Catalog resources:**
   - **Databases:** `lks_analytics_db`
   - **Tables:** pilih **All tables**
4. **Table permissions:** centang `Select`, `Insert`, `Delete`, `Describe`, `Alter`
5. Klik **Grant**

### Step 5: Grant permissions ke LKS-AthenaAnalystRole

**Grant 1 — Database describe:**
1. Lake Formation → **Permissions** → **Data lake permissions** → klik **Grant**
2. **IAM users and roles:** pilih `LKS-AthenaAnalystRole`
3. **Named Data Catalog resources:**
   - **Databases:** `lks_analytics_db`
4. **Database permissions:** centang `Describe`
5. Klik **Grant**

**Grant 2 — Table SELECT:**
1. Lake Formation → **Permissions** → **Data lake permissions** → klik **Grant**
2. **IAM users and roles:** pilih `LKS-AthenaAnalystRole`
3. **Named Data Catalog resources:**
   - **Databases:** `lks_analytics_db`
   - **Tables:** pilih **All tables**
4. **Table permissions:** centang `Select`, `Describe`
5. Klik **Grant**

**Layer 4 checkpoint:**
- [ ] Data lake locations → `lks-analytics-processed-{ACCOUNT_ID}` ada dan status **Registered**
- [ ] Data lake permissions → `LKS-GlueETLRole` punya `DATA_LOCATION_ACCESS`, `CREATE_TABLE`, `SELECT`
- [ ] Data lake permissions → `LKS-AthenaAnalystRole` punya `SELECT` pada `lks_analytics_db`

---

## Task 5 – Deploy Lambda dan EventBridge Rule

### Step 1: Upload Lambda function code

Sebelum membuat fungsi, siapkan zip file. Karena kita tidak pakai CLI, upload langsung kode via console:

1. Buka **Lambda** → klik **Create function**
2. **Author from scratch**
3. **Function name:** `lks-glue-trigger`
4. **Runtime:** Python 3.12
5. **Architecture:** x86_64
6. **Execution role:** pilih **Use an existing role** → `LKS-LambdaGlueTriggerRole`
7. Klik **Create function**

**Upload kode:**
1. Di halaman function, scroll ke **Code source**
2. Klik tab file `lambda_function.py` → hapus semua isi
3. Paste kode berikut seluruhnya:

```python
import json
import boto3
import os

GLUE_JOB_NAME = os.environ['GLUE_JOB_NAME']
S3_PROCESSED_BUCKET = os.environ['S3_PROCESSED_BUCKET']
S3_PROCESSED_PREFIX = os.environ.get('S3_PROCESSED_PREFIX', 'sales')

glue = boto3.client('glue')

def handler(event, context):
    detail = event.get('detail', {})
    bucket = detail.get('bucket', {}).get('name', '')
    key = detail.get('object', {}).get('key', '')

    print(f"Event received: bucket={bucket}, key={key}")

    if not key.lower().endswith('.csv'):
        print(f"Skipping non-CSV file: {key}")
        return {'statusCode': 200, 'body': 'skipped — not a CSV'}

    if not key.startswith('data/sales/'):
        print(f"Skipping file outside data/sales/ prefix: {key}")
        return {'statusCode': 200, 'body': 'skipped — wrong prefix'}

    s3_raw_path = f"s3://{bucket}/{key}"
    print(f"Starting Glue job '{GLUE_JOB_NAME}' for: {s3_raw_path}")

    response = glue.start_job_run(
        JobName=GLUE_JOB_NAME,
        Arguments={
            '--S3_RAW_PATH': s3_raw_path,
            '--S3_PROCESSED_BUCKET': S3_PROCESSED_BUCKET,
            '--S3_PROCESSED_PREFIX': S3_PROCESSED_PREFIX,
        }
    )

    run_id = response['JobRunId']
    print(f"Glue job run started: {run_id}")
    return {
        'statusCode': 200,
        'body': json.dumps({'jobName': GLUE_JOB_NAME, 'jobRunId': run_id})
    }
```

4. Klik **Deploy**

**Ubah handler name:**
1. Scroll ke **Runtime settings** → klik **Edit**
2. **Handler:** ubah dari `lambda_function.lambda_handler` menjadi `lambda_function.handler`
3. Klik **Save**

**Atur konfigurasi:**
1. Tab **Configuration** → **General configuration** → **Edit**
2. **Memory:** `128 MB`
3. **Timeout:** `1 min 0 sec`
4. Klik **Save**

**Tambahkan environment variables:**
1. Tab **Configuration** → **Environment variables** → **Edit**
2. Klik **Add environment variable** tiga kali:
   | Key | Value |
   |---|---|
   | `GLUE_JOB_NAME` | `lks-etl-sales` |
   | `S3_PROCESSED_BUCKET` | `lks-analytics-processed-{ACCOUNT_ID}` |
   | `S3_PROCESSED_PREFIX` | `sales` |
3. Klik **Save**

**Tambahkan tags:**
1. Tab **Configuration** → **Tags** → **Manage tags**
2. Tambah:
   - `Project` = `nusantara-analytics`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
3. Klik **Save**

### Step 2: Buat EventBridge rule

1. Buka **Amazon EventBridge** → menu kiri **Rules** → klik **Create rule**
2. **Name:** `lks-s3-sales-upload`
3. **Event bus:** default
4. **Rule type:** Rule with an event pattern
5. Klik **Next**
6. **Event source:** AWS events or EventBridge partner events
7. **Event pattern** — klik **Edit pattern** → hapus isi → paste JSON ini:

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": {
      "name": ["lks-analytics-raw-{ACCOUNT_ID}"]
    },
    "object": {
      "key": [{"prefix": "data/sales/"}]
    }
  }
}
```

> **Ganti `{ACCOUNT_ID}`** dengan 12 digit account ID kamu dalam JSON di atas.

8. Klik **Next**
9. **Target types:** AWS service
10. **Select a target:** Lambda function
11. **Function:** `lks-glue-trigger`
12. Klik **Next** → **Next** → **Create rule**

**Layer 5 checkpoint:**
- [ ] Lambda `lks-glue-trigger` ada, status **Active**
- [ ] Handler = `lambda_function.handler`
- [ ] 3 environment variables tersimpan
- [ ] EventBridge rule `lks-s3-sales-upload` ada, status **Enabled**
- [ ] Rule target = Lambda `lks-glue-trigger`

---

## Task 6 – Configure Athena Workgroup

1. Buka **Amazon Athena** → menu kiri **Workgroups** → klik **Create workgroup**
2. **Workgroup name:** `lks-analytics-wg`
3. **Analytics engine:** Athena SQL
4. **Query result location:** klik **Browse S3** → pilih `lks-analytics-results-{ACCOUNT_ID}` → **Choose**
   - Pastikan path otomatis terisi: `s3://lks-analytics-results-{ACCOUNT_ID}/`
5. **Encrypt query results:** centang → pilih **SSE-S3**
6. **Enforce workgroup settings:** centang (**Override client-side settings**)
7. **Bytes scanned per query:** centang → isi `1` → pilih **GB**
8. **Publish to CloudWatch:** centang
9. **Tags:**
   - `Project` = `nusantara-analytics`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
10. Klik **Create workgroup**

**Layer 6 checkpoint:**
- [ ] Workgroup `lks-analytics-wg` muncul di Athena → Workgroups
- [ ] Status **Active**, query result location sudah diset ke results bucket

---

## Task 7 – Setup Monitoring

### Step 1: Buat SNS topic dan subscribe email

1. Buka **Amazon SNS** → **Topics** → klik **Create topic**
2. **Type:** Standard
3. **Name:** `lks-analytics-alerts`
4. **Tags:**
   - `Project` = `nusantara-analytics`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
5. Klik **Create topic**

**Buat subscription:**
1. Di halaman topic yang baru dibuat → tab **Subscriptions** → klik **Create subscription**
2. **Protocol:** Email
3. **Endpoint:** isi alamat email kamu
4. Klik **Create subscription**
5. **Buka email kamu** → cari email dari AWS dengan subject "AWS Notification - Subscription Confirmation" → klik **Confirm subscription**

> Status subscription harus berubah dari **PendingConfirmation** ke **Confirmed** sebelum lanjut.

### Step 2: Buat CloudWatch alarm untuk Glue job failure

1. Buka **CloudWatch** → menu kiri **Alarms** → **All alarms** → klik **Create alarm**
2. Klik **Select metric**
3. Navigasi: **Glue** → **Job Metrics** → cari `lks-etl-sales` dengan metric `glue.driver.aggregate.numFailedTasks`
4. Centang metric tersebut → klik **Select metric**
5. Konfigurasi:
   - **Statistic:** Sum
   - **Period:** 5 minutes
6. **Conditions:**
   - **Threshold type:** Static
   - **Whenever glue.driver.aggregate.numFailedTasks is:** Greater/Equal `>=`
   - **than:** `1`
7. Klik **Next**
8. **Alarm state trigger:** In alarm
9. **Send a notification to the following SNS topic:** pilih `lks-analytics-alerts`
10. Klik **Next**
11. **Alarm name:** `lks-glue-job-failure`
12. Klik **Next** → **Create alarm**

**Layer 7 checkpoint:**
- [ ] SNS topic `lks-analytics-alerts` ada
- [ ] Subscription status = **Confirmed** (cek di email)
- [ ] CloudWatch alarm `lks-glue-job-failure` ada, status **OK** atau **Insufficient data**

---

## Task 8 – End-to-End Testing dan Validasi

### Step 1: Upload test data ke S3 (trigger pipeline)

1. Buka **S3** → klik bucket `lks-analytics-raw-{ACCOUNT_ID}`
2. Buat struktur folder dengan klik **Create folder** secara bertingkat:
   - `data` → Create folder
   - Masuk ke `data` → `sales` → Create folder
   - Masuk ke `sales` → `2024` → Create folder
   - Masuk ke `2024` → `01` → Create folder
   - Masuk ke `01` → `15` → Create folder
3. Masuk ke folder `15` → klik **Upload**
4. Klik **Add files** → pilih `data/sample_sales.csv` dari repo ini
5. Klik **Upload**

Path akhir harus: `s3://lks-analytics-raw-{ACCOUNT_ID}/data/sales/2024/01/15/sample_sales.csv`

### Step 2: Verifikasi Lambda dipicu

Tunggu ~10 detik setelah upload selesai.

1. Buka **Lambda** → klik fungsi `lks-glue-trigger`
2. Tab **Monitor** → klik **View CloudWatch logs**
3. Klik log stream terbaru
4. Cari log entries yang berisi:

```
Event received: bucket=lks-analytics-raw-..., key=data/sales/2024/01/15/sample_sales.csv
Starting Glue job 'lks-etl-sales' for: s3://lks-analytics-raw-.../...
Glue job run started: jr_...
```

Jika log kosong atau tidak ada log stream baru → EventBridge rule tidak routing ke Lambda. Cek kembali Step 2 Task 5, pastikan rule target sudah set ke `lks-glue-trigger`.

### Step 3: Monitor Glue job run

1. Buka **AWS Glue** → **ETL jobs** → klik `lks-etl-sales`
2. Tab **Runs** → lihat run paling atas
3. Status akan berubah: `Starting` → `Running` → `Succeeded`

> Worker G.025X membutuhkan 2–4 menit untuk spin up. **Tunggu sampai status `Succeeded`** sebelum lanjut.

Jika status `Failed`:
1. Klik run ID yang failed
2. Scroll ke **Error message** untuk melihat penyebab
3. Cek tab **Logs** → **Output logs** di CloudWatch

### Step 4: Verifikasi Parquet output di processed bucket

1. Buka **S3** → klik bucket `lks-analytics-processed-{ACCOUNT_ID}`
2. Navigasi ke folder `sales/`
3. Kamu harus melihat struktur folder partisi:
   ```
   sales/
   └── year=2024/
       └── month=01/
           └── day=15/
               └── part-00000-xxxx.parquet
   ```

Jika folder `sales/` tidak ada atau kosong → Glue job belum selesai atau gagal (kembali ke Step 3).

### Step 5: Jalankan Glue Crawler

1. AWS Glue → **Crawlers** → centang `lks-crawler-sales`
2. Klik **Run** → konfirmasi

Crawler akan berjalan ~60 detik. Tunggu status kembali ke **Ready**.

Verifikasi tabel terbuat:
1. AWS Glue → **Data Catalog** → **Tables**
2. Cari tabel `sales` di database `lks_analytics_db`
3. Klik tabel → lihat schema:

| Column | Type |
|---|---|
| transaction_id | string |
| store_id | string |
| product_id | string |
| product_name | string |
| category | string |
| quantity | bigint |
| unit_price | bigint |
| amount | bigint |
| sale_date | string |
| payment_method | string |
| year | string |
| month | string |
| day | string |

### Step 6: Query di Athena

1. Buka **Amazon Athena** → **Query editor**
2. Di pojok kanan atas, pastikan workgroup = **lks-analytics-wg** (bukan primary)
   - Klik dropdown workgroup → pilih `lks-analytics-wg`
3. Di panel kiri, pilih **Database:** `lks_analytics_db`

Jalankan query-query berikut satu per satu:

---

**Query 1 — Total row count**
```sql
SELECT COUNT(*) AS row_count FROM lks_analytics_db.sales;
```

> **Expected result:**
>
> | row_count |
> |---|
> | 10 |

---

**Query 2 — Cek partisi**
```sql
SHOW PARTITIONS lks_analytics_db.sales;
```

> **Expected result:**
>
> | partition |
> |---|
> | year=2024/month=01/day=15 |

---

**Query 3 — Revenue by store**
```sql
SELECT store_id,
       SUM(amount)  AS total_revenue,
       COUNT(*)     AS tx_count
FROM lks_analytics_db.sales
WHERE year = '2024' AND month = '01'
GROUP BY store_id
ORDER BY total_revenue DESC;
```

> **Expected result:**
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

> **Expected result:**
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

> **Expected result:**
>
> | payment_method | tx_count | total  |
> |---|---|---|
> | cash           | 4        | 102000 |
> | qris           | 3        | 62000  |
> | debit_card     | 2        | 88500  |
> | transfer       | 1        | 130000 |

---

**Layer 8 checkpoint — semua harus terpenuhi:**
- [ ] Lambda log menunjukkan `Glue job run started: jr_...`
- [ ] Glue job `lks-etl-sales` status **Succeeded**
- [ ] Parquet files ada di `s3://lks-analytics-processed-.../sales/year=2024/month=01/day=15/`
- [ ] Tabel `sales` ada di Glue Data Catalog dengan 13 kolom
- [ ] Athena Query 1 mengembalikan `row_count = 10`
- [ ] Athena Query 3 mengembalikan `STORE-SBY-01` sebagai store dengan revenue tertinggi (165000)

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
| Lake Formation — Glue permissions | CREATE_TABLE, DATA_LOCATION_ACCESS, SELECT | ✓ |
| Lake Formation — Analyst permissions | SELECT, DESCRIBE pada `lks_analytics_db` | ✓ |
| Lambda function | `lks-glue-trigger` (Python 3.12) | ✓ |
| EventBridge rule | `lks-s3-sales-upload` | ✓ |
| Athena workgroup | `lks-analytics-wg` | ⚠️ $5/TB scanned |
| SNS topic | `lks-analytics-alerts` | ✓ |
| CloudWatch alarm | `lks-glue-job-failure` | ✓ |

> **Hemat biaya:** Setelah selesai praktik, nonaktifkan Glue Crawler schedule: AWS Glue → Crawlers → pilih `lks-crawler-sales` → **Edit** → Schedule → **No schedule** → Save. Hapus semua resource setelah ujian selesai.
