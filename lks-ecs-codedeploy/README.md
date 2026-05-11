# LKS Cloud Computing — ECS Blue/Green CI/CD with ElastiCache

**Difficulty:** ★★★★☆  
**Estimated Time:** 90–120 minutes  
**Region:** us-east-1

---

## Scenario

PT Nusantara Digital has built a product catalog API called **NusantaraShop**. The team needs a production-grade deployment pipeline that allows zero-downtime deployments with instant rollback capability. The ops team has requested:

1. Containerized API deployed on **Amazon ECS Fargate** with **Blue/Green deployments** via AWS CodeDeploy
2. **Redis caching layer** using Amazon ElastiCache to reduce database load
3. Automated pipeline triggered by code commits to **AWS CodeCommit**
4. **Static frontend** served from Amazon S3 with website hosting enabled
5. Full observability via **Amazon CloudWatch Logs**

You are not allowed to create IAM roles or policies. Use the existing `LabRole` for all service roles.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Developer                                               │
│  pushes code                                             │
│       │                                                  │
│       ▼                                                  │
│  AWS CodeCommit ──► AWS CodePipeline                     │
│                          │                               │
│                          ▼                               │
│                   AWS CodeDeploy                         │
│                   (Blue/Green)                           │
│                     │       │                            │
│                  Blue       Green                        │
│                  Tasks      Tasks                        │
│                     │       │                            │
│              ┌──────┴───────┘                            │
│              ▼                                           │
│         Application Load Balancer                        │
│         Port 80 (prod) / Port 8080 (test)                │
│              │                                           │
│              ▼                                           │
│      ECS Fargate Service                                 │
│      (nusantara-shop container)                          │
│              │                                           │
│              ▼                                           │
│     Amazon ElastiCache Redis                             │
│     (product catalog cache)                              │
│                                                          │
│  Amazon S3 Static Website                                │
│  (frontend — calls ALB API)                              │
│                                                          │
│  Amazon ECR                                              │
│  (container image registry)                              │
└─────────────────────────────────────────────────────────┘
```

---

## Tasks

### Task 1 — Container Registry (15 pts)

Create an Amazon ECR repository named `nusantara-shop`. Build the Docker image from the provided `app/` directory and push it to ECR with tags `1.0.0` and `latest`.

**Deliverable:** ECR repository with at least one image pushed. Screenshot or CLI output showing image digest.

---

### Task 2 — Network Security (10 pts)

Create three security groups in the default VPC:

| Security Group | Inbound Rules |
|---|---|
| `lks-nusantara-alb-sg` | TCP 80 from 0.0.0.0/0, TCP 8080 from 0.0.0.0/0 |
| `lks-nusantara-ecs-sg` | TCP 5000 from `lks-nusantara-alb-sg` only |
| `lks-nusantara-redis-sg` | TCP 6379 from `lks-nusantara-ecs-sg` only |

**Deliverable:** Three security groups with correct inbound rules shown in console or CLI.

---

### Task 3 — Caching Layer (20 pts)

Deploy an Amazon ElastiCache Redis cluster with the following specifications:

- Cluster ID: `lks-nusantara-redis`
- Node type: `cache.t3.micro`
- Engine: Redis 7.x
- Nodes: 1

Store the Redis endpoint in AWS SSM Parameter Store at path `/nusantara-shop/redis-host`.

**Deliverable:** ElastiCache cluster in `available` state. SSM parameter stored. Verify app reads `"redis": "connected"` from `/health` endpoint.

---

### Task 4 — ECS Fargate Service (25 pts)

Deploy the NusantaraShop container on Amazon ECS Fargate:

- Cluster: `lks-nusantara-cluster`
- Service: `nusantara-shop-svc` with **2 desired tasks**
- Task definition: `nusantara-shop` (0.25 vCPU / 512 MB)
- Deployment controller: **CODE_DEPLOY** (required for Blue/Green)
- Load balancer: Application Load Balancer `lks-nusantara-alb`
  - Production listener: port 80 → target group `lks-nusantara-tg-blue`
  - Test listener: port 8080 → target group `lks-nusantara-tg-green`
- Container logs: CloudWatch Logs group `/ecs/nusantara-shop`
- Execution role + Task role: `LabRole`

**Deliverable:** `curl http://<ALB-DNS>/health` returns `{"status":"ok","redis":"connected","version":"1.0.0"}`.

