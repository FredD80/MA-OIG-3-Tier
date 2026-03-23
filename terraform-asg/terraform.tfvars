# -----------------------------------------------
# MA-OIG NIST 800-53 Infrastructure Variables
# Fill in the values below before running:
#   terraform init
#   terraform plan
#   terraform apply
# -----------------------------------------------

# --- General ---
aws_region = ""        # e.g. "us-east-1"
name       = ""        # Resource name prefix, e.g. "ma-oig-prod"
vpc_cidr   = ""        # VPC CIDR block, e.g. "10.20.0.0/16"
az_count   =           # Number of AZs (2 recommended), e.g. 2

# --- App Tier (ASG / EC2) ---
app_instance_type    = ""  # e.g. "t3.micro"
app_min_size         =     # e.g. 2
app_max_size         =     # e.g. 4
app_desired_capacity =     # e.g. 2
app_port             =     # Port app listens on, e.g. 80
app_health_path      = ""  # ALB health check path, e.g. "/health"

# --- RDS Postgres ---
db_name                 = ""  # Initial database name, e.g. "appdb"
db_username             = ""  # Master username, e.g. "appadmin"
db_instance_class       = ""  # e.g. "db.t4g.medium"
db_allocated_storage_gb =     # Storage in GB, e.g. 50
db_engine_version       = ""  # e.g. "16.3"
db_multi_az             =     # true or false
db_backup_retention_days =    # e.g. 14
db_port                 =     # e.g. 5432

# --- NIST 800-53 Hardening ---
# ACM certificate ARN for HTTPS (SC-8). Leave "" to use HTTP-only.
acm_certificate_arn = ""

# Email for security alarm notifications (IR-6). Leave "" to skip.
alarm_email = ""

# Enable GuardDuty threat detection (SI-3, SI-4). true or false.
enable_guardduty =

# --- Tags ---
# Uncomment and customize if you want to override the default tags.
# tags = {
#   compliance  = "nist-800-53"
#   managed_by  = "terraform"
#   project     = "ma-oig"
#   environment = "production"
# }
