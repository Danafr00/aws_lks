output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "app_log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.main.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
