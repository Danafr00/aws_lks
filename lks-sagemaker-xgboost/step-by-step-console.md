# Step-by-Step — AWS Academy (voclabs) — Console Guide

> **AWS Academy constraints:**
> - Cannot create IAM roles → use `LabRole` for everything
> - `voclabs` session denies `sagemaker:CreateTrainingJob` directly → train **inside a Notebook Instance** (which runs as `LabRole`)
> - Region: **us-east-1**

---

## Layer Summary

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | S3 buckets + training data | S3 console shows `train.csv` and `validation.csv` in correct prefixes |
| **2** | SageMaker Notebook Instance | Notebook status `InService`, JupyterLab opens |
| **3** | XGBoost Training Job (inside notebook) | Training job status `Completed`, AUC > 0.80 |
| **4** | SageMaker Endpoint (inside notebook) | Endpoint status `InService`, test returns float score |
| **5** | Lambda + API Gateway | Lambda console shows function, API test returns JSON with `risk_level` |
| **6** | Amplify UI | Web form loads, submit returns color-coded result |
| **7** | CloudWatch + SNS | Alarm visible in console, email subscription confirmed |

---

## Layer 1 — S3 Buckets + Training Data

### 1.1 Create data bucket

1. Go to **S3 console** → click **Create bucket**
2. **Bucket name**: `lks-sagemaker-data-{YOUR_ACCOUNT_ID}` (replace with your 12-digit account ID)
3. **AWS Region**: `us-east-1`
4. **Object Ownership**: ACLs disabled
5. **Block Public Access**: leave all 4 checkboxes **checked**
6. **Encryption**: SSE-S3 (default)
7. Click **Create bucket**
8. Open the bucket → **Properties** tab → **Tags** → **Edit** → Add:
   - `Project` = `nusantara-fincredit`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`

### 1.2 Create models bucket

Repeat Step 1.1 with bucket name: `lks-sagemaker-models-{YOUR_ACCOUNT_ID}`

### 1.3 Upload training data

1. Open `lks-sagemaker-data-{ACCOUNT_ID}` bucket
2. Click **Create folder** → name: `train` → **Create folder**
3. Open the `train/` folder → click **Upload** → **Add files** → select `data/train.csv` → **Upload**
4. Go back to bucket root → **Create folder** → name: `validation` → **Create folder**
5. Open the `validation/` folder → click **Upload** → **Add files** → select `data/validation.csv` → **Upload**

**Layer 1 checkpoint — verify before continuing:**
- [ ] S3 console → `lks-sagemaker-data-{ACCOUNT_ID}` → `train/train.csv` exists
- [ ] S3 console → `lks-sagemaker-data-{ACCOUNT_ID}` → `validation/validation.csv` exists

---

## Layer 2 — SageMaker Notebook Instance

> Why: `voclabs` session cannot call `sagemaker:CreateTrainingJob` directly (explicit deny in `Pvoclabs2`). A Notebook Instance assumes `LabRole` as its execution role — SDK calls inside the notebook bypass the deny.

### 2.1 Create Notebook Instance

1. Go to **SageMaker console** → left sidebar → **Notebook** → **Notebook instances**
2. Click **Create notebook instance**
3. Fill in:
   - **Notebook instance name**: `lks-loan-notebook`
   - **Notebook instance type**: `ml.t3.medium` (cheapest — $0.05/hr)
   - **Elastic Inference**: None
4. Under **Permissions and encryption**:
   - **IAM role**: click dropdown → **Enter a custom IAM role ARN**
   - Paste: `arn:aws:iam::{YOUR_ACCOUNT_ID}:role/LabRole`
5. Under **Tags**:
   - `Project` = `nusantara-fincredit`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
6. Click **Create notebook instance**
7. Wait ~3 minutes for status → **InService**

### 2.2 Open JupyterLab

Once status = `InService` → click **Open JupyterLab**

> No file uploads needed — all training code runs inline via boto3.

**Layer 2 checkpoint — verify before continuing:**
- [ ] SageMaker console → Notebook instances → `lks-loan-notebook` → status `InService`
- [ ] JupyterLab opens in browser tab

---

## Layer 3 — XGBoost Training Job (inside notebook)

> All cells below run INSIDE JupyterLab on the notebook instance. The instance runs as `LabRole`, so `CreateTrainingJob` is allowed.
> Uses **boto3 directly** — no SageMaker SDK import, no version issues.

### 3.1 Open a new notebook

In JupyterLab → **File** → **New** → **Notebook** → Kernel: **conda_python3**

### 3.2 Run training job (boto3 only)

Paste this entire cell and run (click ▶ or Shift+Enter):

```python
import boto3, time

