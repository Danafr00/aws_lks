output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "ec2_sg_id" {
  value = aws_security_group.ec2.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "redis_sg_id" {
  value = aws_security_group.redis.id
}

output "bastion_sg_id" {
  value = aws_security_group.bastion.id
}

# null when enable_kms_cmk = false (resources will use AWS-managed keys)
output "kms_key_arn" {
  value = var.enable_kms_cmk ? aws_kms_key.main[0].arn : null
}

output "kms_key_id" {
  value = var.enable_kms_cmk ? aws_kms_key.main[0].key_id : null
}

# null when enable_waf = false (ALB/CloudFront will skip WAF association)
output "waf_acl_arn" {
  value = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : null
}

output "ec2_instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}

output "ec2_role_arn" {
  value = aws_iam_role.ec2.arn
}
