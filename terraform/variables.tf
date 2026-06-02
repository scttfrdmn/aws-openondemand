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
                 Requires enable_efs=true (EFS-backed /home survives Spot interruption).
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
  description = "Compute backends to wire up: batch, sagemaker, sagemaker-training, ec2, omics, emr, fargate, stepfunctions, braket, bedrock, plus the meta-adapters router and burst. Infrastructure (IAM, queues, domains) is created per backend entry. router/burst are dispatchers that shell out to the backend adapters and add no IAM of their own — enable the backends they route to as well."
  validation {
    condition     = alltrue([for a in var.adapters_enabled : contains(["batch", "sagemaker", "sagemaker-training", "ec2", "omics", "emr", "fargate", "stepfunctions", "braket", "bedrock", "router", "burst"], a)])
    error_message = "adapters_enabled entries must be one of: batch, sagemaker, sagemaker-training, ec2, omics, emr, fargate, stepfunctions, braket, bedrock, router, burst."
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

# ---------------------------------------------------------------------------
# #78: Directory-backed identity (AWS Directory Service + SSSD/NSS)
#
# Replaces the bespoke oidc-pam + DynamoDB-UID + login-time-useradd stack (#39->#77,
# architecturally unworkable: nginx_stage getpwnam runs before any hook) with OOD's native
# model. The two identity concerns are independent:
#   - Web authn (OIDC): KEEP Cognito (managed, already built) — just move the Apache vhost to
#     generator-owned config so the #52/#60/#73 hand-wiring class can't recur.
#   - POSIX identity: resolve directory-side via NSS/SSSD so getpwnam succeeds with NO account
#     creation at login. The directory is AWS Directory Service (managed: no servers, no DB) —
#     Simple AD for non-prod, Managed Microsoft AD for prod. SSSD uses id_provider=ad +
#     ldap_id_mapping (algorithmic uids). Federate Cognito to the AD so the OIDC username ==
#     the AD/SSSD account by construction (kills the #64/#75 claim->username guessing).
# directory_ldap_uri stays configurable so SSSD can target an on-prem AD/LDAP instead with no
# code change (the real topology). Defaults OFF so existing deployments are unaffected until
# the cutover (#78-5, post live validation).
# ---------------------------------------------------------------------------

variable "enable_directory" {
  type        = bool
  default     = false
  description = "#78: provision an AWS Directory Service domain (Simple AD non-prod / Managed Microsoft AD prod) to serve POSIX identity for SSSD. When true the portal resolves users via the directory instead of the oidc-pam/DynamoDB-UID/login-useradd stack."
}

variable "use_sssd" {
  type        = bool
  default     = false
  description = "#78: configure SSSD/NSS on the OOD host so authenticated users resolve via getpwnam against the directory (no login-time useradd). Pairs with enable_directory, or point directory_ldap_uri at an on-prem AD/LDAP."
}

variable "directory_name" {
  type        = string
  default     = "ood.internal"
  description = "#78: fully-qualified AD domain name for AWS Directory Service (e.g. ood.example.com). Also the SSSD domain."
}

variable "directory_ldap_uri" {
  type        = string
  default     = ""
  description = "#78: override LDAP(S) URI SSSD reads (e.g. an on-prem AD/LDAP: ldaps://ad.corp.example.com:636). Empty + enable_directory uses the provisioned AWS Directory Service endpoint. This is the swappable directory host."
}

variable "directory_ldap_schema" {
  type        = string
  default     = "ad"
  description = "#78: SSSD ldap_schema (ad for AWS Directory Service / Active Directory; rfc2307bis for a POSIX LDAP)."
}

# ---------------------------------------------------------------------------
# #78 PR B: Dex LDAP connector — web-auth bind contract.
# OOD's bundled Dex authenticates users via an LDAP connector bound to the SAME directory SSSD
# reads, so the OIDC username == the POSIX account by construction. These describe how Dex
# binds and searches the directory. For the eval Simple AD they default to sensible values
# derived from directory_name; for BYO production the operator sets them to match their AD/LDAP.
# The bind PASSWORD is never a variable — it lives in the Secrets Manager secret
# ood/<env>/directory-bind-password (operator-populated for BYO; auto-filled from the Simple AD
# admin secret in eval mode).
# ---------------------------------------------------------------------------

variable "directory_bind_dn" {
  type        = string
  default     = ""
  description = "#78: LDAP bind DN Dex uses to search the directory (e.g. CN=ood-bind,OU=Service,DC=ood,DC=internal). Empty + enable_directory derives the Simple AD Administrator DN from directory_name."
}

variable "directory_user_base_dn" {
  type        = string
  default     = ""
  description = "#78: base DN under which Dex searches for users (e.g. CN=Users,DC=ood,DC=internal). Empty + enable_directory derives it from directory_name."
}

variable "directory_user_filter" {
  type        = string
  default     = "(objectClass=person)"
  description = "#78: LDAP filter for the Dex userSearch."
}

variable "directory_username_attr" {
  type        = string
  default     = "sAMAccountName"
  description = "#78: AD/LDAP attribute Dex uses as the OOD username. sAMAccountName (AD) yields a bare name (demo) that matches the POSIX account SSSD resolves — NOT userPrincipalName/email (which would mismatch)."
}

# ---------------------------------------------------------------------------
# #78 PR C: per-user cross-account AWS identity.
# In the multi-account topology, an adapter's AWS calls should run in the LOGGING-IN USER's
# own account under a per-user role, not the OOD instance role. When enabled, the portal's
# cluster YAML passes --assume-role-arn (with a {username} placeholder the adapter expands
# from the runtime user) to each adapter, and the instance role is granted sts:AssumeRole on
# the role pattern. Default OFF: the instance role is used directly (single-account on-ramp).
# The per-user roles themselves live in the user's account and are the operator's to create
# (with a trust policy allowing the OOD instance role + the external id) — see
# docs/reference-architecture.md §4.
# ---------------------------------------------------------------------------

variable "enable_per_user_roles" {
  type        = bool
  default     = false
  description = "#78: adapters assume a per-user role in the user's AWS account (via --assume-role-arn) instead of using the OOD instance role. Requires per_user_role_arn_template. Default off (single-account uses the instance role)."
}

variable "per_user_role_arn_template" {
  type        = string
  default     = ""
  description = "#78: role ARN the adapters assume, with a literal {username} placeholder the adapter expands from the logged-in user, e.g. arn:aws:iam::ACCOUNT:role/ood-user-{username}. Required when enable_per_user_roles=true."

  validation {
    condition     = var.per_user_role_arn_template == "" || can(regex("\\{username\\}", var.per_user_role_arn_template))
    error_message = "per_user_role_arn_template should contain a {username} placeholder so each user assumes their own role (e.g. arn:aws:iam::ACCOUNT:role/ood-user-{username})."
  }
}

variable "per_user_role_external_id" {
  type        = string
  default     = "ood"
  description = "#78: sts:ExternalId the adapters present when assuming the per-user role (the user-account role's trust policy should require this)."
}
