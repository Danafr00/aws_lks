# Step-by-Step Answer Key (CLI)

**Module:** ECS Blue/Green CI/CD with ElastiCache  
**Region:** us-east-1  
**Account:** 547849081977  
**LabRole ARN:** `arn:aws:iam::547849081977:role/LabRole`

---

## Layer Table

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | ECR + Docker build + push | `aws ecr describe-images` shows 2 tags |
| **2** | Security Groups (ALB / ECS / Redis) | 3 SGs visible, rules verified |
| **3** | ElastiCache Redis + SSM parameter | `CacheClusterStatus: available` |
| **4** | ECS Fargate + ALB + Target Groups + Service | `curl ALB/health` → `{"status":"ok","redis":"connected"}` |
| **5** | S3 Static Website (frontend) | Browser opens URL, products load |
| **6** | CodeCommit + CodeDeploy (Blue/Green) | Deployment `Succeeded`, traffic on green tasks |
| **7** | Blue/Green demo (v2.0.0) | `/health` returns `"version":"2.0.0","color":"green"` |

---

## Prerequisites

```bash
# Verify AWS CLI identity
aws sts get-caller-identity

# Expected:
# Account: 547849081977
# Arn: ...assumed-role/voclabs/...

# Set default region
export AWS_DEFAULT_REGION=us-east-1
export ACCOUNT_ID=547849081977
export LAB_ROLE="arn:aws:iam::547849081977:role/LabRole"

# Verify Docker is running
docker info | head -5
```

---

## Layer 1 — ECR + Docker Build + Push

### 1.1 Create ECR Repository

```bash
aws ecr create-repository \
  --repository-name nusantara-shop \
  --region us-east-1 \
  --image-scanning-configuration scanOnPush=true \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team
```

Expected output: JSON with `repositoryUri` like `547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop`

```bash
export ECR_URI="547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"
```

### 1.2 Authenticate Docker to ECR

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  547849081977.dkr.ecr.us-east-1.amazonaws.com
```

Expected: `Login Succeeded`

### 1.3 Build Docker Image

```bash
# From the lks-ecs-codedeploy directory
cd app/

# --platform linux/amd64 required if building on Apple Silicon (M1/M2/M3)
docker buildx build \
  --platform linux/amd64 \
  --build-arg APP_VERSION=1.0.0 \
  -t nusantara-shop:1.0.0 \
  -t nusantara-shop:latest \
  .

# Verify image built
docker images nusantara-shop
```

### 1.4 Tag and Push

```bash
# If built with buildx --push, image is already in ECR. Otherwise tag and push:
docker tag nusantara-shop:1.0.0 $ECR_URI:1.0.0
docker tag nusantara-shop:latest $ECR_URI:latest

docker push $ECR_URI:1.0.0
docker push $ECR_URI:latest
```

**Layer 1 checkpoint — verify before continuing:**
- [ ] `aws ecr describe-images --repository-name nusantara-shop --query 'imageDetails[*].imageTags'` shows `["1.0.0"]` and `["latest"]`
- [ ] No auth errors during push

---

## Layer 2 — Security Groups

Variables needed:
```bash
export VPC_ID="vpc-0afa6269969fc33d9"
```

### 2.1 ALB Security Group

```bash
ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name lks-nusantara-alb-sg \
  --description "ALB SG for NusantaraShop" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=lks-nusantara-alb-sg},{Key=Project,Value=nusantara-shop}]" \
  --query 'GroupId' --output text)

echo "ALB SG: $ALB_SG_ID"

# Allow HTTP (production traffic)
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# Allow port 8080 (test traffic for Blue/Green)
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0
```

### 2.2 ECS Task Security Group

```bash
ECS_SG_ID=$(aws ec2 create-security-group \
  --group-name lks-nusantara-ecs-sg \
  --description "ECS Task SG for NusantaraShop" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=lks-nusantara-ecs-sg},{Key=Project,Value=nusantara-shop}]" \
  --query 'GroupId' --output text)

echo "ECS SG: $ECS_SG_ID"

# Allow port 5000 from ALB only
aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG_ID \
  --protocol tcp --port 5000 \
  --source-group $ALB_SG_ID
```

### 2.3 Redis Security Group

```bash
REDIS_SG_ID=$(aws ec2 create-security-group \
  --group-name lks-nusantara-redis-sg \
  --description "Redis SG for NusantaraShop" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=lks-nusantara-redis-sg},{Key=Project,Value=nusantara-shop}]" \
  --query 'GroupId' --output text)

