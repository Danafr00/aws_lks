# ─────────────────────────────────────────────────────────────────────────────
# DATA SOURCES
# ─────────────────────────────────────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "random_password" "db" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC + NETWORKING
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "lks-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lks-igw" }
}

# Public subnets — for ALB and NAT Gateway
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "lks-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "lks-public-b" }
}

# Private subnets — for EC2 app servers
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "us-east-1a"
  tags              = { Name = "lks-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "us-east-1b"
  tags              = { Name = "lks-private-b" }
}

# DB subnets — for RDS (must span 2 AZs)
resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.21.0/24"
  availability_zone = "us-east-1a"
  tags              = { Name = "lks-db-a" }
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.22.0/24"
  availability_zone = "us-east-1b"
  tags              = { Name = "lks-db-b" }
}

# NAT Gateway — lets private subnet EC2s reach internet (for yum/pip)
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "lks-nat" }
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "lks-rt-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "lks-rt-private" }
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lks-rt-db" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db_a" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "db_b" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.db.id
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY GROUPS
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name   = "lks-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2" {
  name   = "lks-ec2-sg"
  vpc_id = aws_vpc.main.id

  # Only allow traffic from the ALB — not directly from internet
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name   = "lks-rds-sg"
  vpc_id = aws_vpc.main.id

  # Only allow traffic from EC2 — never expose DB to internet
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "alb" {
  name               = "lks-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

resource "aws_lb_target_group" "app" {
  name     = "lks-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS MYSQL
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "rds" {
  name       = "lks-db-subnet-group"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
}

resource "aws_db_instance" "mysql" {
  identifier     = "lks-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  db_name  = "appdb"
  username = "admin"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  allocated_storage   = 20
  storage_type        = "gp2"
  publicly_accessible = false
  multi_az            = false
  skip_final_snapshot = true
  deletion_protection = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "lks-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = "appdb"
    username = "admin"
    password = random_password.db.result
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# EC2 — IAM + LAUNCH TEMPLATE + AUTO SCALING GROUP
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ec2" {
  name = "lks-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_secrets" {
  name = "lks-ec2-secrets"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db.arn]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "lks-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_launch_template" "app" {
  name_prefix   = "lks-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  iam_instance_profile { name = aws_iam_instance_profile.ec2.name }

  network_interfaces {
    security_groups             = [aws_security_group.ec2.id]
    associate_public_ip_address = false
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3 python3-pip

    pip3 install flask boto3 pymysql

    SECRET=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.db.arn} \
      --region us-east-1 \
      --query SecretString --output text)

    export DB_HOST=$(echo $SECRET | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
    export DB_USER=$(echo $SECRET | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
    export DB_PASS=$(echo $SECRET | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
    export DB_NAME=$(echo $SECRET | python3 -c "import sys,json; print(json.load(sys.stdin)['dbname'])")

    cat > /home/ec2-user/app.py << 'PYEOF'
    from flask import Flask, jsonify
    import pymysql, os

    app = Flask(__name__)

    @app.route('/health')
    def health():
        return jsonify({"status": "ok"})

    @app.route('/db-test')
    def db_test():
        conn = pymysql.connect(
            host=os.environ['DB_HOST'], user=os.environ['DB_USER'],
            password=os.environ['DB_PASS'], database=os.environ['DB_NAME'],
            connect_timeout=5
        )
        with conn.cursor() as c:
            c.execute("SELECT VERSION()")
            version = c.fetchone()[0]
        conn.close()
        return jsonify({"mysql_version": version})

    if __name__ == '__main__':
        app.run(host='0.0.0.0', port=8080)
    PYEOF

    nohup python3 /home/ec2-user/app.py >> /var/log/app.log 2>&1 &
  EOF
  )

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "app" {
  name                = "lks-asg"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns   = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 120
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVERLESS — DYNAMODB + LAMBDA + API GATEWAY
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "items" {
  name         = "lks-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_iam_role" "lambda" {
  name = "lks-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "lks-lambda-dynamodb"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem", "dynamodb:Scan"]
      Resource = [aws_dynamodb_table.items.arn]
    }]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../app/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "api" {
  function_name    = "lks-items-api"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10

  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.items.name }
  }
}

resource "aws_apigatewayv2_api" "api" {
  name          = "lks-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_methods = ["GET", "POST", "DELETE", "OPTIONS"]
    allow_origins = ["*"]
    allow_headers = ["content-type"]
  }
}

resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}
