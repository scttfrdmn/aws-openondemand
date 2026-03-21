terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  # Backend config intentionally not hardcoded — provide via -backend-config (C2).
  # Copy terraform/backend.hcl.example → terraform/backend.hcl, fill in values, then:
  #   terraform init -backend-config=backend.hcl
  # backend.hcl is gitignored. Hardcoding causes state collisions across accounts/envs.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "aws-openondemand"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  # ---------------------------------------------------------------------------
  # Deployment profiles
  # ---------------------------------------------------------------------------
  profile_config = {
    minimal  = { instance_type = "t3.medium", cpu_arch = "x86_64", use_spot = false }
    standard = { instance_type = "m6i.xlarge", cpu_arch = "x86_64", use_spot = false }
    graviton = { instance_type = "m7g.xlarge", cpu_arch = "arm64", use_spot = false }
    spot     = { instance_type = "m6i.xlarge", cpu_arch = "x86_64", use_spot = true }
    large    = { instance_type = "m6i.2xlarge", cpu_arch = "x86_64", use_spot = false }
  }

  cpu_arch          = local.profile_config[var.deployment_profile].cpu_arch
  use_spot          = local.profile_config[var.deployment_profile].use_spot
  ec2_instance_type = var.instance_type != "" ? var.instance_type : local.profile_config[var.deployment_profile].instance_type

  # ---------------------------------------------------------------------------
  # Per-environment sizing
  # ---------------------------------------------------------------------------
  env_config = {
    test    = { volume_size = 30, efs_throughput = "elastic", log_retention = 7, multi_az_efs = false, efs_one_zone = true }
    staging = { volume_size = 50, efs_throughput = "elastic", log_retention = 30, multi_az_efs = true, efs_one_zone = false }
    prod    = { volume_size = 50, efs_throughput = "provisioned", log_retention = 90, multi_az_efs = true, efs_one_zone = false }
  }

  config        = local.env_config[var.environment]
  volume_size   = var.ebs_volume_size > 0 ? var.ebs_volume_size : local.config.volume_size
  log_retention = var.cloudwatch_log_retention > 0 ? var.cloudwatch_log_retention : local.config.log_retention

  # EFS one-zone: test always uses it; other envs use the variable
  efs_one_zone = var.environment == "test" ? true : var.enable_efs_one_zone

  # Effective private subnets for EFS/ElastiCache/etc.
  private_subnets = length(var.private_subnet_ids) > 0 ? var.private_subnet_ids : [var.subnet_id]

  # C1: ALB subnets — operator should provide at least 2 subnets in different AZs for prod/staging.
  # If alb_subnet_ids is empty, fall back to a single subnet (acceptable only for test).
  alb_subnets = length(var.alb_subnet_ids) > 0 ? var.alb_subnet_ids : [var.subnet_id]

  # Adapter flags
  enable_batch       = contains(var.adapters_enabled, "batch")
  enable_sagemaker   = contains(var.adapters_enabled, "sagemaker")
  enable_ec2_adapter = contains(var.adapters_enabled, "ec2")

  # Precondition: spot profile requires cloud-native stack
  # (enforced below via lifecycle precondition on the ASG)
  spot_prereqs_met = !local.use_spot || (var.enable_efs && var.enable_dynamodb_uid && var.use_cognito)
}

# ---------------------------------------------------------------------------
# AMI selection
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-${local.cpu_arch}"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = [local.cpu_arch]
  }
}

data "aws_ami" "ood_baked" {
  count       = var.enable_packer_ami ? 1 : 0
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = ["ood-base-*"]
  }
  filter {
    name   = "architecture"
    values = [local.cpu_arch]
  }
}

locals {
  selected_ami = (
    var.enable_packer_ami && length(data.aws_ami.ood_baked) > 0
    ? data.aws_ami.ood_baked[0].id
    : data.aws_ami.al2023.id
  )
}

# ---------------------------------------------------------------------------
# Networking — existing VPC
# ---------------------------------------------------------------------------
data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet" "portal" {
  id = var.subnet_id
}