echo "Redis SG: $REDIS_SG_ID"

# Allow Redis from ECS tasks only
aws ec2 authorize-security-group-ingress \
  --group-id $REDIS_SG_ID \
  --protocol tcp --port 6379 \
  --source-group $ECS_SG_ID
```

**Layer 2 checkpoint — verify before continuing:**
- [ ] `aws ec2 describe-security-groups --filters "Name=group-name,Values=lks-nusantara-alb-sg,lks-nusantara-ecs-sg,lks-nusantara-redis-sg" --query 'SecurityGroups[*].{Name:GroupName,Rules:IpPermissions[*].{Port:FromPort,Source:IpRanges[0].CidrIp}}'` shows 3 groups
- [ ] Redis SG allows port 6379 from ECS SG only (no 0.0.0.0/0)

---

## Layer 3 — ElastiCache Redis

### 3.1 Create Cache Subnet Group

```bash
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name lks-nusantara-redis-subnet \
  --cache-subnet-group-description "Redis subnet group" \
  --subnet-ids \
    subnet-00baa17b56177ca53 \
    subnet-06bd37455afbe4837 \
    subnet-07de5176ed29efed0 \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team
```

### 3.2 Create Redis Replication Group

Use `create-replication-group` (not `create-cache-cluster`) — this gives a proper primary endpoint in `ng.0001` format which the app requires.

```bash
aws elasticache create-replication-group \
  --replication-group-id lks-nusantara-redis \
  --replication-group-description "NusantaraShop Redis cache" \
  --cache-node-type cache.t3.micro \
  --engine redis \
  --engine-version 7.1 \
  --num-cache-clusters 1 \
  --cache-subnet-group-name lks-nusantara-redis-subnet \
  --security-group-ids $REDIS_SG_ID \
  --no-transit-encryption-enabled \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team
```

> **Note:** `--no-transit-encryption-enabled` keeps TLS off from the start. If TLS was accidentally enabled, you must do a two-step disable: `required` → `preferred` → disabled (each step waits ~10 min for cluster to become available again).

### 3.3 Wait and Get Endpoint

```bash
# Wait for cluster to become available (~5 minutes)
aws elasticache wait replication-group-available \
  --replication-group-id lks-nusantara-redis

# Get primary endpoint (ng.0001 format)
REDIS_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id lks-nusantara-redis \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
  --output text)

echo "Redis endpoint: $REDIS_ENDPOINT"
# Expected format: lks-nusantara-redis.xxxxxx.ng.0001.use1.cache.amazonaws.com
```

> **Critical:** Always use the `ng.0001` primary endpoint. Do NOT use `master.<id>.<suffix>` — that format does not exist for ElastiCache replication groups.

### 3.4 Store in SSM Parameter Store

```bash
aws ssm put-parameter \
  --name "/nusantara-shop/redis-host" \
  --value "$REDIS_ENDPOINT" \
  --type String \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production
```

**Layer 3 checkpoint — verify before continuing:**
- [ ] `aws elasticache describe-cache-clusters --cache-cluster-id lks-nusantara-redis --query 'CacheClusters[0].CacheClusterStatus'` returns `"available"`
- [ ] `aws ssm get-parameter --name /nusantara-shop/redis-host --query 'Parameter.Value'` returns the Redis hostname

---

## Layer 4 — ECS Fargate + ALB + Service

### 4.1 Create CloudWatch Log Group

```bash
aws logs create-log-group \
  --log-group-name /ecs/nusantara-shop \
  --tags Project=nusantara-shop,Environment=production,ManagedBy=LKS-Team
```

### 4.2 Create Application Load Balancer

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name lks-nusantara-alb \
  --subnets \
    subnet-00baa17b56177ca53 \
    subnet-06bd37455afbe4837 \
    subnet-07de5176ed29efed0 \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB DNS: $ALB_DNS"
```

### 4.3 Create Target Groups

