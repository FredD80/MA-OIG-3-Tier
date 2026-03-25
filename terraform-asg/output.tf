output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "app_subnet_ids" {
  value = [for s in aws_subnet.app : s.id]
}

output "db_subnet_ids" {
  value = [for s in aws_subnet.db : s.id]
}

output "web_alb_dns_name" {
  value = aws_lb.web.dns_name
}

output "logic_alb_dns_name" {
  value = aws_lb.logic.dns_name
}

output "web_asg_name" {
  value = aws_autoscaling_group.web.name
}

output "logic_asg_name" {
  value = aws_autoscaling_group.logic.name
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}

output "rds_port" {
  value = aws_db_instance.postgres.port
}

output "rds_secret_arn" {
  value = aws_secretsmanager_secret.db_master.arn
}

output "flow_logs_log_group" {
  value = aws_cloudwatch_log_group.flowlogs.name
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.alb.arn
}

# --- NIST 800-53 hardening outputs ---
output "cloudtrail_arn" {
  value = aws_cloudtrail.main.arn
}

output "cloudtrail_s3_bucket" {
  value = aws_s3_bucket.cloudtrail.id
}

output "config_recorder_id" {
  value = aws_config_configuration_recorder.main.id
}

output "guardduty_detector_id" {
  value = var.enable_guardduty ? aws_guardduty_detector.main[0].id : "disabled"
}

output "sns_security_alerts_arn" {
  value = aws_sns_topic.security_alerts.arn
}
