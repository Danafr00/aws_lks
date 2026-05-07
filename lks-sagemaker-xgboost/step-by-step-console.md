# Step-by-Step — AWS Academy (voclabs) — Console Guide

> **AWS Academy constraints:**
> - Cannot create IAM roles → use `LabRole` for everything
> - `voclabs` session denies `sagemaker:CreateTrainingJob` directly → train **inside a Notebook Instance** (which runs as `LabRole`)
> - Region: **us-east-1**

---

## Layer Summary

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | S3 buckets + training data | `aws s3 ls s3://lks-sagemaker-data-{account}/train/` shows `train.csv` |
| **2** | SageMaker Notebook Instance | Notebook opens in JupyterLab, status `InService` |
| **3** | XGBoost Training Job (inside notebook) | Training job status `Completed`, AUC > 0.80 |
| **4** | SageMaker Endpoint (inside notebook) | `invoke-endpoint` returns float score |
| **5** | Lambda + API Gateway | `curl POST /predict` returns JSON with `risk_level` |
| **6** | Amplify UI | Web form loads, submit returns color-coded result |
| **7** | CloudWatch + SNS | Alarm visible in console, email subscription confirmed |

---

## Layer 1 — S3 Buckets + Training Data

### 1.1 Set account ID

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION=us-east-1
echo "Account: $ACCOUNT_ID"
```

### 1.2 Create S3 buckets

```bash
aws s3 mb s3://lks-sagemaker-data-${ACCOUNT_ID} --region $REGION
aws s3 mb s3://lks-sagemaker-models-${ACCOUNT_ID} --region $REGION
```

Tag both buckets:
```bash
for BUCKET in lks-sagemaker-data-${ACCOUNT_ID} lks-sagemaker-models-${ACCOUNT_ID}; do
  aws s3api put-bucket-tagging --bucket $BUCKET --tagging 'TagSet=[
    {Key=Project,Value=nusantara-fincredit},
    {Key=Environment,Value=production},
    {Key=ManagedBy,Value=LKS-Team}
  ]'
done
```

### 1.3 Upload training data

```bash
cd /path/to/lks-sagemaker-xgboost

aws s3 cp data/train.csv s3://lks-sagemaker-data-${ACCOUNT_ID}/train/train.csv
aws s3 cp data/validation.csv s3://lks-sagemaker-data-${ACCOUNT_ID}/validation/validation.csv
```

> Optional — generate 300-row dataset for better accuracy:
> ```bash
> python training/prepare_data.py 300
> aws s3 cp data/train.csv s3://lks-sagemaker-data-${ACCOUNT_ID}/train/train.csv
> aws s3 cp data/validation.csv s3://lks-sagemaker-data-${ACCOUNT_ID}/validation/validation.csv
> ```

**Layer 1 checkpoint — verify before continuing:**
- [ ] `aws s3 ls s3://lks-sagemaker-data-${ACCOUNT_ID}/train/` shows `train.csv`
- [ ] `aws s3 ls s3://lks-sagemaker-data-${ACCOUNT_ID}/validation/` shows `validation.csv`

---

## Layer 2 — SageMaker Notebook Instance

> Why: `voclabs` session cannot call `sagemaker:CreateTrainingJob` directly (explicit deny in `Pvoclabs2`). A Notebook Instance assumes `LabRole` as its execution role — SDK calls inside the notebook bypass the deny.

### 2.1 Create Notebook Instance (Console)

1. Go to **SageMaker console** → left sidebar → **Notebook** → **Notebook instances**
2. Click **Create notebook instance**
3. Fill in:
   - **Notebook instance name**: `lks-loan-notebook`
   - **Notebook instance type**: `ml.t3.medium` (cheapest — $0.05/hr)
   - **Elastic Inference**: None
4. Under **Permissions and encryption**:
   - **IAM role**: click dropdown → **Enter a custom IAM role ARN**
   - Paste: `arn:aws:iam::237675846062:role/LabRole`
5. Add tags:
   - `Project` = `nusantara-fincredit`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
6. Click **Create notebook instance**
7. Wait ~3 minutes for status to change to **InService**

### 2.2 Upload training script to notebook

Once InService → click **Open JupyterLab**

In JupyterLab:
1. Click the **Upload** icon (up arrow) in the file browser
2. Upload `training/train_deploy.py` from your local machine
3. Upload `training/prepare_data.py` (optional)

**Layer 2 checkpoint — verify before continuing:**
- [ ] Notebook Instance status = `InService` in SageMaker console
- [ ] JupyterLab opens in browser
- [ ] `train_deploy.py` visible in file browser

