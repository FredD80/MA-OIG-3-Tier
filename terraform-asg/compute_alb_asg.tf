# ----------------------------
# Latest Amazon Linux 2023 AMI
# ----------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ----------------------------
# KMS for EBS encryption (App tier)
# ----------------------------
resource "aws_kms_key" "ebs" {
  description             = "KMS key for EC2/EBS encryption (app tier)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name}-kms-ebs" })
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

# ----------------------------
# Security Groups
# ----------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-sg-alb"
  description = "ALB SG: inbound 80/443 from Internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # If you later add HTTPS listener + ACM, this is already open.
  ingress {
    description = "HTTPS from Internet (use with ACM + HTTPS listener)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-alb", tier = "public" })
}

resource "aws_security_group" "app" {
  name        = "${var.name}-sg-app"
  description = "App SG: allow app port only from ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App traffic from ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # No SSH — use SSM.
  egress {
    description = "All egress (tighten later if desired)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-app", tier = "app" })
}

# ----------------------------
# IAM Role / Instance Profile (SSM-only)
# ----------------------------
resource "aws_iam_role" "app_ec2" {
  name = "${var.name}-role-app-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-profile-app"
  role = aws_iam_role.app_ec2.name
  tags = var.tags
}

# ----------------------------
# ALB + Target Group + Listener (HTTP)
# ----------------------------
resource "aws_lb" "app" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb.id]
  subnets         = [for az in local.azs : aws_subnet.public[az].id]

  drop_invalid_header_fields = true
  enable_deletion_protection = true

  tags = merge(var.tags, { Name = "${var.name}-alb", tier = "public" })
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = var.app_health_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.name}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ----------------------------
# Launch Template (IMDSv2 required, EBS encrypted)
# Baseline "app": nginx serves /health
# ----------------------------
locals {
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    dnf -y update
    dnf -y install nginx

    cat >/usr/share/nginx/html/health <<'EOT'
    ok
    EOT

    systemctl enable --now nginx
  EOF
  )
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.app_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  user_data = local.user_data

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.name}-app"
      tier = "app"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.name}-app-volume"
      tier = "app"
    })
  }

  tags = merge(var.tags, { Name = "${var.name}-launch-template" })
}

# ----------------------------
# ASG in private app subnets
# ----------------------------
resource "aws_autoscaling_group" "app" {
  name                      = "${var.name}-asg"
  min_size                  = var.app_min_size
  max_size                  = var.app_max_size
  desired_capacity          = var.app_desired_capacity
  vpc_zone_identifier       = [for az in local.azs : aws_subnet.app[az].id]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.app.arn]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "tier"
    value               = "app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
