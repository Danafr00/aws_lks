#!/bin/bash
set -e

ACCOUNT_ID="547849081977"
REGION="us-east-1"
LAB_ROLE="arn:aws:iam::547849081977:role/LabRole"
VPC_ID="vpc-0afa6269969fc33d9"
PROJECT="nusantara-shop"
ECR_IMAGE="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/nusantara-shop:latest"

SUBNETS="subnet-00baa17b56177ca53,subnet-06bd37455afbe4837,subnet-07de5176ed29efed0"

ALB_SG_ID="${ALB_SG_ID:-$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lks-nusantara-alb-sg" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)}"
ECS_SG_ID="${ECS_SG_ID:-$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=lks-nusantara-ecs-sg" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)}"

echo "=== Layer 4: ECS Fargate + ALB ==="

# Create CloudWatch log group
echo "[1/9] Creating CloudWatch log group..."
aws logs create-log-group \
  --log-group-name "/ecs/nusantara-shop" \
  --region "$REGION" \
  --tags Project=$PROJECT,Environment=production,ManagedBy=LKS-Team \
  2>/dev/null || true

# Create ALB
echo "[2/9] Creating ALB..."
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "lks-nusantara-alb" \
  --subnets subnet-00baa17b56177ca53 subnet-06bd37455afbe4837 subnet-07de5176ed29efed0 \
  --security-groups "$ALB_SG_ID" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) || \
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "lks-nusantara-alb" \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "  ALB DNS: $ALB_DNS"

# Create Blue Target Group (production traffic)
echo "[3/9] Creating Blue target group (port 80)..."
TG_BLUE_ARN=$(aws elbv2 create-target-group \
  --name "lks-nusantara-tg-blue" \
  --protocol HTTP \
  --port 5000 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || \
TG_BLUE_ARN=$(aws elbv2 describe-target-groups \
  --names "lks-nusantara-tg-blue" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Create Green Target Group (test traffic during Blue/Green)
echo "[4/9] Creating Green target group (port 8080)..."
TG_GREEN_ARN=$(aws elbv2 create-target-group \
  --name "lks-nusantara-tg-green" \
  --protocol HTTP \
  --port 5000 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || \
TG_GREEN_ARN=$(aws elbv2 describe-target-groups \
  --names "lks-nusantara-tg-green" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Create production listener (port 80 → Blue TG)
echo "[5/9] Creating ALB listeners..."
LISTENER_PROD_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_BLUE_ARN" \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null) || \
LISTENER_PROD_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region "$REGION" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text)

# Create test listener (port 8080 → Green TG) for CodeDeploy Blue/Green test
LISTENER_TEST_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn="$TG_GREEN_ARN" \
  --region "$REGION" \
  --tags Key=Project,Value=$PROJECT \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null) || \
LISTENER_TEST_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region "$REGION" \
  --query "Listeners[?Port==\`8080\`].ListenerArn" --output text)

# Create ECS cluster
echo "[6/9] Creating ECS cluster..."
aws ecs create-cluster \
  --cluster-name "lks-nusantara-cluster" \
  --capacity-providers FARGATE FARGATE_SPOT \
  --region "$REGION" \
  --tags key=Project,value=$PROJECT key=Environment,value=production key=ManagedBy,value=LKS-Team \
  2>/dev/null || true

# Register task definition
echo "[7/9] Registering ECS task definition..."
REDIS_ENDPOINT=$(aws ssm get-parameter \
  --name "/nusantara-shop/redis-host" \
  --region "$REGION" \
  --query 'Parameter.Value' --output text)

aws ecs register-task-definition \
  --family "nusantara-shop" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --execution-role-arn "$LAB_ROLE" \
  --task-role-arn "$LAB_ROLE" \
  --container-definitions "[
    {
      \"name\": \"nusantara-shop\",
      \"image\": \"$ECR_IMAGE\",
      \"portMappings\": [{\"containerPort\": 5000, \"protocol\": \"tcp\"}],
      \"environment\": [
        {\"name\": \"APP_VERSION\", \"value\": \"1.0.0\"},
        {\"name\": \"APP_COLOR\", \"value\": \"blue\"},
        {\"name\": \"REDIS_HOST\", \"value\": \"$REDIS_ENDPOINT\"},
        {\"name\": \"REDIS_PORT\", \"value\": \"6379\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/nusantara-shop\",
          \"awslogs-region\": \"$REGION\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      },
      \"essential\": true,
      \"healthCheck\": {
        \"command\": [\"CMD-SHELL\", \"curl -f http://localhost:5000/health || exit 1\"],
        \"interval\": 30,
        \"timeout\": 5,
        \"retries\": 3,
        \"startPeriod\": 60
      }
    }
  ]" \
  --region "$REGION" \
  --tags key=Project,value=$PROJECT key=Environment,value=production key=ManagedBy,value=LKS-Team

TASK_DEF_ARN=$(aws ecs describe-task-definition \
  --task-definition "nusantara-shop" \
  --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

# Create ECS service with CodeDeploy controller
echo "[8/9] Creating ECS service (CodeDeploy deployment controller)..."
aws ecs create-service \
  --cluster "lks-nusantara-cluster" \
  --service-name "nusantara-shop-svc" \
  --task-definition "nusantara-shop" \
  --desired-count 2 \
  --launch-type FARGATE \
  --deployment-controller type=CODE_DEPLOY \
  --network-configuration "awsvpcConfiguration={
    subnets=[$SUBNETS],
    securityGroups=[$ECS_SG_ID],
    assignPublicIp=ENABLED
  }" \
  --load-balancers "targetGroupArn=$TG_BLUE_ARN,containerName=nusantara-shop,containerPort=5000" \
  --region "$REGION" \
  --tags key=Project,value=$PROJECT key=Environment,value=production key=ManagedBy,value=LKS-Team \
  2>/dev/null || echo "  ECS service already exists, skipping..."

# Wait for service to stabilize
echo "[9/9] Waiting for ECS service to reach steady state (~3 min)..."
aws ecs wait services-stable \
  --cluster "lks-nusantara-cluster" \
  --services "nusantara-shop-svc" \
  --region "$REGION"

echo ""
echo "=== Layer 4 Complete ==="
echo "ALB DNS:         http://$ALB_DNS"
echo "Blue TG ARN:     $TG_BLUE_ARN"
echo "Green TG ARN:    $TG_GREEN_ARN"
echo "Prod listener:   $LISTENER_PROD_ARN"
echo "Test listener:   $LISTENER_TEST_ARN"
echo ""
echo "Checkpoint — run this:"
echo "curl http://$ALB_DNS/health"
echo ""
echo "Save for later scripts:"
echo "export ALB_ARN=$ALB_ARN"
echo "export ALB_DNS=$ALB_DNS"
echo "export TG_BLUE_ARN=$TG_BLUE_ARN"
echo "export TG_GREEN_ARN=$TG_GREEN_ARN"
echo "export LISTENER_PROD_ARN=$LISTENER_PROD_ARN"
echo "export LISTENER_TEST_ARN=$LISTENER_TEST_ARN"
