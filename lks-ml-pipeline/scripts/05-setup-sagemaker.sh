#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROCESSED_BUCKET="lks-paytech-processed-${ACCOUNT_ID}"
DATA_DIR="$(dirname "$0")/../data"

SM_ROLE_ARN=$(aws iam get-role --role-name LKS-SageMakerRole --query 'Role.Arn' --output text 2>/dev/null || true)
if [[ -z "$SM_ROLE_ARN" || "$SM_ROLE_ARN" == "None" ]]; then
  echo "ERROR: LKS-SageMakerRole not found. Run 02-create-iam.sh first."
  exit 1
fi
echo "  Using role: $SM_ROLE_ARN"

echo "==> Uploading training data to S3..."
aws s3 cp "${DATA_DIR}/train.csv" \
  "s3://${PROCESSED_BUCKET}/training/train.csv"
aws s3 cp "${DATA_DIR}/validation.csv" \
  "s3://${PROCESSED_BUCKET}/training/validation.csv"

echo "==> Resolving XGBoost image URI..."
IMAGE_URI=$(python3 -c "
import sagemaker, boto3
print(sagemaker.image_uris.retrieve(
    framework='xgboost',
    region='${AWS_REGION}',
    version='1.7-1',
    image_scope='training',
    instance_type='ml.m5.xlarge'
))")
echo "  Image URI: ${IMAGE_URI}"

TRAINING_JOB="lks-paytech-training-$(date +%Y%m%d%H%M%S)"
echo "==> Starting SageMaker training job: $TRAINING_JOB"

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
  --hyper-parameters '{
    "objective":"binary:logistic",
    "num_round":"150",
    "max_depth":"5",
    "eta":"0.2",
    "subsample":"0.8",
    "colsample_bytree":"0.8",
    "eval_metric":"auc",
    "scale_pos_weight":"4"
  }' \
  --region "$AWS_REGION"

echo "  Waiting for training job to complete (~5-10 min)..."
aws sagemaker wait training-job-completed-or-stopped \
  --training-job-name "$TRAINING_JOB" \
  --region "$AWS_REGION"

STATUS=$(aws sagemaker describe-training-job \
  --training-job-name "$TRAINING_JOB" \
  --query 'TrainingJobStatus' --output text)

if [ "$STATUS" != "Completed" ]; then
  echo "ERROR: Training job status: $STATUS"
  exit 1
fi

MODEL_ARTIFACT=$(aws sagemaker describe-training-job \
  --training-job-name "$TRAINING_JOB" \
  --query 'ModelArtifacts.S3ModelArtifacts' --output text)

echo "==> Creating SageMaker model..."
MODEL_NAME="lks-paytech-model-$(date +%Y%m%d%H%M%S)"
aws sagemaker create-model \
  --model-name "$MODEL_NAME" \
  --primary-container "Image=${IMAGE_URI},ModelDataUrl=${MODEL_ARTIFACT}" \
  --execution-role-arn "$SM_ROLE_ARN" \
  --region "$AWS_REGION"

echo "==> Creating endpoint config..."
aws sagemaker create-endpoint-config \
  --endpoint-config-name "${MODEL_NAME}-config" \
  --production-variants "VariantName=AllTraffic,ModelName=${MODEL_NAME},InitialInstanceCount=1,InstanceType=ml.m5.large,InitialVariantWeight=1" \
  --region "$AWS_REGION"

echo "==> Deploying endpoint: lks-paytech-endpoint ..."
aws sagemaker create-endpoint \
  --endpoint-name lks-paytech-endpoint \
  --endpoint-config-name "${MODEL_NAME}-config" \
  --region "$AWS_REGION" \
  2>/dev/null || \
aws sagemaker update-endpoint \
  --endpoint-name lks-paytech-endpoint \
  --endpoint-config-name "${MODEL_NAME}-config" \
  --region "$AWS_REGION"

echo "  Waiting for endpoint to be InService (~8 min)..."
aws sagemaker wait endpoint-in-service \
  --endpoint-name lks-paytech-endpoint \
  --region "$AWS_REGION"

echo ""
echo "==> 05 Complete!"
echo "Endpoint: lks-paytech-endpoint is InService"
echo "WARNING: Endpoint costs \$0.096/hr — delete when done:"
echo "  aws sagemaker delete-endpoint --endpoint-name lks-paytech-endpoint"
