# ----------------------------
# Hardcoded AZs: us-east-1a, us-east-1c
# ----------------------------
locals {
  azs = ["us-east-1a", "us-east-1c"]

  # "Variable-like" handle for this VPC and related commonly reused values
  vpc = {
    id   = aws_vpc.this.id
    cidr = var.vpc_cidr
  }
}

# ----------------------------
# VPC
# ----------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = local.vpc.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ----------------------------
# Subnets (3 tiers across AZs)
# Carve /20 blocks from /16:
# - Public: idx 0..(az-1)
# - App:    idx 4..(az+3)
# - DB:     idx 8..(az+7)
# ----------------------------
resource "aws_subnet" "public" {
  for_each                = toset(local.azs)
  vpc_id                  = local.vpc.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(local.vpc.cidr, 4, index(local.azs, each.value) + 0)
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-public-${each.value}"
    tier = "public"
  })
}

resource "aws_subnet" "app" {
  for_each          = toset(local.azs)
  vpc_id            = local.vpc.id
  availability_zone = each.value
  cidr_block        = cidrsubnet(local.vpc.cidr, 4, index(local.azs, each.value) + 4)

  tags = merge(var.tags, {
    Name = "${var.name}-app-${each.value}"
    tier = "app"
  })
}

resource "aws_subnet" "db" {
  for_each          = toset(local.azs)
  vpc_id            = local.vpc.id
  availability_zone = each.value
  cidr_block        = cidrsubnet(local.vpc.cidr, 4, index(local.azs, each.value) + 8)

  tags = merge(var.tags, {
    Name = "${var.name}-db-${each.value}"
    tier = "db"
  })
}

# ----------------------------
# NAT per AZ (HA)
# ----------------------------
resource "aws_eip" "nat" {
  for_each = toset(local.azs)
  domain   = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-eip-${each.value}" })
}

resource "aws_nat_gateway" "this" {
  for_each      = toset(local.azs)
  allocation_id = aws_eip.nat[each.value].id
  subnet_id     = aws_subnet.public[each.value].id

  depends_on = [aws_internet_gateway.this]

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.value}" })
}

# ----------------------------
# Route tables
# ----------------------------
resource "aws_route_table" "public" {
  vpc_id = local.vpc.id
  tags   = merge(var.tags, { Name = "${var.name}-rt-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = toset(local.azs)
  subnet_id      = aws_subnet.public[each.value].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  for_each = toset(local.azs)
  vpc_id   = local.vpc.id
  tags     = merge(var.tags, { Name = "${var.name}-rt-app-${each.value}" })
}

resource "aws_route" "app_default" {
  for_each               = toset(local.azs)
  route_table_id         = aws_route_table.app[each.value].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id
}

resource "aws_route_table_association" "app" {
  for_each       = toset(local.azs)
  subnet_id      = aws_subnet.app[each.value].id
  route_table_id = aws_route_table.app[each.value].id
}

resource "aws_route_table" "db" {
  for_each = toset(local.azs)
  vpc_id   = local.vpc.id
  tags     = merge(var.tags, { Name = "${var.name}-rt-db-${each.value}" })
}

resource "aws_route" "db_default" {
  for_each               = toset(local.azs)
  route_table_id         = aws_route_table.db[each.value].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id
}

resource "aws_route_table_association" "db" {
  for_each       = toset(local.azs)
  subnet_id      = aws_subnet.db[each.value].id
  route_table_id = aws_route_table.db[each.value].id
}

# ----------------------------
# VPC Flow Logs -> CloudWatch Logs (KMS encrypted)
# ----------------------------
resource "aws_kms_key" "flowlogs" {
  description             = "KMS key for VPC Flow Logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name}-kms-flowlogs" })

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "flowlogs" {
  name          = "alias/${var.name}-flowlogs"
  target_key_id = aws_kms_key.flowlogs.key_id
}

resource "aws_cloudwatch_log_group" "flowlogs" {
  name              = "/aws/vpc/flowlogs/${var.name}"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.flowlogs.arn
  tags              = merge(var.tags, { Name = "${var.name}-flowlogs-lg" })
}

resource "aws_iam_role" "flowlogs" {
  name = "${var.name}-role-vpc-flowlogs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flowlogs" {
  name = "${var.name}-policy-vpc-flowlogs"
  role = aws_iam_role.flowlogs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = [aws_cloudwatch_log_group.flowlogs.arn, "${aws_cloudwatch_log_group.flowlogs.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [aws_kms_key.flowlogs.arn]
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id               = local.vpc.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flowlogs.arn
  iam_role_arn         = aws_iam_role.flowlogs.arn

  tags = merge(var.tags, { Name = "${var.name}-vpc-flowlog" })
}

# ----------------------------
# VPC Endpoints (SSM-first)
# ----------------------------
resource "aws_security_group" "vpce" {
  name        = "${var.name}-sg-vpce"
  description = "Interface endpoint SG"
  vpc_id      = local.vpc.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc.cidr]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-vpce" })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.vpc.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    [aws_route_table.public.id],
    [for az in local.azs : aws_route_table.app[az].id],
    [for az in local.azs : aws_route_table.db[az].id]
  )

  tags = merge(var.tags, { Name = "${var.name}-vpce-s3" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = local.vpc.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    [aws_route_table.public.id],
    [for az in local.azs : aws_route_table.app[az].id],
    [for az in local.azs : aws_route_table.db[az].id]
  )

  tags = merge(var.tags, { Name = "${var.name}-vpce-dynamodb" })
}

locals {
  interface_endpoints = toset([
    "ssm",
    "ec2messages",
    "ssmmessages",
    "logs",
    "kms",
    "sts"
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoints
  vpc_id              = local.vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for az in local.azs : aws_subnet.app[az].id]
  security_group_ids = [aws_security_group.vpce.id]

  tags = merge(var.tags, { Name = "${var.name}-vpce-${replace(each.value, ".", "-")}" })
}
