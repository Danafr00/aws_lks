output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "asg_arn" {
  value = aws_autoscaling_group.app.arn
}

output "launch_template_id" {
  value = aws_launch_template.app.id
}

output "bastion_public_ip" {
  value = aws_eip.bastion.public_ip
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}
