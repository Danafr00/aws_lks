# Step-by-Step: ML Pipeline + ECS Inference — Build Layer by Layer

**Goal**: Build a fraud detection system for PT. Nusantara PayTech — data pipeline feeds SageMaker training, ECS Fargate serves inference 24/7.  
**Approach**: Build one layer at a time. Verify before moving forward.  
**Region**: ap-southeast-1 | **Cost warning**: SageMaker endpoint $0.096/hr, Fargate ~$0.02/hr — delete after use.

---

## Architecture

```
DATA PIPELINE
S3 (raw CSV) → SQS → Lambda (feature engineering) → S3 (features)
  → Glue ETL → S3 (Parquet) → Athena → SageMaker Training → SageMaker Endpoint

INFERENCE API (24/7)
Amplify (UI) → API Gateway → ALB → ECS Fargate (FastAPI) → SageMaker Endpoint
                                                          → DynamoDB (audit)
                                                          → S3 (results)
```

## Layers

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | S3 + SQS + Lambda feature engineering | Upload CSV → features appear in S3 |
| **2** | Glue ETL + Athena | Athena query returns processed rows |
| **3** | SageMaker Training + Endpoint | Direct invoke returns fraud score |
| **4** | ECR + ECS Fargate + ALB | `curl ALB/predict` returns prediction JSON |
| **5** | API Gateway + DynamoDB + Amplify | Full end-to-end via web UI |

---

## Variables (set once, keep terminal open)

```bash
export AWS_REGION=ap-southeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export RAW_BUCKET="lks-paytech-raw-${ACCOUNT_ID}"
export FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"
export PROCESSED_BUCKET="lks-paytech-processed-${ACCOUNT_ID}"
export RESULTS_BUCKET="lks-paytech-results-${ACCOUNT_ID}"
echo "Account: $ACCOUNT_ID"
```

---

## Layer 1 — S3 + SQS + Lambda

### 1.1 S3 Buckets

```bash
for BUCKET in $RAW_BUCKET $FEATURES_BUCKET $PROCESSED_BUCKET $RESULTS_BUCKET; do
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION
  echo "Created: $BUCKET"
done
```

### 1.2 SQS Queue

```bash
QUEUE_URL=$(aws sqs create-queue \
  --queue-name lks-paytech-queue \
  --attributes VisibilityTimeout=300,MessageRetentionPeriod=86400 \
  --query 'QueueUrl' --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

echo "Queue: $QUEUE_ARN"

# Allow S3 to send messages to SQS
aws sqs set-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attributes "Policy={\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"s3.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"${QUEUE_ARN}\",\"Condition\":{\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:s3:::${RAW_BUCKET}\"}}}]}"
```

### 1.3 S3 Event Notification → SQS

```bash
aws s3api put-bucket-notification-configuration \
  --bucket "$RAW_BUCKET" \
  --notification-configuration "{
    \"QueueConfigurations\": [{
      \"QueueArn\": \"${QUEUE_ARN}\",
      \"Events\": [\"s3:ObjectCreated:*\"],
      \"Filter\": {
        \"Key\": {\"FilterRules\": [
          {\"Name\": \"prefix\", \"Value\": \"data/\"},
          {\"Name\": \"suffix\", \"Value\": \".csv\"}
        ]}
      }
    }]
  }"
echo "S3 → SQS notification configured"
```

### 1.4 IAM Role for Lambda

```bash
cat > /tmp/lambda-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role \
  --role-name LKS-FeatureLambdaRole \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam put-role-policy \
  --role-name LKS-FeatureLambdaRole \
  --policy-name LKS-FeatureLambdaPolicy \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
       \"Resource\":[\"arn:aws:s3:::${RAW_BUCKET}\",\"arn:aws:s3:::${RAW_BUCKET}/*\"]},
      {\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",
       \"Resource\":\"arn:aws:s3:::${FEATURES_BUCKET}/*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],
       \"Resource\":\"${QUEUE_ARN}\"},
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
       \"Resource\":\"arn:aws:logs:*:*:*\"}
    ]
  }"

LAMBDA_ROLE_ARN=$(aws iam get-role \
  --role-name LKS-FeatureLambdaRole \
  --query 'Role.Arn' --output text)
echo "Lambda Role: $LAMBDA_ROLE_ARN"
```

### 1.5 Deploy Lambda