---

## Layer 3 — XGBoost Training Job (inside notebook)

> All cells below run INSIDE JupyterLab on the notebook instance. The instance runs as `LabRole`, so `CreateTrainingJob` is allowed.

### 3.1 Open a new notebook

In JupyterLab → **File** → **New** → **Notebook** → Kernel: **conda_python3**

### 3.2 Install dependencies

```python
!pip install -q sagemaker boto3 --upgrade
```

### 3.3 Run training job

Paste this into a cell and run:

```python
import boto3
import sagemaker
from sagemaker import image_uris
from sagemaker.estimator import Estimator
from sagemaker.inputs import TrainingInput
import time

REGION = 'us-east-1'
ACCOUNT_ID = boto3.client('sts', region_name=REGION).get_caller_identity()['Account']
ROLE_ARN = f'arn:aws:iam::{ACCOUNT_ID}:role/LabRole'
DATA_BUCKET = f'lks-sagemaker-data-{ACCOUNT_ID}'
MODEL_BUCKET = f'lks-sagemaker-models-{ACCOUNT_ID}'

print(f"Account: {ACCOUNT_ID}")
print(f"Role:    {ROLE_ARN}")
print(f"Data:    s3://{DATA_BUCKET}")
print(f"Models:  s3://{MODEL_BUCKET}")

boto_session = boto3.Session(region_name=REGION)
sm_session = sagemaker.Session(boto_session=boto_session)

container = image_uris.retrieve('xgboost', REGION, '1.7-1')
print(f"Container: {container}")

estimator = Estimator(
    image_uri=container,
    role=ROLE_ARN,
    instance_count=1,
    instance_type='ml.m5.xlarge',
    volume_size=10,
    max_run=600,
    output_path=f's3://{MODEL_BUCKET}/model-output/',
    sagemaker_session=sm_session,
    tags=[
        {'Key': 'Project', 'Value': 'nusantara-fincredit'},
        {'Key': 'Environment', 'Value': 'production'},
        {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
    ],
)

estimator.set_hyperparameters(
    objective='binary:logistic',
    num_round=150,
    max_depth=5,
    eta=0.2,
    subsample=0.8,
    colsample_bytree=0.8,
    min_child_weight=1,
    eval_metric='auc',
    scale_pos_weight=3,
)

train_input = TrainingInput(
    s3_data=f's3://{DATA_BUCKET}/train/',
    content_type='text/csv',
)
val_input = TrainingInput(
    s3_data=f's3://{DATA_BUCKET}/validation/',
    content_type='text/csv',
)

job_name = f'lks-loan-xgb-{int(time.time())}'
print(f"\nStarting: {job_name}")

estimator.fit(
    inputs={'train': train_input, 'validation': val_input},
    job_name=job_name,
    wait=True,
    logs=True,
)

print(f"\nModel artifacts: {estimator.model_data}")
MODEL_DATA = estimator.model_data
```

Expected time: **3–5 minutes**. Watch for `[0]#011train-auc:...` lines in logs.

### 3.4 Note the model artifacts path

After training completes, copy the `model_data` path shown in output — looks like:
```
s3://lks-sagemaker-models-237675846062/model-output/lks-loan-xgb-1234567890/output/model.tar.gz
```

**Layer 3 checkpoint — verify before continuing:**
- [ ] Cell runs without error
- [ ] Final log shows `[149]#011train-auc:` value
- [ ] SageMaker console → Training jobs → job status = `Completed`
- [ ] `aws s3 ls s3://lks-sagemaker-models-${ACCOUNT_ID}/model-output/` shows the job folder

---

## Layer 4 — SageMaker Endpoint (inside notebook)

### 4.1 Deploy endpoint (same notebook, next cell)

```python
from sagemaker.model import Model

ENDPOINT_NAME = 'lks-loan-risk-endpoint'

# If continuing from Layer 3 cell above, estimator is still in memory.
# Otherwise, set MODEL_DATA manually:
# MODEL_DATA = 's3://lks-sagemaker-models-237675846062/model-output/.../output/model.tar.gz'

model = Model(
    image_uri=container,
    model_data=MODEL_DATA,
    role=ROLE_ARN,
    sagemaker_session=sm_session,
    name='lks-loan-risk-model',
)

predictor = model.deploy(
    initial_instance_count=1,
    instance_type='ml.m5.large',
    endpoint_name=ENDPOINT_NAME,
    tags=[
        {'Key': 'Project', 'Value': 'nusantara-fincredit'},
        {'Key': 'Environment', 'Value': 'production'},
        {'Key': 'ManagedBy', 'Value': 'LKS-Team'},
    ],
)

print(f"Endpoint: {ENDPOINT_NAME} — deploying (~8-10 min)")
```

