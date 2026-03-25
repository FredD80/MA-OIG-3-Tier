# ----------------------------
# Security Hub — CA-2, CA-7, RA-5, SI-4
# ----------------------------
resource "aws_securityhub_account" "main" {}

resource "aws_securityhub_standards_subscription" "nist_800_53" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/nist-800-53/v/5.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# ----------------------------
# Amazon Inspector v2 — SI-2, RA-5
# Scans EC2 instances and AMIs for OS/package CVEs continuously.
# Findings flow automatically into Security Hub.
# ----------------------------
resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2"]
}

# Route HIGH and CRITICAL Inspector findings to the existing SNS security alerts topic
resource "aws_cloudwatch_event_rule" "inspector_findings" {
  name        = "${var.name}-inspector-high-critical"
  description = "Route HIGH/CRITICAL Inspector v2 findings to SNS (RA-5, SI-4)"

  event_pattern = jsonencode({
    source      = ["aws.inspector2"]
    detail-type = ["Inspector2 Finding"]
    detail = {
      severity = ["CRITICAL", "HIGH"]
    }
  })

  tags = merge(var.tags, { Name = "${var.name}-inspector-findings-rule" })
}

resource "aws_cloudwatch_event_target" "inspector_findings" {
  rule      = aws_cloudwatch_event_rule.inspector_findings.name
  target_id = "inspector-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# ----------------------------
# SNS topic policy — allow both CloudWatch Alarms and EventBridge to publish
# (EventBridge requires an explicit SNS resource policy)
# ----------------------------
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      },
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

# ----------------------------
# Outputs
# ----------------------------
output "securityhub_arn" {
  value = aws_securityhub_account.main.id
}

output "inspector_status" {
  value = aws_inspector2_enabler.main.account_ids
}