```bash
# Blue target group (production traffic)
TG_BLUE_ARN=$(aws elbv2 create-target-group \
  --name lks-nusantara-tg-blue \
  --protocol HTTP \
  --port 5000 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags Key=Project,Value=nusantara-shop \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Green target group (test traffic during Blue/Green swap)
TG_GREEN_ARN=$(aws elbv2 create-target-group \
  --name lks-nusantara-tg-green \
  --protocol HTTP \
  --port 5000 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags Key=Project,Value=nusantara-shop \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

echo "Blue TG: $TG_BLUE_ARN"
echo "Green TG: $TG_GREEN_ARN"
```

### 4.4 Create ALB Listeners

```bash
# Production listener: port 80 → Blue TG
LISTENER_PROD_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_BLUE_ARN \
  --query 'Listeners[0].ListenerArn' --output text)

# Test listener: port 8080 → Green TG (CodeDeploy uses this during traffic shift)
LISTENER_TEST_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$TG_GREEN_ARN \
  --query 'Listeners[0].ListenerArn' --output text)
```

### 4.5 Create ECS Cluster

```bash
aws ecs create-cluster \
  --cluster-name lks-nusantara-cluster \
  --capacity-providers FARGATE FARGATE_SPOT \
  --tags key=Project,value=nusantara-shop key=Environment,value=production key=ManagedBy,value=LKS-Team
```

### 4.6 Register Task Definition

```bash
REDIS_ENDPOINT=$(aws ssm get-parameter \
  --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)

aws ecs register-task-definition \
  --family nusantara-shop \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 \
  --memory 512 \
  --execution-role-arn $LAB_ROLE \
  --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"nusantara-shop\",
      \"image\": \"$ECR_URI:latest\",
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
          \"awslogs-region\": \"us-east-1\",
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
  --tags key=Project,value=nusantara-shop key=Environment,value=production key=ManagedBy,value=LKS-Team
```

### 4.7 Create ECS Service with CODE_DEPLOY Controller

> **CLI vs Console difference:** `create-service` only takes the initial (blue) target group.
> The test listener (port 8080) and green target group are configured in the CodeDeploy
> deployment group at Layer 6, not here. The console combines both steps into one form.

```bash
# IMPORTANT: deployment-controller must be CODE_DEPLOY for Blue/Green
aws ecs create-service \
  --cluster lks-nusantara-cluster \
  --service-name nusantara-shop-svc \
  --task-definition nusantara-shop \
  --desired-count 2 \
  --launch-type FARGATE \
  --deployment-controller type=CODE_DEPLOY \
  --network-configuration "awsvpcConfiguration={
    subnets=[subnet-00baa17b56177ca53,subnet-06bd37455afbe4837,subnet-07de5176ed29efed0],
    securityGroups=[$ECS_SG_ID],
    assignPublicIp=ENABLED
  }" \
  --load-balancers "targetGroupArn=$TG_BLUE_ARN,containerName=nusantara-shop,containerPort=5000" \
  --tags key=Project,value=nusantara-shop key=Environment,value=production key=ManagedBy,value=LKS-Team

# Wait for 2 tasks to be running
aws ecs wait services-stable \
  --cluster lks-nusantara-cluster \
  --services nusantara-shop-svc
```

**Layer 4 checkpoint — verify before continuing:**
- [ ] `curl http://$ALB_DNS/health` returns `{"status":"ok","version":"1.0.0","color":"blue","redis":"connected"}`
- [ ] `curl http://$ALB_DNS/products` returns product list with `"source":"db"`
- [ ] `curl http://$ALB_DNS/products` again returns `"source":"cache"` (Redis working)
- [ ] ALB target group `lks-nusantara-tg-blue` shows 2 healthy targets

---

## Layer 5 — S3 Static Website (Frontend)

### 5.1 Create and Configure S3 Bucket

```bash
BUCKET_NAME="lks-nusantara-frontend-$ACCOUNT_ID"

# Create bucket (us-east-1 does NOT use LocationConstraint)
aws s3api create-bucket \
  --bucket $BUCKET_NAME \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Enable static website hosting
aws s3api put-bucket-website \
  --bucket $BUCKET_NAME \
  --website-configuration '{
    "IndexDocument": {"Suffix": "index.html"},
    "ErrorDocument": {"Key": "index.html"}
  }'

# Disable block public access
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Set public read policy
aws s3api put-bucket-policy \
  --bucket $BUCKET_NAME \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": \"*\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::$BUCKET_NAME/*\"
    }]
  }"
```

### 5.2 Set ALB URL in index.html and Upload

