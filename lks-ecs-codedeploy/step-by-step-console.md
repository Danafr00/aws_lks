# Step-by-Step Answer Key (AWS Console)

**Module:** ECS Blue/Green CI/CD with ElastiCache  
**Region:** us-east-1  
**Account:** 547849081977  
**LabRole ARN:** `arn:aws:iam::547849081977:role/LabRole`

> All layer names and checkpoints match `step-by-step.md`.

---

## Layer Table

| Layer | What You Build | Checkpoint |
|---|---|---|
| **1** | ECR + Docker build + push | Console shows image with 2 tags |
| **2** | Security Groups (ALB / ECS / Redis) | 3 SGs visible in EC2 console |
| **3** | ElastiCache Redis + SSM parameter | Status = available |
| **4** | ECS Fargate + ALB + Target Groups + Service | `curl ALB/health` → `{"status":"ok","redis":"connected"}` |
| **5** | S3 Static Website (frontend) | Browser opens, products load |
| **6** | CodeCommit + CodeDeploy (Blue/Green) | Deployment Succeeded, traffic on green |
| **7** | Blue/Green demo (v2.0.0) | `/health` returns version 2.0.0 |

---

## Layer 1 — ECR + Docker Build + Push

### 1.1 Create ECR Repository

1. Open **AWS Console** → search `ECR` → **Elastic Container Registry**
2. Click **Create repository**
3. Fill in:
   - **Visibility:** Private
   - **Repository name:** `nusantara-shop`
   - **Image scan settings:** Enable *Scan on push*
4. Scroll to **Tags** → Add:
   - `Project` = `nusantara-shop`
   - `Environment` = `production`
   - `ManagedBy` = `LKS-Team`
5. Click **Create repository**

### 1.2 Build and Push Image (Terminal Required)

ECR push requires Docker CLI. Run these commands in your terminal:

```bash
export ACCOUNT_ID=547849081977
export ECR_URI="$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"

# Authenticate
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# Build (from app/ directory)
# --platform linux/amd64 is required on Apple Silicon (M1/M2/M3)
docker buildx build --platform linux/amd64 \
  -t nusantara-shop:1.0.0 -t nusantara-shop:latest app/

# Tag and push
docker tag nusantara-shop:1.0.0 $ECR_URI:1.0.0
docker tag nusantara-shop:latest $ECR_URI:latest
docker push $ECR_URI:1.0.0
docker push $ECR_URI:latest
```

### 1.3 Verify in Console

1. Return to ECR → `nusantara-shop` repository
2. Click **Images** tab
3. Confirm 2 image tags: `1.0.0` and `latest`

**Layer 1 checkpoint — verify before continuing:**
- [ ] Console shows image tags `1.0.0` and `latest` in ECR repository

---

## Layer 2 — Security Groups

Navigate to **EC2 Console** → **Security Groups** (left panel under Network & Security).

### 2.1 ALB Security Group

1. Click **Create security group**
2. Fill:
   - **Name:** `lks-nusantara-alb-sg`
   - **Description:** `ALB SG for NusantaraShop`
   - **VPC:** Select `vpc-0afa6269969fc33d9` (172.31.0.0/16)
3. **Inbound rules** → Add rule:
   - Type: `HTTP`, Port: `80`, Source: `0.0.0.0/0`
4. Add another rule:
   - Type: `Custom TCP`, Port range: `8080`, Source: `0.0.0.0/0`
5. **Tags:** `Name=lks-nusantara-alb-sg`, `Project=nusantara-shop`
6. Click **Create security group** → Copy the **Security group ID** (e.g., `sg-xxxxxxxxx`)

### 2.2 ECS Task Security Group

1. Click **Create security group**
2. Fill:
   - **Name:** `lks-nusantara-ecs-sg`
   - **Description:** `ECS Task SG for NusantaraShop`
   - **VPC:** `vpc-0afa6269969fc33d9`
3. **Inbound rules** → Add rule:
   - Type: `Custom TCP`, Port: `5000`
   - Source: *Custom* → type/select `lks-nusantara-alb-sg` (the SG ID from step 2.1)
4. **Tags:** `Name=lks-nusantara-ecs-sg`, `Project=nusantara-shop`
5. Click **Create security group**

### 2.3 Redis Security Group

1. Click **Create security group**
2. Fill:
   - **Name:** `lks-nusantara-redis-sg`
   - **Description:** `Redis SG for NusantaraShop`
   - **VPC:** `vpc-0afa6269969fc33d9`
