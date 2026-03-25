# ----------------------------
# KMS for RDS + Performance Insights
# ----------------------------
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS storage encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name}-kms-rds" })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_kms_key" "pi" {
  description             = "KMS key for RDS Performance Insights"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name}-kms-pi" })
}

resource "aws_kms_alias" "pi" {
  name          = "alias/${var.name}-pi"
  target_key_id = aws_kms_key.pi.key_id
}

# ----------------------------
# DB Subnet Group (DB subnets only)
# ----------------------------
resource "aws_db_subnet_group" "db" {
  name       = "${var.name}-db-subnets"
  subnet_ids = [for az in local.azs : aws_subnet.db[az].id]

  tags = merge(var.tags, { Name = "${var.name}-db-subnet-group", tier = "db" })
}

# ----------------------------
# Secrets Manager (master creds)
# ----------------------------
resource "random_password" "db_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# SC-28: KMS key for Secrets Manager encryption
resource "aws_kms_key" "secrets" {
  description             = "KMS key for Secrets Manager"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name}-kms-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.name}/rds/master"
  recovery_window_in_days = 7
  kms_key_id              = aws_kms_key.secrets.arn
  tags                    = merge(var.tags, { Name = "${var.name}-db-master-secret" })
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_master.result
  })
}

# ----------------------------
# DB Security Group (allow Postgres ONLY from App SG)
# ----------------------------
resource "aws_security_group" "db" {
  name        = "${var.name}-sg-db"
  description = "DB SG: allow Postgres only from app tier"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from logic tier SG"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.logic.id]
  }

  # SC-7: Restrict egress to VPC only
  egress {
    description = "All egress within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-db", tier = "db" })
}

# ----------------------------
# Parameter group baseline (logging)
# If you use Postgres 15 or 14, change family accordingly.
# ----------------------------
resource "aws_db_parameter_group" "pg" {
  name        = "${var.name}-pg-params"
  family      = "postgres16"
  description = "Postgres parameters baseline (AU-12 audit logging)"

  # Existing baseline
  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_min_duration_statement"
    value        = "500"
    apply_method = "immediate"
  }

  # AU-12: Extended audit logging
  parameter {
    name         = "log_statement"
    value        = "ddl"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_checkpoints"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_lock_waits"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "pgaudit.log"
    value        = "ddl,role"
    apply_method = "immediate"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit"
    apply_method = "pending-reboot"
  }

  tags = merge(var.tags, { Name = "${var.name}-db-parameter-group" })
}

# ----------------------------
# RDS Instance (private)
# ----------------------------
resource "aws_db_instance" "postgres" {
  identifier = "${var.name}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  db_name  = var.db_name
  username = var.db_username
  password = jsondecode(aws_secretsmanager_secret_version.db_master.secret_string).password
  port     = var.db_port

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]

  publicly_accessible = false
  multi_az            = var.db_multi_az

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"

  deletion_protection = false
  skip_final_snapshot = true

  auto_minor_version_upgrade = true
  apply_immediately          = false

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.pi.arn
  performance_insights_retention_period = 7

  parameter_group_name = aws_db_parameter_group.pg.name

  tags = merge(var.tags, { Name = "${var.name}-rds-postgres", tier = "db" })
}
