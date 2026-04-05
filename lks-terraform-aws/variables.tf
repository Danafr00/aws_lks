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
  default     = "production"

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

# single_nat_gateway = true  → 1 NAT GW (saves ~$32/month, FREE TIER recommended)
# single_nat_gateway = false → 1 NAT GW per AZ (HA, but NOT free tier)
variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway. Saves ~$32/month; set false for full HA."
  type        = bool
  default     = true # FREE TIER
}

# ─── Compute ──────────────────────────────────────────────────────────────────
# t2.micro = FREE TIER (750 hrs/month for 12 months)
variable "instance_type" {
  description = "EC2 instance type for application servers (t2.micro = free tier)"
  type        = string
  default     = "t2.micro" # FREE TIER
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion host (t2.micro = free tier)"
  type        = string
  default     = "t2.micro" # FREE TIER
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
  default     = ""
}

# Keep at 1 for free tier (750 hrs/month covers exactly 1 t2.micro)
variable "min_capacity" {
  description = "Minimum number of app instances in the Auto Scaling Group"
  type        = number
  default     = 1 # FREE TIER
}

variable "max_capacity" {
  description = "Maximum number of app instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Desired number of app instances in the Auto Scaling Group"
  type        = number
  default     = 1 # FREE TIER
}

# ─── Database ─────────────────────────────────────────────────────────────────
# db.t3.micro = FREE TIER (750 hrs/month for 12 months)
variable "db_instance_class" {
  description = "RDS instance class (db.t3.micro = free tier)"
  type        = string
  default     = "db.t3.micro" # FREE TIER
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

# 20 GB = FREE TIER limit
variable "db_allocated_storage" {
  description = "Allocated storage for RDS (GB). Free tier max = 20 GB."
  type        = number
  default     = 20 # FREE TIER
}

variable "db_max_allocated_storage" {
  description = "Maximum auto-scaled storage for RDS (GB)"
  type        = number
  default     = 20 # Set equal to allocated to disable autoscaling on free tier
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated RDS backups (0 = disabled)"
  type        = number
  default     = 1
}

# enable_multi_az = false → FREE TIER (single AZ)
# enable_multi_az = true  → NOT free tier (doubles RDS cost)
variable "enable_multi_az" {
  description = "Enable RDS Multi-AZ. NOT free tier – doubles RDS cost."
  type        = bool
  default     = false # FREE TIER
}

# enable_read_replica = false → FREE TIER
variable "enable_read_replica" {
  description = "Create an RDS read replica. NOT free tier."
  type        = bool
  default     = false # FREE TIER
}

# ─── Cache ────────────────────────────────────────────────────────────────────
# ElastiCache is NOT in AWS Free Tier at all
variable "enable_elasticache" {
  description = "Enable ElastiCache Redis. NOT free tier – costs ~$12+/month."
  type        = bool
  default     = false # FREE TIER
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type (only used when enable_elasticache = true)"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_shards" {
  description = "Number of Redis shards"
  type        = number
  default     = 1
}

variable "redis_replicas_per_shard" {
  description = "Number of replica nodes per shard"
  type        = number
  default     = 0 # 0 = no replica on free tier
}

# ─── WAF ──────────────────────────────────────────────────────────────────────
# WAF costs $5/WebACL/month + $1/million requests – NOT free tier
variable "enable_waf" {
  description = "Enable WAF Web ACL. NOT free tier – costs ~$5+/month."
  type        = bool
  default     = false # FREE TIER
}

# ─── KMS ──────────────────────────────────────────────────────────────────────
# KMS CMK costs $1/key/month – NOT free tier
# When false, resources use AWS-managed encryption keys (free)
variable "enable_kms_cmk" {
  description = "Create a KMS Customer Managed Key. NOT free tier – costs $1/month."
  type        = bool
  default     = false # FREE TIER
}

# ─── Domain / SSL ─────────────────────────────────────────────────────────────
variable "domain_name" {
  description = "Custom domain name (leave empty to skip ACM/HTTPS setup)"
  type        = string
  default     = ""
}

# ─── Monitoring ───────────────────────────────────────────────────────────────
variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
  default     = "admin@example.com"
}

# ─── Misc ─────────────────────────────────────────────────────────────────────
variable "enable_deletion_protection" {
  description = "Enable deletion protection on ALB and RDS"
  type        = bool
  default     = false # FREE TIER – keep false so terraform destroy works cleanly
}