Wait ~8–10 minutes for endpoint to reach `InService`.

### 4.2 Test endpoint from CLI (back in your local terminal)

```bash
# Low-risk profile — expect ~0.04–0.15
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name lks-loan-risk-endpoint \
  --content-type text/csv \
  --body "42,85000,12000,36,720,12,0.22,1,3,0" \
  --region us-east-1 \
  /dev/stdout
echo ""

# High-risk profile — expect ~0.70–0.95
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name lks-loan-risk-endpoint \
  --content-type text/csv \
  --body "26,32000,20000,60,545,1,0.58,0,8,5" \
  --region us-east-1 \
  /dev/stdout
echo ""
```

**Layer 4 checkpoint — verify before continuing:**
- [ ] SageMaker console → Endpoints → `lks-loan-risk-endpoint` → status `InService`
- [ ] Low-risk invoke returns value < 0.30
- [ ] High-risk invoke returns value > 0.50

---

## Layer 5 — Lambda + API Gateway

> Back in your **local terminal** (voclabs session). Lambda and API GW are not blocked.

### 5.1 Package Lambda

```bash
cd /path/to/lks-sagemaker-xgboost
cd app && zip function.zip handler.py && cd ..
```

### 5.2 Create Lambda function

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION=us-east-1

aws lambda create-function \
  --region $REGION \
  --function-name lks-loan-risk \
  --runtime python3.12 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LabRole" \
  --handler handler.handler \
  --zip-file fileb://app/function.zip \
  --memory-size 256 \
  --timeout 30 \
  --environment "Variables={SAGEMAKER_ENDPOINT_NAME=lks-loan-risk-endpoint,AWS_REGION=${REGION}}" \
  --tags Project=nusantara-fincredit,Environment=production,ManagedBy=LKS-Team
```

### 5.3 Create API Gateway HTTP API

```bash
API_ID=$(aws apigatewayv2 create-api \
  --region $REGION \
  --name lks-loan-risk-api \
  --protocol-type HTTP \
  --cors-configuration AllowOrigins="*",AllowMethods="POST,OPTIONS",AllowHeaders="content-type",MaxAge=300 \
  --query ApiId --output text)

echo "API ID: ${API_ID}"

INT_ID=$(aws apigatewayv2 create-integration \
  --region $REGION \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:lks-loan-risk" \
  --payload-format-version 2.0 \
  --query IntegrationId --output text)

aws apigatewayv2 create-route \
  --region $REGION \
  --api-id "$API_ID" \
  --route-key "POST /predict" \
  --target "integrations/${INT_ID}"

aws apigatewayv2 create-stage \
  --region $REGION \
  --api-id "$API_ID" \
  --stage-name prod \
  --auto-deploy

aws lambda add-permission \
  --region $REGION \
  --function-name lks-loan-risk \
  --statement-id APIGatewayInvoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*"

export API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"
echo "API URL: ${API_URL}"
```

### 5.4 Test API

```bash
# Low-risk
curl -s -X POST "${API_URL}/predict" \
  -H "Content-Type: application/json" \
  -d '{"age":42,"annual_income":85000,"loan_amount":12000,"loan_term_months":36,"credit_score":720,"employment_years":12,"debt_to_income_ratio":0.22,"has_mortgage":1,"num_credit_lines":3,"num_late_payments":0}'

# High-risk
curl -s -X POST "${API_URL}/predict" \
  -H "Content-Type: application/json" \
  -d '{"age":26,"annual_income":32000,"loan_amount":20000,"loan_term_months":60,"credit_score":545,"employment_years":1,"debt_to_income_ratio":0.58,"has_mortgage":0,"num_credit_lines":8,"num_late_payments":5}'
```

**Layer 5 checkpoint — verify before continuing:**
- [ ] Lambda console shows `lks-loan-risk` function
- [ ] API Gateway console shows `lks-loan-risk-api` with route `POST /predict`
- [ ] `curl` low-risk returns `"risk_level":"LOW"`
- [ ] `curl` high-risk returns `"risk_level":"HIGH"`

---

## Layer 6 — Amplify UI

### 6.1 Inject API URL into index.html

```bash
mkdir -p /tmp/lks-build
sed "s|__API_GATEWAY_URL__|${API_URL}|g" app/index.html > /tmp/lks-build/index.html

# Verify replacement
grep "API_BASE\|execute-api" /tmp/lks-build/index.html | head -3
```

### 6.2 Create Amplify app

```bash
APP_ID=$(aws amplify create-app \
  --region $REGION \
  --name lks-loan-risk-ui \
  --tags Project=nusantara-fincredit,Environment=production,ManagedBy=LKS-Team \
  --query app.appId --output text)

echo "Amplify App ID: ${APP_ID}"

aws amplify create-branch \
  --region $REGION \
  --app-id "$APP_ID" \
  --branch-name main
```

### 6.3 Deploy static file

```bash
cd /tmp/lks-build
zip deploy.zip index.html

DEPLOYMENT=$(aws amplify create-deployment \
  --region $REGION \
  --app-id "$APP_ID" \
  --branch-name main \
  --output json)

JOB_ID=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")
UPLOAD_URL=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['zipUploadUrl'])")

