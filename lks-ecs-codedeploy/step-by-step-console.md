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
| **6** | CodeCommit + CodePipeline + CodeDeploy | Pipeline Succeeded |
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
docker build -t nusantara-shop:1.0.0 -t nusantara-shop:latest app/

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

### 3.2 Create Redis Cluster

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
7. Expand **Tags** → Add:
   - `Project=nusantara-shop`, `Environment=production`, `ManagedBy=LKS-Team`
8. Click **Create**

> Wait ~5 minutes for status to change to **available**.

### 3.3 Copy Redis Endpoint

1. Click on `lks-nusantara-redis` cluster
2. Copy the **Primary endpoint** (format: `lks-nusantara-redis.xxxxx.cfg.use1.cache.amazonaws.com`)
3. Remove the `:6379` port suffix — copy only the hostname

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

### 5.4 Prepare and Upload index.html

Before uploading, inject the ALB DNS into `index.html`:

```bash
# Find ALB DNS first
ALB_DNS=$(aws elbv2 describe-load-balancers --names lks-nusantara-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

cp app/static/index.html /tmp/index.html
sed -i "s|const API = '';|const API = 'http://$ALB_DNS';|g" /tmp/index.html
```

Then upload via console or CLI:
```bash
aws s3 cp /tmp/index.html s3://lks-nusantara-frontend-547849081977/index.html \
  --content-type text/html
```

Or via Console:
1. S3 → bucket → **Objects** → **Upload** → Add file → choose modified `index.html` → Upload

### 5.5 Find Website URL

1. S3 → bucket → **Properties** → scroll to **Static website hosting**
2. Copy the **Bucket website endpoint** URL

**Layer 5 checkpoint — verify before continuing:**
- [ ] Open `http://lks-nusantara-frontend-547849081977.s3-website-us-east-1.amazonaws.com`
- [ ] NusantaraShop UI loads with header and status bar
- [ ] Click "Load Products" — product cards appear

---

## Layer 6 — CodeCommit + CodePipeline + CodeDeploy

### 6.1 Create S3 Artifact Bucket

1. S3 Console → **Create bucket**
2. **Name:** `lks-nusantara-pipeline-547849081977`, **Region:** us-east-1
3. Leave **Block Public Access** enabled
4. Enable **Versioning**: Bucket → Properties → Versioning → Enable
5. Create bucket

### 6.2 Create CodeCommit Repository

1. Open **CodeCommit Console** → **Repositories** → **Create repository**
2. Fill:
   - **Repository name:** `nusantara-shop-app`
   - **Description:** `NusantaraShop CI/CD source`
3. **Tags:** `Project=nusantara-shop`
4. Click **Create**
5. Copy the **HTTPS clone URL** (format: `https://git-codecommit.us-east-1.amazonaws.com/v1/repos/nusantara-shop-app`)

### 6.3 Push Pipeline Files to CodeCommit

```bash
# Configure git credentials helper (one time)
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

# Clone repo
git clone https://git-codecommit.us-east-1.amazonaws.com/v1/repos/nusantara-shop-app /tmp/nusantara-app
cd /tmp/nusantara-app
git checkout -b main

# Get current values
ECR_URI="547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop"
REDIS_ENDPOINT=$(aws ssm get-parameter --name /nusantara-shop/redis-host \
  --query 'Parameter.Value' --output text)

# Copy and update appspec.yaml
cp /path/to/lks-ecs-codedeploy/pipeline/appspec.yaml .

# Create taskdef.json with real values
cat > taskdef.json << 'TASKDEF'
{
  "family": "nusantara-shop",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::547849081977:role/LabRole",
  "taskRoleArn": "arn:aws:iam::547849081977:role/LabRole",
  "containerDefinitions": [{
    "name": "nusantara-shop",
    "image": "<IMAGE1_NAME>",
    "portMappings": [{"containerPort": 5000, "protocol": "tcp"}],
    "environment": [
      {"name": "APP_VERSION", "value": "1.0.0"},
      {"name": "APP_COLOR", "value": "blue"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/nusantara-shop",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "essential": true
  }]
}
TASKDEF

# Create imageDetail.json with current ECR image
cat > imageDetail.json << EOF
{"ImageURI": "$ECR_URI:latest"}
EOF

git add appspec.yaml taskdef.json imageDetail.json
git commit -m "feat: initial CI/CD pipeline configuration"
git push origin main
```

