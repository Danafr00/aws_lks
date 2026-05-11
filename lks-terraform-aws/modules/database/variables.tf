variable "name_prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "db_subnet_ids" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "redis_sg_id" {
  type = string
}

variable "db_instance_class" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_allocated_storage" {
  type = number
}

variable "db_max_allocated_storage" {
  type = number
}

variable "db_backup_retention_period" {
  type    = number
  default = 0
}

# null = use AWS-managed key (free); ARN = use CMK
variable "kms_key_arn" {
  type    = string
  default = null
}

variable "redis_node_type" {
  type = string
}

variable "redis_num_shards" {
  type = number
}

variable "redis_replicas_per_shard" {
  type = number
}

variable "enable_deletion_protection" {
  type = bool
}

# FREE TIER: false (single AZ)
variable "enable_multi_az" {
  type    = bool
  default = false
}

# Pin RDS to a specific AZ. Empty string = AWS picks. Set to first AZ for free tier.
variable "db_availability_zone" {
  type    = string
  default = ""
}

# For learning: true lets you connect directly from your machine (needs public subnet + SG open)
variable "rds_publicly_accessible" {
  type    = bool
  default = true
}

# FREE TIER: false
variable "enable_read_replica" {
  type    = bool
  default = false
}

# FREE TIER: false (ElastiCache is NOT in free tier)
variable "enable_elasticache" {
  type    = bool
  default = false
}
