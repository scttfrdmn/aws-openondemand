# prod.tfvars — Institutional production (~$600/month before compute)
#
# All features enabled. 200+ concurrent users. Compliance logging,
# backup, KMS customer-managed keys. This is what you deploy when
# the CIO's office is asking about your security posture.
#
#   terraform apply -var-file=environments/prod.tfvars \
#     -var='vpc_id=vpc-xxx' \
#     -var='subnet_id=subnet-xxx' \
#     -var='domain_name=ood.university.edu' \
#     -var='alarm_email=hpc-ops@university.edu'

# --- Required (no defaults) ---
# vpc_id       = "vpc-..."
# subnet_id    = "subnet-..."
# domain_name  = "ood.university.edu"
# alarm_email  = "hpc-ops@university.edu"

# --- Profile ---
deployment_profile = "standard"    # m6i.xlarge, on-demand
instance_type      = "m6i.2xlarge" # Override for 200+ users

# --- Cloud-native progression (all levels) ---
enable_efs                   = true  # Level 1: /home on EFS
enable_efs_one_zone          = false # Multi-AZ
enable_dynamodb_uid          = true  # Level 2: replaces LDAP
use_cognito                  = true  # Level 3: institutional SSO
enable_session_cache         = true  # Level 5: PUN sessions survive instance replacement
enable_s3_browser            = true  # Level 6: researchers browse S3 from OOD
enable_cloudwatch_accounting = true  # Level 7: per-user/project dollar-denominated accounting

# --- Feature toggles (everything on) ---
enable_alb           = true
enable_waf           = true
enable_fsx           = true # Lustre scratch for ParallelCluster
enable_vpc_endpoints = true
enable_cdn           = true # CloudFront for static assets
enable_packer_ami    = true # Pre-baked AMI for fast instance replacement

# --- Observability & compliance ---
enable_monitoring          = true
enable_advanced_monitoring = true # Per-user cost tracking, job metrics
enable_compliance_logging  = true # VPC Flow Logs, CloudTrail, Config, Security Hub
enable_backup              = true # AWS Backup: EFS + DynamoDB, cross-region copy
enable_kms_cmk             = true # Customer-managed keys for all encrypted resources

# --- Compute backends ---
adapters_enabled = ["batch", "sagemaker", "parallelcluster"]
# Add "onprem" to the list and set onprem_* vars to connect campus cluster

# --- Identity ---
# cognito_saml_metadata_url = "https://idp.university.edu/metadata"

# --- On-prem (uncomment to enable) ---
# onprem_vpn_cidr   = "10.100.0.0/16"
# onprem_head_node  = "hpc-login.university.edu"

# --- Batch settings ---
batch_spot_enabled = true
batch_max_vcpus    = 512

# --- SageMaker settings ---
sagemaker_default_instance_type = "ml.t3.medium"
# sagemaker_gpu_instance_types = ["ml.g5.xlarge", "ml.p3.2xlarge"]

# --- ParallelCluster settings ---
parallelcluster_max_nodes = 200
parallelcluster_gpu_queue = true

# --- Environment sizing ---
ebs_volume_size          = 50 # GB
cloudwatch_log_retention = 90 # days