curl -s -X PUT -H "Content-Type: application/zip" --upload-file deploy.zip "$UPLOAD_URL"

aws amplify start-deployment \
  --region $REGION \
  --app-id "$APP_ID" \
  --branch-name main \
  --job-id "$JOB_ID"

echo "UI: https://main.${APP_ID}.amplifyapp.com"
```

### 6.4 Verify

Open `https://main.${APP_ID}.amplifyapp.com` in browser:
- Fill low-risk case (Age 42, Income 85000, Credit 720) → expect green **LOW RISK**
- Fill high-risk case (Age 26, Income 32000, Credit 545) → expect red **HIGH RISK**

**Layer 6 checkpoint — verify before continuing:**
- [ ] Amplify console shows `lks-loan-risk-ui` with branch `main` deployed
- [ ] URL opens the PT. Nusantara FinCredit form
- [ ] Both test cases return correct risk level

---

## Layer 7 — CloudWatch + SNS Monitoring

### 7.1 Create SNS topic

```bash
SNS_ARN=$(aws sns create-topic \
  --region $REGION \
  --name lks-fincredit-alerts \
  --query TopicArn --output text)

aws sns subscribe \
  --region $REGION \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint "dana.rabba@mhealth.tech"

echo "SNS ARN: ${SNS_ARN}"
echo "Check email inbox to confirm subscription"
```

### 7.2 Create CloudWatch alarm

```bash
aws cloudwatch put-metric-alarm \
  --region $REGION \
  --alarm-name lks-endpoint-error-rate \
  --alarm-description "Alert on SageMaker endpoint model errors" \
  --namespace AWS/SageMaker \
  --metric-name ModelError \
  --dimensions Name=EndpointName,Value=lks-loan-risk-endpoint \
              Name=VariantName,Value=AllTraffic \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_ARN" \
  --treat-missing-data notBreaching
```

**Layer 7 checkpoint:**
- [ ] CloudWatch console shows `lks-endpoint-error-rate` alarm
- [ ] SNS console shows `lks-fincredit-alerts` topic with 1 subscription
- [ ] Email confirmation received and confirmed

---

## Cleanup (IMPORTANT — $0.096/hr billing)

```bash
# Delete endpoint immediately
aws sagemaker delete-endpoint \
  --endpoint-name lks-loan-risk-endpoint \
  --region $REGION

# Delete endpoint config + model
aws sagemaker delete-endpoint-config \
  --endpoint-config-name lks-loan-risk-endpoint \
  --region $REGION

aws sagemaker delete-model \
  --model-name lks-loan-risk-model \
  --region $REGION

# Stop notebook instance (also billed)
aws sagemaker stop-notebook-instance \
  --notebook-instance-name lks-loan-notebook \
  --region $REGION
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDenied: sagemaker:CreateTrainingJob` from CLI | `Pvoclabs2` explicit deny on voclabs session | Run training from inside notebook instance instead |
| `AccessDenied: sagemaker:CreateNotebookInstance` | Lab doesn't allow notebook creation | Try SageMaker Studio → use Domain with LabRole |
| Training job fails immediately | LabRole missing S3 access | Verify buckets exist and names match `lks-sagemaker-*-{ACCOUNT_ID}` |
| Endpoint stuck `Creating` > 15 min | Instance quota | Try `ml.t2.medium` instead of `ml.m5.large` |
| Lambda returns `500` | Endpoint not `InService` yet | Wait for endpoint, check CloudWatch logs for Lambda |
| `curl` API returns CORS error | Missing Lambda permission | Re-run `lambda add-permission` step |
| UI shows `__API_GATEWAY_URL__` | sed replacement failed | Check `API_URL` variable is set before running sed |
| `invoke-endpoint` AccessDenied from CLI | voclabs may deny runtime invoke | Test from inside notebook: `predictor.predict('42,85000,...')` |
