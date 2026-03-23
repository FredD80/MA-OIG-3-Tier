# ----------------------------
# GuardDuty – SI-3, SI-4
# ----------------------------
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true

  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = merge(var.tags, { Name = "${var.name}-guardduty" })
}