```bash
cd app/feature_lambda/
zip /tmp/lks-feature-trigger.zip handler.py
cd -

aws lambda create-function \
  --function-name lks-feature-trigger \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$LAMBDA_ROLE_ARN" \
  --zip-file fileb:///tmp/lks-feature-trigger.zip \
  --timeout 300 \
  --memory-size 256 \
  --environment "Variables={FEATURES_BUCKET=${FEATURES_BUCKET}}" \
  --region $AWS_REGION

aws lambda wait function-active-v2 --function-name lks-feature-trigger

# Connect SQS to Lambda
aws lambda create-event-source-mapping \
  --function-name lks-feature-trigger \
  --event-source-arn "$QUEUE_ARN" \
  --batch-size 10
echo "Lambda deployed and connected to SQS"
```

### 1.6 Test Layer 1

```bash
# Upload sample CSV to raw bucket
aws s3 cp data/sample_transactions.csv \
  "s3://${RAW_BUCKET}/data/sample_transactions.csv"

echo "Waiting 30s for SQS → Lambda → S3..."
sleep 30

# Check features file appeared
aws s3 ls "s3://${FEATURES_BUCKET}/features/"
# Expected: features/sample_transactions.csv
```

**Layer 1 checkpoint:**
- [ ] `aws s3 ls s3://$FEATURES_BUCKET/features/` shows the processed file
- [ ] `aws lambda get-function --function-name lks-feature-trigger` returns function details

---

## Layer 2 — Glue ETL + Athena

### 2.1 Glue IAM Role

```bash
cat > /tmp/glue-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role \
  --role-name LKS-GlueETLRole \
  --assume-role-policy-document file:///tmp/glue-trust.json

aws iam attach-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

aws iam put-role-policy \
  --role-name LKS-GlueETLRole \
  --policy-name LKS-GlueS3Policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:ListBucket\"],
       \"Resource\":[\"arn:aws:s3:::${FEATURES_BUCKET}/*\",\"arn:aws:s3:::${PROCESSED_BUCKET}\",\"arn:aws:s3:::${PROCESSED_BUCKET}/*\"]}
    ]
  }"

GLUE_ROLE_ARN=$(aws iam get-role --role-name LKS-GlueETLRole --query 'Role.Arn' --output text)
echo "Glue Role: $GLUE_ROLE_ARN"
```

### 2.2 Upload ETL Script + Create Glue Job

```bash
aws s3 cp glue/etl_job.py "s3://${PROCESSED_BUCKET}/scripts/etl_job.py"

aws glue create-database \
  --database-input '{"Name":"lks_paytech_db"}'

aws glue create-job \
  --name lks-etl-paytech \
  --role "$GLUE_ROLE_ARN" \
  --command "Name=glueetl,ScriptLocation=s3://${PROCESSED_BUCKET}/scripts/etl_job.py,PythonVersion=3" \
  --default-arguments "{
    \"--JOB_NAME\": \"lks-etl-paytech\",
    \"--S3_FEATURES_PATH\": \"s3://${FEATURES_BUCKET}/features/\",
    \"--S3_OUTPUT_PATH\": \"s3://${PROCESSED_BUCKET}/parquet/\"
  }" \
  --glue-version "4.0" \
  --worker-type G.025X \
  --number-of-workers 2

echo "Running Glue ETL job..."
RUN_ID=$(aws glue start-job-run \
  --job-name lks-etl-paytech \
  --query 'JobRunId' --output text)

# Poll until complete
while true; do
  STATUS=$(aws glue get-job-run \
    --job-name lks-etl-paytech \
    --run-id $RUN_ID \
    --query 'JobRun.JobRunState' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "SUCCEEDED" ] && break
  [ "$STATUS" = "FAILED" ] && echo "Glue job FAILED" && exit 1
  sleep 20
done
echo "Glue ETL complete!"
```

### 2.3 Crawler + Athena

```bash
aws glue create-crawler \
  --name lks-crawler-paytech \
  --role "$GLUE_ROLE_ARN" \
  --database-name lks_paytech_db \
  --targets "S3Targets=[{Path: \"s3://${PROCESSED_BUCKET}/parquet/\"}]"

aws glue start-crawler --name lks-crawler-paytech
echo "Waiting for crawler... (~2 min)"
while true; do
  STATE=$(aws glue get-crawler --name lks-crawler-paytech \
    --query 'Crawler.State' --output text)
  [ "$STATE" = "READY" ] && break
  sleep 15
done

aws athena create-work-group \
  --name lks-paytech-wg \
  --configuration "ResultConfiguration={OutputLocation=s3://${PROCESSED_BUCKET}/athena-results/}"

# Test query
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM lks_paytech_db.parquet LIMIT 1" \
  --work-group lks-paytech-wg \
  --query 'QueryExecutionId' --output text)
sleep 5
aws athena get-query-results --query-execution-id $QUERY_ID \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' --output text
```

