# LKS Terraform Fundamentals — Infrastructure as Code on AWS

**Difficulty:** ★★★★☆  
**Duration:** 3–4 hours  
**Region:** us-east-1 (Singapore)

---

## Scenario

You are a Cloud Engineer at **Nusantara Tech**. The team previously clicked through the AWS Console to create resources — slow, error-prone, and impossible to reproduce. Your manager asks you to migrate the entire infrastructure to **Terraform** so it can be version-controlled, reviewed, and deployed consistently.

You must provision two separate stacks:

1. **EC2-based stack** — A web application server behind a load balancer, connected to an RDS MySQL database in a private subnet.
2. **Serverless stack** — A REST API built with Lambda + API Gateway, backed by DynamoDB.

Both stacks share the same VPC.

---

## Architecture

```
Internet
  │
  ├─── ALB (public subnets) ──── EC2 Auto Scaling Group (private subnets)
  │                                       │
  │                               RDS MySQL (db subnets)
  │
  └─── API Gateway (HTTP) ──── Lambda Function ──── DynamoDB Table
```

### VPC Layout

| Subnet Type   | CIDR              | AZ          | Purpose                  |
|---------------|-------------------|-------------|--------------------------|
| Public        | 10.0.1.0/24       | us-east-1a | ALB, NAT Gateway     |
| Public        | 10.0.2.0/24       | us-east-1b | ALB (Multi-AZ)       |
| Private       | 10.0.11.0/24      | us-east-1a | EC2 instances        |
| Private       | 10.0.12.0/24      | us-east-1b | EC2 instances        |
| DB            | 10.0.21.0/24      | us-east-1a | RDS primary          |
| DB            | 10.0.22.0/24      | us-east-1b | RDS standby          |

---

## Tasks

### Task 1 — Terraform Setup & VPC (20 points)

Configure Terraform with AWS provider and create the foundational VPC:
- Custom VPC with DNS hostnames enabled
- 2 public subnets across different AZs
- 2 private subnets across different AZs
- 2 DB subnets across different AZs
- Internet Gateway attached to public subnets
- NAT Gateway (single) for private subnet egress
- Proper route tables for each subnet tier

**Checkpoint:** `terraform output vpc_id` returns a valid VPC ID.

---

### Task 2 — EC2 + ALB (25 points)

Deploy a web server fleet behind a load balancer:
- Security group: ALB allows 80/443 from internet; EC2 allows 8080 from ALB SG only
- ALB in public subnets with HTTP listener on port 80
- Launch Template using Amazon Linux 2023, `t3.micro`
- User data script that installs and starts a simple Python web server
- Auto Scaling Group: min=1, max=2, desired=1, in private subnets
- ALB target group health check on `/health`

**Checkpoint:** `curl http://$(terraform output -raw alb_dns_name)/health` returns `{"status":"ok"}`.

---

### Task 3 — RDS MySQL (20 points)

Deploy a managed MySQL database:
- DB subnet group using the 2 DB subnets
- Security group: RDS allows port 3306 from EC2 SG only
- RDS MySQL 8.0, `db.t3.micro`, single-AZ (free tier)
- Credentials stored in AWS Secrets Manager
- Database name: `appdb`
- EC2 user data updated to connect and write a test record on startup

**Checkpoint:** SSH to EC2 via SSM Session Manager and run:
```bash
mysql -h $(aws secretsmanager get-secret-value ...) -u admin -p appdb -e "SHOW TABLES;"
```

---

### Task 4 — Serverless API (25 points)

Deploy a serverless CRUD API for an `items` resource:
- DynamoDB table `lks-items` with `id` as hash key, on-demand billing
- IAM role for Lambda with DynamoDB read/write permissions
- Lambda function (Python 3.12) — handlers for `POST /items`, `GET /items/{id}`
- HTTP API Gateway (v2) with Lambda integration and CORS enabled
- API URL exported as Terraform output

**Checkpoint:** 
```bash
API_URL=$(terraform output -raw api_gateway_url)
curl -X POST "$API_URL/items" -H "Content-Type: application/json" -d '{"name":"test"}'
# returns {"id":"...","name":"test"}
```

---

### Task 5 — Refactor to Modules (10 points)

Refactor the flat Terraform code into reusable modules:
- `modules/vpc` — VPC, subnets, IGW, NAT, routes
- `modules/ec2` — Launch template, ASG, security group
- `modules/rds` — RDS instance, subnet group, security group, secret
- `modules/alb` — ALB, listener, target group
- `modules/serverless` — Lambda, DynamoDB, API Gateway, IAM

**Checkpoint:** `terraform plan` shows 0 changes to add/change/destroy after refactor.

---

## Deliverables

1. All Terraform code in `terraform/` directory
2. `terraform plan` output saved to `plan.txt`
3. All 4 task checkpoints passing
4. `terraform output` showing all required outputs

---

## Cost Warning

| Resource     | Cost         | Action              |
|--------------|--------------|---------------------|
| NAT Gateway  | ~$0.045/hr   | Delete after exam   |
| ALB          | ~$0.008/hr   | Delete after exam   |
| RDS t3.micro | ~$0.017/hr   | Delete after exam   |
| Lambda       | Free tier    | Safe to leave       |
| DynamoDB     | Free tier    | Safe to leave       |

Run `terraform destroy` when done.
