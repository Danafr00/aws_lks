# Terraform Fundamentals — Step-by-Step Learning Guide

## Layer Overview

| Layer | What You Build | Checkpoint |
|---|---|---|
| **0** | Install Terraform + core concepts | `terraform version` succeeds |
| **1** | VPC — subnets, IGW, NAT, route tables | `terraform output vpc_id` returns VPC ID |
| **2** | Security Groups — ALB, EC2, RDS chain | `terraform plan` shows 3 SGs |
| **3** | ALB — load balancer, target group, listener | ALB status `active` in console |
| **4** | RDS MySQL — subnet group, instance, Secrets Manager | RDS status `available` |
| **5** | EC2 — IAM role, Launch Template, Auto Scaling Group | `curl /health` returns `{"status":"ok"}` |
| **6** | Serverless — DynamoDB, Lambda, API Gateway | `POST /items` returns item with generated ID |

**All code lives in 3 files:**
```
terraform/
  versions.tf   ← provider config
  main.tf       ← ALL resources (read top to bottom)
  outputs.tf    ← what to print after apply
```

---

## Layer 0 — Terraform Concepts

### What is Terraform?

Write code that describes what infrastructure should exist. Terraform creates it, tracks it, updates it when you change the code.

```
Click Console = manual, slow, hard to reproduce
Write Terraform = automated, versioned, reproducible
```

### 5 things you need to know

**Resource** — one AWS object:
```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}
```
Format: `resource "TYPE" "LOCAL_NAME" { arguments }`  
Reference it later: `aws_vpc.main.id`

**Data source** — read an existing AWS object without creating it:
```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name", values = ["al2023-ami-*-x86_64"] }
}
# Use it: data.aws_ami.al2023.id
```

**Output** — print a value after apply:
```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}
# Read with: terraform output vpc_id
```

**Dependency** — Terraform auto-detects order from references:
```hcl
resource "aws_subnet" "public" {
  vpc_id = aws_vpc.main.id   # ← Terraform creates VPC first
}
```

**State** — `terraform.tfstate` tracks every resource. Never edit manually. Add to `.gitignore`.

### Workflow

```bash
terraform init      # download providers (run once)
terraform validate  # check syntax
terraform plan      # preview — read this carefully before applying
terraform apply     # create/update resources
terraform destroy   # delete everything
```

### Install

```bash
# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Amazon Linux 2023
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install terraform -y

terraform version
# Terraform v1.9.x

aws configure   # set access key, secret, region us-east-1
```

---

## Layer 1 — VPC + Networking

### Why 3 subnet tiers?

```
Internet
   │ Internet Gateway
   ▼
Public subnets   10.0.1.0/24 + 10.0.2.0/24   ← ALB lives here (internet-facing)
   │ NAT Gateway (outbound only)
   ▼
Private subnets  10.0.11.0/24 + 10.0.12.0/24 ← EC2 lives here (no direct internet)
   │ (no route out)
   ▼
DB subnets       10.0.21.0/24 + 10.0.22.0/24 ← RDS lives here (isolated)
```

Private subnet EC2s need to download packages (yum, pip), so they use the NAT Gateway — outbound only, no inbound from internet. The NAT Gateway costs ~$0.045/hr, destroy after exam.

### Code

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id   # NAT must be in a PUBLIC subnet
  depends_on    = [aws_internet_gateway.igw]
}

# Public route: all traffic → Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Private route: all traffic → NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

# DB route table: NO default route — completely isolated
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
}
```

### Deploy layer 1

```bash
cd terraform/
terraform init
terraform apply -target=aws_vpc.main \
  -target=aws_internet_gateway.igw \
  -target=aws_eip.nat \
  -target=aws_nat_gateway.nat \
  -target=aws_subnet.public_a -target=aws_subnet.public_b \
  -target=aws_subnet.private_a -target=aws_subnet.private_b \
  -target=aws_subnet.db_a -target=aws_subnet.db_b \
  -target=aws_route_table.public -target=aws_route_table.private -target=aws_route_table.db \
  -target=aws_route_table_association.public_a -target=aws_route_table_association.public_b \
  -target=aws_route_table_association.private_a -target=aws_route_table_association.private_b \
  -target=aws_route_table_association.db_a -target=aws_route_table_association.db_b
