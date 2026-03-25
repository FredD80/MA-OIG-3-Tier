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
# KMS for EBS encryption
# ----------------------------
resource "aws_kms_key" "ebs" {
  description             = "KMS key for EC2/EBS encryption"
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

# Web ALB — internet-facing, 80/443 from world
resource "aws_security_group" "alb" {
  name        = "${var.name}-sg-alb-web"
  description = "Web ALB SG: inbound 80/443 from Internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  tags = merge(var.tags, { Name = "${var.name}-sg-alb-web", tier = "public" })
}

# Web EC2 tier — accepts app_port only from web ALB
resource "aws_security_group" "web" {
  name        = "${var.name}-sg-web"
  description = "Web tier SG: allow app port only from web ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Web traffic from web ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-web", tier = "web" })
}

# Logic ALB — internal, accepts HTTPS (443) only from web tier EC2
resource "aws_security_group" "alb_logic" {
  name        = "${var.name}-sg-alb-logic"
  description = "Logic ALB SG: inbound HTTPS from web tier only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTPS from web tier"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    description = "To VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-alb-logic", tier = "logic" })
}

# Logic EC2 tier — accepts logic_port only from logic ALB
resource "aws_security_group" "logic" {
  name        = "${var.name}-sg-logic"
  description = "Logic tier SG: allow logic port only from logic ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Logic traffic from logic ALB"
    from_port       = var.logic_port
    to_port         = var.logic_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_logic.id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-logic", tier = "logic" })
}

# ----------------------------
# IAM Role / Instance Profile (SSM-only, shared by both tiers)
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
# Web ALB (internet-facing) + Target Group + Listener
# ----------------------------
resource "aws_lb" "web" {
  name               = "${var.name}-alb-web"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb.id]
  subnets         = [for az in local.azs : aws_subnet.public[az].id]

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = merge(var.tags, { Name = "${var.name}-alb-web", tier = "public" })
}

resource "aws_lb_target_group" "web" {
  name_prefix = "web-"
  port        = var.app_port
  protocol    = "HTTPS"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    path                = var.app_health_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 2
  }

  tags = var.tags
}

resource "aws_lb_listener" "web_http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "web_https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ----------------------------
# Logic ALB (internal) + Target Group + Listener
# ----------------------------
resource "aws_lb" "logic" {
  name               = "${var.name}-alb-logic"
  internal           = true
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_logic.id]
  subnets         = [for az in local.azs : aws_subnet.app[az].id]

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = merge(var.tags, { Name = "${var.name}-alb-logic", tier = "logic" })
}

resource "aws_lb_target_group" "logic" {
  name_prefix = "lgc-"
  port        = var.logic_port
  protocol    = "HTTPS"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    path                = var.logic_health_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 2
  }

  tags = var.tags
}

resource "aws_lb_listener" "logic_https" {
  load_balancer_arn = aws_lb.logic.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.logic_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.logic.arn
  }
}

# ----------------------------
# Launch Templates (IMDSv2 required, EBS encrypted)
# ----------------------------
locals {
  # If no separate cert is provided for the logic ALB, fall back to the web cert (e.g. wildcard).
  logic_cert_arn = var.logic_acm_certificate_arn != "" ? var.logic_acm_certificate_arn : var.acm_certificate_arn

  web_user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    dnf -y update
    dnf -y install nginx openssl
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/server.key \
      -out /etc/nginx/ssl/server.crt \
      -days 3650 \
      -subj "/CN=web-backend"
    chmod 600 /etc/nginx/ssl/server.key
    cat > /etc/nginx/conf.d/web.conf <<EOT
    server {
        listen ${var.app_port} ssl;
        ssl_certificate     /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        location /health { return 200 "ok\n"; }
    }
    EOT
    rm -f /etc/nginx/conf.d/default.conf
    systemctl enable --now nginx
  EOF
  )

  logic_user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    dnf -y update
    dnf -y install nginx openssl
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/server.key \
      -out /etc/nginx/ssl/server.crt \
      -days 3650 \
      -subj "/CN=logic-backend"
    chmod 600 /etc/nginx/ssl/server.key
    cat > /etc/nginx/conf.d/logic.conf <<EOT
    server {
        listen ${var.logic_port} ssl;
        ssl_certificate     /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        location /health { return 200 "ok\n"; }
    }
    EOT
    rm -f /etc/nginx/conf.d/default.conf
    systemctl enable --now nginx
  EOF
  )
}

resource "aws_launch_template" "web" {
  name_prefix   = "${var.name}-lt-web-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.app_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.web.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
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

  user_data = local.web_user_data

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-web", tier = "web" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-web-volume", tier = "web" })
  }

  tags = merge(var.tags, { Name = "${var.name}-lt-web" })
}

resource "aws_launch_template" "logic" {
  name_prefix   = "${var.name}-lt-logic-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.logic_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.logic.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
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

  user_data = local.logic_user_data

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-logic", tier = "logic" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-logic-volume", tier = "logic" })
  }

  tags = merge(var.tags, { Name = "${var.name}-lt-logic" })
}

# ----------------------------
# ASG — Web tier (private app subnets, min=2, both AZs)
# ----------------------------
resource "aws_autoscaling_group" "web" {
  name                      = "${var.name}-asg-web"
  min_size                  = var.app_min_size
  max_size                  = var.app_max_size
  desired_capacity          = var.app_desired_capacity
  vpc_zone_identifier       = [for az in local.azs : aws_subnet.app[az].id]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web.arn]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-web"
    propagate_at_launch = true
  }

  tag {
    key                 = "tier"
    value               = "web"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ----------------------------
# ASG — Logic tier (private app subnets, min=2, both AZs)
# ----------------------------
resource "aws_autoscaling_group" "logic" {
  name                      = "${var.name}-asg-logic"
  min_size                  = var.logic_min_size
  max_size                  = var.logic_max_size
  desired_capacity          = var.logic_desired_capacity
  vpc_zone_identifier       = [for az in local.azs : aws_subnet.app[az].id]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.logic.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.logic.arn]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-logic"
    propagate_at_launch = true
  }

  tag {
    key                 = "tier"
    value               = "logic"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
