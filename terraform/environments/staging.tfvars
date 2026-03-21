# staging.tfvars — Department deployment (~$235/month)
#
# ALB, WAF, VPC endpoints, monitoring. Good for 50-100 concurrent
# users with real workloads. Graviton profile saves ~20% on compute.
#
#   terraform apply -var-file=environments/staging.tfvars \
#     -var='vpc_id=vpc-xxx' \
#     -var='subnet_id=subnet-xxx' \
#     -var='allowed_cidr=203.0.113.0/24' \   # Replace with your institution's CIDR
#     -var='domain_name=ood-staging.university.edu'
#
# NOTE: allowed_cidr must NOT be 0.0.0.0/0 — Terraform will reject it.
# Use your institution's egress CIDR or a specific IP range.

# --- Required (no defaults) ---
# vpc_id       = "vpc-..."
# subnet_id    = "subnet-..."
# allowed_cidr = "203.0.113.0/24"  # Replace with your institution's CIDR
# domain_name  = "ood-staging.university.edu"

# --- Profile ---
deployment_profile = "graviton" # m7g.xlarge ARM64, ~$112/mo

# --- Cloud-native progression ---
enable_efs                   = true  # Level 1: /home on EFS
enable_efs_one_zone          = false # Multi-AZ for durability
enable_dynamodb_uid          = true  # Level 2: no LDAP
use_cognito                  = true  # Level 3: institutional SSO
enable_session_cache         = false # Level 5: enable if using spot profile
enable_s3_browser            = true  # Level 6: researchers access S3 data from OOD
enable_cloudwatch_accounting = true  # Level 7: per-user cost tracking for cloud jobs

# --- Feature toggles ---
enable_alb                 = true  # HTTPS termination, health checks
enable_waf                 = true  # Managed rules: CommonRuleSet, KnownBadInputs, SQLi
enable_fsx                 = false # No Lustre (enable if ParallelCluster needs it)
enable_vpc_endpoints       = true  # No internet traversal for AWS API calls
enable_cdn                 = false # Enable if static asset performance matters
enable_monitoring          = true  # Dashboard, alarms, SNS
enable_advanced_monitoring = false # Enable for per-user cost tracking
enable_compliance_logging  = false # Enable if compliance requires it
enable_backup              = false
enable_kms_cmk             = false
enable_packer_ami          = false # Set true after building AMI with Packer

# --- Compute backends ---
adapters_enabled = ["batch", "sagemaker"]

# --- Identity ---
# cognito_saml_metadata_url = "https://idp.university.edu/metadata"

# --- Batch settings ---
batch_spot_enabled = true
batch_max_vcpus    = 256

# --- SageMaker settings ---
sagemaker_default_instance_type = "ml.t3.medium"

# --- Environment sizing ---
ebs_volume_size          = 50 # GB
cloudwatch_log_retention = 30 # days
alarm_email              = "" # Set to receive alarm notifications
