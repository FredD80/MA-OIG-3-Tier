# ----------------------------
# SNS + CloudWatch Alarms – IR-4, IR-6, SI-4
# ----------------------------

# KMS key for SNS encryption at rest
resource "aws_kms_key" "sns" {
  description             = "KMS key for SNS security alerts"
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
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      },
      {
        Sid       = "AllowSNSPublish"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-kms-sns" })
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.name}-sns"
  target_key_id = aws_kms_key.sns.key_id
}

# SNS topic for security alerts
resource "aws_sns_topic" "security_alerts" {
  name              = "${var.name}-security-alerts"
  kms_master_key_id = aws_kms_key.sns.id
  tags              = merge(var.tags, { Name = "${var.name}-security-alerts" })
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ----------------------------
# CloudWatch metric filters + alarms (on CloudTrail log group)
# ----------------------------
locals {
  security_alarms = {
    root-account-usage = {
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      description = "Root account usage detected (IA-2, AC-6)"
    }
    console-signin-failure = {
      pattern     = "{ ($.eventName = \"ConsoleLogin\") && ($.errorMessage = \"Failed authentication\") }"
      description = "Console sign-in failure (AC-7, SI-4)"
    }
    unauthorized-api-calls = {
      pattern     = "{ ($.errorCode = \"*UnauthorizedAccess\") || ($.errorCode = \"AccessDenied*\") }"
      description = "Unauthorized API call attempt (AC-6, SI-4)"
    }
    security-group-changes = {
      pattern     = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupEgress) || ($.eventName = CreateSecurityGroup) || ($.eventName = DeleteSecurityGroup) }"
      description = "Security group change detected (CM-6, SC-7)"
    }
    nacl-changes = {
      pattern     = "{ ($.eventName = CreateNetworkAcl) || ($.eventName = CreateNetworkAclEntry) || ($.eventName = DeleteNetworkAcl) || ($.eventName = DeleteNetworkAclEntry) || ($.eventName = ReplaceNetworkAclEntry) || ($.eventName = ReplaceNetworkAclAssociation) }"
      description = "Network ACL change detected (CM-6, SC-7)"
    }
    iam-policy-changes = {
      pattern     = "{ ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = DeletePolicyVersion) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = AttachUserPolicy) || ($.eventName = DetachUserPolicy) || ($.eventName = AttachGroupPolicy) || ($.eventName = DetachGroupPolicy) }"
      description = "IAM policy change detected (AC-6, CM-6)"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "security" {
  for_each = local.security_alarms

  name           = "${var.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "${var.name}/SecurityMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "security" {
  for_each = local.security_alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = each.key
  namespace           = "${var.name}/SecurityMetrics"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]

  tags = merge(var.tags, { Name = "${var.name}-alarm-${each.key}" })
}