```

> **Tip:** For subsequent layers, just run `terraform apply` — Terraform only changes what's new.

### Layer 1 checkpoint

```bash
terraform output vpc_id
# vpc-0abc123...

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock}" \
  --output table
# Should show 6 subnets: 2 public, 2 private, 2 db
```

---

## Layer 2 — Security Groups

### The Security Group chain

This is the most important security pattern for ALB + EC2 + RDS:

```
Internet ──[80/tcp]──▶ ALB SG
                            │
                            └──[8080/tcp, source=ALB SG]──▶ EC2 SG
                                                                   │
                                                                   └──[3306/tcp, source=EC2 SG]──▶ RDS SG
```

Each layer only accepts traffic from the layer above it — never from `0.0.0.0/0`. The key is referencing another **Security Group ID** as the source, not a CIDR:

```hcl
# EC2 only accepts traffic from ALB — not the whole internet
resource "aws_security_group" "ec2" {
  ingress {
    from_port       = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]   # ← SG reference, not CIDR
  }
}

# RDS only accepts traffic from EC2
resource "aws_security_group" "rds" {
  ingress {
    from_port       = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]   # ← SG reference
  }
}
```

---

## Layer 3 — ALB (Application Load Balancer)

### Purpose

Distributes traffic across multiple EC2 instances. Does health checks — stops sending traffic to unhealthy instances automatically.

```hcl
resource "aws_lb" "alb" {
  name               = "lks-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  # Must use ≥2 subnets in different AZs
}