3. **Inbound rules** → Add rule:
   - Type: `Custom TCP`, Port: `6379`
   - Source: *Custom* → select `lks-nusantara-ecs-sg`
4. **Tags:** `Name=lks-nusantara-redis-sg`, `Project=nusantara-shop`
5. Click **Create security group**

**Layer 2 checkpoint — verify before continuing:**
- [ ] EC2 → Security Groups shows 3 new groups with names `lks-nusantara-alb-sg`, `lks-nusantara-ecs-sg`, `lks-nusantara-redis-sg`
- [ ] Redis SG inbound shows port 6379 from ECS SG only

---

## Layer 3 — ElastiCache Redis

### 3.1 Create Subnet Group

1. Open **ElastiCache Console** → **Subnet groups** (left panel)
2. Click **Create subnet group**
3. Fill:
   - **Name:** `lks-nusantara-redis-subnet`
   - **Description:** `Redis subnet group for NusantaraShop`
   - **VPC:** `vpc-0afa6269969fc33d9`
4. Under **Subnets**, select:
   - `us-east-1a` → `subnet-00baa17b56177ca53`
   - `us-east-1b` → `subnet-06bd37455afbe4837`
   - `us-east-1c` → `subnet-07de5176ed29efed0`
5. Click **Create**

### 3.2 Create Redis Replication Group

1. **ElastiCache** → **Redis clusters** → **Create Redis cluster**
2. **Cluster mode:** Disabled
3. Fill:
   - **Cluster name:** `lks-nusantara-redis`
   - **Location:** AWS Cloud
   - **Node type:** `cache.t3.micro`
   - **Number of replicas:** `0` (single node for lab)
4. **Subnet group:** `lks-nusantara-redis-subnet`
5. **Security:** Select `lks-nusantara-redis-sg`
6. **Engine version:** `7.1`
7. **Encryption in transit:** **Disabled** — do not enable TLS
8. Expand **Tags** → Add:
   - `Project=nusantara-shop`, `Environment=production`, `ManagedBy=LKS-Team`
9. Click **Create**

> Wait ~5 minutes for status to change to **available**.

### 3.3 Copy Redis Endpoint

1. Click on `lks-nusantara-redis` cluster
2. Copy the **Primary endpoint** (format: `lks-nusantara-redis.xxxxx.ng.0001.use1.cache.amazonaws.com`)
3. Remove the `:6379` port suffix — copy only the hostname

> **Critical:** Use the primary endpoint in `ng.0001` format exactly as shown. Do NOT use `master.<id>.<suffix>` — that hostname does not exist for ElastiCache replication groups.

### 3.4 Store Endpoint in SSM Parameter Store

1. Open **Systems Manager Console** → **Parameter Store** → **Create parameter**
2. Fill:
   - **Name:** `/nusantara-shop/redis-host`
   - **Tier:** Standard
   - **Type:** String
   - **Value:** Paste the Redis hostname from step 3.3
3. Click **Create parameter**

**Layer 3 checkpoint — verify before continuing:**
- [ ] ElastiCache → Redis clusters shows `lks-nusantara-redis` with Status = **available**
- [ ] SSM Parameter Store shows `/nusantara-shop/redis-host` with the Redis hostname

---

## Layer 4 — ECS Fargate + ALB + Service

### 4.1 Create CloudWatch Log Group

1. Open **CloudWatch Console** → **Log groups** → **Create log group**
2. **Log group name:** `/ecs/nusantara-shop`
3. **Tags:** `Project=nusantara-shop`
4. Click **Create**

### 4.2 Create Application Load Balancer

1. Open **EC2 Console** → **Load Balancers** → **Create load balancer**
2. Select **Application Load Balancer** → **Create**
3. Fill:
   - **Name:** `lks-nusantara-alb`
   - **Scheme:** Internet-facing
   - **IP address type:** IPv4
4. **Network mapping:**
   - VPC: `vpc-0afa6269969fc33d9`
   - Subnets: select `us-east-1a`, `us-east-1b`, `us-east-1c`
5. **Security groups:** Remove default, add `lks-nusantara-alb-sg`
6. **Listeners and routing:** Keep port 80, target group → create new:
   - Click **Create target group** (new tab)

### 4.3 Create Blue Target Group (from the new tab)