---

### Task 5 — Static Frontend (10 pts)

Create an S3 bucket `lks-nusantara-frontend-<ACCOUNT_ID>` with static website hosting enabled. Upload `app/static/index.html` (inject the ALB DNS as the API base URL before uploading). Enable public read access.

**Deliverable:** S3 website URL loads the NusantaraShop UI. Clicking "Load Products" returns data.

---

### Task 6 — CI/CD Pipeline (20 pts)

Set up the full CI/CD pipeline:

1. **AWS CodeCommit** repository named `nusantara-shop-app`
2. **AWS CodeDeploy** application `lks-nusantara-app` (ECS compute platform)
3. **CodeDeploy deployment group** `lks-nusantara-dg` with Blue/Green configuration:
   - Blue TG: `lks-nusantara-tg-blue` (production)
   - Green TG: `lks-nusantara-tg-green` (test)
   - Termination wait: 5 minutes
   - Auto-rollback on deployment failure
4. **AWS CodePipeline** `lks-nusantara-pipeline`:
   - Source: CodeCommit (`main` branch)
   - Deploy: CodeDeployToECS using `taskdef.json` + `appspec.yaml` + `imageDetail.json`

Commit the pipeline files (`appspec.yaml`, `taskdef.json`, `imageDetail.json`) to the CodeCommit repo and verify the pipeline runs successfully.

**Deliverable:** Pipeline shows `Succeeded` status. CodeDeploy console shows a completed Blue/Green deployment.

---

### Task 7 — Blue/Green Demo (Bonus 10 pts)

Demonstrate a full Blue/Green deployment:

1. Build a new Docker image with `APP_VERSION=2.0.0` and `APP_COLOR=green`
2. Push the new image to ECR with tag `2.0.0`
3. Update `imageDetail.json` to point to the `2.0.0` image
4. Commit to CodeCommit → watch CodePipeline trigger → CodeDeploy shifts traffic
5. During the deployment, access the test listener (port 8080) to verify the new version before traffic is fully shifted

**Deliverable:** Screenshots showing Blue/Green traffic shift in progress and `/health` returning `version: 2.0.0` after deployment.

---

## Provided Files

```
app/
  app.py          ← Flask API source code (complete, do not modify)
  requirements.txt
  Dockerfile
  static/
    index.html    ← Frontend UI

pipeline/
  appspec.yaml    ← CodeDeploy ECS appspec template
  taskdef.json    ← ECS task definition template
  imageDetail.json ← ECR image URI file

scripts/
  01-setup-ecr.sh
  02-setup-network.sh
  03-setup-elasticache.sh
  04-setup-ecs.sh
  05-setup-s3-frontend.sh
  06-setup-cicd.sh
  07-validate.sh
```

---

## API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check with Redis status |
| GET | `/version` | App version and deployment color |
| GET | `/products` | All products (cached 60s) |
| GET | `/products?category=electronics` | Filter by category |
| GET | `/products/{id}` | Single product (cached 60s) |
| POST | `/cache/clear` | Flush Redis cache |

---

## Scoring Rubric

| Task | Points | Key Criteria |
|---|---|---|
| 1 — ECR | 15 | Repo created, image pushed with correct tags |
| 2 — Network | 10 | 3 SGs with least-privilege rules |
| 3 — ElastiCache | 20 | Redis available, SSM parameter set, `/health` shows connected |
| 4 — ECS | 25 | 2 tasks running, ALB health check passing, CODE_DEPLOY controller |
| 5 — Frontend | 10 | S3 website loads, UI shows products |
| 6 — CI/CD | 20 | Pipeline succeeds, Blue/Green deployment visible |
| 7 — Demo (bonus) | 10 | Traffic shift captured, v2.0.0 deployed |
| **Total** | **100+10** | |

---

## Important Notes

- Use `LabRole` (ARN: `arn:aws:iam::547849081977:role/LabRole`) for all service roles
- CloudFront is not available in this lab environment — S3 static website hosting is used as the CDN layer
- CodeBuild is not available in this lab — build Docker images locally and push to ECR
- Delete resources when done to avoid charges: ECS service → ElastiCache → ALB → ECR → S3 → Pipeline