### 6.4 Create CodeDeploy Application

1. Open **CodeDeploy Console** → **Applications** → **Create application**
2. Fill:
   - **Application name:** `lks-nusantara-app`
   - **Compute platform:** Amazon ECS
3. Click **Create application**

### 6.5 Create CodeDeploy Deployment Group

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

### 6.6 Create CodePipeline

1. Open **CodePipeline Console** → **Pipelines** → **Create pipeline**
2. **Pipeline settings:**
   - **Pipeline name:** `lks-nusantara-pipeline`
   - **Service role:** Existing service role → `LabRole`
   - **Artifact store:** Custom location → S3 bucket → `lks-nusantara-pipeline-547849081977`
3. Click **Next**
4. **Source stage:**
   - **Source provider:** AWS CodeCommit
   - **Repository:** `nusantara-shop-app`
   - **Branch:** `main`
   - **Detection option:** Amazon CloudWatch Events (recommended)
5. Click **Next**
6. **Build stage:** Click **Skip build stage** (no CodeBuild in this lab)
7. **Deploy stage:**
   - **Deploy provider:** Amazon ECS (Blue/Green)
   - **Application name:** `lks-nusantara-app`
   - **Deployment group:** `lks-nusantara-dg`
   - **Amazon ECS task definition:** SourceArtifact → `taskdef.json`
   - **AWS CodeDeploy AppSpec file:** SourceArtifact → `appspec.yaml`
   - **Input artifact with image details:** SourceArtifact → `imageDetail.json`
   - **Placeholder text in the task definition:** `IMAGE1_NAME`
8. Click **Next** → **Create pipeline**

### 6.7 Monitor Pipeline

1. Pipeline automatically triggers after creation
2. Watch **Source** stage → wait for **Succeeded**
3. Watch **Deploy** stage → CodeDeploy Blue/Green deployment starts
4. Click **Details** link → opens CodeDeploy deployment page
5. Watch deployment lifecycle:
   - Create replacement task set (Green tasks start)
   - Install → Allow test traffic → Reroute production traffic
   - Terminate original task set (after 5 min wait)

**Layer 6 checkpoint — verify before continuing:**
- [ ] CodePipeline → `lks-nusantara-pipeline` → both stages show **Succeeded** (green checkmark)
- [ ] CodeDeploy → `lks-nusantara-app` → Deployments → latest shows **Succeeded**
- [ ] ECS → `nusantara-shop-svc` → still shows 2 running tasks

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

### 7.2 Trigger New Deployment via Console

1. Go to `/tmp/nusantara-app` (cloned CodeCommit repo)
2. Update `imageDetail.json`:
```json
{"ImageURI": "547849081977.dkr.ecr.us-east-1.amazonaws.com/nusantara-shop:2.0.0"}
```
3. Update `taskdef.json` — change:
   - `"APP_VERSION"` value: `"1.0.0"` → `"2.0.0"`
   - `"APP_COLOR"` value: `"blue"` → `"green"`
4. Commit and push:
```bash
git add imageDetail.json taskdef.json
git commit -m "feat: deploy v2.0.0 green"
git push origin main
```

### 7.3 Watch Blue/Green in Console

1. **CodePipeline** → `lks-nusantara-pipeline` → watch Deploy stage start
2. Click **Details** → CodeDeploy deployment page
3. Watch **Deployment lifecycle events**:
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
10. **S3** → Empty then delete `lks-nusantara-frontend-547849081977` and `lks-nusantara-pipeline-547849081977`
11. **CodePipeline** → Delete `lks-nusantara-pipeline`
12. **CodeDeploy** → Delete deployment group → Delete application
13. **CodeCommit** → Delete `nusantara-shop-app` repository
14. **SSM** → Parameter Store → Delete `/nusantara-shop/redis-host`
15. **CloudWatch** → Log groups → Delete `/ecs/nusantara-shop`