REGION = 'us-east-1'
sm = boto3.client('sagemaker', region_name=REGION)
ACCOUNT_ID = boto3.client('sts', region_name=REGION).get_caller_identity()['Account']
ROLE_ARN = f'arn:aws:iam::{ACCOUNT_ID}:role/LabRole'
DATA_BUCKET = f'lks-sagemaker-data-{ACCOUNT_ID}'
MODEL_BUCKET = f'lks-sagemaker-models-{ACCOUNT_ID}'
CONTAINER = f'683313688378.dkr.ecr.{REGION}.amazonaws.com/sagemaker-xgboost:1.7-1'
JOB_NAME = f'lks-loan-xgb-{int(time.time())}'

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
        'scale_pos_weight': '3',
    },
    InputDataConfig=[
        {
            'ChannelName': 'train',
            'ContentType': 'text/csv',
            'DataSource': {'S3DataSource': {
                'S3DataType': 'S3Prefix',
                'S3Uri': f's3://{DATA_BUCKET}/train/',
                'S3DataDistributionType': 'FullyReplicated',
            }},
        },
        {
            'ChannelName': 'validation',
            'ContentType': 'text/csv',
            'DataSource': {'S3DataSource': {
                'S3DataType': 'S3Prefix',
                'S3Uri': f's3://{DATA_BUCKET}/validation/',
                'S3DataDistributionType': 'FullyReplicated',
            }},
        },
    ],
    OutputDataConfig={'S3OutputPath': f's3://{MODEL_BUCKET}/model-output/'},
    ResourceConfig={
        'InstanceType': 'ml.m5.xlarge',
        'InstanceCount': 1,
        'VolumeSizeInGB': 10,
    },
    StoppingCondition={'MaxRuntimeInSeconds': 600},
    Tags=[
        {'Key': 'Project', 'Value': 'nusantara-fincredit'},
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

Expected time: **3–5 minutes**.

### 3.3 Note the model artifacts path

After training completes, `MODEL_DATA` variable holds the S3 path — looks like:
```
s3://lks-sagemaker-models-{ACCOUNT_ID}/model-output/lks-loan-xgb-1234567890/output/model.tar.gz
```

You can also find it in: **SageMaker console → Training → Training jobs → click job name → Output → S3 model artifact**

**Layer 3 checkpoint — verify before continuing:**
- [ ] Notebook cell runs without error, final status = `Completed`
- [ ] SageMaker console → Training jobs → job status = `Completed`
- [ ] `MODEL_DATA` path printed in notebook output

---

## Layer 4 — SageMaker Endpoint (inside notebook)

### 4.1 Create model + endpoint config + endpoint (boto3 only)

Next cell in same notebook — `MODEL_DATA`, `CONTAINER`, `ROLE_ARN`, `REGION`, `sm` still in memory from Layer 3:

```python
ENDPOINT_NAME = 'lks-loan-risk-endpoint'
MODEL_NAME = 'lks-loan-risk-model'
CONFIG_NAME = 'lks-loan-risk-config'

# Create model
sm.create_model(
    ModelName=MODEL_NAME,
    PrimaryContainer={
        'Image': CONTAINER,
        'ModelDataUrl': MODEL_DATA,
    },
    ExecutionRoleArn=ROLE_ARN,
    Tags=[
        {'Key': 'Project', 'Value': 'nusantara-fincredit'},
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
        {'Key': 'Project', 'Value': 'nusantara-fincredit'},
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
        {'Key': 'Project', 'Value': 'nusantara-fincredit'},
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

Wait ~8–10 minutes.

### 4.2 Test endpoint from console

1. **SageMaker console** → left sidebar → **Inference** → **Endpoints**
2. Click `lks-loan-risk-endpoint`
3. Scroll down → **Test inference** section
4. **Payload** field — paste low-risk test:
   ```
   42,85000,12000,36,720,12,0.22,1,3,0
   ```
5. Click **Send** → response should be a float < 0.30 (low risk)
6. Test high-risk:
   ```
   26,32000,20000,60,545,1,0.58,0,8,5
   ```
7. Response should be a float > 0.50 (high risk)

**Layer 4 checkpoint — verify before continuing:**
- [ ] SageMaker console → Endpoints → `lks-loan-risk-endpoint` → status `InService`
- [ ] Low-risk test inference returns value < 0.30
- [ ] High-risk test inference returns value > 0.50

---

## Layer 5 — Lambda + API Gateway

### 5.1 Prepare Lambda zip

On your local machine:
1. Open terminal in `lks-sagemaker-xgboost/app/`
2. Run: `zip function.zip handler.py`
3. You now have `app/function.zip`

### 5.2 Create Lambda function (Console)

1. **Lambda console** → **Create function**
2. Select **Author from scratch**
3. Fill in:
   - **Function name**: `lks-loan-risk`
   - **Runtime**: Python 3.12
   - **Architecture**: x86_64
4. Under **Permissions** → **Change default execution role** → **Use an existing role**
   - Select `LabRole`
5. Click **Create function**

### 5.3 Upload code and configure

1. On the function page → **Code** tab → **Upload from** → **.zip file**
2. Upload `app/function.zip`
3. Set **Handler**: `handler.handler`
4. Click **Save**

**Set environment variables:**
1. **Configuration** tab → **Environment variables** → **Edit**
2. Add:
   - `SAGEMAKER_ENDPOINT_NAME` = `lks-loan-risk-endpoint`
   - `AWS_REGION` = `us-east-1`
3. Click **Save**

**Set memory and timeout:**
1. **Configuration** tab → **General configuration** → **Edit**
2. **Memory**: `256 MB`
3. **Timeout**: `0 min 30 sec`
4. Click **Save**

**Add tags:**
1. **Configuration** tab → **Tags** → **Manage tags**
2. Add `Project=nusantara-fincredit`, `Environment=production`, `ManagedBy=LKS-Team`

### 5.4 Create API Gateway HTTP API (Console)

1. **API Gateway console** → **Create API**
2. Under **HTTP API** → click **Build**
3. **Integrations** → **Add integration** → **Lambda**
   - AWS Region: `us-east-1`
   - Lambda function: `lks-loan-risk`
4. **API name**: `lks-loan-risk-api`
5. Click **Next**
6. **Configure routes**:
   - Method: `POST`
   - Resource path: `/predict`
   - Integration target: `lks-loan-risk`
7. Click **Next** → Stage name: `prod` → **Auto-deploy**: on → **Next** → **Create**

**Enable CORS:**
1. Click on your new API → **CORS** in left sidebar
2. Click **Configure**
3. Set:
   - **Access-Control-Allow-Origin**: `*`
   - **Access-Control-Allow-Headers**: `content-type`
   - **Access-Control-Allow-Methods**: `POST, OPTIONS`
4. Click **Save**

**Copy invoke URL:**
1. Left sidebar → **Stages** → `prod`
2. Copy **Invoke URL** — looks like `https://xxxxxxxx.execute-api.us-east-1.amazonaws.com/prod`
3. Save this URL — needed for Layer 6

### 5.5 Test API from console

1. Left sidebar → **Routes** → `POST /predict`
2. Click **Test** (if available) or use browser console / Postman

Or test from Lambda console:
1. Lambda → `lks-loan-risk` → **Test** tab
2. Create test event with JSON:
```json
{
  "requestContext": {"http": {"method": "POST"}},
  "body": "{\"age\":42,\"annual_income\":85000,\"loan_amount\":12000,\"loan_term_months\":36,\"credit_score\":720,\"employment_years\":12,\"debt_to_income_ratio\":0.22,\"has_mortgage\":1,\"num_credit_lines\":3,\"num_late_payments\":0}"
}
```
3. Click **Test** → response should include `"risk_level": "LOW"`

**Layer 5 checkpoint — verify before continuing:**
- [ ] Lambda console shows `lks-loan-risk` function with Python 3.12
- [ ] API Gateway console shows `lks-loan-risk-api` with route `POST /predict`
- [ ] Lambda test event returns `"risk_level":"LOW"` for low-risk input
- [ ] Invoke URL copied and saved

---

## Layer 6 — Amplify UI

### 6.1 Edit index.html — inject API URL

1. Open `app/index.html` in a **text editor** (VS Code, Notepad++, etc.)
2. Find the text: `__API_GATEWAY_URL__`
3. Replace it with your API Gateway invoke URL from Layer 5, e.g.:
   ```
   https://xxxxxxxx.execute-api.us-east-1.amazonaws.com/prod
   ```
4. Save the file

### 6.2 Create zip for deployment

1. Create a new folder, e.g. `lks-build/`
2. Copy the edited `index.html` into `lks-build/`
3. Zip the folder contents → `deploy.zip` (zip must contain `index.html` at root, not inside a subfolder)

### 6.3 Deploy to Amplify (Console)

1. **Amplify console** → click **Create new app**
2. Select **Host your web app**
3. Select **Deploy without Git provider** → click **Continue**
4. **App name**: `lks-loan-risk-ui`
5. **Environment name**: `main`
6. **Method**: Drag and drop your `deploy.zip` onto the upload area
7. Click **Save and deploy**
8. Wait for deployment to complete (status → **Deployed**)

**Add tags:**
1. Left sidebar → **App settings** → **General**
2. Scroll to **Tags** → **Manage tags**
3. Add `Project=nusantara-fincredit`, `Environment=production`, `ManagedBy=LKS-Team`

### 6.4 Verify

1. Copy the **Domain** URL shown in Amplify (e.g. `https://main.xxxxxxxx.amplifyapp.com`)
2. Open in browser
3. Test low-risk (Age 42, Income 85000, Credit Score 720) → expect green **LOW RISK**
4. Test high-risk (Age 26, Income 32000, Credit Score 545) → expect red **HIGH RISK**

**Layer 6 checkpoint — verify before continuing:**
- [ ] Amplify console shows `lks-loan-risk-ui` → branch `main` → status `Deployed`
- [ ] URL opens PT. Nusantara FinCredit loan assessment form
- [ ] Both test cases return correct risk level with correct color

---

## Layer 7 — CloudWatch + SNS Monitoring

### 7.1 Create SNS topic

1. **SNS console** → **Topics** → **Create topic**
2. **Type**: Standard
3. **Name**: `lks-fincredit-alerts`
4. Add tags: `Project=nusantara-fincredit`, `Environment=production`, `ManagedBy=LKS-Team`
5. Click **Create topic**

### 7.2 Subscribe email to topic

1. On topic page → **Subscriptions** tab → **Create subscription**
2. **Protocol**: Email
3. **Endpoint**: your email address
4. Click **Create subscription**
5. Check your inbox → click **Confirm subscription** link

### 7.3 Create CloudWatch alarm

1. **CloudWatch console** → left sidebar → **Alarms** → **All alarms** → **Create alarm**
2. Click **Select metric**
3. Browse: **SageMaker** → **Endpoint Metrics** → filter by `lks-loan-risk-endpoint`
4. Select **ModelError** → click **Select metric**
5. Configure:
   - **Statistic**: Sum
   - **Period**: 5 minutes
6. Click **Next**
7. **Threshold**:
   - Whenever `ModelError` is **Greater than or equal to** `5`
   - Datapoints: 1 out of 1
8. Click **Next**
9. **Notification**: Select **In alarm** → **Select an existing SNS topic** → `lks-fincredit-alerts`
10. Click **Next**
11. **Alarm name**: `lks-endpoint-error-rate`
12. Click **Create alarm**

**Layer 7 checkpoint:**
- [ ] SNS console → Topics → `lks-fincredit-alerts` exists
- [ ] SNS → Subscriptions → email subscription status = `Confirmed`
- [ ] CloudWatch → Alarms → `lks-endpoint-error-rate` visible

---

## Cleanup (IMPORTANT — $0.096/hr billing)

### Delete endpoint (stop billing immediately)

1. **SageMaker console** → **Inference** → **Endpoints**
2. Select `lks-loan-risk-endpoint` → **Actions** → **Delete** → confirm

### Delete endpoint config

1. **SageMaker console** → **Inference** → **Endpoint configurations**
2. Select `lks-loan-risk-config` → **Actions** → **Delete** → confirm

### Delete model

1. **SageMaker console** → **Inference** → **Models**
2. Select `lks-loan-risk-model` → **Actions** → **Delete** → confirm

### Stop notebook instance (also billed at $0.05/hr)

1. **SageMaker console** → **Notebook** → **Notebook instances**
2. Select `lks-loan-notebook` → **Actions** → **Stop**
3. Once stopped → **Actions** → **Delete** (optional)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDenied: sagemaker:CreateTrainingJob` from CLI | `Pvoclabs2` explicit deny on voclabs session | Run training from inside notebook instance (LabRole) |
| `AccessDenied: sagemaker:CreateNotebookInstance` | Lab doesn't allow notebook creation | Try SageMaker Studio → use Domain with LabRole |
| `no module named sagemaker.estimator` | SageMaker SDK v3 broke import paths | Use boto3 direct approach in Layer 3 (no SDK needed) |
| Training job fails immediately | LabRole missing S3 access | Verify buckets exist and names match `lks-sagemaker-*-{ACCOUNT_ID}` |
| Endpoint stuck `Creating` > 15 min | Instance quota | Try `ml.t2.medium` instead of `ml.m5.large` |
| Lambda returns `500` | Endpoint not `InService` yet | Wait for endpoint, check CloudWatch logs for Lambda |
| UI shows `__API_GATEWAY_URL__` | URL not replaced in index.html | Edit index.html in text editor before zipping |
| Amplify shows blank page | index.html inside subfolder in zip | Re-zip — `index.html` must be at zip root, not inside a folder |
| Test inference tab not visible in console | Endpoint still creating | Refresh page after `InService` status |
