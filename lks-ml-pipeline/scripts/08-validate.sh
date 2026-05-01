#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RAW_BUCKET="lks-paytech-raw-${ACCOUNT_ID}"
FEATURES_BUCKET="lks-paytech-features-${ACCOUNT_ID}"
DATA_DIR="$(dirname "$0")/../data"
PASS=0; FAIL=0

check() {
  local DESC=$1; local CMD=$2
  echo -n "  [ ] $DESC ... "
  if eval "$CMD" > /dev/null 2>&1; then
    echo "PASS ✓"; PASS=$((PASS+1))
  else
    echo "FAIL ✗"; FAIL=$((FAIL+1))
  fi
}

echo "===== PayTech ML Pipeline — End-to-End Validation ====="

echo ""
echo "--- Layer 1: S3 + SQS + Lambda ---"
check "Raw S3 bucket exists" "aws s3api head-bucket --bucket $RAW_BUCKET"
check "Features S3 bucket exists" "aws s3api head-bucket --bucket $FEATURES_BUCKET"
check "SQS queue exists" "aws sqs get-queue-url --queue-name lks-paytech-queue --region $AWS_REGION"
check "Lambda function exists" "aws lambda get-function --function-name lks-feature-trigger --region $AWS_REGION"

echo "==> Uploading test CSV to trigger pipeline..."
aws s3 cp "${DATA_DIR}/sample_transactions.csv" \
  "s3://${RAW_BUCKET}/data/sample_transactions.csv"
echo "   Waiting 30s for SQS → Lambda processing..."
sleep 30

check "Features file in S3" \
  "aws s3api head-object --bucket $FEATURES_BUCKET --key features/sample_transactions.csv"

echo ""
echo "--- Layer 2: Glue + Athena ---"
check "Glue job exists" "aws glue get-job --job-name lks-etl-paytech"
check "Athena workgroup exists" "aws athena get-work-group --work-group lks-paytech-wg"

echo ""
echo "--- Layer 3: SageMaker Endpoint ---"
check "SageMaker endpoint InService" \
  "aws sagemaker describe-endpoint --endpoint-name lks-paytech-endpoint --query 'EndpointStatus' --output text | grep -q InService"

echo ""
echo "--- Layer 4: ECS + ALB ---"
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names lks-paytech-alb \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")

check "ALB exists" "[ -n '$ALB_DNS' ]"
check "ECS service running" \
  "aws ecs describe-services --cluster lks-paytech-cluster --services lks-paytech-service --query 'services[0].runningCount' --output text | grep -q '[1-9]'"
check "ALB health check pass" "curl -sf http://${ALB_DNS}/health | grep -q ok"

echo ""
echo "--- Layer 5: Predict API + DynamoDB ---"
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='lks-paytech-api'].ApiId" --output text 2>/dev/null || echo "")
API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

check "API Gateway exists" "[ -n '$API_ID' ]"

echo "==> Sending test prediction..."
RESPONSE=$(curl -sf -X POST "${API_URL}/predict" \
  -H "Content-Type: application/json" \
  -d @"${DATA_DIR}/test_predict.json" 2>/dev/null || echo "{}")

check "Predict returns fraud_score" "echo '$RESPONSE' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert 'fraud_score' in d\""
check "Predict returns label" "echo '$RESPONSE' | python3 -c \"import sys,json; d=json.load(sys.stdin); assert d['label'] in ['FRAUD','NORMAL']\""

TXN_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transaction_id',''))" 2>/dev/null || echo "")
check "DynamoDB record saved" \
  "[ -n '$TXN_ID' ] && aws dynamodb query --table-name lks-paytech-predictions --key-condition-expression 'transaction_id = :id' --expression-attribute-values '{\",\:id\":{\"S\":\"${TXN_ID}\"}}' --query 'Count' | grep -qv '^0'"

echo ""
echo "===== Results ====="
echo "PASS: $PASS  |  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All checks passed! ✓" || echo "Some checks failed — review output above"
