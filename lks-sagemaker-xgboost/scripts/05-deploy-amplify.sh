#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
REGION="${AWS_REGION:-ap-southeast-1}"
# API_URL can also be read from /tmp/lks-api-url.txt written by script 04
API_URL="${API_URL:-$(cat /tmp/lks-api-url.txt 2>/dev/null || echo '')}"
# ──────────────────────────────────────────────────────────────

if [[ -z "$API_URL" ]]; then
  echo "ERROR: API_URL is not set."
  echo "  Run script 04-setup-api-gateway.sh first, or:"
  echo "  export API_URL=https://<api-id>.execute-api.${REGION}.amazonaws.com/prod"
  exit 1
fi

SCRIPT_DIR="$(dirname "$0")"
APP_DIR="${SCRIPT_DIR}/../app"
BUILD_DIR="/tmp/lks-amplify-build"

echo "==> API Gateway URL: ${API_URL}"
echo "==> Region: ${REGION}"

# ── Inject API URL into index.html ────────────────────────────
echo ""
echo "==> Injecting API URL into index.html..."
mkdir -p "$BUILD_DIR"
sed "s|__API_GATEWAY_URL__|${API_URL}|g" "${APP_DIR}/index.html" > "${BUILD_DIR}/index.html"
echo "  index.html ready in ${BUILD_DIR}"

# ── Zip for Amplify deployment ────────────────────────────────
echo ""
echo "==> Creating deployment package..."
cd "$BUILD_DIR"
zip -q deploy.zip index.html
echo "  deploy.zip created ($(wc -c < deploy.zip) bytes)"

# ── Create Amplify app ────────────────────────────────────────
echo ""
echo "==> Creating Amplify app: lks-loan-risk-ui..."
APP_ID=$(aws amplify create-app \
  --region "$REGION" \
  --name lks-loan-risk-ui \
  --description "PT. Nusantara FinCredit loan risk assessment UI" \
  --tags '{"Project":"nusantara-fincredit","Environment":"production","ManagedBy":"LKS-Team"}' \
  --query app.appId --output text \
  2>/dev/null) || {
    echo "  (app already exists — fetching app ID...)"
    APP_ID=$(aws amplify list-apps \
      --region "$REGION" \
      --query "apps[?name=='lks-loan-risk-ui'].appId | [0]" \
      --output text)
  }

echo "  Amplify App ID: ${APP_ID}"

# ── Create branch: main ───────────────────────────────────────
echo ""
echo "==> Creating branch: main..."
aws amplify create-branch \
  --region "$REGION" \
  --app-id "$APP_ID" \
  --branch-name main \
  2>/dev/null || echo "  (branch already exists, skipping)"

# ── Create deployment (get presigned S3 upload URL) ───────────
echo ""
echo "==> Creating Amplify deployment..."
DEPLOYMENT=$(aws amplify create-deployment \
  --region "$REGION" \
  --app-id "$APP_ID" \
  --branch-name main)

JOB_ID=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['jobId'])")
UPLOAD_URL=$(echo "$DEPLOYMENT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['zipUploadUrl'])")

echo "  Job ID: ${JOB_ID}"

# ── Upload zip to presigned URL ───────────────────────────────
echo ""
echo "==> Uploading frontend to Amplify..."
curl -s -X PUT \
  -H "Content-Type: application/zip" \
  --upload-file deploy.zip \
  "$UPLOAD_URL"

# ── Start deployment ──────────────────────────────────────────
echo ""
echo "==> Starting Amplify deployment..."
aws amplify start-deployment \
  --region "$REGION" \
  --app-id "$APP_ID" \
  --branch-name main \
  --job-id "$JOB_ID" > /dev/null

echo "  Deployment started — waiting for it to complete (~30s)..."
sleep 30

# ── Poll until complete ───────────────────────────────────────
for i in {1..12}; do
  STATUS=$(aws amplify get-job \
    --region "$REGION" \
    --app-id "$APP_ID" \
    --branch-name main \
    --job-id "$JOB_ID" \
    --query job.summary.status \
    --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "$STATUS" == "SUCCEED" ]]; then
    echo "  Deployment SUCCEEDED"
    break
  elif [[ "$STATUS" == "FAILED" ]]; then
    echo "  ERROR: Amplify deployment FAILED"
    echo "  Check: AWS Amplify console → lks-loan-risk-ui → main branch → job ${JOB_ID}"
    exit 1
  else
    echo "  Status: ${STATUS} — waiting 15s..."
    sleep 15
  fi
done

cd - > /dev/null
rm -rf "$BUILD_DIR"

# ── Output ─────────────────────────────────────────────────────
AMPLIFY_URL="https://main.${APP_ID}.amplifyapp.com"

echo ""
echo "================================================================"
echo " DEPLOYMENT COMPLETE"
echo "================================================================"
echo ""
echo "  Amplify App:    lks-loan-risk-ui"
echo "  UI URL:         ${AMPLIFY_URL}"
echo "  API URL:        ${API_URL}/predict"
echo ""
echo "  Open the UI URL in your browser to test the loan risk form."
echo ""
echo "  Test cases are in: data/test_samples.json"
echo "================================================================"

echo "${AMPLIFY_URL}" > /tmp/lks-amplify-url.txt
