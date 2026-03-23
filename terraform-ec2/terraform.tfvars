# -----------------------------------------------
# MA-OIG NIST 800-53 Infrastructure Variables
# (Variation: Static EC2 + RDS Primary/Replica)
# -----------------------------------------------

# --- General ---
aws_region = "us-east-1"
name       = "ma-oig-mvp"
vpc_cidr   = "10.20.0.0/16"

# --- Web Tier (2 web EC2 instances in public subnets: us-east-1a, us-east-1c) ---
# These face the Internet via the external ALB.
web_instance_type = "t3.micro"

# --- App Tier (2 app EC2 instances in private subnets: us-east-1a, us-east-1c) ---
# These are accessible only via the internal ALB from the web tier.
app_instance_type = "t3.micro"
app_port          = 80
app_health_path   = "/health"

# --- RDS Postgres (Primary in us-east-1a, Read Replica in us-east-1c) ---
db_name                  = "maOigDb"
db_username              = "appadmin"
db_instance_class        = "db.t3.micro"
db_allocated_storage_gb  = 20
db_engine_version        = "16.3"
db_backup_retention_days = 1
db_port                  = 5432

# --- NIST 800-53 Hardening ---
# ACM certificate ARN for HTTPS (SC-8). Leave "" to use HTTP-only.
acm_certificate_arn = ""

# Email for security alarm notifications (IR-6). Leave "" to skip SNS subscription.
alarm_email = ""

# Enable GuardDuty threat detection (SI-3, SI-4).
enable_guardduty = false

# --- Tags ---
tags = {
  compliance  = "nist-800-53"
  managed_by  = "terraform"
  project     = "ma-oig"
  environment = "mvp"
}
