#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
ENDPOINT_NAME="lks-loan-risk-endpoint"
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(dirname "$0")"
APP_DIR="${SCRIPT_DIR}/../app"

echo "==> Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── Lambda: package ───────────────────────────────────────────
echo ""
echo "==> Packaging Lambda function (inference only)..."
cd "$APP_DIR"
zip -q function.zip handler.py
echo "  function.zip created"

# ── Lambda: create / update ───────────────────────────────────
echo ""
echo "==> Deploying Lambda function: lks-loan-risk..."
echo "    Waiting 10s for IAM role propagation..."
sleep 10

LAMBDA_ARN=$(aws lambda create-function \
  --region "$REGION" \
  --function-name lks-loan-risk \
  --runtime python3.12 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/LKS-LoanRiskLambdaRole" \
  --handler handler.handler \
  --zip-file fileb://function.zip \
  --memory-size 256 \
  --timeout 30 \
  --environment "Variables={
    SAGEMAKER_ENDPOINT_NAME=${ENDPOINT_NAME},
    AWS_REGION=${REGION}
  }" \
  --tags '{
    "Project":"nusantara-fincredit",
    "Environment":"production",
    "ManagedBy":"LKS-Team"
  }' \
  --query FunctionArn --output text \
  2>/dev/null) || {
    echo "  (already exists — updating code and config...)"
    aws lambda update-function-code \
      --region "$REGION" \
      --function-name lks-loan-risk \
      --zip-file fileb://function.zip > /dev/null
    aws lambda update-function-configuration \
      --region "$REGION" \
      --function-name lks-loan-risk \
      --environment "Variables={SAGEMAKER_ENDPOINT_NAME=${ENDPOINT_NAME},AWS_REGION=${REGION}}" > /dev/null
    LAMBDA_ARN=$(aws lambda get-function \
      --region "$REGION" \
      --function-name lks-loan-risk \
      --query Configuration.FunctionArn --output text)
  }

rm -f function.zip
cd - > /dev/null
echo "  Lambda ARN: ${LAMBDA_ARN}"

# ── API Gateway HTTP API ───────────────────────────────────────
echo ""
echo "==> Creating API Gateway HTTP API: lks-loan-risk-api..."

API_ID=$(aws apigatewayv2 create-api \
  --region "$REGION" \
  --name lks-loan-risk-api \
  --protocol-type HTTP \
  --cors-configuration \
    AllowOrigins="*",AllowMethods="POST,OPTIONS",AllowHeaders="content-type",MaxAge=300 \
  --tags '{"Project":"nusantara-fincredit","Environment":"production","ManagedBy":"LKS-Team"}' \
  --query ApiId --output text \
  2>/dev/null) || {
    echo "  (already exists — fetching existing API ID...)"
    API_ID=$(aws apigatewayv2 get-apis \
      --region "$REGION" \
      --query "Items[?Name=='lks-loan-risk-api'].ApiId | [0]" \
      --output text)
  }

echo "  API ID: ${API_ID}"

# ── Lambda integration ─────────────────────────────────────────
echo ""
echo "==> Creating Lambda integration..."
INT_ID=$(aws apigatewayv2 create-integration \
  --region "$REGION" \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "$LAMBDA_ARN" \
  --payload-format-version 2.0 \
  --query IntegrationId --output text \
  2>/dev/null) || {
    echo "  (fetching existing integration...)"
    INT_ID=$(aws apigatewayv2 get-integrations \
      --region "$REGION" \
      --api-id "$API_ID" \
      --query "Items[0].IntegrationId" \
      --output text)
  }

echo "  Integration ID: ${INT_ID}"

# ── Route: POST /predict ───────────────────────────────────────
echo ""
echo "==> Creating route: POST /predict..."
aws apigatewayv2 create-route \
  --region "$REGION" \
  --api-id "$API_ID" \
  --route-key "POST /predict" \
  --target "integrations/${INT_ID}" \
  2>/dev/null || echo "  (route already exists, skipping)"

# ── Stage: prod (auto-deploy) ──────────────────────────────────
echo ""
echo "==> Creating stage: prod..."
aws apigatewayv2 create-stage \
  --region "$REGION" \
  --api-id "$API_ID" \
  --stage-name prod \
  --auto-deploy \
  2>/dev/null || echo "  (stage already exists, skipping)"

# ── Permission for API GW to invoke Lambda ────────────────────
echo ""
echo "==> Granting API Gateway permission to invoke Lambda..."
aws lambda add-permission \
  --region "$REGION" \
  --function-name lks-loan-risk \
  --statement-id APIGatewayInvoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  2>/dev/null || echo "  (permission already exists, skipping)"

# ── Output ─────────────────────────────────────────────────────
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"

echo ""
echo "================================================================"
echo " API Gateway setup complete"
echo "================================================================"
echo "  API ID:        ${API_ID}"
echo "  Invoke URL:    ${API_URL}"
echo "  Predict URL:   ${API_URL}/predict"
echo ""
echo "  Quick test:"
echo "  curl -X POST '${API_URL}/predict' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"age\":42,\"annual_income\":85000,\"loan_amount\":12000,\"loan_term_months\":36,\"credit_score\":720,\"employment_years\":12,\"debt_to_income_ratio\":0.22,\"has_mortgage\":1,\"num_credit_lines\":3,\"num_late_payments\":0}'"
echo ""
echo "  Save the Invoke URL — you will need it for script 05-deploy-amplify.sh"
echo "  export API_URL=\"${API_URL}\""
echo "================================================================"

# Persist for next script
echo "${API_URL}" > /tmp/lks-api-url.txt
echo "  API URL saved to /tmp/lks-api-url.txt"
