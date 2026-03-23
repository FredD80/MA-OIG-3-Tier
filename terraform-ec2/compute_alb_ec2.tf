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
# KMS for EBS encryption (both tiers share one key – SC-28)
# ----------------------------
resource "aws_kms_key" "ebs" {
  description             = "KMS key for EC2/EBS encryption (web + app tiers)"
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

# External ALB – accepts Internet traffic on 80/443
resource "aws_security_group" "alb_ext" {
  name        = "${var.name}-sg-alb-ext"
  description = "External ALB SG: inbound 80/443 from Internet"
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
    description = "To VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-alb-ext", tier = "public" })
}

# Web tier – accepts app_port only from external ALB (SC-7 DMZ)
resource "aws_security_group" "web" {
  name        = "${var.name}-sg-web"
  description = "Web tier SG: allow app port only from external ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Web traffic from external ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_ext.id]
  }

  # No SSH — use SSM.
  egress {
    description = "All egress (tighten later if desired)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-web", tier = "public" })
}

# Internal ALB – accepts traffic from web tier only
resource "aws_security_group" "alb_int" {
  name        = "${var.name}-sg-alb-int"
  description = "Internal ALB SG: inbound app port from web tier"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App traffic from web tier"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    description = "To VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-alb-int", tier = "app" })
}

# App tier – accepts app_port only from internal ALB
resource "aws_security_group" "app" {
  name        = "${var.name}-sg-app"
  description = "App SG: allow app port only from internal ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App traffic from internal ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_int.id]
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
# External ALB + Target Group + Listener (HTTP → Web Tier)
# ----------------------------
resource "aws_lb" "ext" {
  name               = "${var.name}-alb-ext"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_ext.id]
  subnets         = [for az in local.azs : aws_subnet.public[az].id]

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = merge(var.tags, { Name = "${var.name}-alb-ext", tier = "public" })
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name}-tg-web"
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

  tags = merge(var.tags, { Name = "${var.name}-tg-web" })
}

resource "aws_lb_listener" "http_ext" {
  load_balancer_arn = aws_lb.ext.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ----------------------------
# Internal ALB + Target Group + Listener (HTTP → App Tier)
# ----------------------------
resource "aws_lb" "int" {
  name               = "${var.name}-alb-int"
  internal           = true
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_int.id]
  subnets         = [for az in local.azs : aws_subnet.app[az].id]

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = merge(var.tags, { Name = "${var.name}-alb-int", tier = "app" })
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-tg-app"
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

  tags = merge(var.tags, { Name = "${var.name}-tg-app" })
}

resource "aws_lb_listener" "http_int" {
  load_balancer_arn = aws_lb.int.arn
  port              = var.app_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ----------------------------
# User data for web tier (nginx serving static content)
# ----------------------------
locals {
  web_user_data = base64encode(<<-EOF
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

  app_user_data = base64encode(<<-EOF
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

# ----------------------------
# Web Tier EC2 Instances (PUBLIC subnets: us-east-1a, us-east-1c)
# ----------------------------
resource "aws_instance" "web_1a" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.web_instance_type
  subnet_id            = aws_subnet.public["us-east-1a"].id
  iam_instance_profile = aws_iam_instance_profile.app.name

  vpc_security_group_ids = [aws_security_group.web.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true
  }

  user_data_base64 = local.web_user_data

  tags = merge(var.tags, {
    Name = "${var.name}-web-1a"
    tier = "public"
    az   = "us-east-1a"
  })

  volume_tags = merge(var.tags, {
    Name = "${var.name}-web-1a-volume"
    tier = "public"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "web_1c" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.web_instance_type
  subnet_id            = aws_subnet.public["us-east-1c"].id
  iam_instance_profile = aws_iam_instance_profile.app.name

  vpc_security_group_ids = [aws_security_group.web.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true
  }

  user_data_base64 = local.web_user_data

  tags = merge(var.tags, {
    Name = "${var.name}-web-1c"
    tier = "public"
    az   = "us-east-1c"
  })

  volume_tags = merge(var.tags, {
    Name = "${var.name}-web-1c-volume"
    tier = "public"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# ----------------------------
# App Tier EC2 Instances (PRIVATE app subnets: us-east-1a, us-east-1c)
# ----------------------------
resource "aws_instance" "app_1a" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.app_instance_type
  subnet_id            = aws_subnet.app["us-east-1a"].id
  iam_instance_profile = aws_iam_instance_profile.app.name

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true
  }

  user_data_base64 = local.app_user_data

  tags = merge(var.tags, {
    Name = "${var.name}-app-1a"
    tier = "app"
    az   = "us-east-1a"
  })

  volume_tags = merge(var.tags, {
    Name = "${var.name}-app-1a-volume"
    tier = "app"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "app_1c" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.app_instance_type
  subnet_id            = aws_subnet.app["us-east-1c"].id
  iam_instance_profile = aws_iam_instance_profile.app.name

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true
  }

  user_data_base64 = local.app_user_data

  tags = merge(var.tags, {
    Name = "${var.name}-app-1c"
    tier = "app"
    az   = "us-east-1c"
  })

  volume_tags = merge(var.tags, {
    Name = "${var.name}-app-1c-volume"
    tier = "app"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# ----------------------------
# Register Web EC2s with External ALB Target Group
# ----------------------------
resource "aws_lb_target_group_attachment" "web_1a" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web_1a.id
  port             = var.app_port
}

resource "aws_lb_target_group_attachment" "web_1c" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web_1c.id
  port             = var.app_port
}

# ----------------------------
# Register App EC2s with Internal ALB Target Group
# ----------------------------
resource "aws_lb_target_group_attachment" "app_1a" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app_1a.id
  port             = var.app_port
}

resource "aws_lb_target_group_attachment" "app_1c" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app_1c.id
  port             = var.app_port
}
