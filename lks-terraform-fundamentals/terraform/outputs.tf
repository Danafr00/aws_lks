output "vpc_id" {
  value = aws_vpc.main.id
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "web_health_url" {
  value = "http://${aws_lb.alb.dns_name}/health"
}

output "db_endpoint" {
  value = aws_db_instance.mysql.address
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "api_url" {
  value = aws_apigatewayv2_stage.prod.invoke_url
}

output "lambda_function_name" {
  value = aws_lambda_function.api.function_name
}
