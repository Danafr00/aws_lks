variable "aws_region" {
  description = "AWS Region to deploy resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "lks-app"
}

variable "environment" {
  description = "Environment name (development / staging / production)"
  type        = string
  default     = "development"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "Environment must be one of: development, staging, production."
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private (app) subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for database subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

# 1 NAT GW ~$32/month. false = 1 per AZ ~$65/month (HA, not needed for learning)
variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway."
  type        = bool
  default     = true
}

# ─── Compute ──────────────────────────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type for application servers (t2.micro = free tier)"
  type        = string
  default     = "t2.micro"
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion host"
  type        = string
  default     = "t2.micro"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access (leave empty to skip)"
  type        = string
  default     = ""
}

variable "min_capacity" {
  description = "Minimum number of app instances in the Auto Scaling Group"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of app instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Desired number of app instances in the Auto Scaling Group"
  type        = number
  default     = 1
}

# ─── Database ─────────────────────────────────────────────────────────────────
variable "db_instance_class" {
  description = "RDS instance class (db.t3.micro = free tier)"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "lksapp"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS (GB). Free tier max = 20 GB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum auto-scaled storage for RDS (GB). Equal to allocated = disable autoscaling."
  type        = number
  default     = 20
}

variable "db_backup_retention_period" {
  description = "Days to retain automated RDS backups (0 = disabled, faster for learning)"
  type        = number
  default     = 0
}

variable "db_availability_zone" {
  description = "AZ to pin RDS instance (single-AZ only). Empty = AWS picks."
  type        = string
  default     = "ap-southeast-1a"
}

# Open SG port 3306 to 0.0.0.0/0 so students can connect with any MySQL client
variable "rds_open_ingress" {
  description = "Open RDS SG port 3306 to 0.0.0.0/0. For learning only."
  type        = bool
  default     = true
}

# Needs public subnet to actually be reachable; set true when testing direct DB access
variable "rds_publicly_accessible" {
  description = "Set RDS publicly_accessible = true. For learning only."
  type        = bool
  default     = true
}

# false = single AZ (learning default). true = Multi-AZ HA (doubles cost)
variable "enable_multi_az" {
  description = "Enable RDS Multi-AZ. NOT free tier – doubles RDS cost."
  type        = bool
  default     = false
}

variable "enable_read_replica" {
  description = "Create an RDS read replica. NOT free tier."
  type        = bool
  default     = false
}

# ─── Cache ────────────────────────────────────────────────────────────────────
# ElastiCache is NOT in AWS Free Tier at all (~$12+/month)
variable "enable_elasticache" {
  description = "Enable ElastiCache Redis. NOT free tier."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_shards" {
  description = "Number of Redis shards"
  type        = number
  default     = 1
}

variable "redis_replicas_per_shard" {
  description = "Number of replica nodes per shard (0 = no replica)"
  type        = number
  default     = 0
}

# ─── WAF ──────────────────────────────────────────────────────────────────────
# ~$5/WebACL/month + $1/million requests
variable "enable_waf" {
  description = "Enable WAF Web ACL. NOT free tier."
  type        = bool
  default     = false
}

# ─── KMS ──────────────────────────────────────────────────────────────────────
# $1/key/month. When false, uses AWS-managed keys (free, still encrypted)
variable "enable_kms_cmk" {
  description = "Create a KMS Customer Managed Key. NOT free tier – costs $1/month."
  type        = bool
  default     = false
}

# ─── Domain / SSL ─────────────────────────────────────────────────────────────
variable "domain_name" {
  description = "Custom domain name (leave empty to use ALB DNS directly)"
  type        = string
  default     = ""
}

# CloudFront requires ACM certs in us-east-1. Create manually then paste ARN here.
variable "cloudfront_certificate_arn" {
  description = "ACM certificate ARN (us-east-1) for CloudFront custom domain."
  type        = string
  default     = ""
}

# ─── Monitoring ───────────────────────────────────────────────────────────────
variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
  default     = "admin@example.com"
}

# ─── Safety ───────────────────────────────────────────────────────────────────
# Keep false so terraform destroy works cleanly during learning
variable "enable_deletion_protection" {
  description = "Enable deletion protection on ALB and RDS"
  type        = bool
  default     = false
}
