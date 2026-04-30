# Kunci Jawaban – ML Inference API: Loan Default Risk Prediction

---

## Task 1 – Setup S3 Buckets

### Step 1: Create two S3 buckets

**Console:**
1. S3 → Create bucket → **`lks-sagemaker-data-{ACCOUNT_ID}`** → Region ap-southeast-1 → SSE-S3 → block all public access
2. Repeat for **`lks-sagemaker-models-{ACCOUNT_ID}`**
3. Add tags to both: `Project=nusantara-fincredit`, `Environment=production`, `ManagedBy=LKS-Team`

**CLI (run script):**
```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
bash scripts/01-setup-s3.sh
```

### Step 2: Upload training data

```bash
aws s3 cp data/train.csv \
  s3://lks-sagemaker-data-${ACCOUNT_ID}/train/train.csv

aws s3 cp data/validation.csv \
  s3://lks-sagemaker-data-${ACCOUNT_ID}/validation/validation.csv
```

> **Optional – generate more training data for better accuracy:**
> ```bash
> python training/prepare_data.py 300
> # Then re-upload the generated data/train.csv and data/validation.csv
> ```

---

## Task 2 – Create IAM Roles

### Step 1: Create LKS-SageMakerRole

**Console:**
1. IAM → Roles → Create role
2. Trusted entity: **AWS service → SageMaker**
3. Role name: `LKS-SageMakerRole`
4. Attach managed policy: `AmazonSageMakerFullAccess`
5. Add inline policy → paste `iam/sagemaker-role-policy.json` → policy name: `LKS-SageMakerS3Policy`
6. Add tags

**CLI:**
```bash
aws iam create-role \
  --role-name LKS-SageMakerRole \
  --assume-role-policy-document file://iam/sagemaker-role-trust.json

aws iam put-role-policy \
  --role-name LKS-SageMakerRole \
  --policy-name LKS-SageMakerS3Policy \
  --policy-document file://iam/sagemaker-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-SageMakerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess
```

### Step 2: Create LKS-LoanRiskLambdaRole

**CLI:**
```bash
aws iam create-role \
  --role-name LKS-LoanRiskLambdaRole \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }'

aws iam put-role-policy \
  --role-name LKS-LoanRiskLambdaRole \
  --policy-name LKS-LoanRiskLambdaPolicy \
  --policy-document file://iam/lambda-role-policy.json

aws iam attach-role-policy \
  --role-name LKS-LoanRiskLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

---

## Task 3 – Train the XGBoost Model

### Step 1: Install SageMaker SDK

```bash
pip install sagemaker boto3
```

### Step 2: Run training job

**Using the provided script (recommended):**
```bash
export AWS_REGION=ap-southeast-1
python training/train_deploy.py --train
```

**Console alternative:**
1. SageMaker console → Training → Training jobs → Create training job
2. Job name: `lks-loan-xgb-manual`
3. Algorithm: **Amazon SageMaker built-in algorithm → XGBoost**
4. XGBoost version: `1.7-1`
5. Instance type: `ml.m5.xlarge`, count: 1
6. IAM role: `LKS-SageMakerRole`
7. Hyperparameters:

| Parameter | Value |
|---|---|
| `objective` | `binary:logistic` |
| `num_round` | `150` |
| `max_depth` | `5` |
| `eta` | `0.2` |
| `subsample` | `0.8` |
| `colsample_bytree` | `0.8` |
| `eval_metric` | `auc` |
| `scale_pos_weight` | `3` |

8. Input data:
   - Channel name: `train`, S3 location: `s3://lks-sagemaker-data-{account}/train/`, content type: `text/csv`
   - Channel name: `validation`, S3 location: `s3://lks-sagemaker-data-{account}/validation/`, content type: `text/csv`
9. Output path: `s3://lks-sagemaker-models-{account}/model-output/`

### Step 3: Monitor training

```bash
# Watch training job status
aws sagemaker describe-training-job \
  --training-job-name <job-name> \
  --region ap-southeast-1 \
  --query '{Status:TrainingJobStatus,AUC:FinalMetricDataList}'
```

