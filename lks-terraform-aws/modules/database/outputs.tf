output "rds_endpoint" {
  value     = aws_db_instance.main.address
  sensitive = true
}

output "rds_port" {
  value = aws_db_instance.main.port
}

output "rds_identifier" {
  value = aws_db_instance.main.identifier
}

output "rds_replica_endpoint" {
  value     = var.enable_read_replica ? aws_db_instance.read_replica[0].address : null
  sensitive = true
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

# null when ElastiCache is disabled – app falls back to in-process cache
output "redis_endpoint" {
  value     = var.enable_elasticache ? aws_elasticache_replication_group.main[0].primary_endpoint_address : null
  sensitive = true
}

output "redis_reader_endpoint" {
  value     = var.enable_elasticache ? aws_elasticache_replication_group.main[0].reader_endpoint_address : null
  sensitive = true
}
