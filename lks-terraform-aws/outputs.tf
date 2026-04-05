output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB (for Route 53 alias records)"
  value       = module.alb.alb_zone_id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = module.storage.cloudfront_domain_name
}

output "rds_endpoint" {
  description = "RDS instance endpoint (without port)"
  value       = module.database.rds_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = module.database.redis_endpoint
  sensitive   = true
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  value       = module.database.db_secret_arn
}

output "assets_bucket_name" {
  description = "S3 bucket for static assets"
  value       = module.storage.assets_bucket_id
}

output "logs_bucket_name" {
  description = "S3 bucket for access logs"
  value       = module.storage.logs_bucket_id
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = module.compute.bastion_public_ip
}

output "kms_key_arn" {
  description = "KMS key ARN used for encryption"
  value       = module.security.kms_key_arn
}

output "sns_alert_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  value       = module.monitoring.sns_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = module.monitoring.dashboard_name
}

output "bastion_instance_id" {
  description = "EC2 instance ID of the bastion host (for SSM session)"
  value       = module.compute.bastion_instance_id
}
