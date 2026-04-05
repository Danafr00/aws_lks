# ─── Launch Template ──────────────────────────────────────────────────────────
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  # IMDSv2 enforced (security: prevents SSRF credential theft)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.ec2_sg_id]
    delete_on_termination       = true
  }

  iam_instance_profile {
    name = var.instance_profile_name
  }

  dynamic "key_name" {
    for_each = var.key_pair_name != "" ? [var.key_pair_name] : []
    content {}
  }

  # Encrypted root volume
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/../../scripts/user_data.sh", {
    db_secret_arn  = var.db_secret_arn
    redis_endpoint = var.redis_endpoint
    s3_bucket_name = var.s3_bucket_name
    aws_region     = var.aws_region
    project_name   = var.project_name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-app-server"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Auto Scaling Group ───────────────────────────────────────────────────────
resource "aws_autoscaling_group" "app" {
  name                = "${var.name_prefix}-asg"
  min_size            = var.min_capacity
  max_size            = var.max_capacity
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = var.private_subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns = [var.alb_target_group_arn]

  health_check_type         = "ELB"
  health_check_grace_period = 120

  # Wait for instances to pass health checks before marking scaling complete
  wait_for_capacity_timeout = "10m"

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 60
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-app-server"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# ─── Scaling Policies ─────────────────────────────────────────────────────────
# Target Tracking – CPU at 60%
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${var.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 60.0
    disable_scale_in = false
  }
}

# Target Tracking – ALB request count per target
resource "aws_autoscaling_policy" "request_count_tracking" {
  name                   = "${var.name_prefix}-request-count-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.name_prefix}-app-server"
    }
    target_value = 1000.0
  }
}

# ─── Scheduled Scaling (edge case: pre-scale for peak hours) ─────────────────
resource "aws_autoscaling_schedule" "scale_up_morning" {
  scheduled_action_name  = "${var.name_prefix}-scale-up-morning"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = "0 1 * * MON-FRI" # 08:00 WIB (UTC+7)
  min_size               = var.min_capacity
  max_size               = var.max_capacity
  desired_capacity       = var.desired_capacity + 1
}

resource "aws_autoscaling_schedule" "scale_down_night" {
  scheduled_action_name  = "${var.name_prefix}-scale-down-night"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = "0 16 * * *" # 23:00 WIB (UTC+7)
  min_size               = 1
  max_size               = var.max_capacity
  desired_capacity       = 1
}

# ─── Bastion Host ─────────────────────────────────────────────────────────────
resource "aws_instance" "bastion" {
  ami                    = var.ami_id
  instance_type          = var.bastion_instance_type
  subnet_id              = var.public_subnet_ids[0]
  vpc_security_group_ids = [var.bastion_sg_id]
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null

  # IMDSv2 on bastion too
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "${var.name_prefix}-bastion" }
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "${var.name_prefix}-bastion-eip" }
}
