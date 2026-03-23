# ----------------------------
# AWS Backup – CP-9 (System Backup)
# ----------------------------

# KMS key for Backup Vault encryption
resource "aws_kms_key" "backup" {
  description             = "KMS key for AWS Backup Vault encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

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
        Sid       = "AllowBackupService"
        Effect    = "Allow"
        Principal = { Service = "backup.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-kms-backup" })
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.name}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

# ----------------------------
# Backup Vault
# ----------------------------
resource "aws_backup_vault" "main" {
  name        = "${var.name}-backup-vault"
  kms_key_arn = aws_kms_key.backup.arn
  tags        = merge(var.tags, { Name = "${var.name}-backup-vault" })
}

# ----------------------------
# Backup Plan (Daily, retain 14 days)
# ----------------------------
resource "aws_backup_plan" "daily" {
  name = "${var.name}-daily-backup-plan"

  rule {
    rule_name         = "daily-backup-rule"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 * * ? *)" # 5 AM UTC daily

    lifecycle {
      delete_after = var.db_backup_retention_days
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-daily-backup" })
}

# ----------------------------
# IAM Role for AWS Backup
# ----------------------------
resource "aws_iam_role" "backup" {
  name = "${var.name}-role-aws-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "backup_default" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restores" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ----------------------------
# Backup Selection (Targeting by Tag: compliance = nist-800-53)
# ----------------------------
resource "aws_backup_selection" "all_nist_resources" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${var.name}-backup-selection"
  plan_id      = aws_backup_plan.daily.id

  # Backup anything tagged with compliance = nist-800-53
  resources = ["*"]

  condition {
    string_equals {
      key   = "aws:ResourceTag/compliance"
      value = "nist-800-53"
    }
  }
}