1. **Target type:** IP addresses
2. **Name:** `lks-nusantara-tg-blue`
3. **Protocol:** HTTP, **Port:** `5000`
4. **VPC:** `vpc-0afa6269969fc33d9`
5. **Health checks:**
   - Protocol: HTTP
   - Path: `/health`
   - Healthy threshold: 2
   - Interval: 30 seconds
6. Click **Next** → **Create target group** (no targets to register — ECS handles this)
7. Return to ALB tab, refresh target group dropdown, select `lks-nusantara-tg-blue`
8. **Tags:** `Project=nusantara-shop`
9. Click **Create load balancer**

### 4.4 Create Green Target Group

1. **EC2** → **Target Groups** → **Create target group**
2. Same settings as Blue TG but:
   - **Name:** `lks-nusantara-tg-green`
3. Click **Create target group**

### 4.5 Add Test Listener (Port 8080)

1. **EC2** → **Load Balancers** → click `lks-nusantara-alb`
2. **Listeners** tab → **Add listener**
3. **Protocol:** HTTP, **Port:** `8080`
4. **Default action:** Forward → `lks-nusantara-tg-green`
5. Click **Add**

### 4.6 Create ECS Cluster

1. Open **ECS Console** → **Clusters** → **Create cluster**
2. **Cluster name:** `lks-nusantara-cluster`
3. **Infrastructure:** Fargate (keep checked)
4. **Tags:** `Project=nusantara-shop`, `Environment=production`, `ManagedBy=LKS-Team`
5. Click **Create**

### 4.7 Create Task Definition

1. **ECS** → **Task definitions** → **Create new task definition**
2. Fill:
   - **Family:** `nusantara-shop`
   - **Launch type:** Fargate
   - **Operating system:** Linux/X86_64
   - **CPU:** 0.25 vCPU
   - **Memory:** 0.5 GB
   - **Task role:** `LabRole`
   - **Task execution role:** `LabRole`
3. **Container 1:**
   - **Name:** `nusantara-shop`
   - **Image URI:** `547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop:latest`
   - **Port mapping:** Container port `5000`, TCP
4. **Environment variables:**
   - `APP_VERSION` = `1.0.0`
   - `APP_COLOR` = `blue`
   - `REDIS_HOST` = *(paste Redis hostname from SSM)*
   - `REDIS_PORT` = `6379`
5. **Logging:**
   - Log collection: enabled
   - Log driver: `awslogs`
   - Log group: `/ecs/nusantara-shop`
   - Region: `us-east-1`
   - Stream prefix: `ecs`
6. **Health check command:** `CMD-SHELL, curl -f http://localhost:5000/health || exit 1`
7. **Health check:**
   - Interval: 30
   - Timeout: 5
   - Retries: 3
   - Start period: 60
8. Click **Create**

### 4.8 Create ECS Service

1. **ECS** → **Clusters** → `lks-nusantara-cluster` → **Services** tab → **Create**
2. **Compute options:** Launch type → Fargate
3. **Deployment configuration:**
   - **Family:** `nusantara-shop`
   - **Revision:** LATEST
   - **Service name:** `nusantara-shop-svc`
   - **Desired tasks:** `2`
4. **Deployment options:**
   - **Deployment type:** Blue/green deployment (powered by AWS CodeDeploy)  
   > ⚠️ This sets deployment controller to CODE_DEPLOY — required for Blue/Green
5. **Deployment configuration:** `CodeDeployDefault.ECSAllAtOnce`
6. **Service Connect:** disabled for now
7. **Networking:**
   - VPC: `vpc-0afa6269969fc33d9`
   - Subnets: `us-east-1a`, `us-east-1b`, `us-east-1c`
   - Security group: `lks-nusantara-ecs-sg`
   - Public IP: **Turned on** (required for Fargate to pull ECR image without NAT Gateway)
8. **Load balancing:**
   - Load balancer type: Application Load Balancer
   - Load balancer: `lks-nusantara-alb`
   - Container to load balance: `nusantara-shop 5000:5000`
   - **Production listener port:** 80:HTTP
   - **Test listener port:** 8080:HTTP
   - **Target group 1 (Blue):** `lks-nusantara-tg-blue`
   - **Target group 2 (Green):** `lks-nusantara-tg-green`
9. Click **Create**

> Wait ~3–5 minutes for 2 tasks to reach **Running** state.

