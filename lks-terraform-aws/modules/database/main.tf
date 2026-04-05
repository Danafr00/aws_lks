# ─── Random password ──────────────────────────────────────────────────────────
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ─── Secrets Manager ($0.40/secret/month – minimal cost) ─────────────────────
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name_prefix}/rds/credentials"
  description = "RDS master credentials for ${var.name_prefix}"
  kms_key_id  = var.kms_key_arn # null → AWS-managed key (free)

  recovery_window_in_days = 0 # FREE TIER: immediate deletion on destroy

  tags = { Name = "${var.name_prefix}-db-secret" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
    engine   = "mysql"
    host     = aws_db_instance.main.address
    port     = 3306
  })

  depends_on = [aws_db_instance.main]
}

# ─── RDS Subnet Group ─────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = { Name = "${var.name_prefix}-db-subnet-group" }
}

# ─── RDS Parameter Group ──────────────────────────────────────────────────────
resource "aws_db_parameter_group" "main" {
  name   = "${var.name_prefix}-mysql8-params"
  family = "mysql8.0"

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  parameter {
    name  = "log_output"
    value = "FILE"
  }

  parameter {
    name         = "require_secure_transport"
    value        = "ON"
    apply_method = "immediate"
  }

  tags = { Name = "${var.name_prefix}-mysql-params" }
}

# ─── RDS MySQL ────────────────────────────────────────────────────────────────
# FREE TIER: db.t3.micro, single-AZ, 20 GB gp2 (750 hrs/month for 12 months)
# PAID:      enable_multi_az = true doubles the instance cost
resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp2"      # gp2 is free tier; gp3 is not
  storage_encrypted     = var.kms_key_arn != null ? true : false
  kms_key_id            = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.main.name

  # FREE TIER: false | PAID HA: true
  multi_az = var.enable_multi_az

  backup_retention_period = var.db_backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  # Enhanced monitoring = 60s interval (covered by free tier CloudWatch)
  monitoring_interval = 0 # 0 = disabled on free tier (enhanced monitoring costs)
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  # Performance Insights – free tier: 7 days retention
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  deletion_protection       = var.enable_deletion_protection
  skip_final_snapshot       = true # FREE TIER: skip snapshot on destroy to avoid storage cost
  copy_tags_to_snapshot     = true

  auto_minor_version_upgrade = true
  publicly_accessible        = false

  tags = { Name = "${var.name_prefix}-mysql" }
}

# ─── RDS Read Replica (optional – NOT free tier) ─────────────────────────────
# enable_read_replica = false (FREE TIER default)
# enable_read_replica = true  → extra instance cost (same as db_instance_class)
resource "aws_db_instance" "read_replica" {
  count = var.enable_read_replica ? 1 : 0

  identifier          = "${var.name_prefix}-mysql-replica"
  replicate_source_db = aws_db_instance.main.identifier
  instance_class      = var.db_instance_class

  storage_encrypted      = var.kms_key_arn != null ? true : false
  kms_key_id             = var.kms_key_arn
  vpc_security_group_ids = [var.rds_sg_id]

  auto_minor_version_upgrade = true
  publicly_accessible        = false
  skip_final_snapshot        = true

  tags = { Name = "${var.name_prefix}-mysql-replica" }
}

# ─── ElastiCache (optional – NOT free tier at all) ───────────────────────────
# enable_elasticache = false (FREE TIER default) → app uses in-memory dict cache
# enable_elasticache = true  → Redis replication group (~$12+/month)

resource "aws_elasticache_subnet_group" "main" {
  count      = var.enable_elasticache ? 1 : 0
  name       = "${var.name_prefix}-redis-subnet-group"
  subnet_ids = var.db_subnet_ids
  tags       = { Name = "${var.name_prefix}-redis-subnet-group" }
}

resource "aws_elasticache_parameter_group" "redis" {
  count  = var.enable_elasticache ? 1 : 0
  name   = "${var.name_prefix}-redis7-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_elasticache_replication_group" "main" {
  count = var.enable_elasticache ? 1 : 0

  replication_group_id    = "${var.name_prefix}-redis"
  description             = "Redis for ${var.name_prefix}"
  node_type               = var.redis_node_type
  num_node_groups         = var.redis_num_shards
  replicas_per_node_group = var.redis_replicas_per_shard

  engine_version       = "7.0"
  parameter_group_name = aws_elasticache_parameter_group.redis[0].name
  subnet_group_name    = aws_elasticache_subnet_group.main[0].name
  security_group_ids   = [var.redis_sg_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn

  automatic_failover_enabled = var.redis_replicas_per_shard > 0
  multi_az_enabled           = var.redis_replicas_per_shard > 0

  snapshot_retention_limit = 1
  apply_immediately        = true

  tags = { Name = "${var.name_prefix}-redis" }
}