Expected training time: 3–5 minutes. Final validation AUC should be > 0.85.

---

## Task 4 – Deploy SageMaker Endpoint

### Step 1: Create model

**Console:**
1. SageMaker → Models → Create model
2. Model name: `lks-loan-risk-model`
3. IAM role: `LKS-SageMakerRole`
4. Container: XGBoost 1.7-1 image URI (retrieved from training job)
5. Model artifacts: S3 path to `model.tar.gz` from training output

**SDK (via train_deploy.py):**
```bash
python training/train_deploy.py --deploy
```

When prompted, paste the model artifacts S3 URI shown at the end of training output:
```
s3://lks-sagemaker-models-{account}/model-output/{job-name}/output/model.tar.gz
```

### Step 2: Create endpoint configuration

**Console:**
1. SageMaker → Endpoints → Endpoint configurations → Create
2. Name: `lks-loan-risk-config`
3. Production variants → Add model: `lks-loan-risk-model`
4. Instance type: `ml.m5.large`, initial count: 1

### Step 3: Create endpoint

**Console:**
1. SageMaker → Endpoints → Create endpoint
2. Endpoint name: `lks-loan-risk-endpoint`
3. Configuration: `lks-loan-risk-config`
4. Wait for status → **InService** (~8–10 minutes)

**CLI test after InService:**
```bash
# Low-risk profile: expect ~0.04–0.15
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name lks-loan-risk-endpoint \
  --content-type text/csv \
  --body "42,85000,12000,36,720,12,0.22,1,3,0" \
  --region ap-southeast-1 /dev/stdout
echo ""

# High-risk profile: expect ~0.70–0.95
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name lks-loan-risk-endpoint \
  --content-type text/csv \
  --body "26,32000,20000,60,545,1,0.58,0,8,5" \
  --region ap-southeast-1 /dev/stdout
echo ""
```

---

## Task 5 – Deploy Lambda + API Gateway

### Step 1: Package and create Lambda function

Lambda's only job here is to proxy inference requests — it does **not** serve HTML.

**CLI:**
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd app && zip function.zip handler.py && cd ..

aws lambda create-function \
  --region ap-southeast-1 \
  --function-name lks-loan-risk \
  --runtime python3.12 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-LoanRiskLambdaRole" \
  --handler handler.handler \
  --zip-file fileb://app/function.zip \
  --memory-size 256 \
  --timeout 30 \
  --environment "Variables={SAGEMAKER_ENDPOINT_NAME=lks-loan-risk-endpoint,AWS_REGION=ap-southeast-1}"
```

**Console:**
1. Lambda → Create function → Author from scratch
2. Name: `lks-loan-risk`, Runtime: Python 3.12
3. Role: `LKS-LoanRiskLambdaRole`, Memory: 256 MB, Timeout: 30 s
4. Upload `app/function.zip`, Handler: `handler.handler`
5. Environment variables: `SAGEMAKER_ENDPOINT_NAME=lks-loan-risk-endpoint`, `AWS_REGION=ap-southeast-1`

### Step 2: Create API Gateway HTTP API

**Console:**
1. API Gateway → Create API → **HTTP API** → Build
2. Integration: Lambda → `lks-loan-risk`
3. API name: `lks-loan-risk-api`
4. Route: `POST /predict`
5. Stage: `prod` (auto-deploy)
6. After creation → CORS settings:
   - Allow origins: `*`
   - Allow methods: `POST, OPTIONS`
   - Allow headers: `content-type`

**CLI:**
```bash
# Create HTTP API with CORS
API_ID=$(aws apigatewayv2 create-api \
  --region ap-southeast-1 \
  --name lks-loan-risk-api \
  --protocol-type HTTP \
  --cors-configuration AllowOrigins="*",AllowMethods="POST,OPTIONS",AllowHeaders="content-type",MaxAge=300 \
  --query ApiId --output text)

echo "API ID: ${API_ID}"