**Layer 4 checkpoint — verify before continuing:**
- [ ] ECS → Clusters → `lks-nusantara-cluster` → Services shows `nusantara-shop-svc` with 2/2 Running
- [ ] EC2 → Target Groups → `lks-nusantara-tg-blue` → Targets tab shows 2 healthy IPs
- [ ] Run: `curl http://<ALB-DNS>/health` → `{"status":"ok","redis":"connected","version":"1.0.0"}`
- [ ] Run twice: first `"source":"db"`, second `"source":"cache"` from `/products`

> Find ALB DNS: EC2 → Load Balancers → `lks-nusantara-alb` → **DNS name**

---

## Layer 5 — S3 Static Website (Frontend)

### 5.1 Create S3 Bucket

1. Open **S3 Console** → **Create bucket**
2. Fill:
   - **Bucket name:** `lks-nusantara-frontend-547849081977`
   - **Region:** us-east-1
   - **Object Ownership:** ACLs disabled
3. **Block Public Access:** Uncheck all 4 boxes → Confirm
4. Click **Create bucket**

### 5.2 Enable Static Website Hosting

1. Click bucket → **Properties** tab
2. Scroll to **Static website hosting** → Edit
3. Enable → **Index document:** `index.html` → **Error document:** `index.html`
4. Save

### 5.3 Set Bucket Policy

