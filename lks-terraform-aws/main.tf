# ─── Data Sources ─────────────────────────────────────────────────────────────
data "aws_ami" "amazon_linux_2023" {
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

data "aws_caller_identity" "current" {}

# ─── Random suffix for globally unique names ──────────────────────────────────
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  suffix      = random_id.suffix.hex
  ami_id      = data.aws_ami.amazon_linux_2023.id
  account_id  = data.aws_caller_identity.current.account_id
}

# ─── Modules ──────────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
}

module "security" {
  source = "./modules/security"

  name_prefix    = local.name_prefix
  suffix         = local.suffix
  vpc_id         = module.vpc.vpc_id
  account_id     = local.account_id
  aws_region     = var.aws_region
  enable_waf     = var.enable_waf
  enable_kms_cmk = var.enable_kms_cmk
}

module "storage" {
  source = "./modules/storage"

  name_prefix = local.name_prefix
  suffix      = local.suffix
  kms_key_arn = module.security.kms_key_arn # null when enable_kms_cmk = false
  domain_name = var.domain_name
}

module "database" {
  source = "./modules/database"

  name_prefix                = local.name_prefix
  suffix                     = local.suffix
  db_subnet_ids              = module.vpc.db_subnet_ids
  rds_sg_id                  = module.security.rds_sg_id
  redis_sg_id                = module.security.redis_sg_id
  db_instance_class          = var.db_instance_class
  db_name                    = var.db_name
  db_username                = var.db_username
  db_allocated_storage       = var.db_allocated_storage
  db_max_allocated_storage   = var.db_max_allocated_storage
  db_backup_retention_period = var.db_backup_retention_period
  kms_key_arn                = module.security.kms_key_arn
  redis_node_type            = var.redis_node_type
  redis_num_shards           = var.redis_num_shards
  redis_replicas_per_shard   = var.redis_replicas_per_shard
  enable_deletion_protection = var.enable_deletion_protection
  enable_multi_az            = var.enable_multi_az
  enable_read_replica        = var.enable_read_replica
  enable_elasticache         = var.enable_elasticache
}

module "alb" {
  source = "./modules/alb"

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  public_subnet_ids          = module.vpc.public_subnet_ids
  alb_sg_id                  = module.security.alb_sg_id
  waf_acl_arn                = module.security.waf_acl_arn # null when enable_waf = false
  enable_deletion_protection = var.enable_deletion_protection
  logs_bucket_id             = module.storage.logs_bucket_id
  domain_name                = var.domain_name
}

module "compute" {
  source = "./modules/compute"

  name_prefix           = local.name_prefix
  suffix                = local.suffix
  ami_id                = local.ami_id
  instance_type         = var.instance_type
  bastion_instance_type = var.bastion_instance_type
  key_pair_name         = var.key_pair_name
  private_subnet_ids    = module.vpc.private_subnet_ids
  public_subnet_ids     = module.vpc.public_subnet_ids
  ec2_sg_id             = module.security.ec2_sg_id
  bastion_sg_id         = module.security.bastion_sg_id
  instance_profile_name = module.security.ec2_instance_profile_name
  alb_target_group_arn  = module.alb.target_group_arn
  min_capacity          = var.min_capacity
  max_capacity          = var.max_capacity
  desired_capacity      = var.desired_capacity

  db_secret_arn  = module.database.db_secret_arn
  redis_endpoint = module.database.redis_endpoint # null if elasticache disabled
  s3_bucket_name = module.storage.assets_bucket_id
  aws_region     = var.aws_region
  project_name   = var.project_name
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix    = local.name_prefix
  suffix         = local.suffix
  aws_region     = var.aws_region
  account_id     = local.account_id
  alert_email    = var.alert_email
  alb_arn_suffix = module.alb.alb_arn_suffix
  asg_name       = module.compute.asg_name
  rds_identifier = module.database.rds_identifier
  logs_bucket_id = module.storage.logs_bucket_id
  kms_key_arn    = module.security.kms_key_arn
  vpc_id         = module.vpc.vpc_id
}
