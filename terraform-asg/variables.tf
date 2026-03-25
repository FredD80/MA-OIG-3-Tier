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

# --- Web tier (ASG) ---
variable "app_instance_type" {
  type        = string
  description = "Instance type for web tier ASG"
  default     = "t3.micro"
}

variable "app_min_size" {
  type        = number
  description = "Web tier ASG minimum size"
  default     = 2
}

variable "app_max_size" {
  type        = number
  description = "Web tier ASG maximum size"
  default     = 2
}

variable "app_desired_capacity" {
  type        = number
  description = "Web tier ASG desired capacity"
  default     = 2
}

variable "app_port" {
  type        = number
  description = "Web tier listen port on EC2 instances (HTTPS)"
  default     = 443
}

variable "app_health_path" {
  type        = string
  description = "Web ALB health check path"
  default     = "/health"
}

# --- Logic tier (ASG) ---
variable "logic_instance_type" {
  type        = string
  description = "Instance type for logic tier ASG"
  default     = "t3.micro"
}

variable "logic_min_size" {
  type        = number
  description = "Logic tier ASG minimum size"
  default     = 2
}

variable "logic_max_size" {
  type        = number
  description = "Logic tier ASG maximum size"
  default     = 2
}

variable "logic_desired_capacity" {
  type        = number
  description = "Logic tier ASG desired capacity"
  default     = 2
}

variable "logic_port" {
  type        = number
  description = "Logic tier listen port on EC2 instances (HTTPS)"
  default     = 8443
}

variable "logic_health_path" {
  type        = string
  description = "Logic ALB health check path"
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
  description = "ACM certificate ARN for the web ALB HTTPS listener (SC-8). Required."
}

variable "logic_acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the logic ALB HTTPS listener. Leave empty to reuse acm_certificate_arn (e.g. wildcard cert)."
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