1. **Permissions** tab → **Bucket policy** → Edit
2. Paste:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::lks-nusantara-frontend-547849081977/*"
  }]
}
```
3. Save

### 5.4 Set ALB URL and Upload index.html

1. Find your ALB DNS name: **EC2** → **Load Balancers** → `lks-nusantara-alb` → copy **DNS name**

2. Open `app/static/index.html` in a text editor and find line 78:
   ```javascript
   const API = '';
   ```
   Replace with your ALB DNS:
   ```javascript
   const API = 'http://<YOUR-ALB-DNS-HERE>';
   ```
   Save the file.

3. Upload via CLI:
   ```bash
   aws s3 cp app/static/index.html s3://lks-nusantara-frontend-547849081977/index.html \
     --content-type text/html
   ```
   Or via Console: S3 → bucket → **Objects** → **Upload** → choose the modified `index.html` → Upload

> The `index.html` source file keeps `const API = ''` as a placeholder. You must set the real ALB URL before uploading — the S3 page cannot reach the API without it.

### 5.5 Find Website URL

1. S3 → bucket → **Properties** → scroll to **Static website hosting**
2. Copy the **Bucket website endpoint** URL

**Layer 5 checkpoint — verify before continuing:**
- [ ] Open `http://lks-nusantara-frontend-547849081977.s3-website-us-east-1.amazonaws.com`
- [ ] NusantaraShop UI loads with header and status bar
- [ ] Click "Load Products" — product cards appear

---

## Layer 6 — CodeCommit + CodeDeploy (Blue/Green)

> **Note:** CodePipeline requires `codepipeline.amazonaws.com` in the IAM role trust policy. LabRole (AWS Academy) does not include it. This layer uses CodeDeploy directly instead.

### 6.1 Create CodeCommit Repository

1. Open **CodeCommit Console** → **Repositories** → **Create repository**
2. Fill:
   - **Repository name:** `nusantara-shop-app`
   - **Description:** `NusantaraShop CI/CD source`
3. **Tags:** `Project=nusantara-shop`
4. Click **Create**
5. Copy the **HTTPS clone URL**

### 6.2 Push Deployment Files to CodeCommit

```bash
# Configure git credentials helper (one time)
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

git clone https://git-codecommit.us-east-1.amazonaws.com/v1/repos/nusantara-shop-app /tmp/nusantara-app
cd /tmp/nusantara-app
git checkout -b main

ECR_URI="547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"
REDIS_ENDPOINT=$(aws ssm get-parameter --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)
LAB_ROLE="arn:aws:iam::547849081977:role/LabRole"

cp /path/to/lks-ecs-codedeploy/pipeline/appspec.yaml .

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
      "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 60
    }
  }]
}
EOF

git add appspec.yaml taskdef.json
git commit -m "feat: add CodeDeploy deployment files"
git push origin main
```

### 6.3 Create CodeDeploy Application

1. Open **CodeDeploy Console** → **Applications** → **Create application**
2. Fill:
   - **Application name:** `lks-nusantara-app`
   - **Compute platform:** Amazon ECS
3. Click **Create application**

### 6.4 Create CodeDeploy Deployment Group

1. Click `lks-nusantara-app` → **Deployment groups** → **Create deployment group**
2. Fill:
   - **Deployment group name:** `lks-nusantara-dg`
   - **Service role:** `LabRole`
3. **Deployment settings:**
   - **Deployment type:** Blue/green
   - How to specify replacement tasks: *Automatically copy Amazon ECS service*
   - Amazon ECS cluster: `lks-nusantara-cluster`
   - Amazon ECS service: `nusantara-shop-svc`
4. **Load balancer:**
   - Application Load Balancer: `lks-nusantara-alb`
   - Production listener: port `80`
   - Test listener: port `8080`
   - Target group 1 (Blue): `lks-nusantara-tg-blue`
   - Target group 2 (Green): `lks-nusantara-tg-green`
5. **Deployment settings:**
   - Traffic rerouting: *Reroute traffic immediately*
   - Original revision termination: 5 minutes
   - Deployment configuration: `CodeDeployDefault.ECSAllAtOnce`
6. **Rollbacks:** Enable *Roll back when a deployment fails*
7. **Tags:** `Project=nusantara-shop`
8. Click **Create deployment group**

### 6.5 Trigger First CodeDeploy Deployment (CLI)

CodeDeploy ECS deployments must be triggered via CLI (console requires an artifact store with a specific format):

```bash
ECR_URI="547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"
LAB_ROLE="arn:aws:iam::547849081977:role/LabRole"
REDIS_ENDPOINT=$(aws ssm get-parameter --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)

# Register new task definition revision
NEW_TD_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/nusantara-app/taskdef.json \
  --region us-east-1 \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "Task def: $NEW_TD_ARN"

# Build appspec and trigger deployment
APPSPEC=$(python3 -c "
import json
appspec = {
    'version': '0.0',
    'Resources': [{'TargetService': {'Type': 'AWS::ECS::Service', 'Properties': {
        'TaskDefinition': '$NEW_TD_ARN',
        'LoadBalancerInfo': {'ContainerName': 'nusantara-shop', 'ContainerPort': 5000}
    }}}]
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

### 6.6 Monitor Deployment in Console

1. **CodeDeploy Console** → **Applications** → `lks-nusantara-app` → **Deployments**
2. Click the deployment ID → watch lifecycle events:
   - *Create replacement task set* — green tasks launch
   - *Allow test traffic* — green tasks register to green TG (port 8080)
   - *Reroute production traffic* — port 80 shifts to green tasks
   - *Terminate original task set* — old blue tasks stop after 5 min
3. Status changes to **Succeeded**

**Layer 6 checkpoint — verify before continuing:**
- [ ] CodeDeploy → `lks-nusantara-app` → Deployments → latest shows **Succeeded**
- [ ] EC2 → Target Groups → `lks-nusantara-tg-green` → Targets shows 2 healthy IPs
- [ ] `curl http://<ALB-DNS>/health` returns `{"status":"ok","redis":"connected"}`

---

## Layer 7 — Blue/Green Demo (Bonus)

### 7.1 Build v2.0.0 Image

```bash
ECR_URI="547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"

docker build -t nusantara-shop:2.0.0 app/

docker tag nusantara-shop:2.0.0 $ECR_URI:2.0.0

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  547849081977.dkr.ecr.us-east-1.amazonaws.com

docker push $ECR_URI:2.0.0
```

### 7.2 Register v2.0.0 Task Definition and Trigger Deployment

```bash
ECR_URI="547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"
LAB_ROLE="arn:aws:iam::547849081977:role/LabRole"
REDIS_ENDPOINT=$(aws ssm get-parameter --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)

# Register v2.0.0 task definition
NEW_TD_ARN=$(aws ecs register-task-definition \
  --family nusantara-shop \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --execution-role-arn $LAB_ROLE \
  --task-role-arn $LAB_ROLE \
  --container-definitions "[{
    \"name\": \"nusantara-shop\",
    \"image\": \"$ECR_URI:2.0.0\",
    \"portMappings\": [{\"containerPort\": 5000, \"protocol\": \"tcp\"}],
    \"environment\": [
      {\"name\": \"APP_VERSION\", \"value\": \"2.0.0\"},
      {\"name\": \"APP_COLOR\", \"value\": \"green\"},
      {\"name\": \"REDIS_HOST\", \"value\": \"$REDIS_ENDPOINT\"},
      {\"name\": \"REDIS_PORT\", \"value\": \"6379\"}
    ],
    \"logConfiguration\": {\"logDriver\": \"awslogs\", \"options\": {
      \"awslogs-group\": \"/ecs/nusantara-shop\",
      \"awslogs-region\": \"us-east-1\",
      \"awslogs-stream-prefix\": \"ecs\"
    }},
    \"essential\": true,
    \"healthCheck\": {\"command\": [\"CMD-SHELL\", \"curl -f http://localhost:5000/health || exit 1\"],
      \"interval\": 30, \"timeout\": 5, \"retries\": 3, \"startPeriod\": 60}
  }]" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "v2.0.0 task def: $NEW_TD_ARN"

# Trigger Blue/Green deployment
APPSPEC=$(python3 -c "
import json
appspec = {'version': '0.0', 'Resources': [{'TargetService': {'Type': 'AWS::ECS::Service', 'Properties': {
    'TaskDefinition': '$NEW_TD_ARN',
    'LoadBalancerInfo': {'ContainerName': 'nusantara-shop', 'ContainerPort': 5000}
}}}]}
print(json.dumps(appspec))
")

DEPLOY_ID=$(aws deploy create-deployment \
  --application-name lks-nusantara-app \
  --deployment-group-name lks-nusantara-dg \
  --revision "{\"revisionType\":\"AppSpecContent\",\"appSpecContent\":{\"content\":$(echo $APPSPEC | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}" \
  --query 'deploymentId' --output text)

echo "Deployment: $DEPLOY_ID"
```

### 7.3 Watch Blue/Green in Console

1. **CodeDeploy** → `lks-nusantara-app` → **Deployments** → click the new deployment ID
2. Watch **Deployment lifecycle events**:
   - `ApplicationStop` → `BeforeInstall` → `AfterInstall` (Green tasks starting)
   - `AllowTestTraffic` — test on port 8080:
     ```bash
     ALB_DNS=$(aws elbv2 describe-load-balancers --names lks-nusantara-alb \
       --query 'LoadBalancers[0].DNSName' --output text)
     curl http://$ALB_DNS:8080/health
     # Returns: "version":"2.0.0","color":"green"
     # Port 80 still returns: "version":"1.0.0","color":"blue"
     ```
   - `AllowTraffic` — production traffic shifts to Green
   - `AfterAllowTraffic` → `ApplicationStart` → `ValidateService`
   - Old Blue tasks terminate after 5 minutes

4. After deployment completes:
```bash
curl http://$ALB_DNS/health
# Expected: {"status":"ok","version":"2.0.0","color":"green","redis":"connected"}
```

**Layer 7 checkpoint:**
- [ ] During deployment: port 8080 shows v2.0.0, port 80 shows v1.0.0
- [ ] After completion: port 80 shows v2.0.0
- [ ] ECR shows 3 image tags: `1.0.0`, `2.0.0`, `latest`

---

## Console Monitoring Tips

| What to Check | Where in Console |
|---|---|
| ECS task logs | CloudWatch → Log groups → `/ecs/nusantara-shop` |
| ALB target health | EC2 → Target Groups → select TG → Targets tab |
| ECS task status | ECS → Cluster → Service → Tasks tab |
| Redis metrics | ElastiCache → Metrics tab on cluster |
| Pipeline history | CodePipeline → Pipeline → History |
| Deployment details | CodeDeploy → Application → Deployments |

---

## Cleanup (Console Order)

1. **ECS** → Cluster → Service → Update → Desired tasks = 0 → Update
2. **ECS** → Cluster → Service → Delete
3. **ECS** → Cluster → Delete
4. **ElastiCache** → Clusters → Delete `lks-nusantara-redis`
5. **ElastiCache** → Subnet groups → Delete `lks-nusantara-redis-subnet`
6. **EC2** → Load Balancers → Delete `lks-nusantara-alb`
7. **EC2** → Target Groups → Delete both `lks-nusantara-tg-blue` and `lks-nusantara-tg-green`
8. **EC2** → Security Groups → Delete in order: ECS SG → Redis SG → ALB SG (wait 2 min after ALB delete)
9. **ECR** → Delete `nusantara-shop` repository
10. **S3** → Empty then delete `lks-nusantara-frontend-547849081977`
11. **CodeDeploy** → Delete deployment group → Delete application
12. **CodeCommit** → Delete `nusantara-shop-app` repository
14. **SSM** → Parameter Store → Delete `/nusantara-shop/redis-host`
15. **CloudWatch** → Log groups → Delete `/ecs/nusantara-shop`