Open `app/static/index.html` and find line 78:
```javascript
const API = '';
```
Replace with your ALB DNS:
```javascript
const API = 'http://<YOUR-ALB-DNS>';
```

Get your ALB DNS if needed:
```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names lks-nusantara-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
echo $ALB_DNS
```

Then upload to S3:
```bash
aws s3 cp app/static/index.html s3://$BUCKET_NAME/index.html \
  --content-type text/html

WEBSITE_URL="http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com"
echo "Frontend: $WEBSITE_URL"
```

> The `index.html` in the repo keeps `const API = ''` as a placeholder. Always set the actual ALB URL before uploading — without it the frontend cannot reach the API.

**Layer 5 checkpoint — verify before continuing:**
- [ ] Open `$WEBSITE_URL` in browser — NusantaraShop UI loads
- [ ] Click "Load Products" — product cards appear, `source: db` badge visible
- [ ] Click again — `source: cache` badge appears (Redis confirmed)

---

## Layer 6 — CodeCommit + CodeDeploy (Blue/Green)

> **Note:** CodePipeline requires `codepipeline.amazonaws.com` in the IAM role trust policy. If using LabRole (AWS Academy), CodePipeline is not available. This layer uses CodeDeploy directly instead.

### 6.1 Create CodeCommit Repository

```bash
REPO_URL=$(aws codecommit create-repository \
  --repository-name nusantara-shop-app \
  --repository-description "NusantaraShop CI/CD source" \
  --tags Project=nusantara-shop,Environment=production,ManagedBy=LKS-Team \
  --query 'repositoryMetadata.cloneUrlHttp' --output text)

echo "Repo URL: $REPO_URL"
```

### 6.2 Push Deployment Files to CodeCommit

```bash
# Configure git credentials helper (one time)
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

# Clone and populate
cd /tmp
git clone $REPO_URL nusantara-app
cd nusantara-app
git checkout -b main

# Get current values
REDIS_ENDPOINT=$(aws ssm get-parameter --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)

# Copy appspec.yaml
cp /path/to/lks-ecs-codedeploy/pipeline/appspec.yaml .

# Create taskdef.json with real values (no <IMAGE1_NAME> placeholder needed for direct deploy)
cat > taskdef.json << EOF
{
  "family": "nusantara-shop",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$LAB_ROLE",
  "taskRoleArn": "$LAB_ROLE",
  "containerDefinitions": [{
    "name": "nusantara-shop",
    "image": "$ECR_URI:latest",
    "portMappings": [{"containerPort": 5000, "protocol": "tcp"}],
    "environment": [
      {"name": "APP_VERSION", "value": "1.0.0"},
      {"name": "APP_COLOR", "value": "blue"},
      {"name": "REDIS_HOST", "value": "$REDIS_ENDPOINT"},
      {"name": "REDIS_PORT", "value": "6379"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/nusantara-shop",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "essential": true,
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:5000/health || exit 1"],
      "interval": 30,
      "timeout": 5,
      "retries": 3,
      "startPeriod": 60
    }
  }]
}
EOF

git add appspec.yaml taskdef.json
git commit -m "feat: add CodeDeploy deployment files"
git push origin main
```

### 6.3 Create CodeDeploy Application

```bash
aws deploy create-application \
  --application-name lks-nusantara-app \
  --compute-platform ECS \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team
```

### 6.4 Get Listener ARNs

```bash
LISTENER_PROD_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text)

LISTENER_TEST_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query 'Listeners[?Port==`8080`].ListenerArn' --output text)

echo "Prod listener: $LISTENER_PROD_ARN"
echo "Test listener: $LISTENER_TEST_ARN"
```

### 6.5 Create CodeDeploy Deployment Group