**Layer 2 checkpoint:**
- [ ] Glue job status: SUCCEEDED
- [ ] Athena query returns a row count

---

## Layer 3 — SageMaker Training + Endpoint

### 3.1 SageMaker IAM Role

```bash
cat > /tmp/sm-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sagemaker.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role \
  --role-name LKS-SageMakerRole \
  --assume-role-policy-document file:///tmp/sm-trust.json

aws iam attach-role-policy \
  --role-name LKS-SageMakerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

SM_ROLE_ARN=$(aws iam get-role --role-name LKS-SageMakerRole --query 'Role.Arn' --output text)
echo "SageMaker Role: $SM_ROLE_ARN"
```

### 3.2 Upload Training Data + Train

```bash
aws s3 cp data/train.csv "s3://${PROCESSED_BUCKET}/training/train.csv"
aws s3 cp data/validation.csv "s3://${PROCESSED_BUCKET}/training/validation.csv"

# XGBoost built-in container URI
IMAGE_URI="683313688378.dkr.ecr.${AWS_REGION}.amazonaws.com/sagemaker-xgboost:1.7-1"
TRAINING_JOB="lks-paytech-training-$(date +%Y%m%d%H%M%S)"

aws sagemaker create-training-job \
  --training-job-name "$TRAINING_JOB" \
  --algorithm-specification "TrainingImage=${IMAGE_URI},TrainingInputMode=File" \
  --role-arn "$SM_ROLE_ARN" \
  --input-data-config "[
    {\"ChannelName\":\"train\",\"DataSource\":{\"S3DataSource\":{\"S3DataType\":\"S3Prefix\",\"S3Uri\":\"s3://${PROCESSED_BUCKET}/training/train.csv\",\"S3DataDistributionType\":\"FullyReplicated\"}},\"ContentType\":\"text/csv\"},
    {\"ChannelName\":\"validation\",\"DataSource\":{\"S3DataSource\":{\"S3DataType\":\"S3Prefix\",\"S3Uri\":\"s3://${PROCESSED_BUCKET}/training/validation.csv\",\"S3DataDistributionType\":\"FullyReplicated\"}},\"ContentType\":\"text/csv\"}
  ]" \
  --output-data-config "S3OutputPath=s3://${PROCESSED_BUCKET}/models/" \
  --resource-config "InstanceType=ml.m5.xlarge,InstanceCount=1,VolumeSizeInGB=10" \
  --stopping-condition "MaxRuntimeInSeconds=3600" \
  --hyper-parameters '{"objective":"binary:logistic","num_round":"150","max_depth":"5","eta":"0.2","subsample":"0.8","colsample_bytree":"0.8","eval_metric":"auc","scale_pos_weight":"4"}'

echo "Waiting for training (~5-10 min)..."
aws sagemaker wait training-job-completed-or-stopped \
  --training-job-name "$TRAINING_JOB"
echo "Training done!"

MODEL_ARTIFACT=$(aws sagemaker describe-training-job \
  --training-job-name "$TRAINING_JOB" \
  --query 'ModelArtifacts.S3ModelArtifacts' --output text)
echo "Model: $MODEL_ARTIFACT"
```

### 3.3 Create Model + Deploy Endpoint

```bash
MODEL_NAME="lks-paytech-model-$(date +%Y%m%d%H%M%S)"

aws sagemaker create-model \
  --model-name "$MODEL_NAME" \
  --primary-container "Image=${IMAGE_URI},ModelDataUrl=${MODEL_ARTIFACT}" \
  --execution-role-arn "$SM_ROLE_ARN"

aws sagemaker create-endpoint-config \
  --endpoint-config-name "${MODEL_NAME}-config" \
  --production-variants "VariantName=AllTraffic,ModelName=${MODEL_NAME},InitialInstanceCount=1,InstanceType=ml.m5.large,InitialVariantWeight=1"

aws sagemaker create-endpoint \
  --endpoint-name lks-paytech-endpoint \
  --endpoint-config-name "${MODEL_NAME}-config"

echo "Waiting for endpoint to be InService (~8 min)..."
aws sagemaker wait endpoint-in-service --endpoint-name lks-paytech-endpoint
echo "Endpoint InService!"
```

