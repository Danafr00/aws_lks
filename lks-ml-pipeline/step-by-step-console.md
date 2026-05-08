# Step-by-Step: ML Pipeline + ECS Inference — AWS Console Guide

**Goal**: Fraud detection system for PT. Nusantara PayTech — data pipeline trains XGBoost model, ECS Fargate serves inference 24/7.  
**Region**: us-east-1 | **Cost warning**: SageMaker endpoint $0.096/hr, Fargate ~$0.02/hr — delete after use.

> **AWS Academy constraints:**
> - Cannot create IAM roles → use `LabRole` for everything
> - `voclabs` session denies `sagemaker:CreateTrainingJob` directly → train inside a Notebook Instance
> - Region: **us-east-1**

> **Terminal required for**: Docker build/push, zip/deploy Lambda, Glue job polling, and kubectl-equivalent CLI steps. Everything else is in the AWS Console.

---

## Layers

| Layer | Console | Terminal |
|---|---|---|
| **1** | S3 buckets, SQS queue, SQS policy, S3 event notification | Package + deploy Lambda |
| **2** | Glue job, Crawler, Athena workgroup | Run ETL job, query Athena |
| **3** | SageMaker Notebook Instance → training + endpoint | Upload data, run boto3 training cell |
| **4** | ECR repo, ECS cluster, task def, ALB, security groups, ECS service | Docker build/push |
| **5** | DynamoDB table, API Gateway, Amplify | Deploy frontend |

---

## Layer 1 — S3 + SQS + Lambda

### 1.1 S3 Buckets (Console)

1. Open [S3 Console](https://s3.console.aws.amazon.com) → **Create bucket** — repeat 4 times:

   | Bucket name (replace `{ACCOUNT_ID}`) | Purpose |
   |---|---|
   | `lks-paytech-raw-{ACCOUNT_ID}` | Raw transaction CSV files |
   | `lks-paytech-features-{ACCOUNT_ID}` | Feature-engineered CSV |
   | `lks-paytech-processed-{ACCOUNT_ID}` | Glue Parquet output + model artifacts |
   | `lks-paytech-results-{ACCOUNT_ID}` | Prediction JSON results |

   For each bucket:
   - Region: **us-east-1**
   - Block all public access: ✅ (keep default)
   - Leave everything else default → **Create bucket**

---

### 1.2 SQS Queue (Console)

1. Open [SQS Console](https://console.aws.amazon.com/sqs) → **Create queue**
   - Type: **Standard**
   - Name: `lks-paytech-queue`
   - Visibility timeout: `300` seconds
   - Message retention period: `86400` seconds (1 day)
2. **Create queue**
3. Click the queue → **Access policy** tab → **Edit**
4. Replace the policy JSON with (replace `ACCOUNT_ID`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "s3.amazonaws.com" },
    "Action": "sqs:SendMessage",
    "Resource": "arn:aws:sqs:us-east-1:ACCOUNT_ID:lks-paytech-queue",
    "Condition": {
      "ArnLike": {
        "aws:SourceArn": "arn:aws:s3:::lks-paytech-raw-ACCOUNT_ID"
      }
    }
  }]
}
```

5. **Save**

Note the **Queue ARN** (visible in queue details).

---

### 1.3 S3 Event Notification → SQS (Console)

1. S3 Console → `lks-paytech-raw-{ACCOUNT_ID}` → **Properties** tab
2. Scroll to **Event notifications** → **Create event notification**
   - Name: `raw-to-sqs`
   - Prefix: `data/`
   - Suffix: `.csv`
   - Event types: ✅ **s3:ObjectCreated:All**
   - Destination: **SQS queue** → select `lks-paytech-queue`
3. **Save changes**

---

### 1.4 IAM Role for Lambda

> **AWS Academy:** Skip this step. `LabRole` already exists with required permissions.
> Use ARN: `arn:aws:iam::{ACCOUNT_ID}:role/LabRole`

---

### 1.5 Deploy Lambda (Terminal)

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"

# AWS Academy: skip IAM role creation — use LabRole instead
# arn:aws:iam::${ACCOUNT_ID}:role/LabRole

cd app/feature_lambda/
zip /tmp/lks-feature-trigger.zip handler.py
cd -

aws lambda create-function \
  --function-name lks-feature-trigger \
  --runtime python3.12 \
  --handler handler.handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
  --zip-file fileb:///tmp/lks-feature-trigger.zip \
  --timeout 300 \
  --memory-size 256 \
  --environment "Variables={FEATURES_BUCKET=${FEATURES_BUCKET}}" \
  --region $AWS_REGION

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/lks-paytech-queue" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

aws lambda create-event-source-mapping \
  --function-name lks-feature-trigger \
  --event-source-arn "$QUEUE_ARN" \
  --batch-size 10

echo "Lambda deployed!"
```