```bash
aws deploy create-deployment-group \
  --application-name lks-nusantara-app \
  --deployment-group-name lks-nusantara-dg \
  --service-role-arn $LAB_ROLE \
  --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
  --deployment-style "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL" \
  --ecs-services "[{\"serviceName\":\"nusantara-shop-svc\",\"clusterName\":\"lks-nusantara-cluster\"}]" \
  --load-balancer-info "{
    \"targetGroupPairInfoList\": [{
      \"targetGroups\": [
        {\"name\": \"lks-nusantara-tg-blue\"},
        {\"name\": \"lks-nusantara-tg-green\"}
      ],
      \"prodTrafficRoute\": {\"listenerArns\": [\"$LISTENER_PROD_ARN\"]},
      \"testTrafficRoute\": {\"listenerArns\": [\"$LISTENER_TEST_ARN\"]}
    }]
  }" \
  --blue-green-deployment-configuration "{
    \"terminateBlueInstancesOnDeploymentSuccess\": {
      \"action\": \"TERMINATE\",
      \"terminationWaitTimeInMinutes\": 5
    },
    \"deploymentReadyOption\": {
      \"actionOnTimeout\": \"CONTINUE_DEPLOYMENT\",
      \"waitTimeInMinutes\": 0
    }
  }" \
  --auto-rollback-configuration "enabled=true,events=DEPLOYMENT_FAILURE" \
  --tags Key=Project,Value=nusantara-shop Key=Environment,Value=production Key=ManagedBy,Value=LKS-Team
```

> **Important:** `--deployment-style "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL"` is required. Without it the command fails with `InvalidDeploymentStyleException`.

### 6.6 Register Task Definition and Trigger First Deployment

```bash
# Register task def revision
NEW_TD_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/nusantara-app/taskdef.json \
  --region us-east-1 \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "Task def: $NEW_TD_ARN"

# Build appspec content inline
APPSPEC=$(python3 -c "
import json, sys
appspec = {
    'version': '0.0',
    'Resources': [{
        'TargetService': {
            'Type': 'AWS::ECS::Service',
            'Properties': {
                'TaskDefinition': '$NEW_TD_ARN',
                'LoadBalancerInfo': {
                    'ContainerName': 'nusantara-shop',
                    'ContainerPort': 5000
                }
            }
        }
    }]
}
print(json.dumps(appspec))
")

# Trigger deployment
DEPLOY_ID=$(aws deploy create-deployment \
  --application-name lks-nusantara-app \
  --deployment-group-name lks-nusantara-dg \
  --revision "{\"revisionType\":\"AppSpecContent\",\"appSpecContent\":{\"content\":$(echo $APPSPEC | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}" \
  --query 'deploymentId' --output text)

echo "Deployment: $DEPLOY_ID"
```

### 6.7 Monitor Deployment

```bash
# Poll until Succeeded or Failed
watch -n 15 "aws deploy get-deployment \
  --deployment-id $DEPLOY_ID \
  --query 'deploymentInfo.{Status:status,Overview:deploymentOverview}' \
  --output table"
```

**Layer 6 checkpoint — verify before continuing:**
- [ ] `aws deploy get-deployment --deployment-id $DEPLOY_ID --query 'deploymentInfo.status'` returns `"Succeeded"`
- [ ] `aws elbv2 describe-target-health --target-group-arn $TG_GREEN_ARN --query 'TargetHealthDescriptions[*].TargetHealth.State'` shows `"healthy"`
- [ ] `curl http://$ALB_DNS/health` returns `{"status":"ok","redis":"connected"}`

---

## Layer 7 — Blue/Green Demo (Bonus)

### 7.1 Build v2.0.0 Image (Green)

```bash
cd /path/to/lks-ecs-codedeploy/app

# Build new version with green color
docker build \
  --build-arg APP_VERSION=2.0.0 \
  -t nusantara-shop:2.0.0 \
  .

docker tag nusantara-shop:2.0.0 $ECR_URI:2.0.0

# Push to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  547849081977.dkr.ecr.us-east-1.amazonaws.com

docker push $ECR_URI:2.0.0
```

### 7.2 Register New Task Definition and Trigger Deployment