# Lambda integration
INT_ID=$(aws apigatewayv2 create-integration \
  --region ap-southeast-1 \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:ap-southeast-1:${ACCOUNT_ID}:function:lks-loan-risk" \
  --payload-format-version 2.0 \
  --query IntegrationId --output text)

# Route
aws apigatewayv2 create-route \
  --region ap-southeast-1 \
  --api-id "$API_ID" \
  --route-key "POST /predict" \
  --target "integrations/${INT_ID}"

# Stage
aws apigatewayv2 create-stage \
  --region ap-southeast-1 \
  --api-id "$API_ID" \
  --stage-name prod \
  --auto-deploy

# Allow API GW to invoke Lambda
aws lambda add-permission \
  --region ap-southeast-1 \
  --function-name lks-loan-risk \
  --statement-id APIGatewayInvoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:ap-southeast-1:${ACCOUNT_ID}:${API_ID}/*/*"

# Save the invoke URL
API_URL="https://${API_ID}.execute-api.ap-southeast-1.amazonaws.com/prod"
echo "Invoke URL: ${API_URL}"
export API_URL
```

### Step 3: Test the API directly

```bash
# Low-risk profile (expected: LOW, ~5-15%)
curl -X POST "${API_URL}/predict" \
  -H "Content-Type: application/json" \
  -d '{"age":42,"annual_income":85000,"loan_amount":12000,"loan_term_months":36,"credit_score":720,"employment_years":12,"debt_to_income_ratio":0.22,"has_mortgage":1,"num_credit_lines":3,"num_late_payments":0}'

# High-risk profile (expected: HIGH, ~70-95%)
curl -X POST "${API_URL}/predict" \
  -H "Content-Type: application/json" \
  -d '{"age":26,"annual_income":32000,"loan_amount":20000,"loan_term_months":60,"credit_score":545,"employment_years":1,"debt_to_income_ratio":0.58,"has_mortgage":0,"num_credit_lines":8,"num_late_payments":5}'
```

---

## Task 6 – Deploy UI on AWS Amplify

**Why Amplify?** The UI is a static HTML file. Amplify provides CDN-backed HTTPS hosting with a `*.amplifyapp.com` domain in seconds — no S3 bucket website config, no CloudFront distribution, no ACM certificate setup needed.

### Step 1: Inject the API Gateway URL into index.html

The placeholder `__API_GATEWAY_URL__` in `app/index.html` must be replaced with the real API Gateway URL before deploying.

```bash
mkdir -p /tmp/lks-build
sed "s|__API_GATEWAY_URL__|${API_URL}|g" app/index.html > /tmp/lks-build/index.html

# Verify the replacement worked
grep "API_BASE" /tmp/lks-build/index.html
# Should show: const API_BASE = 'https://xxx.execute-api.ap-southeast-1.amazonaws.com/prod';
```

### Step 2: Create Amplify app and branch

**Console:**
1. AWS Amplify → New app → **Host web app**
2. Deploy without Git provider → **Deploy without Git**
3. App name: `lks-loan-risk-ui`
4. Environment name: `main`
5. Drag-and-drop the zip file containing `index.html`
6. Save and deploy

**CLI:**
```bash
# Create Amplify app
APP_ID=$(aws amplify create-app \
  --region ap-southeast-1 \
  --name lks-loan-risk-ui \
  --query app.appId --output text)

echo "Amplify App ID: ${APP_ID}"

# Create branch
aws amplify create-branch \
  --region ap-southeast-1 \
  --app-id "$APP_ID" \
  --branch-name main
```

### Step 3: Deploy the static file

```bash
cd /tmp/lks-build
zip deploy.zip index.html

# Create deployment (get pre-signed S3 URL)
DEPLOYMENT=$(aws amplify create-deployment \
  --region ap-southeast-1 \
  --app-id "$APP_ID" \
  --branch-name main)

JOB_ID=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")
UPLOAD_URL=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['zipUploadUrl'])")

# Upload zip to the pre-signed URL
curl -X PUT -H "Content-Type: application/zip" --upload-file deploy.zip "$UPLOAD_URL"

# Kick off the deployment
aws amplify start-deployment \
  --region ap-southeast-1 \
  --app-id "$APP_ID" \
  --branch-name main \
  --job-id "$JOB_ID"

echo "UI will be live at: https://main.${APP_ID}.amplifyapp.com"
```

### Step 4: Verify the UI

1. Open `https://main.{APP_ID}.amplifyapp.com` in browser
2. The loan assessment form should load with the PT. Nusantara FinCredit header
3. Test with the **Low Risk** case (Age 42, Income 85000, Credit 720): expect green **LOW RISK** result
4. Test with the **High Risk** case (Age 26, Income 32000, Credit 545): expect red **HIGH RISK** result

---

## Task 6 – Setup Monitoring

### Step 1: Create SNS topic

```bash
SNS_ARN=$(aws sns create-topic \
  --region ap-southeast-1 \
  --name lks-fincredit-alerts \
  --query TopicArn --output text)

aws sns subscribe \
  --region ap-southeast-1 \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint "your@email.com"
# Confirm the subscription from your inbox
```

### Step 2: Create CloudWatch alarm for endpoint errors

```bash
aws cloudwatch put-metric-alarm \
  --region ap-southeast-1 \
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

### Step 3: Enable endpoint data capture (bonus)

**Console:**
1. SageMaker → Endpoints → `lks-loan-risk-endpoint` → Edit
2. Data capture → Enable
3. S3 location: `s3://lks-sagemaker-models-{account}/endpoint-capture/`
4. Capture input + output: 100%

This stores every inference request and response in S3 for auditing and model monitoring.

---

## Task 7 – Cleanup (IMPORTANT)

```bash
# Delete endpoint immediately to stop billing (~$0.096/hr)
aws sagemaker delete-endpoint \
  --endpoint-name lks-loan-risk-endpoint \
  --region ap-southeast-1

# Optional: delete endpoint config and model
aws sagemaker delete-endpoint-config \
  --endpoint-config-name lks-loan-risk-config \
  --region ap-southeast-1

# Delete Lambda (no cost, but good practice)
aws lambda delete-function \
  --function-name lks-loan-risk \
  --region ap-southeast-1

# Or use the script:
python training/train_deploy.py --delete
```

---

## Summary Checklist

| Task | Resource | Free Tier |
|---|---|---|
| S3 data bucket | `lks-sagemaker-data-{account}` | ✓ |
| S3 model bucket | `lks-sagemaker-models-{account}` | ✓ |
| IAM role — SageMaker | `LKS-SageMakerRole` | ✓ |
| IAM role — Lambda | `LKS-LoanRiskLambdaRole` | ✓ |
| SageMaker Training Job | XGBoost 1.7-1, ml.m5.xlarge | ⚠️ ~$0.02 (or 2-mo trial) |
| SageMaker Model | `lks-loan-risk-model` | ✓ |
| SageMaker Endpoint Config | `lks-loan-risk-config` | ✓ |
| SageMaker Endpoint | `lks-loan-risk-endpoint`, ml.m5.large | ⚠️ $0.096/hr — DELETE AFTER USE |
| Lambda function | `lks-loan-risk` (Python 3.12, 256MB) | ✓ |
| API Gateway HTTP API | `lks-loan-risk-api`, route `POST /predict` | ✓ |
| Amplify Hosting | `lks-loan-risk-ui`, branch `main`, CDN URL | ✓ |
| SNS topic | `lks-fincredit-alerts` | ✓ |
| CloudWatch alarm | `lks-endpoint-error-rate` | ✓ |

> **Total exam cost estimate**: < $0.10 if endpoint is deleted within 1 hour.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Training job fails immediately | IAM role missing S3 or ECR permissions | Verify `LKS-SageMakerRole` has `AmazonSageMakerFullAccess` |
| Endpoint status `Failed` | Instance quota exceeded | Use a different instance type or request quota increase |
| Lambda returns `500` | Endpoint not `InService` yet | Wait for endpoint to reach `InService` state |
| UI shows wrong probability | Feature order mismatch | Verify `FEATURE_KEYS` in `handler.py` matches training column order |
| `AccessDenied` on invoke | Lambda role missing `sagemaker:InvokeEndpoint` | Check `iam/lambda-role-policy.json` is applied |
| XGBoost AUC < 0.7 | Too few training samples | Run `prepare_data.py 500` and retrain |