# Instance security group
resource "aws_security_group" "ood" {
  name_prefix = "ood-${var.environment}-"
  description = "OOD portal ${var.environment} instance"
  vpc_id      = data.aws_vpc.selected.id

  # Direct HTTP/HTTPS only when ALB is not in front
  dynamic "ingress" {
    for_each = var.enable_alb ? [] : [80, 443]
    content {
      description = ingress.value == 80 ? "HTTP" : "HTTPS"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "HTTP outbound (package repos)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # EFS NFS egress — scoped to VPC CIDR to avoid SG cycle
  dynamic "egress" {
    for_each = var.enable_efs ? [1] : []
    content {
      description = "NFS to EFS"
      from_port   = 2049
      to_port     = 2049
      protocol    = "tcp"
      cidr_blocks = [data.aws_vpc.selected.cidr_block]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ALB security group
resource "aws_security_group" "alb" {
  count       = var.enable_alb ? 1 : 0
  name_prefix = "ood-alb-${var.environment}-"
  description = "OOD ALB ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  # C3: ALB terminates TLS and forwards HTTP to the EC2 instance over a private VPC
  # connection. This is intentional — OOD runs Apache on port 80 behind the ALB.
  # HTTPS egress (443) is not needed because the ALB→EC2 path never uses TLS.
  egress {
    description     = "HTTP to EC2 (intentional: ALB terminates TLS, forwards plaintext on private VPC)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.ood.id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ALB ingress rule on instance SG (only when ALB is enabled)
resource "aws_vpc_security_group_ingress_rule" "ood_from_alb" {
  count                        = var.enable_alb ? 1 : 0
  security_group_id            = aws_security_group.ood.id
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP from ALB"
}

# EFS security group
resource "aws_security_group" "efs" {
  count       = var.enable_efs ? 1 : 0
  name_prefix = "ood-efs-${var.environment}-"
  description = "OOD EFS ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "NFS from OOD instance"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ood.id]
  }

  # M3: explicit egress overrides the default allow-all rule
  egress {
    description     = "NFS replies to OOD instance"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ood.id]
  }

  lifecycle {
    create_before_destroy = true
  }
}


# ElastiCache security group
resource "aws_security_group" "elasticache" {
  count       = var.enable_session_cache ? 1 : 0
  name_prefix = "ood-elasticache-${var.environment}-"
  description = "OOD ElastiCache ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "Redis from OOD instance"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ood.id]
  }

  # M4: explicit egress overrides the default allow-all rule
  egress {
    description     = "Redis replies to OOD instance"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ood.id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "ood_to_elasticache" {
  count                        = var.enable_session_cache ? 1 : 0
  security_group_id            = aws_security_group.ood.id
  referenced_security_group_id = aws_security_group.elasticache[0].id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis to ElastiCache"
}

# ---------------------------------------------------------------------------
# IAM — EC2 instance role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ood" {
  name_prefix = "ood-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ood.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ood" {
  name_prefix = "ood-${var.environment}-"
  role        = aws_iam_role.ood.name
}

# CloudWatch logs/metrics (always needed for bootstrap logs)
resource "aws_iam_role_policy" "cw" {
  name_prefix = "ood-cw-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # cloudwatch:PutMetricData requires Resource="*" (no resource-level support)
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        # Log actions scoped to OOD log group prefix and SSM session logs
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/ood-${var.environment}",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/ood-${var.environment}/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/ood-${var.environment}:*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/ood-${var.environment}",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/ood-${var.environment}/*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/ood-${var.environment}:*",
        ]
      }
    ]
  })
}

# SSM Parameter Store read access
resource "aws_iam_role_policy" "ssm_params" {
  count       = var.enable_parameter_store ? 1 : 0
  name_prefix = "ood-ssm-params-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ood/${var.environment}",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ood/${var.environment}/*"
      ]
    }]
  })
}

# M6: allow instance to write SSM session transcripts to S3
resource "aws_iam_role_policy" "ssm_session_s3" {
  count       = var.enable_monitoring ? 1 : 0
  name_prefix = "ood-ssm-session-s3-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetEncryptionConfiguration"]
      Resource = [
        aws_s3_bucket.ssm_sessions[0].arn,
        "${aws_s3_bucket.ssm_sessions[0].arn}/sessions/*",
      ]
    }]
  })
}

# Secrets Manager: fetch OIDC client secret at runtime (H2)
resource "aws_iam_role_policy" "secrets_manager" {
  count       = var.use_cognito ? 1 : 0
  name_prefix = "ood-secrets-manager-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.oidc_client_secret[0].arn
    }]
  })
}

# DynamoDB UID mapping table access
resource "aws_iam_role_policy" "dynamodb_uid" {
  count       = var.enable_dynamodb_uid ? 1 : 0
  name_prefix = "ood-dynamodb-uid-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
      ]
      Resource = aws_dynamodb_table.uid_map[0].arn
    }]
  })
}

# EFS mount access (ClientMount + DescribeMountTargets for IAM auth DNS fallback)
resource "aws_iam_role_policy" "efs" {
  count       = var.enable_efs ? 1 : 0
  name_prefix = "ood-efs-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess",
        ]
        Resource = aws_efs_file_system.home[0].arn
        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = aws_efs_access_point.home[0].arn
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticfilesystem:DescribeMountTargets"]
        Resource = aws_efs_file_system.home[0].arn
      }
    ]
  })
}

# S3 browser bucket access
resource "aws_iam_role_policy" "s3_browser" {
  count       = var.enable_s3_browser ? 1 : 0
  name_prefix = "ood-s3-browser-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject"]
      Resource = [
        aws_s3_bucket.ood_files[0].arn,
        "${aws_s3_bucket.ood_files[0].arn}/*",
      ]
    }]
  })
}

# AWS Batch adapter IAM — scoped to OOD job queue and job definitions
resource "aws_iam_role_policy" "batch_adapter" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-aws-batch-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["batch:SubmitJob", "batch:TerminateJob", "batch:ListJobs"]
        Resource = [
          aws_batch_job_queue.ood[0].arn,
          "arn:aws:batch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:job-definition/ood-${var.environment}-*",
        ]
      },
      {
        # Describe actions require Resource="*" (no resource-level support)
        Effect   = "Allow"
        Action   = ["batch:DescribeJobs", "batch:DescribeJobDefinitions", "batch:DescribeJobQueues"]
        Resource = "*"
      }
    ]
  })
}

# SageMaker adapter IAM — mutating actions scoped to OOD domain
resource "aws_iam_role_policy" "sagemaker_adapter" {
  count       = local.enable_sagemaker ? 1 : 0
  name_prefix = "ood-sagemaker-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sagemaker:CreateApp", "sagemaker:DeleteApp", "sagemaker:CreatePresignedDomainUrl"]
        Resource = [
          aws_sagemaker_domain.ood[0].arn,
          "${aws_sagemaker_domain.ood[0].arn}/*",
        ]
      },
      {
        # Describe/List actions require Resource="*"
        Effect   = "Allow"
        Action   = ["sagemaker:DescribeApp", "sagemaker:ListApps"]
        Resource = "*"
      }
    ]
  })
}

# EC2 adapter IAM — mutating actions scoped to tagged OOD instances and region
resource "aws_iam_role_policy" "ec2_adapter" {
  count       = local.enable_ec2_adapter ? 1 : 0
  name_prefix = "ood-ec2-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ec2:RunInstances"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*",
        ]
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      {
        # RunInstances on images: restrict to AMIs tagged as OOD project AND owned by this account.
        # H3: ec2:Owner matches the account ID that CREATED the AMI — a cross-account shared AMI
        # would fail this check even if tagged Project=aws-openondemand, because the owner is the
        # source account, not this account. This is the authoritative control for AMI origin.
        Effect = "Allow"
        Action = ["ec2:RunInstances"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}::image/*",
        ]
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/Project" = "aws-openondemand"
            "ec2:Owner"               = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # Terminate/tag only instances tagged as OOD-managed
        Effect    = "Allow"
        Action    = ["ec2:TerminateInstances", "ec2:CreateTags"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = { StringEquals = { "ec2:ResourceTag/Project" = "aws-openondemand" } }
      },
      {
        # Describe actions require Resource="*"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Cognito — User Pool + App Client
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "ood" {
  count = var.use_cognito ? 1 : 0
  name  = "ood-${var.environment}"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # M5: enable software TOTP MFA — optional so existing users without MFA can
  # still authenticate; recommend REQUIRED for prod after initial rollout
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  lifecycle {
    prevent_destroy = true # M10: user pool contains identity mappings; accidental destroy loses all users
  }
}

resource "aws_cognito_user_pool_domain" "ood" {
  count        = var.use_cognito ? 1 : 0
  domain       = "ood-${var.environment}-${data.aws_vpc.selected.id}"
  user_pool_id = aws_cognito_user_pool.ood[0].id
}

resource "aws_cognito_user_pool_client" "ood" {
  count        = var.use_cognito ? 1 : 0
  name         = "ood-portal-${var.environment}"
  user_pool_id = aws_cognito_user_pool.ood[0].id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = var.domain_name != "" ? [
    "https://${var.domain_name}/oidc/callback"
    ] : var.enable_alb ? [
    "https://${aws_lb.ood[0].dns_name}/oidc/callback"
  ] : ["https://localhost/oidc/callback"]

  logout_urls = var.domain_name != "" ? [
    "https://${var.domain_name}"
    ] : var.enable_alb ? [
    "https://${aws_lb.ood[0].dns_name}"
  ] : ["https://localhost"]

  supported_identity_providers = var.cognito_saml_metadata_url != "" ? [
    "COGNITO",
    aws_cognito_identity_provider.saml[0].provider_name,
    ] : [
    "COGNITO"
  ]

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]
}

resource "aws_cognito_identity_provider" "saml" {
  count         = var.use_cognito && var.cognito_saml_metadata_url != "" ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.ood[0].id
  provider_name = "InCommon"
  provider_type = "SAML"

  provider_details = {
    MetadataURL             = var.cognito_saml_metadata_url
    IDPSignout              = "true"
    RequestSigningAlgorithm = "rsa-sha256"
  }

  attribute_mapping = {
    email    = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
    username = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier"
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — UID mapping table (replaces LDAP for cloud-native auth)
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "uid_map" {
  count        = var.enable_dynamodb_uid ? 1 : 0
  name         = "oid-uid-map-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "oidc_sub"

  attribute {
    name = "oidc_sub"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = var.enable_kms_cmk
    kms_key_arn = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
  }

  tags = {
    Name = "oid-uid-map-${var.environment}"
  }

  lifecycle {
    prevent_destroy = true # M10: PITR recovers rows; this prevents accidental table drop
  }
}

# ---------------------------------------------------------------------------
# EFS — /home filesystem
# ---------------------------------------------------------------------------
resource "aws_efs_file_system" "home" {
  count            = var.enable_efs ? 1 : 0
  encrypted        = true
  kms_key_id       = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
  performance_mode = "generalPurpose"
  throughput_mode  = local.efs_one_zone ? "elastic" : local.config.efs_throughput

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "ood-home-${var.environment}"
  }
}

resource "aws_efs_access_point" "home" {
  count          = var.enable_efs ? 1 : 0
  file_system_id = aws_efs_file_system.home[0].id

  posix_user {
    uid = 0
    gid = 0
  }

  root_directory {
    path = "/home"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "755"
    }
  }

  tags = {
    Name = "ood-home-${var.environment}"
  }
}

resource "aws_efs_mount_target" "home" {
  count           = var.enable_efs ? length(local.private_subnets) : 0
  file_system_id  = aws_efs_file_system.home[0].id
  subnet_id       = local.private_subnets[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

# ---------------------------------------------------------------------------
# FSx Lustre — /scratch (optional)
# ---------------------------------------------------------------------------
resource "aws_fsx_lustre_file_system" "scratch" {
  count              = var.enable_fsx ? 1 : 0
  storage_capacity   = var.fsx_storage_capacity_gb
  subnet_ids         = [var.subnet_id]
  security_group_ids = [aws_security_group.ood.id]
  deployment_type    = "SCRATCH_2"
  storage_type       = "SSD"

  tags = {
    Name = "ood-scratch-${var.environment}"
  }
}

# ---------------------------------------------------------------------------
# ElastiCache Redis — PUN session externalization (Level 5)
# ---------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "ood" {
  count      = var.enable_session_cache ? 1 : 0
  name       = "ood-${var.environment}"
  subnet_ids = local.private_subnets
}

resource "aws_elasticache_replication_group" "ood" {
  count                      = var.enable_session_cache ? 1 : 0
  replication_group_id       = "ood-${var.environment}"
  description                = "OOD PUN session cache ${var.environment}"
  node_type                  = "cache.t3.micro"
  num_cache_clusters         = var.environment == "prod" ? 2 : 1
  parameter_group_name       = "default.redis7"
  engine_version             = "7.0"
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.ood[0].name
  security_group_ids         = [aws_security_group.elasticache[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth[0].result

  # M4: retain daily snapshots so session-cache nodes can be rebuilt with data
  snapshot_retention_limit = var.environment == "prod" ? 14 : 1
  snapshot_window          = "05:00-06:00"

  tags = {
    Name = "ood-session-cache-${var.environment}"
  }
}

resource "random_password" "redis_auth" {
  count   = var.enable_session_cache ? 1 : 0
  length  = 64 # ElastiCache supports up to 128 chars; 64 provides >380 bits of entropy
  special = true
  # M3: restrict to shell-safe special characters — exclude $ ` \ " ' ! * ? and others
  # that cause interpolation issues in bash heredocs and shell parameter expansion.
  # ElastiCache auth token allows printable ASCII 33–126 except space and @.
  override_special = "#%&*-_+=:,./"
}

# ---------------------------------------------------------------------------
# S3 — OOD file browser bucket (Level 6)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "ood_files" {
  count         = var.enable_s3_browser ? 1 : 0
  bucket_prefix = "ood-files-${var.environment}-"

  tags = {
    Name = "ood-files-${var.environment}"
  }

  lifecycle {
    prevent_destroy = true # H4: protect user data from accidental destroy
  }
}

resource "aws_s3_bucket_versioning" "ood_files" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ood_files" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_kms_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
    }
  }
}

resource "aws_s3_bucket_public_access_block" "ood_files" {
  count                   = var.enable_s3_browser ? 1 : 0
  bucket                  = aws_s3_bucket.ood_files[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 server access logging for the OOD files bucket (H1)
resource "aws_s3_bucket" "ood_files_logs" {
  count         = var.enable_s3_browser ? 1 : 0
  bucket_prefix = "ood-files-logs-${var.environment}-"
  tags          = { Name = "ood-files-logs-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "ood_files_logs" {
  count                   = var.enable_s3_browser ? 1 : 0
  bucket                  = aws_s3_bucket.ood_files_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ood_files_logs" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files_logs[0].id
  rule { object_ownership = "BucketOwnerPreferred" }
}

# H1: Encrypt the access-logs bucket — S3 server-access log delivery uses AES256 (SSE-KMS not supported)
resource "aws_s3_bucket_server_side_encryption_configuration" "ood_files_logs" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files_logs[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ood_files_logs" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files_logs[0].id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.environment == "prod" ? 365 : 90
    }
  }
}

resource "aws_s3_bucket_logging" "ood_files" {
  count         = var.enable_s3_browser ? 1 : 0
  bucket        = aws_s3_bucket.ood_files[0].id
  target_bucket = aws_s3_bucket.ood_files_logs[0].id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "ood_files" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files[0].id
  rule {
    id     = "transition-to-ia"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

# H1: Deny unencrypted uploads and non-TLS access to the OOD file browser bucket.
# SSE is configured as the default, but without this policy a client can explicitly
# override encryption or use HTTP, bypassing both controls.
resource "aws_s3_bucket_policy" "ood_files" {
  count  = var.enable_s3_browser ? 1 : 0
  bucket = aws_s3_bucket.ood_files[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.ood_files[0].arn,
          "${aws_s3_bucket.ood_files[0].arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # Deny uploads that explicitly opt out of server-side encryption.
        # Applies to all callers — the OOD app must not set x-amz-server-side-encryption: none.
        Sid       = "DenyUnencryptedUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.ood_files[0].arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-server-side-encryption" = "false"
          }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# SSM Parameter Store — runtime config for userdata.sh
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "ood_domain" {
  count = var.enable_parameter_store && var.domain_name != "" ? 1 : 0
  name  = "/ood/${var.environment}/domain_name"
  type  = "String"
  value = var.domain_name
}

resource "aws_ssm_parameter" "oidc_client_id" {
  count = var.enable_parameter_store && var.use_cognito ? 1 : 0
  name  = "/ood/${var.environment}/oidc_client_id"
  type  = "String"
  value = var.use_cognito ? aws_cognito_user_pool_client.ood[0].id : var.oidc_client_id
}

# OIDC client secret stored in Secrets Manager — NOT SSM — to reduce blast radius (H2).
# The secret ARN is stored in SSM as a non-sensitive pointer; userdata.sh fetches
# the secret value at runtime via secretsmanager:GetSecretValue.
resource "aws_secretsmanager_secret" "oidc_client_secret" {
  count                   = var.use_cognito ? 1 : 0
  name                    = "ood/${var.environment}/oidc-client-secret"
  recovery_window_in_days = var.environment == "prod" ? 30 : 7
  kms_key_id              = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null

  tags = { Name = "ood-oidc-secret-${var.environment}" }
}

resource "aws_secretsmanager_secret_version" "oidc_client_secret" {
  count         = var.use_cognito ? 1 : 0
  secret_id     = aws_secretsmanager_secret.oidc_client_secret[0].id
  secret_string = aws_cognito_user_pool_client.ood[0].client_secret
}

# H2: automatic rotation — requires a Lambda that regenerates the Cognito app client
# secret and updates the Secrets Manager value. Wire via oidc_secret_rotation_lambda_arn.
# Without a Lambda, ops must manually rotate every 90 days and update the secret version.
resource "aws_secretsmanager_secret_rotation" "oidc_client_secret" {
  count               = var.use_cognito && var.oidc_secret_rotation_lambda_arn != "" ? 1 : 0
  secret_id           = aws_secretsmanager_secret.oidc_client_secret[0].id
  rotation_lambda_arn = var.oidc_secret_rotation_lambda_arn

  rotation_rules {
    automatically_after_days = 90
  }

  lifecycle {
    # H2: prod deployments must have automatic rotation — manual rotation is error-prone
    # and a missed rotation causes all user logins to fail for the full rotation window.
    # Build a rotation Lambda and set oidc_secret_rotation_lambda_arn in prod.tfvars.
    # See docs/identity-guide.md for the rotation Lambda implementation.
    precondition {
      condition     = var.environment != "prod" || var.oidc_secret_rotation_lambda_arn != ""
      error_message = "Production deployments require oidc_secret_rotation_lambda_arn to enable automatic OIDC secret rotation. Manual rotation every 90 days is not acceptable for prod."
    }
  }
}

# SSM pointer to the Secrets Manager ARN (non-sensitive — just a name/ARN)
resource "aws_ssm_parameter" "oidc_client_secret_arn" {
  count = var.enable_parameter_store && var.use_cognito ? 1 : 0
  name  = "/ood/${var.environment}/oidc_client_secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.oidc_client_secret[0].arn
}

resource "aws_ssm_parameter" "oidc_issuer_url" {
  count = var.enable_parameter_store && var.use_cognito ? 1 : 0
  name  = "/ood/${var.environment}/oidc_issuer_url"
  type  = "String"
  value = var.use_cognito ? "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.ood[0].id}" : var.oidc_issuer_url
}

resource "aws_ssm_parameter" "efs_id" {
  count = var.enable_parameter_store && var.enable_efs ? 1 : 0
  name  = "/ood/${var.environment}/efs_id"
  type  = "String"
  value = aws_efs_file_system.home[0].id
}

resource "aws_ssm_parameter" "efs_access_point_id" {
  count = var.enable_parameter_store && var.enable_efs ? 1 : 0
  name  = "/ood/${var.environment}/efs_access_point_id"
  type  = "String"
  value = aws_efs_access_point.home[0].id
}

resource "aws_ssm_parameter" "dynamodb_uid_table" {
  count = var.enable_parameter_store && var.enable_dynamodb_uid ? 1 : 0
  name  = "/ood/${var.environment}/dynamodb_uid_table"
  type  = "String"
  value = aws_dynamodb_table.uid_map[0].name
}

# M5: split endpoint URL (non-secret) from auth token (secret) so the token
# never appears in SSM history for a plain String parameter
resource "aws_ssm_parameter" "redis_endpoint" {
  count = var.enable_parameter_store && var.enable_session_cache ? 1 : 0
  name  = "/ood/${var.environment}/redis_endpoint"
  type  = "String"
  value = "rediss://${aws_elasticache_replication_group.ood[0].primary_endpoint_address}:6379"
}

resource "aws_ssm_parameter" "redis_auth_token" {
  count  = var.enable_parameter_store && var.enable_session_cache ? 1 : 0
  name   = "/ood/${var.environment}/redis_auth_token"
  type   = "SecureString"
  value  = random_password.redis_auth[0].result
  key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
}

# ---------------------------------------------------------------------------
# Launch Template + ASG
# ---------------------------------------------------------------------------
resource "aws_launch_template" "ood" {
  name_prefix = "ood-${var.environment}-"

  image_id      = local.selected_ami
  instance_type = local.ec2_instance_type

  vpc_security_group_ids = [aws_security_group.ood.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ood.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = local.volume_size
      encrypted             = true
      kms_key_id            = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
      delete_on_termination = true
    }
  }

  dynamic "instance_market_options" {
    for_each = local.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price          = var.spot_max_price != "" ? var.spot_max_price : null
        spot_instance_type = "one-time"
      }
    }
  }

  user_data = base64encode(join("\n", [
    "#!/usr/bin/env bash",
    "export OOD_ENVIRONMENT='${var.environment}'",
    "export OOD_ENABLE_PARAMETER_STORE='${tostring(var.enable_parameter_store)}'",
    "export OOD_ENABLE_MONITORING='${tostring(var.enable_monitoring)}'",
    "export OOD_ENABLE_EFS='${tostring(var.enable_efs)}'",
    "export OOD_EFS_ID='${var.enable_efs ? aws_efs_file_system.home[0].id : ""}'",
    "export OOD_EFS_ACCESS_POINT_ID='${var.enable_efs ? aws_efs_access_point.home[0].id : ""}'",
    "export OOD_ENABLE_FSX='${tostring(var.enable_fsx)}'",
    "export OOD_FSX_DNS_NAME='${var.enable_fsx ? aws_fsx_lustre_file_system.scratch[0].dns_name : ""}'",
    "export OOD_FSX_MOUNT_NAME='${var.enable_fsx ? aws_fsx_lustre_file_system.scratch[0].mount_name : ""}'",
    "export OOD_ENABLE_SESSION_CACHE='${tostring(var.enable_session_cache)}'",
    "export OOD_ENABLE_S3_BROWSER='${tostring(var.enable_s3_browser)}'",
    "export OOD_S3_BROWSER_BUCKET='${var.enable_s3_browser ? aws_s3_bucket.ood_files[0].id : ""}'",
    "export OOD_ENABLE_ALB='${tostring(var.enable_alb)}'",
    "export OOD_ADAPTERS_ENABLED='${jsonencode(var.adapters_enabled)}'",
    "export OOD_LOG_GROUP_PREFIX='/aws/ec2/ood-${var.environment}'",
    "export OOD_DOMAIN='${var.domain_name}'",
    file("${path.module}/../scripts/userdata.sh")
  ]))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ood-${var.environment}"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "ood-${var.environment}"
    }
  }

  lifecycle {
    precondition {
      condition     = local.spot_prereqs_met
      error_message = "spot profile requires enable_efs=true, enable_dynamodb_uid=true, and use_cognito=true."
    }
  }
}

resource "aws_autoscaling_group" "ood" {
  name_prefix = "ood-${var.environment}-"

  vpc_zone_identifier = [var.subnet_id]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.ood.id
    version = "$Latest"
  }

  health_check_type         = var.enable_alb ? "ELB" : "EC2"
  health_check_grace_period = 300
  default_instance_warmup   = 120 # L4: allow metrics to stabilize before scale decisions

  tag {
    key                 = "Name"
    value               = "ood-${var.environment}"
    propagate_at_launch = true
  }
  tag {
    key                 = "Patch Group"
    value               = "ood-${var.environment}"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------------------
# EBS Snapshot Lifecycle (DLM)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "dlm" {
  name_prefix = "ood-dlm-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ood" {
  description        = "OOD ${var.environment} EBS snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "Daily snapshots"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }
      retain_rule {
        count = var.environment == "prod" ? 14 : 3
      }
      tags_to_add = {
        SnapshotCreator = "DLM"
      }
      copy_tags = true
    }

    target_tags = {
      "Patch Group" = "ood-${var.environment}"
    }
  }
}

# ---------------------------------------------------------------------------
# ALB access logging bucket (M6)
# ---------------------------------------------------------------------------
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  count         = var.enable_alb ? 1 : 0
  bucket_prefix = "ood-alb-logs-${var.environment}-"
  tags          = { Name = "ood-alb-logs-${var.environment}" }

  lifecycle {
    prevent_destroy = true # H5: preserve audit logs from accidental destroy
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count                   = var.enable_alb ? 1 : 0
  bucket                  = aws_s3_bucket.alb_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  count  = var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id
  rule {
    # H5: upgrade to CMK when available; ALB requires SSE-S3 (not SSE-KMS) for log delivery
    # so we use AES256 here regardless — ALB logs are delivered by the ELB service account
    # and SSE-KMS requires the ELB service to have kms:GenerateDataKey, which is not supported.
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  count  = var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id
  versioning_configuration {
    status = "Enabled" # H5: versioning detects log tampering
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  count  = var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id
  rule {
    id     = "expire-alb-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.environment == "prod" ? 365 : 90 # L4: prevent unbounded growth
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  count  = var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowELBLogs"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.main.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs[0].arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        # H4: Prevent any principal (including account root) from disabling versioning.
        # Versioning must remain enabled to detect log deletion or tampering.
        Sid       = "DenyVersioningDisable"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutBucketVersioning"
        Resource  = aws_s3_bucket.alb_logs[0].arn
        Condition = {
          StringEquals = { "s3:VersionStatus" = "Suspended" }
        }
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.alb_logs[0].arn,
          "${aws_s3_bucket.alb_logs[0].arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# ALB + ACM (optional)
# ---------------------------------------------------------------------------
resource "aws_lb" "ood" {
  count              = var.enable_alb ? 1 : 0
  name_prefix        = "ood-"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = local.alb_subnets

  enable_deletion_protection = var.environment != "test"

  access_logs {
    bucket  = aws_s3_bucket.alb_logs[0].bucket
    prefix  = "alb-logs"
    enabled = true
  }

  tags = {
    Name = "ood-${var.environment}"
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  lifecycle {
    # C1: staging and prod require multi-AZ ALB subnets to survive an AZ outage.
    # Set alb_subnet_ids to subnets in at least 2 different AZs in staging/prod.tfvars.
    precondition {
      condition     = var.environment == "test" || length(local.alb_subnets) >= 2
      error_message = "ALB requires at least 2 subnets in different AZs for staging and prod deployments. Set alb_subnet_ids in your tfvars."
    }
  }
}

resource "aws_lb_target_group" "ood" {
  count       = var.enable_alb ? 1 : 0
  name_prefix = "ood-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.selected.id

  health_check {
    path                = "/pun/sys/dashboard"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
  }
}

resource "aws_autoscaling_attachment" "ood" {
  count                  = var.enable_alb ? 1 : 0
  autoscaling_group_name = aws_autoscaling_group.ood.id
  lb_target_group_arn    = aws_lb_target_group.ood[0].arn
}

resource "aws_acm_certificate" "ood" {
  count             = var.enable_alb && var.acm_certificate_arn == "" && var.domain_name != "" ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  alb_cert_arn = (
    var.acm_certificate_arn != "" ? var.acm_certificate_arn :
    var.domain_name != "" && var.enable_alb ? try(aws_acm_certificate.ood[0].arn, "") :
    ""
  )
}

resource "aws_lb_listener" "http" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.ood[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_alb && local.alb_cert_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.ood[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.alb_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ood[0].arn
  }
}

# ---------------------------------------------------------------------------
# WAF v2 (optional, requires ALB)
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "ood" {
  count = var.enable_waf && var.enable_alb ? 1 : 0
  name  = "ood-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimit"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  # M2: block IPs on the AWS threat intelligence list before all other rules
  rule {
    name     = "IpReputationList"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "CommonRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "KnownBadInputs"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "SQLiProtection"
    priority = 4
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiProtection"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "ood-${var.environment}"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "ood-waf-${var.environment}"
  }
}

resource "aws_wafv2_web_acl_association" "ood" {
  count        = var.enable_waf && var.enable_alb ? 1 : 0
  resource_arn = aws_lb.ood[0].arn
  web_acl_arn  = aws_wafv2_web_acl.ood[0].arn
}

# ---------------------------------------------------------------------------
# VPC Endpoints (optional)
# ---------------------------------------------------------------------------
data "aws_route_table" "portal_subnet" {
  count     = var.enable_vpc_endpoints ? 1 : 0
  subnet_id = var.subnet_id
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_vpc_endpoints ? 1 : 0
  vpc_id            = data.aws_vpc.selected.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.portal_subnet[0].id]

  tags = { Name = "ood-s3-endpoint-${var.environment}" }
}

resource "aws_security_group" "vpc_endpoints" {
  count       = var.enable_vpc_endpoints ? 1 : 0
  name_prefix = "ood-vpce-${var.environment}-"
  description = "OOD VPC interface endpoints ${var.environment}"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "HTTPS from OOD instance"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ood.id]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "ood_to_vpce" {
  count                        = var.enable_vpc_endpoints ? 1 : 0
  security_group_id            = aws_security_group.ood.id
  referenced_security_group_id = aws_security_group.vpc_endpoints[0].id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS to VPC endpoints"
}

locals {
  interface_endpoints = var.enable_vpc_endpoints ? [
    "ssm", "ssmmessages", "ec2messages", "secretsmanager", "logs"
  ] : []
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "ood-${each.key}-endpoint-${var.environment}" }
}

# ---------------------------------------------------------------------------
# CloudFront (optional)
# ---------------------------------------------------------------------------

# M1: S3 bucket for CloudFront access logs
resource "aws_s3_bucket" "cdn_logs" {
  count         = var.enable_cdn && var.enable_alb ? 1 : 0
  bucket_prefix = "ood-cdn-logs-${var.environment}-"
  tags          = { Name = "ood-cdn-logs-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "cdn_logs" {
  count                   = var.enable_cdn && var.enable_alb ? 1 : 0
  bucket                  = aws_s3_bucket.cdn_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cdn_logs" {
  count  = var.enable_cdn && var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.cdn_logs[0].id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cdn_logs" {
  count  = var.enable_cdn && var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.cdn_logs[0].id
  rule {
    # M1: CloudFront log delivery uses the CloudFront service account — SSE-KMS is not supported,
    # so AES256 is required regardless of CMK setting.
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cdn_logs" {
  count  = var.enable_cdn && var.enable_alb ? 1 : 0
  bucket = aws_s3_bucket.cdn_logs[0].id
  rule {
    id     = "expire-cdn-logs"
    status = "Enabled"
    filter {}
    expiration { days = var.environment == "prod" ? 365 : 90 }
  }
}

resource "aws_cloudfront_distribution" "ood" {
  count = var.enable_cdn && var.enable_alb ? 1 : 0

  origin {
    domain_name = aws_lb.ood[0].dns_name
    origin_id   = "alb-${var.environment}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "OOD ${var.environment} CDN"
  default_root_object = ""

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-${var.environment}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization", "Origin"]
      cookies { forward = "all" }
    }

    # OOD interactive sessions — don't cache
    default_ttl = 0
    max_ttl     = 0
    min_ttl     = 0
  }

  # Static assets: cache for 1 day
  ordered_cache_behavior {
    path_pattern           = "/public/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-${var.environment}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    default_ttl = 86400
    max_ttl     = 86400
    min_ttl     = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # M1: enable CDN access logging
  logging_config {
    bucket          = aws_s3_bucket.cdn_logs[0].bucket_domain_name
    prefix          = "cdn-logs/"
    include_cookies = false
  }

  viewer_certificate {
    cloudfront_default_certificate = local.alb_cert_arn == ""
    acm_certificate_arn            = local.alb_cert_arn != "" ? local.alb_cert_arn : null
    ssl_support_method             = local.alb_cert_arn != "" ? "sni-only" : null
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = {
    Name = "ood-cdn-${var.environment}"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch — log groups, dashboard, alarms
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "bootstrap" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/ood-${var.environment}/bootstrap"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null # M4
}

resource "aws_cloudwatch_log_group" "nginx_access" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/ood-${var.environment}/nginx-access"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null # M4
}

resource "aws_cloudwatch_log_group" "nginx_error" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/ood-${var.environment}/nginx-error"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null # M4
}

resource "aws_cloudwatch_log_group" "passenger" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ec2/ood-${var.environment}/passenger"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null # M4
}

resource "aws_sns_topic" "ood" {
  count = var.enable_monitoring ? 1 : 0
  name  = "ood-alarms-${var.environment}"
  # C1: Always encrypt SNS — use CMK when available, fall back to AWS-managed SNS key (never unencrypted)
  kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.enable_monitoring && var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.ood[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# L7: SQS dead-letter queue captures alarm notifications if delivery fails.
# Alarms published to SNS are also forwarded here, so they are never silently lost.
resource "aws_sqs_queue" "alarm_dlq" {
  count                      = var.enable_monitoring ? 1 : 0
  name                       = "ood-alarm-dlq-${var.environment}"
  message_retention_seconds  = 1209600 # 14 days — long enough for on-call rotation to review
  visibility_timeout_seconds = 30      # standard for consumer-less audit queues
  kms_master_key_id          = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : "alias/aws/sqs"

  tags = { Name = "ood-alarm-dlq-${var.environment}" }
}

# M3: alarm fires if messages accumulate in the DLQ — means SNS→SQS delivery worked
# but the intended consumers (operators) have not drained the queue.
resource "aws_cloudwatch_metric_alarm" "alarm_dlq_depth" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "ood-${var.environment}-alarm-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "OOD ${var.environment} alarm DLQ has unread messages — review CloudWatch alarm delivery failures"
  alarm_actions       = [aws_sns_topic.ood[0].arn]
  treat_missing_data  = "notBreaching" # empty queue = healthy
  dimensions = {
    QueueName = aws_sqs_queue.alarm_dlq[0].name
  }
}

resource "aws_sqs_queue_policy" "alarm_dlq" {
  count     = var.enable_monitoring ? 1 : 0
  queue_url = aws_sqs_queue.alarm_dlq[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.alarm_dlq[0].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.ood[0].arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "sqs_dlq" {
  count     = var.enable_monitoring ? 1 : 0
  topic_arn = aws_sns_topic.ood[0].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.alarm_dlq[0].arn
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "ood-${var.environment}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.environment == "prod" ? 3 : 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = var.environment == "prod" ? 60 : 300
  statistic           = "Average"
  threshold           = var.environment == "prod" ? 70 : 80
  alarm_description   = "OOD ${var.environment} CPU > threshold"
  alarm_actions       = [aws_sns_topic.ood[0].arn]
  treat_missing_data  = "breaching" # M7: missing data = instance not publishing = alarm fires
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.ood.name
  }
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "ood-${var.environment}-instance-status"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "OOD ${var.environment} instance status check failed"
  alarm_actions       = [aws_sns_topic.ood[0].arn]
  treat_missing_data  = "breaching"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.ood.name
  }
}

# M7: Disk and memory alarms using CWAgent custom metrics (CWAgent must be running on the instance)
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "ood-${var.environment}-disk-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = var.environment == "prod" ? 80 : 90
  alarm_description   = "OOD ${var.environment} root disk usage > threshold — portal may run out of space"
  alarm_actions       = [aws_sns_topic.ood[0].arn]
  treat_missing_data  = "breaching"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.ood.name
    path                 = "/"
    fstype               = "xfs"
  }
}

resource "aws_cloudwatch_metric_alarm" "mem_high" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "ood-${var.environment}-mem-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = var.environment == "prod" ? 80 : 90
  alarm_description   = "OOD ${var.environment} memory usage > threshold — Passenger workers may OOM"
  alarm_actions       = [aws_sns_topic.ood[0].arn]
  treat_missing_data  = "breaching"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.ood.name
  }
}

resource "aws_cloudwatch_dashboard" "ood" {
  count          = var.enable_monitoring ? 1 : 0
  dashboard_name = "ood-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "CPU Utilization"
          period = 300
          stat   = "Average"
          metrics = [[
            "AWS/EC2", "CPUUtilization",
            "AutoScalingGroupName", aws_autoscaling_group.ood.name
          ]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "EFS Client Connections"
          period = 300
          stat   = "Average"
          metrics = var.enable_efs ? [[
            "AWS/EFS", "ClientConnections",
            "FileSystemId", aws_efs_file_system.home[0].id
          ]] : []
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# SSM Session Manager — audit logging
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ssm_sessions" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/ssm/ood-${var.environment}/sessions"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null

  tags = { Name = "ood-ssm-sessions-${var.environment}" }
}

# M6: S3 bucket for SSM session transcript dual-destination logging
resource "aws_s3_bucket" "ssm_sessions" {
  count         = var.enable_monitoring ? 1 : 0
  bucket_prefix = "ood-ssm-sessions-${var.environment}-"
  tags          = { Name = "ood-ssm-sessions-${var.environment}" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "ssm_sessions" {
  count                   = var.enable_monitoring ? 1 : 0
  bucket                  = aws_s3_bucket.ssm_sessions[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm_sessions" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = aws_s3_bucket.ssm_sessions[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_kms_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ssm_sessions" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = aws_s3_bucket.ssm_sessions[0].id
  rule {
    id     = "expire-sessions"
    status = "Enabled"
    filter {}
    expiration {
      days = var.environment == "prod" ? 365 : 90
    }
  }
}

# M6: Restrict SSM session transcript writes to the OOD instance role only.
# This prevents other principals in the account from writing arbitrary data into the audit trail.
resource "aws_s3_bucket_policy" "ssm_sessions" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = aws_s3_bucket.ssm_sessions[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonInstanceWrites"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:PutObject"]
        Resource  = "${aws_s3_bucket.ssm_sessions[0].arn}/*"
        Condition = {
          ArnNotEquals = {
            "aws:PrincipalArn" = [
              aws_iam_role.ood.arn,
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
            ]
          }
        }
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.ssm_sessions[0].arn,
          "${aws_s3_bucket.ssm_sessions[0].arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_ssm_document" "session_manager_prefs" {
  count         = var.enable_monitoring ? 1 : 0
  name          = "SSM-SessionManagerRunShell-ood-${var.environment}"
  document_type = "Session"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "OOD ${var.environment} SSM session preferences — dual logging to CloudWatch + S3"
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.ssm_sessions[0].name
      cloudWatchEncryptionEnabled = var.enable_kms_cmk
      cloudWatchStreamingEnabled  = true
      s3BucketName                = aws_s3_bucket.ssm_sessions[0].id # M6
      s3KeyPrefix                 = "sessions/"
      s3EncryptionEnabled         = true
    }
  })

  tags = { Name = "ood-session-prefs-${var.environment}" }
}

# ---------------------------------------------------------------------------
# AWS Batch (conditional on adapters_enabled containing "batch")
# ---------------------------------------------------------------------------
resource "aws_iam_role" "batch_service" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-batch-service-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "batch.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  count      = local.enable_batch ? 1 : 0
  role       = aws_iam_role.batch_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_iam_role" "batch_job" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-batch-job-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_job_ecs" {
  count      = local.enable_batch ? 1 : 0
  role       = aws_iam_role.batch_job[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_batch_compute_environment" "ood" {
  count                    = local.enable_batch ? 1 : 0
  compute_environment_name = "ood-${var.environment}"
  type                     = "MANAGED"
  service_role             = aws_iam_role.batch_service[0].arn

  compute_resources {
    type                = "SPOT"
    bid_percentage      = 60
    min_vcpus           = 0
    max_vcpus           = 256
    instance_role       = aws_iam_instance_profile.ood.arn
    instance_type       = ["optimal"]
    subnets             = local.private_subnets
    security_group_ids  = [aws_security_group.ood.id]
    spot_iam_fleet_role = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/AmazonEC2SpotFleetRole"
  }

  lifecycle {
    ignore_changes = [compute_resources[0].desired_vcpus]
  }
}

resource "aws_batch_job_queue" "ood" {
  count    = local.enable_batch ? 1 : 0
  name     = "ood-${var.environment}"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.ood[0].arn
  }
}

# ---------------------------------------------------------------------------
# SageMaker Domain (conditional on adapters_enabled containing "sagemaker")
# ---------------------------------------------------------------------------
resource "aws_iam_role" "sagemaker_execution" {
  count       = local.enable_sagemaker ? 1 : 0
  name_prefix = "ood-sagemaker-exec-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Scoped SageMaker execution policy — replaces AmazonSageMakerFullAccess (H2)
resource "aws_iam_role_policy" "sagemaker_execution_scoped" {
  count       = local.enable_sagemaker ? 1 : 0
  name_prefix = "ood-sagemaker-exec-scoped-"
  role        = aws_iam_role.sagemaker_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateApp",
          "sagemaker:DeleteApp",
          "sagemaker:CreatePresignedDomainUrl",
          "sagemaker:DescribeApp",
          "sagemaker:ListApps",
        ]
        Resource = [
          aws_sagemaker_domain.ood[0].arn,
          "${aws_sagemaker_domain.ood[0].arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sagemaker:DescribeDomain", "sagemaker:ListDomains"]
        Resource = "*"
      },
      {
        # SageMaker needs S3 access for model artifacts and notebook data
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::sagemaker-${var.aws_region}-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::sagemaker-${var.aws_region}-${data.aws_caller_identity.current.account_id}/*",
        ]
      },
    ]
  })
}

resource "aws_sagemaker_domain" "ood" {
  count       = local.enable_sagemaker ? 1 : 0
  domain_name = "ood-${var.environment}"
  auth_mode   = "IAM"
  vpc_id      = data.aws_vpc.selected.id
  subnet_ids  = local.private_subnets

  default_user_settings {
    execution_role = aws_iam_role.sagemaker_execution[0].arn
  }

  tags = {
    Name = "ood-sagemaker-${var.environment}"
  }
}

resource "aws_sagemaker_user_profile" "ood_default" {
  count             = local.enable_sagemaker ? 1 : 0
  domain_id         = aws_sagemaker_domain.ood[0].id
  user_profile_name = "ood-default"

  user_settings {
    execution_role = aws_iam_role.sagemaker_execution[0].arn
  }
}

# ---------------------------------------------------------------------------
# Compliance (optional)
# ---------------------------------------------------------------------------
resource "aws_flow_log" "ood" {
  count           = var.enable_compliance_logging ? 1 : 0
  iam_role_arn    = aws_iam_role.flow_log[0].arn
  log_destination = aws_cloudwatch_log_group.flow_log[0].arn
  traffic_type    = "ALL"
  vpc_id          = data.aws_vpc.selected.id
}

# S3 flow log destination for long-term retention and Athena queries (H5)
resource "aws_s3_bucket" "flow_logs" {
  count         = var.enable_compliance_logging ? 1 : 0
  bucket_prefix = "ood-flow-logs-${var.environment}-"
  tags          = { Name = "ood-flow-logs-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count                   = var.enable_compliance_logging ? 1 : 0
  bucket                  = aws_s3_bucket.flow_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  count  = var.enable_compliance_logging ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_kms_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count  = var.enable_compliance_logging ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id
  rule {
    id     = "expire-flow-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.environment == "prod" ? 365 : 90
    }
  }
}

resource "aws_flow_log" "ood_s3" {
  count                = var.enable_compliance_logging ? 1 : 0
  log_destination      = "${aws_s3_bucket.flow_logs[0].arn}/vpc-flow-logs/"
  log_destination_type = "s3"
  traffic_type         = "ALL"
  vpc_id               = data.aws_vpc.selected.id
}

resource "aws_cloudwatch_log_group" "flow_log" {
  count             = var.enable_compliance_logging ? 1 : 0
  name              = "/aws/vpc/ood-${var.environment}/flow-logs"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
}

resource "aws_iam_role" "flow_log" {
  count       = var.enable_compliance_logging ? 1 : 0
  name_prefix = "ood-flow-log-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  count       = var.enable_compliance_logging ? 1 : 0
  name_prefix = "ood-flow-log-"
  role        = aws_iam_role.flow_log[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      # Scoped to the OOD flow log group only (H3)
      Resource = [
        aws_cloudwatch_log_group.flow_log[0].arn,
        "${aws_cloudwatch_log_group.flow_log[0].arn}:*",
      ]
    }]
  })
}

resource "aws_cloudtrail" "ood" {
  count                         = var.enable_compliance_logging ? 1 : 0
  name                          = "ood-${var.environment}"
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true # Always multi-region — cross-region calls invisible otherwise (H3)
  enable_log_file_validation    = true

  # M3: audit S3 object access and Lambda invocations (adapter functions)
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"] # All S3 objects — narrow to specific buckets if cost is a concern
    }

    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"] # All Lambda functions in this account/region
    }
  }

  tags = {
    Name = "ood-trail-${var.environment}"
  }

  lifecycle {
    # H3: multi-region trail is always enabled above; this precondition prevents future edits
    # from silently disabling it and creating a gap in cross-region audit coverage.
    precondition {
      condition     = var.environment != "prod" || var.enable_compliance_logging
      error_message = "enable_compliance_logging must be true for prod deployments."
    }
  }
}

resource "aws_s3_bucket" "cloudtrail" {
  count         = var.enable_compliance_logging ? 1 : 0
  bucket_prefix = "ood-cloudtrail-${var.environment}-"

  tags = { Name = "ood-cloudtrail-${var.environment}" }

  lifecycle {
    prevent_destroy = true # M2: preserve compliance audit trail from accidental destroy
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = var.enable_compliance_logging ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_kms_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
    }
    bucket_key_enabled = var.enable_kms_cmk
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  count  = var.enable_compliance_logging ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# CloudTrail bucket public access block (M1)
resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = var.enable_compliance_logging ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudTrail bucket access logging (M2) — audit trail for the audit trail
resource "aws_s3_bucket" "cloudtrail_logs" {
  count         = var.enable_compliance_logging ? 1 : 0
  bucket_prefix = "ood-cloudtrail-logs-${var.environment}-"
  tags          = { Name = "ood-cloudtrail-logs-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  count                   = var.enable_compliance_logging ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail_logs" {
  count  = var.enable_compliance_logging ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_logs[0].id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_logging" "cloudtrail" {
  count         = var.enable_compliance_logging ? 1 : 0
  bucket        = aws_s3_bucket.cloudtrail[0].id
  target_bucket = aws_s3_bucket.cloudtrail_logs[0].id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.enable_compliance_logging ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail[0].arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# AWS Backup (optional)
# ---------------------------------------------------------------------------
resource "aws_backup_vault" "ood" {
  count       = var.enable_backup ? 1 : 0
  name        = "ood-${var.environment}"
  kms_key_arn = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null

  tags = { Name = "ood-backup-${var.environment}" }

  lifecycle {
    # M10: prod deployments require backups — EFS home dirs and DynamoDB UID map are irreplaceable.
    # Set enable_backup=true in prod.tfvars to satisfy this precondition.
    precondition {
      condition     = var.environment != "prod" || var.enable_backup
      error_message = "enable_backup must be true for prod deployments to protect EFS and DynamoDB data."
    }
  }
}

resource "aws_iam_role" "backup" {
  count       = var.enable_backup ? 1 : 0
  name_prefix = "ood-backup-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.enable_backup ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# M9: When CMK is enabled, AWS Backup needs explicit kms grants to encrypt/decrypt backup data.
# The KMS key policy already has BackupEncryption statement; this inline policy lets the role use it.
resource "aws_iam_role_policy" "backup_kms" {
  count = var.enable_backup && var.enable_kms_cmk ? 1 : 0
  name  = "backup-kms-access"
  role  = aws_iam_role.backup[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
        "kms:CreateGrant",
      ]
      Resource = aws_kms_key.ood[0].arn
    }]
  })
}

resource "aws_backup_plan" "ood" {
  count = var.enable_backup ? 1 : 0
  name  = "ood-${var.environment}"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.ood[0].name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.environment == "prod" ? 90 : 30
    }
  }
}

resource "aws_backup_selection" "ood" {
  # M9: include S3 browser bucket alongside EFS + DynamoDB
  count        = var.enable_backup && (var.enable_efs || var.enable_dynamodb_uid || var.enable_s3_browser) ? 1 : 0
  iam_role_arn = aws_iam_role.backup[0].arn
  name         = "ood-${var.environment}"
  plan_id      = aws_backup_plan.ood[0].id

  resources = concat(
    var.enable_efs ? [aws_efs_file_system.home[0].arn] : [],
    var.enable_dynamodb_uid ? [aws_dynamodb_table.uid_map[0].arn] : [],
    var.enable_s3_browser ? [aws_s3_bucket.ood_files[0].arn] : [],
  )
}

# ---------------------------------------------------------------------------
# KMS CMK (optional)
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "ood" {
  count                   = var.enable_kms_cmk ? 1 : 0
  description             = "OOD ${var.environment} CMK"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Root can manage the key (IAM delegation, grants, policy updates) but not use it for data operations (M4)
        Sid    = "RootKeyAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Create*",
          "kms:Describe*",
          "kms:Enable*",
          "kms:List*",
          "kms:Put*",
          "kms:Update*",
          "kms:Revoke*",
          "kms:Disable*",
          "kms:Get*",
          "kms:Delete*",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:CreateGrant",
          "kms:RetireGrant",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Access"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ood.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        # M4: CloudWatch Logs service principal must be explicitly granted — without this,
        # log group encryption silently fails even when kms_key_id is set on the log group.
        Sid    = "CloudWatchLogsEncryption"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
      {
        # SNS service principal required for encrypted SNS topics
        Sid    = "SNSEncryption"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
        ]
        Resource = "*"
      },
      {
        # Backup service principal required when enable_backup=true and enable_kms_cmk=true
        Sid    = "BackupEncryption"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = { Name = "ood-cmk-${var.environment}" }

  lifecycle {
    # M2: prod deployments should use CMK so all encrypted resources (EFS, DynamoDB, S3, SNS,
    # CloudWatch Logs) are under customer control rather than AWS-managed keys.
    # Set enable_kms_cmk=true in prod.tfvars to satisfy this.
    precondition {
      condition     = var.environment != "prod" || var.enable_kms_cmk
      error_message = "Production deployments require enable_kms_cmk=true for full customer control of encryption keys."
    }
  }
}

resource "aws_kms_alias" "ood" {
  count         = var.enable_kms_cmk ? 1 : 0
  name          = "alias/ood-${var.environment}"
  target_key_id = aws_kms_key.ood[0].key_id
}
