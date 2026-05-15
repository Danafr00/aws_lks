# LKS CloudFormation Fundamentals

**Difficulty:** ★★★★☆  
**Duration:** 3–4 hours  
**Region:** us-east-1

---

## Scenario

Same infrastructure as the Terraform module, but using **AWS CloudFormation** — AWS's native IaC service. No extra tools to install; only the AWS CLI is needed.

Architecture:
```
Internet
  │
  ├── ALB (public subnets) ── EC2 ASG (private subnets) ── RDS MySQL (db subnets)
  │
  └── API Gateway (HTTP) ── Lambda ── DynamoDB
```

---

## Tasks

### Task 1 — VPC + Networking (20 pts)
Deploy VPC with 6 subnets (2 public / 2 private / 2 DB), IGW, NAT Gateway, route tables.

**Checkpoint:** Stack status `CREATE_COMPLETE`, 6 subnets exist.

---

### Task 2 — Security Groups + ALB (20 pts)
Security group chain: internet → ALB SG → EC2 SG → RDS SG. ALB with HTTP listener and target group.

**Checkpoint:** ALB status `active`.

---

### Task 3 — RDS MySQL (20 pts)
RDS MySQL 8.0 in DB subnets. Password stored in Secrets Manager.

**Checkpoint:** `curl http://ALB/db-test` returns `{"mysql_version":"8.0..."}`.

---

### Task 4 — EC2 ASG (20 pts)
IAM role with SSM + Secrets Manager access. Launch Template with user data. ASG in private subnets.

**Checkpoint:** `curl http://ALB/health` returns `{"status":"ok"}`.

---

### Task 5 — Serverless (20 pts)
DynamoDB table, Lambda (Python 3.12 inline), HTTP API Gateway v2 with CORS.

**Checkpoint:** `POST /items` returns item with generated UUID.

---

## Deploy

```bash
# Deploy everything
chmod +x scripts/*.sh
./scripts/01-deploy.sh

# Validate all layers
./scripts/02-validate.sh

# Cleanup
./scripts/03-destroy.sh
```

---

## Cost Warning

| Resource    | Cost       |
|-------------|------------|
| NAT Gateway | ~$0.045/hr |
| ALB         | ~$0.008/hr |
| RDS t3.micro| ~$0.017/hr |
| Lambda/DDB  | Free tier  |

Run `./scripts/03-destroy.sh` after the exam.
