variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (test, staging, or prod)"
  validation {
    condition     = contains(["test", "staging", "prod"], var.environment)
    error_message = "Environment must be test, staging, or prod."
  }
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC"
}

variable "subnet_id" {
  type        = string
  description = "ID of a public subnet in the VPC (portal EC2 instance)"
}

variable "private_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Private subnet IDs for EFS mount targets, ElastiCache, and other private resources (defaults to [subnet_id] when empty)"
}

variable "alb_subnet_ids" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Subnet IDs for the ALB (must be in different AZs for high availability).
    Defaults to [subnet_id] when empty, but that produces a single-AZ ALB.
    For staging and prod, provide at least 2 subnets in different AZs.
  EOT
}

variable "allowed_cidr" {
  type        = string
  description = "CIDR for inbound HTTP/HTTPS — do NOT use 0.0.0.0/0 in staging/prod"
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be a valid CIDR block (e.g. 203.0.113.5/32)."
  }
  validation {
    condition     = var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must not be 0.0.0.0/0. Specify your institution's CIDR (e.g. 203.0.113.0/24)."
  }
}

variable "domain_name" {
  type        = string
  default     = ""
  description = "Fully-qualified domain name for the OOD portal (e.g. ood.example.edu)"
}

variable "deployment_profile" {
  type        = string
  default     = "minimal"
  description = <<-EOT
    Compute cost profile:
      minimal  — t3.medium x86_64 on-demand (~$30/mo). Default.
      standard — m6i.xlarge x86_64 on-demand (~$140/mo). Departmental use.
      graviton — m7g.xlarge ARM64 on-demand (~$115/mo). ~20% cheaper than standard.
      spot     — m6i.xlarge x86_64 spot pricing (~$14–28/mo compute).
                 Requires enable_efs=true, enable_dynamodb_uid=true, use_cognito=true.
      large    — m6i.2xlarge x86_64 on-demand (~$280/mo). High-concurrency portal.
    Use instance_type to override the profile's default instance size.
  EOT
  validation {
    condition     = contains(["minimal", "standard", "graviton", "spot", "large"], var.deployment_profile)
    error_message = "deployment_profile must be one of: minimal, standard, graviton, spot, large."
  }
}

variable "instance_type" {
  type        = string
  default     = ""
  description = "Override the EC2 instance type set by deployment_profile. Leave empty to use the profile default."
}

# ---------------------------------------------------------------------------
# Identity / Auth
# ---------------------------------------------------------------------------

variable "use_cognito" {
  type        = bool
  default     = true
  description = "Provision a Cognito User Pool + App Client for OIDC auth (Level 3 cloud-native)"
}

variable "cognito_saml_metadata_url" {
  type        = string
  default     = ""
  description = "SAML metadata URL for InCommon/Shibboleth federation via Cognito (optional — requires use_cognito=true)"
}

variable "oidc_client_id" {
  type        = string
  default     = ""
  description = "OIDC client ID (from Cognito App Client or external IdP). Auto-populated from Cognito when use_cognito=true."
}

variable "oidc_issuer_url" {
  type        = string
  default     = ""
  description = "OIDC issuer URL. Auto-populated from Cognito User Pool when use_cognito=true."
}

# ---------------------------------------------------------------------------
# Cloud-native progression toggles
# ---------------------------------------------------------------------------

variable "enable_efs" {
  type        = bool
  default     = true
  description = "Provision an EFS file system for /home (Level 1: instance becomes replaceable)"
}

variable "enable_efs_one_zone" {
  type        = bool
  default     = false
  description = "Use single-AZ EFS (~47% cheaper). Automatically true for test environment."
}

variable "enable_dynamodb_uid" {
  type        = bool
  default     = true
  description = "Provision a DynamoDB UID mapping table replacing LDAP (Level 2)"
}

variable "enable_session_cache" {
  type        = bool
  default     = false
  description = "Store PUN session tokens in ElastiCache Redis so Spot interruptions are transparent (Level 5)"
}

variable "enable_s3_browser" {
  type        = bool
  default     = false
  description = "Provision an S3 bucket and enable the OOD S3 file browser panel (Level 6)"
}

variable "enable_cloudwatch_accounting" {
  type        = bool
  default     = false
  description = "Enable per-user dollar-denominated job accounting via Lambda + Cost Explorer (Level 7)"
}