resource "aws_lb_target_group" "app" {
  port     = 8080      # EC2 app listens on 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/health"   # ALB calls GET /health every 15s per instance
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80      # public traffic comes in on port 80

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

### Layer 3 checkpoint

```bash
terraform apply   # deploy VPC + SGs + ALB

aws elbv2 describe-load-balancers \
  --names lks-alb \
  --query "LoadBalancers[0].State.Code" \
  --output text
# active
```

---

## Layer 4 — RDS MySQL

### Why Secrets Manager?

Never put passwords in Terraform code. If you do, they end up in `terraform.tfstate` in plaintext and possibly in git.

The pattern:
1. Generate random password with `random_password`
2. Create RDS using that password
3. Store credentials as JSON in Secrets Manager
4. EC2 fetches credentials at boot using IAM role — never hardcoded anywhere

```hcl
resource "random_password" "db" {
  length  = 16
  special = true
}

resource "aws_db_instance" "mysql" {
  username = "admin"
  password = random_password.db.result   # ← generated, not hardcoded
  # ...
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_string = jsonencode({
    host     = aws_db_instance.mysql.address   # available after RDS created
    username = "admin"
    password = random_password.db.result
    dbname   = "appdb"
  })
}
```

### Important settings (exam)

```hcl
resource "aws_db_instance" "mysql" {
  skip_final_snapshot = true   # don't create snapshot on terraform destroy
  deletion_protection = false  # allow terraform destroy to delete it
  multi_az            = false  # single-AZ, saves cost
  publicly_accessible = false  # no public endpoint
}
```

### Layer 4 checkpoint

```bash
terraform apply   # takes 5–10 min for RDS to provision

aws rds describe-db-instances \
  --db-instance-identifier lks-mysql \
  --query "DBInstances[0].DBInstanceStatus" \
  --output text
# available

aws secretsmanager get-secret-value \
  --secret-id lks-db-credentials \
  --query SecretString --output text | python3 -m json.tool
# shows host, username, password, dbname
```

---

## Layer 5 — EC2 Auto Scaling Group

### IAM Instance Profile

EC2 needs an IAM role to call AWS APIs (SSM for remote access, Secrets Manager for DB creds):

```hcl
resource "aws_iam_role" "ec2" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Attach to instance via profile (not role directly)
resource "aws_iam_instance_profile" "ec2" {
  role = aws_iam_role.ec2.name
}

resource "aws_launch_template" "app" {
  iam_instance_profile { name = aws_iam_instance_profile.ec2.name }
}
```

### User Data

Script that runs once at first boot. Installs packages, fetches DB credentials, starts the app:

```hcl
resource "aws_launch_template" "app" {
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum install -y python3 pip3
    pip3 install flask pymysql boto3

    SECRET=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.db.arn} \
      --region us-east-1 \
      --query SecretString --output text)

    export DB_HOST=$(echo $SECRET | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
    # ... start Flask app
  EOF
  )
}
```

Note the `${aws_secretsmanager_secret.db.arn}` — Terraform interpolates this at plan time, injecting the real ARN into the script.

### Auto Scaling Group

```hcl
resource "aws_autoscaling_group" "app" {
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns   = [aws_lb_target_group.app.arn]   # register with ALB

  health_check_type         = "ELB"   # use ALB health check, not EC2 ping
  health_check_grace_period = 120     # wait 2 min before first check
}
```

### Layer 5 checkpoint

```bash
terraform apply   # ~3 min for instance to boot + health check to pass

# Wait for health check, then:
curl http://$(terraform output -raw alb_dns_name)/health
# {"status": "ok"}

curl http://$(terraform output -raw alb_dns_name)/db-test
# {"mysql_version": "8.0.35"}

# SSH without keys — SSM Session Manager
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names lks-asg \
  --query "AutoScalingGroups[0].Instances[0].InstanceId" \
  --output text)
aws ssm start-session --target $INSTANCE_ID
```

---

## Layer 6 — Serverless (Lambda + API Gateway + DynamoDB)

### DynamoDB

NoSQL table. You only define attributes that are part of the primary key — other fields are added freely by your app:

```hcl
resource "aws_dynamodb_table" "items" {
  name         = "lks-items"
  billing_mode = "PAY_PER_REQUEST"   # pay per read/write, no capacity planning
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"   # S=String, N=Number, B=Binary
  }
  # Don't define 'name', 'price', etc. here — add them in app code freely
}
```

### Lambda code packaging

Terraform zips the Python file and re-deploys when code changes:

```hcl
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../app/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "api" {
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  # source_code_hash forces re-deploy when file content changes
}
```

### API Gateway → Lambda permission

API Gateway needs explicit permission to call Lambda — without this you get 403:

```hcl
resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
```

### $default route

HTTP API v2 uses a catch-all `$default` route. Lambda receives the path and method, handles routing internally:

```hcl
resource "aws_apigatewayv2_route" "default" {
  route_key = "$default"   # matches ALL paths and methods
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}
```

### Layer 6 checkpoint

```bash
terraform apply

API=$(terraform output -raw api_url)

# Create
curl -X POST "$API/items" -H "Content-Type: application/json" \
  -d '{"name":"laptop","price":1500}'
# {"id":"550e8400-...", "name":"laptop", "price":1500}

# Read
ID=<paste id from above>
curl "$API/items/$ID"
# {"id":"...", "name":"laptop", "price":1500}

# List
curl "$API/items"
# {"items":[...]}

# Delete
curl -X DELETE "$API/items/$ID"
# {"deleted":"..."}
```

---

## Full Deploy (all layers at once)

```bash
terraform init
terraform plan    # review everything — 30+ resources
terraform apply   # ~15 min (RDS is the bottleneck)
terraform output
```

Expected output:
```
alb_dns_name         = "lks-alb-xxx.us-east-1.elb.amazonaws.com"
api_url              = "https://xxx.execute-api.us-east-1.amazonaws.com"
db_endpoint          = "lks-mysql.xxx.us-east-1.rds.amazonaws.com"
db_secret_arn        = "arn:aws:secretsmanager:us-east-1:...:lks-db-credentials"
lambda_function_name = "lks-items-api"
vpc_id               = "vpc-0abc123..."
web_health_url       = "http://lks-alb-xxx.../health"
```

---

## Common Errors

**`Error: No valid credential sources`**
```bash
aws configure   # or export AWS_PROFILE=...
```

**`Error: InvalidGroup.Duplicate`** — SG with that name already exists from a previous run:
```bash
terraform import aws_security_group.alb sg-0abc123...
# or rename in code, or terraform destroy first
```

**Health check never passes** — EC2 user data failed. Debug:
```bash
aws ssm start-session --target $INSTANCE_ID
# inside:
cat /var/log/cloud-init-output.log
cat /var/log/app.log
```

**`Plan shows replace on launch template`** — user data changed (secret ARN changed etc.). Normal — apply it and ASG rolls the instance.

---

## Destroy

```bash
terraform destroy
# Type 'yes' when prompted

# Verify expensive resources gone:
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayId" --output text   # should be empty

aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='lks-mysql'].DBInstanceStatus" \
  --output text   # should be empty
```
