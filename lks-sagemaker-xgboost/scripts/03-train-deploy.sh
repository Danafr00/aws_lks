#!/bin/bash
set -e

# ── Edit these before running ──────────────────────────────────
REGION="${AWS_REGION:-ap-southeast-1}"
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(dirname "$0")"
TRAIN_SCRIPT="${SCRIPT_DIR}/../training/train_deploy.py"

echo "==> Checking Python dependencies..."
python3 -c "import sagemaker, boto3" 2>/dev/null || {
  echo "Installing sagemaker SDK..."
  pip install --quiet sagemaker boto3
}

echo ""
echo "==> Starting SageMaker training + deployment..."
echo "    This will:"
echo "    1. Launch a Training Job on ml.m5.xlarge (~3-5 min)"
echo "    2. Deploy to a SageMaker Endpoint on ml.m5.large (~8-10 min)"
echo "    3. Print the endpoint name and a test curl command"
echo ""
echo "    ⚠️  COST REMINDER: Delete endpoint after use!"
echo "       python3 training/train_deploy.py --delete"
echo "       OR: aws sagemaker delete-endpoint --endpoint-name lks-loan-risk-endpoint --region ${REGION}"
echo ""
read -p "Press ENTER to continue or Ctrl+C to cancel..."

export AWS_REGION="$REGION"
python3 "$TRAIN_SCRIPT"

echo ""
echo "==> Training + deployment complete."
echo ""
echo "    Test low-risk prediction (expected probability < 0.30):"
echo "    aws sagemaker-runtime invoke-endpoint \\"
echo "      --endpoint-name lks-loan-risk-endpoint \\"
echo "      --content-type text/csv \\"
echo "      --body '42,85000,12000,36,720,12,0.22,1,3,0' \\"
echo "      --region ${REGION} /dev/stdout"
echo ""
echo "    Test high-risk prediction (expected probability > 0.55):"
echo "    aws sagemaker-runtime invoke-endpoint \\"
echo "      --endpoint-name lks-loan-risk-endpoint \\"
echo "      --content-type text/csv \\"
echo "      --body '26,32000,20000,60,545,1,0.58,0,8,5' \\"
echo "      --region ${REGION} /dev/stdout"
