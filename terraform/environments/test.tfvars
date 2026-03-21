# test.tfvars — Cheapest path (~$35/month)
#
# A functional Open OnDemand deployment with OIDC auth for
# development, demos, and small labs. No ALB, no WAF, no VPC
# endpoints — just OOD on an EC2 instance with EFS and Cognito.
#
# Required: set vpc_id, subnet_id, and allowed_cidr below or
# pass them on the command line:
#
#   terraform apply -var-file=environments/test.tfvars \
#     -var='vpc_id=vpc-xxx' \
#     -var='subnet_id=subnet-xxx' \
#     -var='allowed_cidr=YOUR_IP/32'

# --- Required (no defaults) ---
environment  = "test"
aws_region   = "us-west-2"
vpc_id       = "vpc-e7e2999f"
subnet_id    = "subnet-0a73ca94ed00cdaf9"
allowed_cidr = "47.150.84.16/32"

# --- Profile ---
deployment_profile = "minimal" # t3.medium, on-demand, ~$30/mo

# --- Cloud-native progression ---
# Each toggle tips OOD further into the cloud. See docs/architecture.md.
enable_efs                   = true  # Level 1: /home on EFS — instance is replaceable
enable_efs_one_zone          = true  # Single-AZ EFS, ~47% cheaper
enable_dynamodb_uid          = true  # Level 2: UID mapping replaces LDAP (~$1/mo)
use_cognito                  = true  # Level 3: Cognito for OIDC (free tier)
enable_session_cache         = false # Level 5: PUN sessions in ElastiCache (not needed without spot)
enable_s3_browser            = false # Level 6: S3 browsing in file manager
enable_cloudwatch_accounting = false # Level 7: per-user cost tracking

# --- Feature toggles (cost-saving defaults) ---
enable_alb                 = false # Direct access, saves ~$20/mo
enable_waf                 = false # No WAF (no ALB to attach it to)
enable_fsx                 = false # No Lustre scratch
enable_vpc_endpoints       = false # Requires NAT or IGW for SSM (default VPC has IGW)
enable_cdn                 = false # No CloudFront
enable_monitoring          = false # No dashboard or alarms — just bootstrap logs
enable_advanced_monitoring = false
enable_compliance_logging  = false
enable_backup              = false
enable_kms_cmk             = false
enable_packer_ami          = true # Use pre-baked OOD AMI (ami-0a3ca20950d8cff2c)

# --- Compute backends ---
adapters_enabled = [] # Portal only — add backends later

# --- Environment sizing ---
ebs_volume_size          = 30 # GB
cloudwatch_log_retention = 7  # days