### 3.4 Test Endpoint Directly

```bash
# Test with the fraud transaction from test_predict.json
# Features: log1p(4500000)=15.32, merchant=1(electronics), hour=2, dow=0, age=45, fraud_hist=1, log1p(1200)=7.09, foreign=1, freq=18
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name lks-paytech-endpoint \
  --content-type text/csv \
  --body "15.32,1,2,0,45,1,7.09,1,18" \
  /tmp/sm-output.txt
cat /tmp/sm-output.txt
# Expected: a float close to 1.0 (high fraud probability)
```

**Layer 3 checkpoint:**
- [ ] Training job status: Completed
- [ ] Endpoint status: InService
- [ ] Direct invoke returns a float between 0 and 1

---

## Layer 4 — ECS Fargate + ALB

### 4.1 IAM Roles for ECS

```bash
cat > /tmp/ecs-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role \
  --role-name LKS-ECSTaskRole \
  --assume-role-policy-document file:///tmp/ecs-trust.json

aws iam put-role-policy \
  --role-name LKS-ECSTaskRole \
  --policy-name LKS-ECSTaskPolicy \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":\"sagemaker:InvokeEndpoint\",
       \"Resource\":\"arn:aws:sagemaker:${AWS_REGION}:${ACCOUNT_ID}:endpoint/lks-paytech-endpoint\"},
      {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:GetItem\"],
       \"Resource\":\"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/lks-paytech-predictions\"},
      {\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",
       \"Resource\":\"arn:aws:s3:::${RESULTS_BUCKET}/*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
       \"Resource\":\"arn:aws:logs:*:*:*\"}
    ]
  }"

aws iam create-role \
  --role-name LKS-ECSExecutionRole \
  --assume-role-policy-document file:///tmp/ecs-trust.json

aws iam attach-role-policy \
  --role-name LKS-ECSExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

TASK_ROLE_ARN=$(aws iam get-role --role-name LKS-ECSTaskRole --query 'Role.Arn' --output text)
EXEC_ROLE_ARN=$(aws iam get-role --role-name LKS-ECSExecutionRole --query 'Role.Arn' --output text)
echo "Task Role: $TASK_ROLE_ARN"
```

### 4.2 Build + Push Docker Image

```bash
ECR_REPO="lks-paytech-api"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

aws ecr create-repository \
  --repository-name "$ECR_REPO" \
  --image-tag-mutability MUTABLE \
  --region $AWS_REGION

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t "${ECR_REPO}:latest" app/inference_api/
docker tag "${ECR_REPO}:latest" "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"
echo "Image pushed: ${ECR_URI}:latest"
```

### 4.3 ECS Cluster + Task Definition

```bash
aws logs create-log-group --log-group-name /ecs/lks-paytech-task 2>/dev/null || true

aws ecs create-cluster \
  --cluster-name lks-paytech-cluster \
  --capacity-providers FARGATE FARGATE_SPOT

aws ecs register-task-definition \
  --family lks-paytech-task \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 512 --memory 1024 \
  --task-role-arn "$TASK_ROLE_ARN" \
  --execution-role-arn "$EXEC_ROLE_ARN" \
  --container-definitions "[{
    \"name\": \"inference-api\",
    \"image\": \"${ECR_URI}:latest\",
    \"portMappings\": [{\"containerPort\": 8080}],
    \"environment\": [
      {\"name\": \"SAGEMAKER_ENDPOINT_NAME\", \"value\": \"lks-paytech-endpoint\"},
      {\"name\": \"DYNAMODB_TABLE\", \"value\": \"lks-paytech-predictions\"},
      {\"name\": \"RESULTS_BUCKET\", \"value\": \"${RESULTS_BUCKET}\"},
      {\"name\": \"AWS_DEFAULT_REGION\", \"value\": \"${AWS_REGION}\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"/ecs/lks-paytech-task\",
        \"awslogs-region\": \"${AWS_REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    },
    \"healthCheck\": {
      \"command\": [\"CMD-SHELL\", \"curl -f http://localhost:8080/health || exit 1\"],
      \"interval\": 30, \"timeout\": 5, \"retries\": 3, \"startPeriod\": 15
    }
  }]"
echo "Task definition registered"
```

