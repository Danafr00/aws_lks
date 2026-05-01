#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RESULTS_BUCKET="lks-paytech-results-${ACCOUNT_ID}"
TASK_ROLE_ARN=$(aws iam get-role --role-name LKS-ECSTaskRole --query 'Role.Arn' --output text)
EXEC_ROLE_ARN=$(aws iam get-role --role-name LKS-ECSExecutionRole --query 'Role.Arn' --output text)
APP_DIR="$(dirname "$0")/../app/inference_api"
ECR_REPO="lks-paytech-api"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

echo "==> Creating ECR repository..."
aws ecr create-repository \
  --repository-name "$ECR_REPO" \
  --image-tag-mutability MUTABLE \
  --region "$AWS_REGION" \
  2>/dev/null || echo "  ECR repo already exists"

echo "==> Authenticating Docker to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Building inference image..."
docker build -t "${ECR_REPO}:latest" "$APP_DIR"
docker tag "${ECR_REPO}:latest" "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"
echo "  Image pushed: ${ECR_URI}:latest"

echo "==> Creating CloudWatch Log Group..."
aws logs create-log-group \
  --log-group-name /ecs/lks-paytech-task \
  2>/dev/null || true

echo "==> Registering ECS Task Definition..."
TASK_DEF=$(cat <<EOF
{
  "family": "lks-paytech-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "inference-api",
    "image": "${ECR_URI}:latest",
    "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
    "environment": [
      {"name": "SAGEMAKER_ENDPOINT_NAME", "value": "lks-paytech-endpoint"},
      {"name": "DYNAMODB_TABLE", "value": "lks-paytech-predictions"},
      {"name": "RESULTS_BUCKET", "value": "${RESULTS_BUCKET}"},
      {"name": "AWS_DEFAULT_REGION", "value": "${AWS_REGION}"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/lks-paytech-task",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
      "interval": 30,
      "timeout": 5,
      "retries": 3,
      "startPeriod": 15
    }
  }]
}
EOF
)

aws ecs register-task-definition \
  --cli-input-json "$TASK_DEF" \
  --region "$AWS_REGION" > /dev/null

echo "==> Creating ECS Cluster..."
aws ecs create-cluster \
  --cluster-name lks-paytech-cluster \
  --capacity-providers FARGATE FARGATE_SPOT \
  --region "$AWS_REGION" \
  2>/dev/null || echo "  Cluster already exists"

echo "==> Creating VPC resources for ECS..."
# Use default VPC for simplicity
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${DEFAULT_VPC}" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

echo "==> Creating Security Group for ECS service..."
ECS_SG=$(aws ec2 create-security-group \
  --group-name lks-paytech-ecs-sg \
  --description "PayTech ECS inference service" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text \
  2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=lks-paytech-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ECS_SG" \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0 \
  2>/dev/null || true

echo "==> Creating ALB Security Group..."
ALB_SG=$(aws ec2 create-security-group \
  --group-name lks-paytech-alb-sg \
  --description "PayTech ALB" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text \
  2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=lks-paytech-alb-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  2>/dev/null || true

echo "==> Creating ALB..."
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name lks-paytech-alb \
  --subnets $(echo "$SUBNETS" | tr ',' ' ') \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text \
  2>/dev/null || \
  aws elbv2 describe-load-balancers \
    --names lks-paytech-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)

echo "==> Creating Target Group..."
TG_ARN=$(aws elbv2 create-target-group \
  --name lks-paytech-tg \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$DEFAULT_VPC" \
  --target-type ip \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --query 'TargetGroups[0].TargetGroupArn' --output text \
  2>/dev/null || \
  aws elbv2 describe-target-groups \
    --names lks-paytech-tg \
    --query 'TargetGroups[0].TargetGroupArn' --output text)

echo "==> Creating ALB Listener..."
aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
  2>/dev/null || echo "  Listener already exists"

SUBNET_LIST=$(echo "$SUBNETS" | tr ',' ' ' | awk '{print "subnet="$1",subnet="$2}' 2>/dev/null || echo "subnet=${SUBNETS%%,*}")

echo "==> Creating ECS Service..."
aws ecs create-service \
  --cluster lks-paytech-cluster \
  --service-name lks-paytech-service \
  --task-definition lks-paytech-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${ECS_SG}],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=inference-api,containerPort=8080" \
  --region "$AWS_REGION" \
  2>/dev/null || echo "  Service already exists"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names lks-paytech-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

echo ""
echo "==> 06 Complete!"
echo "ALB DNS: http://$ALB_DNS"
echo "Test health: curl http://$ALB_DNS/health"
echo "(Wait ~2 min for ECS task to be healthy)"
