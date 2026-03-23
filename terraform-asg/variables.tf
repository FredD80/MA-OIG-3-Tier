variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "name" {
  type        = string
  description = "Name prefix for resources"
  default     = "nist-3tier"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
  default     = "10.20.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of AZs (2 recommended)"
  default     = 2
}

# --- App tier (ASG) ---
variable "app_instance_type" {
  type        = string
  description = "Instance type for app ASG"
  default     = "t3.micro"
}

variable "app_min_size" {
  type    = number
  default = 2
}

variable "app_max_size" {
  type    = number
  default = 4
}

variable "app_desired_capacity" {
  type    = number
  default = 2
}

# App will listen on port 80 in this baseline (simple nginx placeholder).
variable "app_port" {
  type        = number
  description = "App listen port on EC2 instances"
  default     = 80
}

variable "app_health_path" {
  type        = string
  description = "ALB health check path"
  default     = "/health"
}

# --- RDS Postgres ---
variable "db_name" {
  type        = string
  description = "Initial database name"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "DB master username"
  default     = "appadmin"
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class"
  default     = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  type        = number
  description = "Allocated storage in GB"
  default     = 50
}

# If apply fails due to unsupported minor version, adjust to one supported in your region.
variable "db_engine_version" {
  type        = string
  description = "PostgreSQL engine version"
  default     = "16.3"
}

variable "db_multi_az" {
  type        = bool
  description = "Multi-AZ for RDS"
  default     = true
}

variable "db_backup_retention_days" {
  type        = number
  description = "Backup retention days"
  default     = 14
}

variable "db_port" {
  type        = number
  description = "Postgres port"
  default     = 5432
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default = {
    compliance = "nist-800-53"
    managed_by = "terraform"
  }
}

# --- NIST 800-53 hardening ---
variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for HTTPS listener (SC-8). Leave empty to keep HTTP-only."
  default     = ""
}

variable "alarm_email" {
  type        = string
  description = "Email address for security alarm notifications (IR-6)"
  default     = ""
}

variable "enable_guardduty" {
  type        = bool
  description = "Enable GuardDuty threat detection (SI-3, SI-4)"
  default     = true
}