### 4.4 ALB + Security Groups + ECS Service

```bash
# Use default VPC
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SUBNET1=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${DEFAULT_VPC}" "Name=availabilityZone,Values=${AWS_REGION}a" \
  --query 'Subnets[0].SubnetId' --output text)

SUBNET2=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${DEFAULT_VPC}" "Name=availabilityZone,Values=${AWS_REGION}b" \
  --query 'Subnets[0].SubnetId' --output text)

# ALB Security Group (port 80 open)
ALB_SG=$(aws ec2 create-security-group \
  --group-name lks-paytech-alb-sg \
  --description "PayTech ALB" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0

# ECS Service Security Group (port 8080 from ALB)
ECS_SG=$(aws ec2 create-security-group \
  --group-name lks-paytech-ecs-sg \
  --description "PayTech ECS service" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "$ECS_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"

# ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name lks-paytech-alb \
  --subnets $SUBNET1 $SUBNET2 \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Target Group
TG_ARN=$(aws elbv2 create-target-group \
  --name lks-paytech-tg \
  --protocol HTTP --port 8080 \
  --vpc-id "$DEFAULT_VPC" \
  --target-type ip \
  --health-check-path /health \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}"

# ECS Service
aws ecs create-service \
  --cluster lks-paytech-cluster \
  --service-name lks-paytech-service \
  --task-definition lks-paytech-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET1},${SUBNET2}],securityGroups=[${ECS_SG}],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=inference-api,containerPort=8080"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "ALB: http://$ALB_DNS  (wait ~2 min for task to be healthy)"
```

### 4.5 Test ECS Inference

```bash
# Wait for task to be healthy
sleep 120

curl -s http://$ALB_DNS/health
# Expected: {"status":"ok","endpoint":"lks-paytech-endpoint"}

curl -s -X POST http://$ALB_DNS/predict \
  -H "Content-Type: application/json" \
  -d @data/test_predict.json | python3 -m json.tool
# Expected: fraud_score ~0.8+, label: "FRAUD"
```

**Layer 4 checkpoint:**
- [ ] `curl http://$ALB_DNS/health` returns `{"status":"ok"}`
- [ ] `POST /predict` returns JSON with `fraud_score` and `label`
- [ ] ECS service shows running count ≥ 1

---

## Layer 5 — API Gateway + DynamoDB + Amplify

### 5.1 DynamoDB Table

```bash
aws dynamodb create-table \
  --table-name lks-paytech-predictions \
  --attribute-definitions \
    AttributeName=transaction_id,AttributeType=S \
    AttributeName=timestamp,AttributeType=S \
  --key-schema \
    AttributeName=transaction_id,KeyType=HASH \
    AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION
echo "DynamoDB table created"
```

### 5.2 API Gateway HTTP API → ALB

```bash
API_ID=$(aws apigatewayv2 create-api \
  --name lks-paytech-api \
  --protocol-type HTTP \
  --cors-configuration AllowOrigins="*",AllowMethods="GET,POST,OPTIONS",AllowHeaders="Content-Type" \
  --query 'ApiId' --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${ALB_DNS}/{proxy}" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' --output text)

aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /predict" \
  --target "integrations/${INTEGRATION_ID}"

aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /health" \
  --target "integrations/${INTEGRATION_ID}"

aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
echo "API: $API_URL"

# Test via API Gateway
curl -s -X POST "${API_URL}/predict" \
  -H "Content-Type: application/json" \
  -d @data/test_predict.json | python3 -m json.tool
```

### 5.3 Verify DynamoDB Record

```bash
TXN_ID="txn-test-001"
aws dynamodb get-item \
  --table-name lks-paytech-predictions \
  --key "{\"transaction_id\":{\"S\":\"${TXN_ID}\"},\"timestamp\":{\"S\":\"$(date -u +%Y-%m-%d)\"}}" \
  2>/dev/null || \
aws dynamodb scan \
  --table-name lks-paytech-predictions \
  --limit 1
```

### 5.4 Amplify Frontend

