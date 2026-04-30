#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="${AWS_REGION:-ap-southeast-1}"
ENDPOINT_NAME="lks-loan-risk-endpoint"
API_URL="${API_URL:-$(cat /tmp/lks-api-url.txt 2>/dev/null || echo '')}"
AMPLIFY_URL="${AMPLIFY_URL:-$(cat /tmp/lks-amplify-url.txt 2>/dev/null || echo '')}"
# ──────────────────────────────────────────────────────────────

PASS=0; FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
chk()  { local label="$1"; shift; if eval "$*" >/dev/null 2>&1; then ok "$label"; else fail "$label"; fi; }

echo "================================================================"
echo " LKS SageMaker XGBoost — Full Stack Validation"
echo " Account: ${ACCOUNT_ID} | Region: ${REGION}"
echo "================================================================"

# ── 1: S3 ────────────────────────────────────────────────────
echo ""
echo "[1/6] S3 Buckets"
chk "Data bucket exists"       "aws s3api head-bucket --bucket lks-sagemaker-data-${ACCOUNT_ID} --region ${REGION}"
chk "Model bucket exists"      "aws s3api head-bucket --bucket lks-sagemaker-models-${ACCOUNT_ID} --region ${REGION}"
chk "Training data uploaded"   "aws s3api head-object --bucket lks-sagemaker-data-${ACCOUNT_ID} --key train/train.csv --region ${REGION}"
chk "Validation data uploaded" "aws s3api head-object --bucket lks-sagemaker-data-${ACCOUNT_ID} --key validation/validation.csv --region ${REGION}"

# ── 2: IAM ───────────────────────────────────────────────────
echo ""
echo "[2/6] IAM Roles"
chk "LKS-SageMakerRole exists"       "aws iam get-role --role-name LKS-SageMakerRole"
chk "LKS-LoanRiskLambdaRole exists"  "aws iam get-role --role-name LKS-LoanRiskLambdaRole"

# ── 3: SageMaker Endpoint ─────────────────────────────────────
echo ""
echo "[3/6] SageMaker Endpoint"
EP_STATUS=$(aws sagemaker describe-endpoint \
  --endpoint-name "$ENDPOINT_NAME" \
  --region "$REGION" \
  --query EndpointStatus \
  --output text 2>/dev/null || echo "NOT_FOUND")
echo "  Status: ${EP_STATUS}"
[[ "$EP_STATUS" == "InService" ]] && ok "Endpoint is InService" || fail "Endpoint not InService (${EP_STATUS})"

# ── 4: API Gateway ────────────────────────────────────────────
echo ""
echo "[4/6] API Gateway"
chk "lks-loan-risk-api exists" \
  "aws apigatewayv2 get-apis --region ${REGION} --query \"Items[?Name=='lks-loan-risk-api'].ApiId | [0]\" --output text | grep -v None"
chk "Lambda function exists" \
  "aws lambda get-function --function-name lks-loan-risk --region ${REGION}"

# ── 5: API Inference Tests ────────────────────────────────────
echo ""
echo "[5/6] Inference via API Gateway"
if [[ -z "$API_URL" ]]; then
  fail "API_URL not set — export API_URL=https://... or run script 04 first"
else
  echo "  API URL: ${API_URL}"

  # Low-risk test
  LOW_JSON='{"age":42,"annual_income":85000,"loan_amount":12000,"loan_term_months":36,"credit_score":720,"employment_years":12,"debt_to_income_ratio":0.22,"has_mortgage":1,"num_credit_lines":3,"num_late_payments":0}'
  LOW_RESP=$(curl -s -X POST "${API_URL}/predict" \
    -H "Content-Type: application/json" \
    -d "$LOW_JSON" 2>/dev/null || echo '{}')
  LOW_RISK=$(echo "$LOW_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('risk_level','ERR'))" 2>/dev/null || echo "ERR")
  LOW_PCT=$(echo "$LOW_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('probability',0))" 2>/dev/null || echo "0")
  echo "  Low-risk profile  → risk=${LOW_RISK}, probability=${LOW_PCT}%"
  [[ "$LOW_RISK" == "LOW" ]] && ok "Low-risk profile classified correctly" || fail "Low-risk profile returned: ${LOW_RISK} (${LOW_PCT}%)"

  # High-risk test
  HIGH_JSON='{"age":26,"annual_income":32000,"loan_amount":20000,"loan_term_months":60,"credit_score":545,"employment_years":1,"debt_to_income_ratio":0.58,"has_mortgage":0,"num_credit_lines":8,"num_late_payments":5}'
  HIGH_RESP=$(curl -s -X POST "${API_URL}/predict" \
    -H "Content-Type: application/json" \
    -d "$HIGH_JSON" 2>/dev/null || echo '{}')
  HIGH_RISK=$(echo "$HIGH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('risk_level','ERR'))" 2>/dev/null || echo "ERR")
  HIGH_PCT=$(echo "$HIGH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('probability',0))" 2>/dev/null || echo "0")
  echo "  High-risk profile → risk=${HIGH_RISK}, probability=${HIGH_PCT}%"
  [[ "$HIGH_RISK" == "HIGH" ]] && ok "High-risk profile classified correctly" || fail "High-risk profile returned: ${HIGH_RISK} (${HIGH_PCT}%)"
fi

# ── 6: Amplify ────────────────────────────────────────────────
echo ""
echo "[6/6] Amplify Hosting"
AMPLIFY_APP=$(aws amplify list-apps \
  --region "$REGION" \
  --query "apps[?name=='lks-loan-risk-ui'].appId | [0]" \
  --output text 2>/dev/null || echo "None")
[[ "$AMPLIFY_APP" != "None" && -n "$AMPLIFY_APP" ]] \
  && ok "Amplify app exists (ID: ${AMPLIFY_APP})" \
  || fail "Amplify app not found"

if [[ -n "$AMPLIFY_URL" ]]; then
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$AMPLIFY_URL" 2>/dev/null || echo "000")
  [[ "$HTTP_STATUS" == "200" ]] \
    && ok "Amplify UI returns HTTP 200" \
    || fail "Amplify UI returned HTTP ${HTTP_STATUS}"
  echo "  URL: ${AMPLIFY_URL}"
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " RESULT: ${PASS} PASS / ${FAIL} FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo " STATUS:  ALL CHECKS PASSED"
  [[ -n "$AMPLIFY_URL" ]] && echo "" && echo "  Open UI: ${AMPLIFY_URL}"
else
  echo " STATUS:  ${FAIL} CHECK(S) FAILED — review output above"
fi
echo "================================================================"
echo ""
echo "  ⚠️  Remember to delete the SageMaker endpoint when done:"
echo "  aws sagemaker delete-endpoint --endpoint-name ${ENDPOINT_NAME} --region ${REGION}"