### 1.6 Test Layer 1 (Terminal)

```bash
RAW_BUCKET="lks-paytech-raw-${ACCOUNT_ID}"
FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"

aws s3 cp data/sample_transactions.csv "s3://${RAW_BUCKET}/data/sample_transactions.csv"
echo "Waiting 30s for processing..."
sleep 30
aws s3 ls "s3://${FEATURES_BUCKET}/features/"
# Expected: features/sample_transactions.csv
```

**Layer 1 checkpoint:**
- [ ] Features file appears in S3 features bucket
- [ ] Lambda function is visible in Lambda Console

---

## Layer 2 — Glue ETL + Athena

### 2.1 IAM Role for Glue

> **AWS Academy:** Skip this step. `LabRole` already exists with required permissions.
> Use ARN: `arn:aws:iam::{ACCOUNT_ID}:role/LabRole`

---

### 2.2 Upload ETL Script (Terminal)

```bash
PROCESSED_BUCKET="lks-paytech-processed-${ACCOUNT_ID}"
aws s3 cp glue/etl_job.py "s3://${PROCESSED_BUCKET}/scripts/etl_job.py"
```

---

### 2.3 Create Glue Job (Console)

1. Open [Glue Console](https://console.aws.amazon.com/glue) → **ETL Jobs** → **Script editor**
   - Engine: **Spark** | Options: **Upload and edit an existing script**
   - Upload: *(or paste the content of `glue/etl_job.py`)*
2. **Job details** tab:
   - Name: `lks-etl-paytech`
   - IAM role: `LabRole`
   - Glue version: **Glue 4.0**
   - Worker type: **G.025X** | Number of workers: `2`
3. **Job parameters** → **Add new parameter**:

   | Key | Value (replace ACCOUNT_ID) |
   |---|---|
   | `--JOB_NAME` | `lks-etl-paytech` |
   | `--S3_FEATURES_PATH` | `s3://lks-paytech-features-ACCOUNT_ID/features/` |
   | `--S3_OUTPUT_PATH` | `s3://lks-paytech-processed-ACCOUNT_ID/parquet/` |

4. **Save** → **Run**

Wait for the job run status to show **Succeeded** (check **Runs** tab).

---

### 2.4 Glue Crawler (Console)

1. Glue Console → **Crawlers** → **Create crawler**
   - Name: `lks-crawler-paytech`
   - Data source: **S3** → path: `s3://lks-paytech-processed-{ACCOUNT_ID}/parquet/`
   - IAM role: `LabRole`
   - Target database: **Add database** → name: `lks_paytech_db` → **Create database**
   - Schedule: **Hourly**
2. **Create crawler** → **Run crawler**

---

### 2.5 Athena Workgroup (Console)

1. Open [Athena Console](https://console.aws.amazon.com/athena) → **Workgroups** → **Create workgroup**
   - Name: `lks-paytech-wg`
   - Query result location: `s3://lks-paytech-processed-{ACCOUNT_ID}/athena-results/`
2. **Create workgroup**
3. Switch to `lks-paytech-wg` → run a test query:

```sql
SELECT COUNT(*) FROM lks_paytech_db.parquet;
```

**Layer 2 checkpoint:**
- [ ] Glue job run: Succeeded
- [ ] Athena query returns a row count

---

## Layer 3 — SageMaker Training + Endpoint

> **AWS Academy:** Cannot call `sagemaker:CreateTrainingJob` from `voclabs` session directly.
> Must run training inside a SageMaker Notebook Instance (runs as LabRole, bypasses the deny).

### 3.1 Upload Training Data (Terminal)

```bash
PROCESSED_BUCKET="lks-paytech-processed-${ACCOUNT_ID}"
aws s3 cp data/train.csv "s3://${PROCESSED_BUCKET}/training/train.csv"
aws s3 cp data/validation.csv "s3://${PROCESSED_BUCKET}/training/validation.csv"
```

---

### 3.2 Create Notebook Instance (Console)

1. Open [SageMaker Console](https://console.aws.amazon.com/sagemaker) → **Notebook** → **Notebook instances** → **Create notebook instance**
2. Fill in:
   - **Notebook instance name**: `lks-fraud-notebook`
   - **Notebook instance type**: `ml.t3.medium`
   - **Elastic Inference**: None
3. Under **Permissions and encryption**:
   - **IAM role**: click dropdown → **Enter a custom IAM role ARN**
   - Paste: `arn:aws:iam::{ACCOUNT_ID}:role/LabRole`
4. Add tags: `Project=nusantara-paytech`, `Environment=production`, `ManagedBy=LKS-Team`
5. **Create notebook instance** → wait ~3 min for status **InService**
6. Click **Open JupyterLab** → **File** → **New** → **Notebook** → Kernel: **conda_python3**

---

### 3.3 Run Training Job (Inside Notebook — Cell 1)

> All code below runs INSIDE JupyterLab. The notebook instance runs as `LabRole` — `CreateTrainingJob` is allowed.

```python
import boto3, time

REGION = 'us-east-1'
sm = boto3.client('sagemaker', region_name=REGION)
ACCOUNT_ID = boto3.client('sts', region_name=REGION).get_caller_identity()['Account']
ROLE_ARN = f'arn:aws:iam::{ACCOUNT_ID}:role/LabRole'
PROCESSED_BUCKET = f'lks-paytech-processed-{ACCOUNT_ID}'
CONTAINER = f'683313688378.dkr.ecr.{REGION}.amazonaws.com/sagemaker-xgboost:1.7-1'
JOB_NAME = f'lks-fraud-xgb-{int(time.time())}'

print(f"Account:   {ACCOUNT_ID}")
print(f"Role:      {ROLE_ARN}")
print(f"Job name:  {JOB_NAME}")
print(f"Container: {CONTAINER}")

sm.create_training_job(
    TrainingJobName=JOB_NAME,
    RoleArn=ROLE_ARN,
    AlgorithmSpecification={
        'TrainingImage': CONTAINER,
        'TrainingInputMode': 'File',
    },
    HyperParameters={
        'objective': 'binary:logistic',
        'num_round': '150',
        'max_depth': '5',
        'eta': '0.2',
        'subsample': '0.8',
        'colsample_bytree': '0.8',
        'min_child_weight': '1',
        'eval_metric': 'auc',
        'scale_pos_weight': '4',
    },
    InputDataConfig=[
        {
            'ChannelName': 'train',
            'ContentType': 'text/csv',
            'DataSource': {'S3DataSource': {
                'S3DataType': 'S3Prefix',
                'S3Uri': f's3://{PROCESSED_BUCKET}/training/train.csv',
                'S3DataDistributionType': 'FullyReplicated',
            }},
        },
        {
            'ChannelName': 'validation',
            'ContentType': 'text/csv',
            'DataSource': {'S3DataSource': {
                'S3DataType': 'S3Prefix',
                'S3Uri': f's3://{PROCESSED_BUCKET}/training/validation.csv',
                'S3DataDistributionType': 'FullyReplicated',
            }},
        },
    ],
    OutputDataConfig={'S3OutputPath': f's3://{PROCESSED_BUCKET}/models/'},
    ResourceConfig={
        'InstanceType': 'ml.m5.xlarge',
        'InstanceCount': 1,
        'VolumeSizeInGB': 10,
    },
    StoppingCondition={'MaxRuntimeInSeconds': 600},
    Tags=[
        {'Key': 'Project', 'Value': 'nusantara-paytech'},
        {'Key': 'Environment', 'Value': 'production'},
        {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
    ],
)

print(f"\nStarted: {JOB_NAME} — polling every 30s...")

while True:
    resp = sm.describe_training_job(TrainingJobName=JOB_NAME)
    status = resp['TrainingJobStatus']
    print(f"  Status: {status}")
    if status in ('Completed', 'Failed', 'Stopped'):
        break
    time.sleep(30)

if status == 'Completed':
    MODEL_DATA = resp['ModelArtifacts']['S3ModelArtifacts']
    print(f"\nDone. Model: {MODEL_DATA}")
else:
    print(f"\nFailed: {resp.get('FailureReason')}")
```

Expected time: **5–10 minutes**.

---

### 3.4 Deploy Endpoint (Inside Notebook — Cell 2)

> `MODEL_DATA`, `CONTAINER`, `ROLE_ARN`, `REGION`, `sm` still in memory from Cell 1.

```python
MODEL_NAME = 'lks-paytech-model'
CONFIG_NAME = 'lks-paytech-endpoint-config'
ENDPOINT_NAME = 'lks-paytech-endpoint'

# Create model
sm.create_model(
    ModelName=MODEL_NAME,
    PrimaryContainer={
        'Image': CONTAINER,
        'ModelDataUrl': MODEL_DATA,
    },
    ExecutionRoleArn=ROLE_ARN,
    Tags=[
        {'Key': 'Project', 'Value': 'nusantara-paytech'},
        {'Key': 'Environment', 'Value': 'production'},
        {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
    ],
)
print(f"Model created: {MODEL_NAME}")

# Create endpoint config
sm.create_endpoint_config(
    EndpointConfigName=CONFIG_NAME,
    ProductionVariants=[{
        'VariantName': 'AllTraffic',
        'ModelName': MODEL_NAME,
        'InitialInstanceCount': 1,
        'InstanceType': 'ml.m5.large',
        'InitialVariantWeight': 1,
    }],
    Tags=[
        {'Key': 'Project', 'Value': 'nusantara-paytech'},
        {'Key': 'Environment', 'Value': 'production'},
        {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
    ],
)
print(f"Config created: {CONFIG_NAME}")

# Create endpoint
sm.create_endpoint(
    EndpointName=ENDPOINT_NAME,
    EndpointConfigName=CONFIG_NAME,
    Tags=[
        {'Key': 'Project', 'Value': 'nusantara-paytech'},
        {'Key': 'Environment', 'Value': 'production'},
        {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
    ],
)
print(f"Endpoint creating: {ENDPOINT_NAME} — polling every 30s (~8-10 min)...")

while True:
    resp = sm.describe_endpoint(EndpointName=ENDPOINT_NAME)
    status = resp['EndpointStatus']
    print(f"  Status: {status}")
    if status == 'InService':
        print("\nEndpoint ready.")
        break
    elif status in ('Failed', 'OutOfService'):
        print(f"\nFailed: {resp.get('FailureReason')}")
        break
    time.sleep(30)
```

> ⚠️ **This endpoint costs $0.096/hr. Delete immediately after finishing the exam.**

**Layer 3 checkpoint:**
- [ ] Notebook cell completes, status = `Completed`
- [ ] SageMaker console → Training jobs → status: Completed
- [ ] SageMaker console → Endpoints → `lks-paytech-endpoint` → status: InService

---

## Layer 4 — ECR + ECS Fargate + ALB

### 4.1 ECR Repository (Console)

1. Open [ECR Console](https://console.aws.amazon.com/ecr) → **Repositories** → **Create repository**
   - Visibility: **Private**
   - Name: `lks-paytech-api`
   - Tag immutability: **Disabled** (we use `latest`)
2. **Create repository**

---

### 4.2 Build + Push Docker Image (Terminal)

```bash
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lks-paytech-api"

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t lks-paytech-api:latest app/inference_api/
docker tag lks-paytech-api:latest "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"
echo "Image pushed: ${ECR_URI}:latest"
```

---

### 4.3 IAM Roles for ECS

> **AWS Academy:** Skip this step. `LabRole` already exists with required permissions for both task role and execution role.
> Use ARN: `arn:aws:iam::{ACCOUNT_ID}:role/LabRole` for both **Task role** and **Task execution role**.

---

### 4.4 Security Groups (Console)

1. [VPC Console](https://console.aws.amazon.com/vpc) → **Security groups** → **Create security group**

**ALB Security Group:**
- Name: `lks-paytech-alb-sg` | VPC: default
- Inbound: **HTTP** port 80 from `0.0.0.0/0`

**ECS Security Group:**
- Name: `lks-paytech-ecs-sg` | VPC: default
- Inbound: **Custom TCP** port 8080 from Source: `lks-paytech-alb-sg`

---

### 4.5 Application Load Balancer (Console)

1. [EC2 Console](https://console.aws.amazon.com/ec2) → **Load balancers** → **Create load balancer** → **Application Load Balancer**
   - Name: `lks-paytech-alb`
   - Scheme: **Internet-facing** | IP type: IPv4
   - VPC: **default** | Subnets: select `us-east-1a` and `us-east-1b`
   - Security groups: `lks-paytech-alb-sg`

2. **Listeners and routing** → Create a target group:
   - Click **Create target group**
   - Target type: **IP addresses**
   - Name: `lks-paytech-tg` | Protocol: HTTP | Port: 8080
   - VPC: default
   - Health check path: `/health`
   - **Create target group** (no IPs to add — ECS adds them automatically)
   - Back in ALB creation → select `lks-paytech-tg`

3. **Create load balancer**

Note the **DNS name** of the ALB (e.g., `lks-paytech-alb-xxx.us-east-1.elb.amazonaws.com`)

---

### 4.6 CloudWatch Log Group (Console)

1. [CloudWatch Console](https://console.aws.amazon.com/cloudwatch) → **Log groups** → **Create log group**
   - Name: `/ecs/lks-paytech-task`

---

### 4.7 ECS Cluster + Task Definition (Console)

**Create Cluster:**
1. [ECS Console](https://console.aws.amazon.com/ecs) → **Clusters** → **Create cluster**
   - Cluster name: `lks-paytech-cluster`
   - Infrastructure: ✅ **AWS Fargate (serverless)**
2. **Create cluster**

**Create Task Definition:**
1. ECS Console → **Task definitions** → **Create new task definition**
   - Family: `lks-paytech-task`
   - Launch type: **AWS Fargate**
   - OS/Architecture: Linux/x86_64
   - CPU: `0.5 vCPU` | Memory: `1 GB`
   - Task role: `LabRole`
   - Task execution role: `LabRole`

2. **Container** → **Add container**:
   - Name: `inference-api`
   - Image URI: `{ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/lks-paytech-api:latest`
   - Container port: `8080`

3. **Environment variables** (Add 4):

   | Key | Value |
   |---|---|
   | `SAGEMAKER_ENDPOINT_NAME` | `lks-paytech-endpoint` |
   | `DYNAMODB_TABLE` | `lks-paytech-predictions` |
   | `RESULTS_BUCKET` | `lks-paytech-results-{ACCOUNT_ID}` |
   | `AWS_DEFAULT_REGION` | `us-east-1` |

4. **Logging** → select **Use log collection** → log group: `/ecs/lks-paytech-task`

5. **Health check**: `CMD-SHELL,curl -f http://localhost:8080/health || exit 1`

6. **Create task definition**

---

### 4.8 ECS Service (Console)

1. ECS Console → `lks-paytech-cluster` → **Services** → **Create**
   - Launch type: **Fargate** | Platform version: **LATEST**
   - Task definition: `lks-paytech-task` (latest revision)
   - Service name: `lks-paytech-service`
   - Desired tasks: `1`

2. **Networking**:
   - VPC: default | Subnets: `us-east-1a`, `us-east-1b`
   - Security group: `lks-paytech-ecs-sg`
   - Public IP: **Turned on**

3. **Load balancing**:
   - Load balancer type: **Application Load Balancer**
   - Load balancer: `lks-paytech-alb`
   - Container to load balance: `inference-api:8080`
   - Target group: `lks-paytech-tg`

4. **Create service**

> ⏳ Wait ~3 minutes for the task to show **Running** and the target group health check to pass.

### 4.9 Test ECS (Terminal)

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names lks-paytech-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

curl -s http://$ALB_DNS/health
# Expected: {"status":"ok","endpoint":"lks-paytech-endpoint"}

curl -s -X POST http://$ALB_DNS/predict \
  -H "Content-Type: application/json" \
  -d @data/test_predict.json | python3 -m json.tool
# Expected: fraud_score ~0.8, label "FRAUD"
```

**Layer 4 checkpoint:**
- [ ] ECS service shows 1 running task
- [ ] ALB target group: 1 healthy target
- [ ] `GET /health` returns `{"status":"ok"}`
- [ ] `POST /predict` returns prediction JSON

---

## Layer 5 — API Gateway + DynamoDB + Amplify

### 5.1 DynamoDB Table (Console)

1. Open [DynamoDB Console](https://console.aws.amazon.com/dynamodb) → **Tables** → **Create table**
   - Table name: `lks-paytech-predictions`
   - Partition key: `transaction_id` (String)
   - Sort key: `timestamp` (String)
   - Table settings: **Customize settings**
   - Billing mode: **On-demand**
2. **Create table**

---

### 5.2 API Gateway (Console)

1. Open [API Gateway Console](https://console.aws.amazon.com/apigateway) → **Create API**
   - API type: **HTTP API** → **Build**
   - API name: `lks-paytech-api`

2. **Add integration** → **HTTP**:
   - Method: `ANY`
   - URL endpoint: `http://{ALB_DNS_NAME}/{proxy}`

3. **Routes** — add:
   - `POST /predict` → HTTP integration
   - `GET /health` → HTTP integration

4. **Stages** → default stage is `$default` with auto-deploy enabled

5. Note the **Invoke URL** (e.g., `https://abc123.execute-api.us-east-1.amazonaws.com`)

6. **CORS** tab → **Configure**:
   - Allow origins: `*`
   - Allow methods: ✅ GET, POST, OPTIONS
   - Allow headers: `Content-Type`
   - **Save**

Test in terminal:
```bash
API_URL="https://{your-api-id}.execute-api.us-east-1.amazonaws.com"
curl -X POST "$API_URL/predict" \
  -H "Content-Type: application/json" \
  -d @data/test_predict.json
```

---

### 5.3 Amplify Frontend (Console)

1. Open [Amplify Console](https://console.aws.amazon.com/amplify)
2. **New app** → **Host web app** → **Deploy without Git**
3. App name: `lks-paytech-ui` → **Continue**
4. First create a branch: **main** → **Next**

**Prepare and upload (Terminal):**
```bash
API_URL="https://{YOUR_API_ID}.execute-api.us-east-1.amazonaws.com"

sed "s|__API_GATEWAY_URL__|${API_URL}|g" \
  app/frontend/index.html > /tmp/index.html

cd /tmp && zip -q amplify-deploy.zip index.html && cd -

AMPLIFY_APP_ID=$(aws amplify list-apps \
  --query "apps[?name=='lks-paytech-ui'].appId" --output text)

DEPLOYMENT=$(aws amplify create-deployment \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main --output json)

UPLOAD_URL=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['zipUploadUrl'])")
JOB_ID=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")

curl -s -X PUT -H "Content-Type: application/zip" \
  --data-binary @/tmp/amplify-deploy.zip "$UPLOAD_URL"

aws amplify start-deployment \
  --app-id "$AMPLIFY_APP_ID" --branch-name main --job-id "$JOB_ID"

echo "App URL: https://main.${AMPLIFY_APP_ID}.amplifyapp.com"
```

**Layer 5 checkpoint:**
- [ ] API Gateway invoke URL returns prediction JSON
- [ ] DynamoDB table has a record after calling `/predict`
- [ ] Amplify web UI loads and shows prediction result

---

## Cleanup (Console)

**Delete in this order:**

1. **Amplify Console** → `lks-paytech-ui` → **Actions** → **Delete app**

2. **API Gateway Console** → `lks-paytech-api` → **Delete**

3. **ECS Console** → `lks-paytech-cluster` → **Services** → `lks-paytech-service` → **Delete service**
   - Then → **Clusters** → `lks-paytech-cluster` → **Delete cluster**

4. **EC2 Console → Load Balancers** → `lks-paytech-alb` → **Actions** → **Delete load balancer**
   - **Target Groups** → `lks-paytech-tg` → **Actions** → **Delete**
   - **Security Groups** → delete `lks-paytech-alb-sg` and `lks-paytech-ecs-sg`

5. **SageMaker Console → Endpoints** → `lks-paytech-endpoint` → **Delete** ⚠️ PRIORITY

6. **SageMaker Console → Models** → `lks-paytech-model` → **Delete**

7. **SageMaker Console → Notebook instances** → `lks-fraud-notebook` → **Stop** → **Delete**

8. **ECR Console** → `lks-paytech-api` → **Delete**

9. **Glue Console → Jobs** → `lks-etl-paytech` → **Delete**
   - **Crawlers** → `lks-crawler-paytech` → **Delete**
   - **Databases** → `lks_paytech_db` → **Delete**

10. **Lambda Console** → `lks-feature-trigger` → **Delete**

11. **DynamoDB Console** → `lks-paytech-predictions` → **Delete table**

12. **SQS Console** → `lks-paytech-queue` → **Delete**

13. **S3 Console** → empty and delete all 4 `lks-paytech-*` buckets

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| S3 event not triggering SQS | SQS policy missing S3 source ARN | Check SQS Access Policy matches exact bucket ARN |
| Lambda error: `KeyError` | CSV missing column | Verify `sample_transactions.csv` has all 10 columns |
| Glue job fails | ETL script path wrong or permissions | Check S3 path matches and LabRole has S3 access |
| `AccessDenied: sagemaker:CreateTrainingJob` from CLI | `Pvoclabs2` explicit deny on voclabs session | Run training from inside notebook instance (LabRole) |
| `no module named sagemaker.estimator` | SageMaker SDK v3 broke import paths | Use boto3 direct approach in Layer 3 (no SDK needed) |
| SageMaker training fails | S3 input path wrong | Ensure `train.csv` is at the correct S3 URI |
| ECS task keeps stopping | Container missing env var or IAM issue | CloudWatch Logs → `/ecs/lks-paytech-task` |
| ALB health check unhealthy | FastAPI still starting | Wait 30s — `startPeriod=15` in health check config |
| `POST /predict` → 503 | SageMaker endpoint deleted | Redeploy endpoint from notebook |
| DynamoDB write fails | Check LabRole has `dynamodb:PutItem` | LabRole should have full DynamoDB access |