```bash
AMPLIFY_APP_ID=$(aws amplify create-app \
  --name lks-paytech-ui \
  --query 'app.appId' --output text)

aws amplify create-branch \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main

# Inject API URL + deploy
sed "s|__API_GATEWAY_URL__|${API_URL}|g" \
  app/frontend/index.html > /tmp/index.html

cd /tmp && zip -q amplify-deploy.zip index.html && cd -

DEPLOYMENT=$(aws amplify create-deployment \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main --output json)

UPLOAD_URL=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['zipUploadUrl'])")
JOB_ID=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")

curl -s -X PUT -H "Content-Type: application/zip" \
  --data-binary @/tmp/amplify-deploy.zip "$UPLOAD_URL"

aws amplify start-deployment \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main \
  --job-id "$JOB_ID"

echo "Amplify URL: https://main.${AMPLIFY_APP_ID}.amplifyapp.com"
```

**Layer 5 checkpoint:**
- [ ] `curl $API_URL/predict` returns prediction JSON
- [ ] DynamoDB has a record with `fraud_score`
- [ ] S3 results bucket has prediction JSON file
- [ ] Amplify UI loads and submit returns result

---

## Cleanup

```bash
# 1. Delete K8s / app resources
aws amplify delete-app --app-id "$AMPLIFY_APP_ID" 2>/dev/null || true
aws apigatewayv2 delete-api --api-id "$API_ID" 2>/dev/null || true

# 2. Delete ECS
aws ecs update-service --cluster lks-paytech-cluster \
  --service lks-paytech-service --desired-count 0
aws ecs delete-service --cluster lks-paytech-cluster --service lks-paytech-service --force
aws ecs delete-cluster --cluster lks-paytech-cluster
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
sleep 30
aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
aws ec2 delete-security-group --group-id "$ECS_SG" 2>/dev/null || true
aws ec2 delete-security-group --group-id "$ALB_SG" 2>/dev/null || true

# 3. Delete SageMaker (CRITICAL — $0.096/hr)
aws sagemaker delete-endpoint --endpoint-name lks-paytech-endpoint
aws sagemaker wait endpoint-deleted --endpoint-name lks-paytech-endpoint

# 4. Delete ECR
aws ecr delete-repository --repository-name lks-paytech-api --force

# 5. Delete Glue
aws glue delete-job --job-name lks-etl-paytech
aws glue delete-crawler --name lks-crawler-paytech
aws glue delete-database --name lks_paytech_db

# 6. Delete Lambda
aws lambda delete-function --function-name lks-feature-trigger

# 7. Delete DynamoDB
aws dynamodb delete-table --table-name lks-paytech-predictions

# 8. Delete S3 buckets (must empty first)
for BUCKET in $RAW_BUCKET $FEATURES_BUCKET $PROCESSED_BUCKET $RESULTS_BUCKET; do
  aws s3 rm "s3://${BUCKET}" --recursive
  aws s3api delete-bucket --bucket "$BUCKET"
done

# 9. Delete SQS
aws sqs delete-queue --queue-url "$QUEUE_URL"

# 10. Delete IAM
for ROLE in LKS-FeatureLambdaRole LKS-GlueETLRole LKS-SageMakerRole LKS-ECSTaskRole LKS-ECSExecutionRole; do
  for P in $(aws iam list-attached-role-policies --role-name $ROLE \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $ROLE --policy-arn $P
  done
  for P in $(aws iam list-role-policies --role-name $ROLE \
    --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name $ROLE --policy-name $P
  done
  aws iam delete-role --role-name $ROLE 2>/dev/null && echo "Deleted $ROLE"
done

echo "All resources deleted"
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| SQS message not consumed | Lambda SQS trigger not created | Check `aws lambda list-event-source-mappings --function-name lks-feature-trigger` |
| Lambda KeyError in handler | CSV missing expected column | Verify `sample_transactions.csv` has all required columns |
| SageMaker endpoint `Failed` | IAM role missing ECR access | Attach `AmazonSageMakerFullAccess` to `LKS-SageMakerRole` |
| ECS task stops immediately | Missing env var or IAM permission | Check CloudWatch Logs at `/ecs/lks-paytech-task` |
| ALB health check failing | FastAPI not started yet (cold start) | Wait 30s, then check `/health`; also verify port 8080 in security group |
| `POST /predict` returns 503 | SageMaker endpoint deleted or throttled | Recreate endpoint with `05-setup-sagemaker.sh` |
| DynamoDB record not found | ECS task role missing `dynamodb:PutItem` | Check task role inline policy |