```bash
REDIS_ENDPOINT=$(aws ssm get-parameter --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)

# Register v2.0.0 task definition
NEW_TD_ARN=$(aws ecs register-task-definition \
  --family nusantara-shop \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 \
  --memory 512 \
  --execution-role-arn $LAB_ROLE \
  --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"nusantara-shop\",
      \"image\": \"$ECR_URI:2.0.0\",
      \"portMappings\": [{\"containerPort\": 5000, \"protocol\": \"tcp\"}],
      \"environment\": [
        {\"name\": \"APP_VERSION\", \"value\": \"2.0.0\"},
        {\"name\": \"APP_COLOR\", \"value\": \"green\"},
        {\"name\": \"REDIS_HOST\", \"value\": \"$REDIS_ENDPOINT\"},
        {\"name\": \"REDIS_PORT\", \"value\": \"6379\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/nusantara-shop\",
          \"awslogs-region\": \"us-east-1\",
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
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "v2.0.0 task def: $NEW_TD_ARN"

# Trigger Blue/Green deployment
APPSPEC=$(python3 -c "
import json
appspec = {
    'version': '0.0',
    'Resources': [{
        'TargetService': {
            'Type': 'AWS::ECS::Service',
            'Properties': {
                'TaskDefinition': '$NEW_TD_ARN',
                'LoadBalancerInfo': {
                    'ContainerName': 'nusantara-shop',
                    'ContainerPort': 5000
                }
            }
        }
    }]
}
print(json.dumps(appspec))
")

DEPLOY_ID=$(aws deploy create-deployment \
  --application-name lks-nusantara-app \
  --deployment-group-name lks-nusantara-dg \
  --revision "{\"revisionType\":\"AppSpecContent\",\"appSpecContent\":{\"content\":$(echo $APPSPEC | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}" \
  --query 'deploymentId' --output text)

echo "Deployment: $DEPLOY_ID"
```

### 7.3 Watch Blue/Green Traffic Shift

```bash
# During deployment: test port 8080 (green tasks) before production shift
echo "Testing GREEN tasks on port 8080:"
curl http://$ALB_DNS:8080/health

# Production port 80 still on Blue
echo "Production port 80 (still Blue):"
curl http://$ALB_DNS/health

# After deployment completes: port 80 should show v2.0.0
echo "After deployment — production:"
curl http://$ALB_DNS/health
# Expected: "version":"2.0.0","color":"green"

# Check deployment detail
DEPLOY_ID=$(aws deploy list-deployments \
  --application-name lks-nusantara-app \
  --deployment-group-name lks-nusantara-dg \
  --include-only-statuses InProgress \
  --query 'deployments[0]' --output text)

aws deploy get-deployment \
  --deployment-id $DEPLOY_ID \
  --query 'deploymentInfo.{Status:status,Blue:blueGreenDeploymentConfiguration}'
```

**Layer 7 checkpoint:**
- [ ] During deployment: `curl http://$ALB_DNS:8080/health` shows `"version":"2.0.0","color":"green"`
- [ ] Production still serves v1.0.0 during test phase
- [ ] After deployment: `curl http://$ALB_DNS/health` shows `"version":"2.0.0","color":"green"`
- [ ] Old blue tasks terminated after 5-minute wait

---

## Final Validation

```bash
# Run full validation script
chmod +x scripts/07-validate.sh
./scripts/07-validate.sh
```

Expected output: all 8 checks passing.

---

## Cleanup (Run in Order)

```bash
# 1. Delete ECS service
aws ecs update-service --cluster lks-nusantara-cluster --service nusantara-shop-svc --desired-count 0
aws ecs delete-service --cluster lks-nusantara-cluster --service nusantara-shop-svc --force

# 2. Delete ECS cluster
aws ecs delete-cluster --cluster lks-nusantara-cluster

# 3. Delete ElastiCache cluster
aws elasticache delete-cache-cluster --cache-cluster-id lks-nusantara-redis
aws elasticache delete-cache-subnet-group --cache-subnet-group-name lks-nusantara-redis-subnet

# 4. Delete ALB and target groups
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 delete-target-group --target-group-arn $TG_BLUE_ARN
aws elbv2 delete-target-group --target-group-arn $TG_GREEN_ARN

# 5. Delete security groups (wait ~2 min after ALB delete)
aws ec2 delete-security-group --group-id $ECS_SG_ID
aws ec2 delete-security-group --group-id $REDIS_SG_ID
aws ec2 delete-security-group --group-id $ALB_SG_ID

# 6. Delete ECR repository
aws ecr delete-repository --repository-name nusantara-shop --force

# 7. Delete S3 bucket
aws s3 rb s3://$BUCKET_NAME --force

# 8. Delete CodeDeploy and CodeCommit
aws deploy delete-deployment-group --application-name lks-nusantara-app --deployment-group-name lks-nusantara-dg
aws deploy delete-application --application-name lks-nusantara-app
aws codecommit delete-repository --repository-name nusantara-shop-app

# 9. Delete SSM parameter and log group
aws ssm delete-parameter --name /nusantara-shop/redis-host
aws logs delete-log-group --log-group-name /ecs/nusantara-shop
```
