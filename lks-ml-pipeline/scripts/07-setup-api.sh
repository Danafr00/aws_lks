#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
API_NAME="lks-paytech-api"
DYNAMO_TABLE="lks-paytech-predictions"
AMPLIFY_APP_NAME="lks-paytech-ui"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names lks-paytech-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "==> Creating DynamoDB table..."
aws dynamodb create-table \
  --table-name "$DYNAMO_TABLE" \
  --attribute-definitions \
    AttributeName=transaction_id,AttributeType=S \
    AttributeName=timestamp,AttributeType=S \
  --key-schema \
    AttributeName=transaction_id,KeyType=HASH \
    AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=Project,Value=nusantara-paytech Key=Environment,Value=production \
  --region "$AWS_REGION" \
  2>/dev/null || echo "  DynamoDB table already exists"

echo "==> Creating API Gateway HTTP API..."
API_ID=$(aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --cors-configuration AllowOrigins="*",AllowMethods="GET,POST,OPTIONS",AllowHeaders="Content-Type" \
  --query 'ApiId' --output text \
  2>/dev/null || \
  aws apigatewayv2 get-apis \
    --query "Items[?Name=='${API_NAME}'].ApiId" --output text)

echo "  API ID: $API_ID"

echo "==> Creating HTTP integration (API Gateway → ALB)..."
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${ALB_DNS}/{proxy}" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' --output text)

echo "==> Creating routes..."
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "POST /predict" \
  --target "integrations/${INTEGRATION_ID}" \
  2>/dev/null || true

aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /health" \
  --target "integrations/${INTEGRATION_ID}" \
  2>/dev/null || true

echo "==> Creating default stage with auto-deploy..."
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy \
  2>/dev/null || echo "  Stage already exists"

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

echo "==> Deploying Amplify frontend..."
AMPLIFY_APP_ID=$(aws amplify create-app \
  --name "$AMPLIFY_APP_NAME" \
  --query 'app.appId' --output text \
  2>/dev/null || \
  aws amplify list-apps \
    --query "apps[?name=='${AMPLIFY_APP_NAME}'].appId" --output text)

BRANCH=$(aws amplify create-branch \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main \
  2>/dev/null || true)

FRONTEND_DIR="$(dirname "$0")/../app/frontend"

# Inject API URL into index.html
sed "s|__API_GATEWAY_URL__|${API_URL}|g" \
  "${FRONTEND_DIR}/index.html" > /tmp/index.html

# Package and deploy
cd /tmp && zip -q amplify-deploy.zip index.html && cd - > /dev/null

DEPLOYMENT=$(aws amplify create-deployment \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main \
  --output json)

UPLOAD_URL=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['zipUploadUrl'])")
JOB_ID=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")

curl -s -X PUT -H "Content-Type: application/zip" \
  --data-binary @/tmp/amplify-deploy.zip \
  "$UPLOAD_URL"

aws amplify start-deployment \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main \
  --job-id "$JOB_ID"

echo "  Waiting for Amplify deployment..."
sleep 15

AMPLIFY_URL=$(aws amplify get-branch \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main \
  --query 'branch.displayName' --output text 2>/dev/null || echo "deploying")

echo ""
echo "==> 07 Complete!"
echo "API Gateway URL:  $API_URL"
echo "Test endpoint:    curl -X POST $API_URL/predict -H 'Content-Type: application/json' -d @data/test_predict.json"
echo "Amplify App ID:   $AMPLIFY_APP_ID"
echo "Amplify URL:      https://main.${AMPLIFY_APP_ID}.amplifyapp.com"