# ---------------------------------------------------------------------------
# Compute backends (adapters)
# ---------------------------------------------------------------------------

variable "adapters_enabled" {
  type        = list(string)
  default     = []
  description = "Compute backends to wire up: batch, sagemaker, ec2. Infrastructure (IAM, queues, domains) is created per entry."
  validation {
    condition     = alltrue([for a in var.adapters_enabled : contains(["batch", "sagemaker", "ec2"], a)])
    error_message = "adapters_enabled entries must be one of: batch, sagemaker, ec2."
  }
}

# ---------------------------------------------------------------------------
# Feature toggles
# ---------------------------------------------------------------------------

variable "enable_alb" {
  type        = bool
  default     = true
  description = "Provision an Application Load Balancer with HTTPS termination"
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = "Existing ACM certificate ARN for the ALB HTTPS listener. If empty and domain_name is set, a new certificate with DNS validation is created."
}

variable "enable_waf" {
  type        = bool
  default     = true
  description = "Attach AWS WAF v2 (regional) to the ALB with CommonRuleSet, KnownBadInputs, SQLi in Block mode. Requires enable_alb=true."
}

variable "enable_fsx" {
  type        = bool
  default     = false
  description = "Provision an FSx for Lustre scratch filesystem mounted at /scratch"
}

variable "fsx_storage_capacity_gb" {
  type        = number
  default     = 1200
  description = "FSx Lustre storage capacity in GB (minimum 1200 GB; must be multiple of 1200)"
}

variable "enable_vpc_endpoints" {
  type        = bool
  default     = true
  description = "Create VPC endpoints for S3 (gateway) and SSM/Secrets Manager/CloudWatch/EC2Messages (interface)"
}

variable "enable_cdn" {
  type        = bool
  default     = false
  description = "Provision a CloudFront distribution for static asset caching. Requires enable_alb=true."
}

variable "enable_monitoring" {
  type        = bool
  default     = true
  description = "Enable CloudWatch log groups, dashboard, and alarms"
}

variable "enable_advanced_monitoring" {
  type        = bool
  default     = false
  description = "Enable detailed CloudWatch metrics for EFS and Batch in addition to standard monitoring"
}

variable "alarm_email" {
  type        = string
  default     = ""
  description = "Email for CloudWatch alarm SNS notifications (empty = topic created, no subscription)"
}

variable "enable_compliance_logging" {
  type        = bool
  default     = false
  description = "Enable VPC Flow Logs, CloudTrail, AWS Config, and Security Hub for compliance"
}

variable "enable_backup" {
  type        = bool
  default     = false
  description = "Enable AWS Backup vault + plan for EFS and DynamoDB"
}

variable "enable_kms_cmk" {
  type        = bool
  default     = false
  description = "Use customer-managed KMS keys for EFS, DynamoDB, and S3 instead of AWS-managed keys"
}

variable "enable_packer_ami" {
  type        = bool
  default     = true
  description = "Use a pre-baked OOD AMI (ood-base-*) when available; falls back to AL2023 base AMI. Reduces bootstrap from 10-15 min to 3-5 min."
}

variable "enable_parameter_store" {
  type        = bool
  default     = true
  description = "Store runtime configuration in SSM Parameter Store and source at instance launch"
}

# H2: provide a pre-deployed rotation Lambda ARN to enable automatic OIDC client
# secret rotation. Without this, the secret must be rotated manually.
# See docs/identity-guide.md for instructions on building the rotation Lambda.
variable "oidc_secret_rotation_lambda_arn" {
  type        = string
  default     = ""
  description = "ARN of a Lambda function to rotate the Cognito OIDC client secret. Empty = no automatic rotation (manual rotation required every 90 days)."
}

# ---------------------------------------------------------------------------
# Sizing overrides (normally controlled by environment)
# ---------------------------------------------------------------------------

variable "spot_max_price" {
  type        = string
  default     = ""
  description = "Max hourly price for Spot instances (empty = on-demand price as ceiling). Only applies when deployment_profile=spot."
}

variable "ebs_volume_size" {
  type        = number
  default     = 0
  description = "Root EBS volume size in GB (0 = use environment default: test=30, staging=50, prod=50)"
}

variable "cloudwatch_log_retention" {
  type        = number
  default     = 0
  description = "CloudWatch log retention in days (0 = use environment default: test=7, staging=30, prod=90)"
}
