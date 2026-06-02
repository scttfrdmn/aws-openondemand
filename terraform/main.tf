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

  # ALB subnets — an ALB always requires >=2 subnets in different AZs (#33), so operators
  # must set alb_subnet_ids when enable_alb=true. The fallback to the single subnet_id only
  # exists so non-ALB deploys evaluate cleanly; the aws_lb precondition rejects a <2-AZ ALB.
  alb_subnets = length(var.alb_subnet_ids) > 0 ? var.alb_subnet_ids : [var.subnet_id]

  # Adapter flags
  enable_batch              = contains(var.adapters_enabled, "batch")
  enable_sagemaker          = contains(var.adapters_enabled, "sagemaker")
  enable_ec2_adapter        = contains(var.adapters_enabled, "ec2")
  enable_omics              = contains(var.adapters_enabled, "omics")
  enable_emr                = contains(var.adapters_enabled, "emr")
  enable_sagemaker_training = contains(var.adapters_enabled, "sagemaker-training")
  enable_fargate            = contains(var.adapters_enabled, "fargate")
  enable_stepfunctions      = contains(var.adapters_enabled, "stepfunctions")
  enable_braket             = contains(var.adapters_enabled, "braket")
  enable_bedrock            = contains(var.adapters_enabled, "bedrock")

  # #79: deletion protection is on only in prod. Terraform's lifecycle.prevent_destroy must
  # be a literal (can't read a var), and using it blocked `terraform destroy` of a test env
  # entirely (all-or-nothing) — forcing manual `state rm` and risking orphaned billing
  # resources. So instead of prevent_destroy we use AWS-native, expression-driven protection
  # (Cognito deletion_protection, DynamoDB deletion_protection_enabled) and env-aware
  # S3 force_destroy, all keyed on this flag. prod stays protected; non-prod tears down clean.
  prod_protected = var.environment == "prod"

  # #78: directory-backed identity (AWS Directory Service + SSSD). enable_directory provisions
  # the managed AD; use_sssd configures NSS/SSSD on the OOD host. The LDAP URI SSSD reads is
  # either the operator-supplied directory_ldap_uri (on-prem AD/LDAP) or, when enable_directory
  # and no override is given, the provisioned AWS Directory Service DNS endpoint. Keeps the
  # directory host swappable (prototype managed-AD <-> on-prem AD) with no code change.
  directory_ldap_uri = var.directory_ldap_uri != "" ? var.directory_ldap_uri : (
    var.enable_directory ? "ldaps://${var.directory_name}" : ""
  )

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

  # Outbound HTTPS/HTTP/DNS to the internet is required: OS package repos, AWS
  # service APIs (when not using VPC endpoints), OOD/oidc-pam release downloads,
  # and OIDC/Cognito. Inbound is the controlled surface (allowed_cidr); egress to
  # 0.0.0.0/0 on these ports is normal.
  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }
  egress {
    description = "HTTP outbound (package repos)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }
  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
  }
  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr
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
# False positive for aws-iam-no-policy-wildcards: the wildcard is on the OBJECT KEY
# (sessions/*) within a single named bucket ARN, not the resource. No broad s3:* on *.
#tfsec:ignore:aws-iam-no-policy-wildcards
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

# Read access to the bootstrap artifact bucket so the launch-template stub can
# fetch userdata.sh / bake.sh at boot (#16). Scoped to this bucket only. The CMK
# decrypt grant (when enable_kms_cmk) is already covered by the EC2Access
# statement on aws_kms_key.ood, so no extra KMS policy is needed here.
resource "aws_iam_role_policy" "artifacts_read" {
  name_prefix = "ood-artifacts-read-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*",
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
        # N3: ec2:Vpc condition restricts subnet and security-group resources to the OOD
        # VPC, preventing the EC2 adapter from launching instances into uncontrolled VPCs
        # or attaching security groups from other networks in the same account.
        Effect = "Allow"
        Action = ["ec2:RunInstances"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*",
        ]
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
          ArnLike      = { "ec2:Vpc" = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc/${data.aws_vpc.selected.id}" }
        }
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
      },
      {
        # H4: Belt-and-suspenders Deny for cross-account AMI launches.
        # The Allow statement above requires ec2:Owner = this account, but an explicit
        # Deny ensures a permissive policy elsewhere cannot override the Allow condition.
        Effect = "Deny"
        Action = ["ec2:RunInstances"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}::image/*",
        ]
        Condition = {
          StringNotEquals = {
            "ec2:Owner" = data.aws_caller_identity.current.account_id
          }
        }
      },
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

  # H2: TOTP MFA — OPTIONAL during rollout so existing users are not locked out.
  # Set cognito_mfa_required=true in prod.tfvars once all users have enrolled.
  # A lifecycle precondition below warns operators that prod should enforce MFA.
  mfa_configuration = var.cognito_mfa_required ? "ON" : "OPTIONAL"
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

  # #79: native deletion protection in prod only (replaces lifecycle.prevent_destroy, which
  # couldn't be env-aware and blocked test teardown). prod = ACTIVE, non-prod = INACTIVE.
  deletion_protection = local.prod_protected ? "ACTIVE" : "INACTIVE"

  lifecycle {
    # H2: production portals must enforce MFA — a compromised password alone would grant
    # full portal access including compute submission and EFS home directory reads.
    # Set cognito_mfa_required=true in prod.tfvars after users have enrolled TOTP.
    precondition {
      condition     = var.environment != "prod" || var.cognito_mfa_required
      error_message = "Production Cognito deployments require cognito_mfa_required=true. Set this in prod.tfvars after users complete TOTP enrollment to enforce MFA for all logins."
    }
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

  # A stable HTTPS callback is required for the OIDC code flow. The precondition
  # below guarantees either a domain or an ALB exists, so these branches always
  # resolve to a real, reachable host (no localhost fallback — see #25).
  #
  # #60: the path is `/oidc`, NOT `/oidc/callback`. OOD's ood_portal.yml sets
  # `oidc_uri: /oidc`, so mod_auth_openidc's OIDCRedirectURI — the redirect_uri it sends to
  # Cognito — is `/oidc`. The registered callback must match that exact path or Cognito
  # rejects the round-trip after the user authenticates.
  callback_urls = var.domain_name != "" ? [
    "https://${var.domain_name}/oidc"
    ] : [
    "https://${aws_lb.ood[0].dns_name}/oidc"
  ]

  logout_urls = var.domain_name != "" ? [
    "https://${var.domain_name}"
    ] : [
    "https://${aws_lb.ood[0].dns_name}"
  ]

  supported_identity_providers = var.cognito_saml_metadata_url != "" ? [
    "COGNITO",
    aws_cognito_identity_provider.saml[0].provider_name,
    ] : [
    "COGNITO"
  ]

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  lifecycle {
    # #25: a no-ALB, no-domain deployment has no stable HTTPS endpoint to serve as
    # the OIDC redirect target — the portal would come up with no working browser
    # login. An ephemeral instance public IP is not viable (changes on every
    # replacement, no TLS cert). Fail fast at plan with actionable guidance rather
    # than producing a portal nobody can log into.
    precondition {
      condition     = !(var.use_cognito && !var.enable_alb && var.domain_name == "")
      error_message = "Cognito browser auth requires a stable HTTPS callback URL. Set enable_alb=true, or provide domain_name. A no-ALB, no-domain deployment has no working portal login (the instance public IP cannot serve as a reliable OIDC redirect target)."
    }
  }
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
  # #39: keyed on `username` (the cognito:username claim — see #64). The account-provisioning
  # PAM hook (pam_exec → ood-provision-user) only receives PAM_USER, not the OIDC sub,
  # so username is the lookup key. Rows are {username, uid}; a "__uid_counter__" sentinel
  # item holds the next_uid for atomic allocation.
  hash_key = "username"

  # #79: native deletion protection in prod only (replaces lifecycle.prevent_destroy, which
  # couldn't be env-aware and blocked test teardown). PITR still recovers rows if needed.
  deletion_protection_enabled = local.prod_protected

  attribute {
    name = "username"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  # DynamoDB always encrypts at rest; this block only selects the KEY (CMK when
  # enable_kms_cmk=true, else the AWS-owned key — the free-tier default).
  server_side_encryption {
    enabled     = var.enable_kms_cmk #tfsec:ignore:aws-dynamodb-enable-at-rest-encryption
    kms_key_arn = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
  }

  tags = {
    Name = "oid-uid-map-${var.environment}"
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

# N3: Redis auth token compromise is mitigated at two independent layers:
#   1. Network: ElastiCache is in private subnets; aws_security_group.elasticache allows
#      inbound 6379 only from aws_security_group.ood — no internet path exists.
#   2. Credential: auth_token is a 64-char random secret stored in Secrets Manager /
#      SSM SecureString; only the OOD instance role can retrieve it.
# Even if the token were exfiltrated, an attacker still needs network access to port 6379.
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

# #37: oidc-auth-broker v0.3.x requires security.token_encryption_key (a 32-byte
# base64 key). Generate it here and stash in SSM SecureString; userdata.sh injects it
# into broker.yaml at boot. 32 raw bytes → base64 is what `openssl rand -base64 32` yields.
resource "random_password" "broker_token_key" {
  count   = var.use_cognito ? 1 : 0
  length  = 32
  special = false # base64-encoded in userdata; keep the raw value alphanumeric-safe
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

  # #79: prod protects user data by refusing to delete a non-empty bucket; non-prod purges
  # all objects+versions on destroy so `terraform destroy` is one clean pass (was
  # lifecycle.prevent_destroy, which couldn't be env-aware and blocked test teardown).
  force_destroy = !local.prod_protected

  tags = {
    Name = "ood-files-${var.environment}"
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
  force_destroy = !local.prod_protected # #79: clean non-prod teardown
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
# Bootstrap artifact bucket — stages userdata.sh / bake.sh out of user_data
# ---------------------------------------------------------------------------
# EC2 user_data has a hard 16,384-byte limit (applied to the base64-encoded
# value). scripts/userdata.sh alone is ~18 KB, so it cannot be inlined (#16).
# Instead the launch template carries a tiny stub that fetches the script from
# this bucket, verifies its SHA256, and execs it. The "ood-" name prefix is
# REQUIRED: the S3 gateway endpoint policy (aws_vpc_endpoint_policy.s3) scopes
# reachable buckets to arn:aws:s3:::ood-*, so this delivery path works even in
# no-egress / VPC-endpoint-only deployments with no NAT or internet route.
# The artifacts bucket holds only rebuildable bootstrap scripts (userdata.sh/
# bake.sh), already TLS- and encryption-enforced via aws_s3_bucket_policy.artifacts.
# Access logging would require a second always-on bucket for no audit value.
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "ood-artifacts-${var.environment}-"

  tags = {
    Name = "ood-artifacts-${var.environment}"
  }

  # Unlike ood_files (which holds user data), these are rebuildable artifacts re-uploaded
  # from source on every apply. #79: force_destroy in all envs — the bucket is versioned, so
  # without it DeleteBucket fails with BucketNotEmpty on leftover object versions even after
  # the current objects are gone (the bucket is always rebuildable, so this is safe in prod).
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_kms_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny non-TLS access and uploads that opt out of server-side encryption,
# matching the hardening on the OOD files bucket (H1).
resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyUnencryptedUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.artifacts.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-server-side-encryption" = "false"
          }
        }
      },
    ]
  })
}

# CKV2_AWS_61 / CKV_AWS_300: the artifacts bucket is versioned and re-uploaded on
# every apply, so noncurrent versions and aborted multipart uploads would
# accumulate indefinitely. Expire old script versions and clean up failed uploads.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Stage the bootstrap scripts. source_hash forces a re-upload whenever the local
# file changes, and filebase64sha256 (computed identically in the launch-template
# stub) is what the instance verifies the download against at boot.
resource "aws_s3_object" "userdata" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "userdata.sh"
  source      = "${path.module}/../scripts/userdata.sh"
  source_hash = filemd5("${path.module}/../scripts/userdata.sh")

  # Inherit the bucket default encryption; set explicitly so DenyUnencryptedUploads
  # never rejects the upload.
  server_side_encryption = var.enable_kms_cmk ? "aws:kms" : "AES256"
  kms_key_id             = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
}

resource "aws_s3_object" "bake" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "bake.sh"
  source      = "${path.module}/../scripts/bake.sh"
  source_hash = filemd5("${path.module}/../scripts/bake.sh")

  server_side_encryption = var.enable_kms_cmk ? "aws:kms" : "AES256"
  kms_key_id             = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
}

# #39: account-provisioning helper, fetched by userdata.sh and invoked by the pam_exec
# hook to materialize local accounts from the DynamoDB UID map on first login.
resource "aws_s3_object" "provision_user" {
  count       = var.enable_dynamodb_uid ? 1 : 0
  bucket      = aws_s3_bucket.artifacts.id
  key         = "ood-provision-user.sh"
  source      = "${path.module}/../scripts/ood-provision-user.sh"
  source_hash = filemd5("${path.module}/../scripts/ood-provision-user.sh")

  server_side_encryption = var.enable_kms_cmk ? "aws:kms" : "AES256"
  kms_key_id             = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
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
  recovery_window_in_days = var.environment == "prod" ? 30 : (var.environment == "staging" ? 14 : 7) # N5: staging gets 14d; test keeps 7d
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

# H3: Alert when Secrets Manager rotation fails — a failed rotation means the OIDC
# secret will expire at the end of the current rotation window, causing all logins to
# fail. Operators must investigate and re-trigger rotation before the expiry deadline.
resource "aws_cloudwatch_metric_alarm" "oidc_rotation_failure" {
  count               = var.use_cognito && var.enable_monitoring && var.oidc_secret_rotation_lambda_arn != "" ? 1 : 0
  alarm_name          = "ood-${var.environment}-oidc-rotation-failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RotationFailed"
  namespace           = "AWS/SecretsManager"
  period              = 3600
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching" # No rotation activity = healthy; rotation failure is an event
  alarm_description   = "OIDC client secret rotation failed — the secret will expire in <90 days causing all portal logins to fail. Investigate the rotation Lambda and re-trigger: aws secretsmanager rotate-secret --secret-id ${aws_secretsmanager_secret.oidc_client_secret[0].id}"
  alarm_actions       = [aws_sns_topic.ood[0].arn]
  dimensions = {
    SecretId = aws_secretsmanager_secret.oidc_client_secret[0].id
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

# #37: token_encryption_key for oidc-auth-broker, base64-encoded (openssl rand -base64 32
# equivalent). userdata.sh reads this and writes it into broker.yaml security block.
resource "aws_ssm_parameter" "broker_token_key" {
  count  = var.enable_parameter_store && var.use_cognito ? 1 : 0
  name   = "/ood/${var.environment}/broker_token_key"
  type   = "SecureString"
  value  = base64encode(random_password.broker_token_key[0].result)
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

  # #16: user_data is a tiny stub — it sets the OOD_* launch-time config, then
  # fetches the real bootstrap script(s) from the artifact bucket, verifies their
  # SHA256, and execs them. The 18 KB userdata.sh can no longer be inlined (the
  # base64-encoded value would exceed EC2's 16,384-byte hard limit). The hashes
  # below are computed by Terraform from the exact files uploaded to S3, so
  # verification is intrinsic — there is no separate checksum file to drift.
  user_data = base64encode(join("\n", concat([
    "#!/usr/bin/env bash",
    "set -euo pipefail",
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
    "export OOD_ALB_DNS='${var.enable_alb ? aws_lb.ood[0].dns_name : ""}'",
    "export OOD_OIDC_PAM_VERSION='${var.oidc_pam_version}'",
    "export OOD_USE_SSSD='${tostring(var.use_sssd)}'",        # #78: directory-backed POSIX identity
    "export ARTIFACT_BUCKET='${aws_s3_bucket.artifacts.id}'", # exported so the fetched userdata.sh child inherits it (#49)
    ],
    # bake.sh runs at boot only on the base AL2023 AMI; with a pre-baked AMI it was
    # already applied at image build time (matches the CDK base-AMI branch).
    var.enable_packer_ami ? ["# Baked AMI — bake.sh already applied at image build time"] : [
      "aws s3 cp \"s3://$ARTIFACT_BUCKET/bake.sh\" /tmp/bake.sh --region ${var.aws_region}",
      "echo '${filesha256("${path.module}/../scripts/bake.sh")}  /tmp/bake.sh' | sha256sum -c -",
      "bash /tmp/bake.sh",
      "rm -f /tmp/bake.sh",
    ],
    [
      "aws s3 cp \"s3://$ARTIFACT_BUCKET/userdata.sh\" /tmp/userdata.sh --region ${var.aws_region}",
      "echo '${filesha256("${path.module}/../scripts/userdata.sh")}  /tmp/userdata.sh' | sha256sum -c -",
      "bash /tmp/userdata.sh",
      "rm -f /tmp/userdata.sh",
    ]
  )))

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

  # The bootstrap scripts must exist in S3 before any instance boots and runs the
  # user_data stub that fetches them (#16).
  depends_on = [aws_s3_object.userdata, aws_s3_object.bake, aws_s3_object.provision_user]
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

# N2: DLM snapshots automatically inherit the encryption state of the source EBS volume.
# When enable_kms_cmk=true, the launch template uses aws_kms_key.ood[0] for the root
# volume — snapshots created by this policy will be encrypted with that same CMK.
# When enable_kms_cmk=false, volumes use the default aws/ebs managed key and snapshots
# inherit that key. Snapshots are NEVER unencrypted regardless of this policy configuration.
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

# This IS a log-destination bucket (ALB access logs); enabling access logging on
# it would recursively log-the-logs.
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "alb_logs" {
  count         = var.enable_alb ? 1 : 0
  bucket_prefix = "ood-alb-logs-${var.environment}-"
  tags          = { Name = "ood-alb-logs-${var.environment}" }

  # #79: prod preserves audit logs (refuses delete of non-empty bucket); non-prod purges
  # objects+versions+delete-markers on destroy for a clean one-pass teardown.
  force_destroy = !local.prod_protected
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count                   = var.enable_alb ? 1 : 0
  bucket                  = aws_s3_bucket.alb_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB access-log delivery requires SSE-S3 (AES256); the ELB service account cannot
# write with SSE-KMS. CMK is not an option for this bucket regardless of enable_kms_cmk.
#tfsec:ignore:aws-s3-encryption-customer-key
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
  rule {
    id     = "abort-incomplete-multipart" # CKV_AWS_300
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
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
      # H4 (was DenyVersioningDisable): a bucket policy cannot prevent suspending
      # versioning — there is no `s3:VersionStatus` request condition key, and S3
      # rejects the entire policy as malformed if one is used (#31). Versioning is
      # kept on by aws_s3_bucket_versioning.alb_logs; enforcing that it stays on
      # belongs to an Organizations SCP or a permissions boundary (deny
      # s3:PutBucketVersioning on this bucket ARN at the org/role level), or to
      # S3 Object Lock for true write-once immutability — none of which can be
      # expressed in a bucket policy condition.
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
  count       = var.enable_alb ? 1 : 0
  name_prefix = "ood-"
  # Public research portal — an internet-facing ALB is the product. Access is
  # fronted by allowed_cidr SG rules and (optionally) WAF when enable_waf=true.
  internal           = false #tfsec:ignore:aws-elb-alb-not-public
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = local.alb_subnets

  enable_deletion_protection = var.environment != "test"

  # CKV_AWS_131 / tfsec aws-elb-drop-invalid-headers: drop malformed headers
  # before they reach the OOD backend.
  drop_invalid_header_fields = true

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
    # #33: an Application Load Balancer ALWAYS requires subnets in >=2 AZs — AWS rejects a
    # single-subnet ALB at creation regardless of environment. (This previously exempted
    # test, which always failed at aws_lb creation with the default single subnet_id.)
    # distinct() guards against the same subnet listed twice (still one AZ).
    precondition {
      condition     = length(distinct(local.alb_subnets)) >= 2
      error_message = "enable_alb=true requires at least 2 subnets in different AZs. Set alb_subnet_ids to two subnets in distinct AZs (an ALB cannot be created in a single AZ)."
    }
  }
}

resource "aws_lb_target_group" "ood" {
  count                = var.enable_alb ? 1 : 0
  name_prefix          = "ood-"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.selected.id
  deregistration_delay = 30 # N4: 30s is sufficient for OOD dashboard requests; default 300s delays ASG instance replacement unnecessarily

  health_check {
    path                = "/pun/sys/dashboard"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    # #59: once OIDC protects the dashboard, an unauthenticated health-check prober is
    # redirected to the Cognito login (302), and OOD's `/` rewrite returns 301 — neither is
    # a 200. Accept the redirect codes: a 301/302 from this path still proves Apache + the
    # mod_auth_openidc vhost are alive (a dead instance returns 5xx/connection-refused),
    # which is the liveness signal we actually want. Without this the target is permanently
    # unhealthy and the ALB returns 502/503 (portal unreachable behind the ALB).
    matcher = "200,301,302"
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

# C1: Scope S3 gateway endpoint so only the OOD instance role can use it.
# Without a policy, the default allows Principal:* / Action:s3:* — any workload
# in the VPC can reach any S3 bucket via this endpoint without further IAM checks.
# The second statement permits read-only access to AWS-managed service buckets
# (AL2023 yum repos, SSM agent, CWAgent) which the instance accesses without
# explicit IAM credentials through the OS package manager.
# N1: Resource is scoped to the ood-* bucket prefix (all OOD-created buckets use
# this prefix). Without bucket scoping, a compromised OOD process could reach any
# S3 bucket in the account via this private endpoint, bypassing normal egress paths.
resource "aws_vpc_endpoint_policy" "s3" {
  count           = var.enable_vpc_endpoints ? 1 : 0
  vpc_endpoint_id = aws_vpc_endpoint.s3[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOODInstanceRole"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.ood.arn }
        Action    = "s3:*"
        Resource = [
          "arn:aws:s3:::ood-*",
          "arn:aws:s3:::ood-*/*",
        ]
      },
      {
        # Allow read from AWS-managed service buckets used by yum/dnf, SSM agent,
        # and CWAgent installer on AL2023. These requests originate from the OS
        # without the instance IAM role attached to the HTTP request.
        Sid       = "AllowAWSServiceBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::amazonlinux*",
          "arn:aws:s3:::amazonlinux*/*",
          "arn:aws:s3:::aws-ssm-${var.aws_region}",
          "arn:aws:s3:::aws-ssm-${var.aws_region}/*",
          "arn:aws:s3:::amazon-ssm-${var.aws_region}",
          "arn:aws:s3:::amazon-ssm-${var.aws_region}/*",
          "arn:aws:s3:::patch-baseline-snapshot-${var.aws_region}",
          "arn:aws:s3:::patch-baseline-snapshot-${var.aws_region}/*",
        ]
      },
    ]
  })
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

# H1: Scope interface endpoint policies so only the OOD instance role can use each endpoint.
# Secrets Manager policy also allows the rotation Lambda ARN when configured.
# ssmmessages and ec2messages require a broader action set for SSM Session Manager to work.

resource "aws_vpc_endpoint_policy" "secretsmanager" {
  count           = var.enable_vpc_endpoints && var.use_cognito ? 1 : 0
  vpc_endpoint_id = aws_vpc_endpoint.interfaces["secretsmanager"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOODSecretAccess"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.ood.arn }
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = aws_secretsmanager_secret.oidc_client_secret[0].arn
    }]
  })
}

resource "aws_vpc_endpoint_policy" "ssm" {
  count           = var.enable_vpc_endpoints ? 1 : 0
  vpc_endpoint_id = aws_vpc_endpoint.interfaces["ssm"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOODSSMAccess"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.ood.arn }
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:DescribeParameters",
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:DescribeSessions",
        "ssm:GetConnectionStatus",
        "ssm:DescribeInstanceInformation",
        "ssm:UpdateInstanceInformation",
        "ssm:SendCommand",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_vpc_endpoint_policy" "ssmmessages" {
  count           = var.enable_vpc_endpoints ? 1 : 0
  vpc_endpoint_id = aws_vpc_endpoint.interfaces["ssmmessages"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOODSSMMessages"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.ood.arn }
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_vpc_endpoint_policy" "ec2messages" {
  count           = var.enable_vpc_endpoints ? 1 : 0
  vpc_endpoint_id = aws_vpc_endpoint.interfaces["ec2messages"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOODEC2Messages"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.ood.arn }
      Action = [
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_vpc_endpoint_policy" "logs" {
  count           = var.enable_vpc_endpoints ? 1 : 0
  vpc_endpoint_id = aws_vpc_endpoint.interfaces["logs"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOODCloudWatchLogs"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.ood.arn }
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
      ]
      Resource = [
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/ood-${var.environment}",
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/ood-${var.environment}:*",
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/ood-${var.environment}*",
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/ood-${var.environment}*:*",
      ]
    }]
  })
}

# ---------------------------------------------------------------------------
# CloudFront (optional)
# ---------------------------------------------------------------------------

# M1: S3 bucket for CloudFront access logs
resource "aws_s3_bucket" "cdn_logs" {
  count         = var.enable_cdn && var.enable_alb ? 1 : 0
  bucket_prefix = "ood-cdn-logs-${var.environment}-"
  tags          = { Name = "ood-cdn-logs-${var.environment}" }
  force_destroy = !local.prod_protected # #79: clean non-prod teardown
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
  rule {
    id     = "abort-incomplete-multipart" # CKV_AWS_300
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
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
# M3: Bootstrap log group is always created regardless of enable_monitoring.
# userdata.sh writes to this log group on every boot — if the group doesn't exist,
# the CWAgent fails silently and bootstrap failures become invisible.
# This is the minimum audit trail needed to diagnose a broken deployment.
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/aws/ec2/ood-${var.environment}/bootstrap"
  retention_in_days = local.log_retention
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
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
  # CMK is opt-in (enable_kms_cmk); AWS-managed alias/aws/sns is the free-tier default.
  kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : "alias/aws/sns" #tfsec:ignore:aws-sns-topic-encryption-use-cmk
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
  # CMK is opt-in (enable_kms_cmk); AWS-managed alias/aws/sqs is the free-tier default.
  kms_master_key_id = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : "alias/aws/sqs" #tfsec:ignore:aws-sqs-queue-encryption-use-cmk

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

  # Every metric widget must declare `region` and explicit x/y/width/height layout
  # coordinates, or CloudWatch rejects the dashboard body (PutDashboard 400). The EFS
  # widget is only emitted when enable_efs=true — an empty metrics array is also invalid.
  dashboard_body = jsonencode({
    widgets = concat([
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CPU Utilization"
          region = var.aws_region
          period = 300
          stat   = "Average"
          metrics = [[
            "AWS/EC2", "CPUUtilization",
            "AutoScalingGroupName", aws_autoscaling_group.ood.name
          ]]
        }
      }
      ], var.enable_efs ? [
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EFS Client Connections"
          region = var.aws_region
          period = 300
          stat   = "Average"
          metrics = [[
            "AWS/EFS", "ClientConnections",
            "FileSystemId", aws_efs_file_system.home[0].id
          ]]
        }
      }
    ] : [])
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
# SSM session transcripts are an append-only audit log. Logging-the-logs and
# versioning add no value here; integrity is enforced by the bucket policy
# (writes scoped to the OOD role) and lifecycle expiration.
#tfsec:ignore:aws-s3-enable-bucket-logging
#tfsec:ignore:aws-s3-enable-versioning
resource "aws_s3_bucket" "ssm_sessions" {
  count         = var.enable_monitoring ? 1 : 0
  bucket_prefix = "ood-ssm-sessions-${var.environment}-"
  tags          = { Name = "ood-ssm-sessions-${var.environment}" }

  # #79: prod preserves session transcripts; non-prod purges on destroy for clean teardown.
  force_destroy = !local.prod_protected
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
  rule {
    id     = "abort-incomplete-multipart" # CKV_AWS_300
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
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

# #79: the AWS-managed AWSBatchServiceRole lacks the ECS actions Batch needs to tear down a
# managed compute environment's underlying ECS cluster. Without these, on `terraform destroy`
# the CE goes INVALID (statusReason: not authorized to perform ecs:ListClusters) and can't be
# deleted — blocking the whole destroy and risking an orphaned (billable) CE. Grant the ECS
# teardown actions explicitly so the CE deletes cleanly.
resource "aws_iam_role_policy" "batch_service_ecs_teardown" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-batch-ecs-teardown-"
  role        = aws_iam_role.batch_service[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecs:ListClusters",
        "ecs:DescribeClusters",
        "ecs:ListContainerInstances",
        "ecs:DescribeContainerInstances",
        "ecs:DeleteCluster",
        "ecs:DeregisterContainerInstance",
        "ecs:UpdateContainerInstancesState",
      ]
      Resource = "*"
    }]
  })
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

# M1: Create the Spot Fleet IAM role used by AWS Batch instead of assuming it exists.
# Previously this referenced a pre-existing role by hardcoded ARN; if absent, Batch
# silently fails to launch Spot instances with an opaque error.
resource "aws_iam_role" "batch_spot_fleet" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-batch-spot-fleet-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "spotfleet.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "ood-batch-spot-fleet-${var.environment}" }
}

resource "aws_iam_role_policy_attachment" "batch_spot_fleet" {
  count      = local.enable_batch ? 1 : 0
  role       = aws_iam_role.batch_spot_fleet[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

# N2: Dedicated minimal instance role for Batch compute nodes.
# Batch worker instances previously inherited the full OOD portal role — giving
# every Batch job the ability to read EFS home directories, write DynamoDB UID
# mappings, read the OIDC client secret, and submit further Batch jobs.
# Workers only need SSM session access (for troubleshooting) and CloudWatch Logs.
resource "aws_iam_role" "batch_instance" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-batch-instance-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "ood-batch-instance-${var.environment}" }
}

resource "aws_iam_role_policy_attachment" "batch_instance_ssm" {
  count      = local.enable_batch ? 1 : 0
  role       = aws_iam_role.batch_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "batch_instance_cw" {
  count      = local.enable_batch ? 1 : 0
  role       = aws_iam_role.batch_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "batch_instance" {
  count       = local.enable_batch ? 1 : 0
  name_prefix = "ood-batch-instance-${var.environment}-"
  role        = aws_iam_role.batch_instance[0].name
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
    instance_role       = aws_iam_instance_profile.batch_instance[0].arn
    instance_type       = ["m5", "m5a", "m6i"] # Explicit families avoid "optimal" picking GPU/storage instances
    subnets             = local.private_subnets
    security_group_ids  = [aws_security_group.ood.id]
    spot_iam_fleet_role = aws_iam_role.batch_spot_fleet[0].arn
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
# HealthOmics adapter (conditional on adapters_enabled containing "omics")
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "omics_adapter" {
  count       = local.enable_omics ? 1 : 0
  name_prefix = "ood-omics-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["omics:StartRun", "omics:GetRun", "omics:CancelRun", "omics:ListRuns"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "omics.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Bedrock batch-inference adapter (conditional on adapters_enabled containing "bedrock")
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "bedrock_adapter" {
  count       = local.enable_bedrock ? 1 : 0
  name_prefix = "ood-bedrock-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:CreateModelInvocationJob",
          "bedrock:GetModelInvocationJob",
          "bedrock:StopModelInvocationJob",
          "bedrock:ListModelInvocationJobs",
        ]
        Resource = "*"
      },
      {
        # Bedrock assumes this role to read the S3 input manifest and write outputs.
        # S3 access lives on the passed role's own policy, not the instance role.
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "bedrock.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# EMR Serverless adapter (conditional on adapters_enabled containing "emr")
# ---------------------------------------------------------------------------
resource "aws_emrserverless_application" "ood" {
  count         = local.enable_emr ? 1 : 0
  name          = "ood-${var.environment}"
  release_label = "emr-7.0.0"
  type          = "spark"

  tags = {
    Name = "ood-emr-${var.environment}"
  }
}

resource "aws_ssm_parameter" "emr_application_id" {
  count = local.enable_emr ? 1 : 0
  name  = "/ood/${var.environment}/emr_application_id"
  type  = "String"
  value = aws_emrserverless_application.ood[0].id
}

resource "aws_iam_role_policy" "emr_adapter" {
  count       = local.enable_emr ? 1 : 0
  name_prefix = "ood-emr-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "emr-serverless:StartJobRun",
          "emr-serverless:GetJobRun",
          "emr-serverless:CancelJobRun",
          "emr-serverless:ListJobRuns",
        ]
        Resource = [
          aws_emrserverless_application.ood[0].arn,
          "${aws_emrserverless_application.ood[0].arn}/jobruns/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "emr-serverless.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# SageMaker Training adapter (conditional on adapters_enabled containing "sagemaker-training")
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "sagemaker_training_adapter" {
  count       = local.enable_sagemaker_training ? 1 : 0
  name_prefix = "ood-sagemaker-training-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateTrainingJob",
          "sagemaker:DescribeTrainingJob",
          "sagemaker:StopTrainingJob",
          "sagemaker:ListTrainingJobs",
        ]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:training-job/ood-*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Fargate adapter (conditional on adapters_enabled containing "fargate")
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "ood" {
  count = local.enable_fargate ? 1 : 0
  name  = "ood-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "ood-fargate-${var.environment}"
  }
}

resource "aws_iam_role_policy" "fargate_adapter" {
  count       = local.enable_fargate ? 1 : 0
  name_prefix = "ood-fargate-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecs:RunTask", "ecs:StopTask", "ecs:ListTasks"]
        Resource = [
          aws_ecs_cluster.ood[0].arn,
          "${aws_ecs_cluster.ood[0].arn}/task/*",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/*",
        ]
      },
      {
        # DescribeTasks requires Resource="*"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Step Functions adapter (conditional on adapters_enabled containing "stepfunctions")
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "stepfunctions_adapter" {
  count       = local.enable_stepfunctions ? 1 : 0
  name_prefix = "ood-stepfunctions-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["states:StartExecution", "states:StopExecution", "states:ListExecutions"]
        Resource = [
          "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:ood-*",
        ]
      },
      {
        Effect = "Allow"
        Action = ["states:DescribeExecution"]
        Resource = [
          "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:execution:ood-*:*",
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Braket adapter (conditional on adapters_enabled containing "braket")
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "braket_adapter" {
  count       = local.enable_braket ? 1 : 0
  name_prefix = "ood-braket-adapter-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Quantum-task lifecycle. Task ARNs are server-assigned UUIDs under this
        # account, so they cannot be prefix-scoped to ood-*; scope to the account's
        # quantum-task namespace in-region.
        Sid    = "BraketQuantumTasks"
        Effect = "Allow"
        Action = [
          "braket:CreateQuantumTask",
          "braket:GetQuantumTask",
          "braket:CancelQuantumTask",
          "braket:SearchQuantumTasks",
        ]
        Resource = [
          "arn:aws:braket:${var.aws_region}:${data.aws_caller_identity.current.account_id}:quantum-task/*",
        ]
      },
      {
        # Device discovery/selection. QPU and simulator devices are AWS-owned global
        # resources (ARNs carry no account id), so these actions require "*".
        Sid    = "BraketDevices"
        Effect = "Allow"
        Action = [
          "braket:GetDevice",
          "braket:SearchDevices",
        ]
        Resource = ["*"]
      },
      {
        # Braket writes task results to the caller-specified output bucket; the
        # adapter also reads them back. Scope to the ood-* bucket prefix (matches
        # the S3 gateway endpoint policy).
        Sid    = "BraketResultsS3"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::ood-*",
          "arn:aws:s3:::ood-*/*",
        ]
      },
    ]
  })
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
  force_destroy = !local.prod_protected # #79: clean non-prod teardown
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

  # #79: prod preserves the compliance audit trail (refuses delete of non-empty bucket);
  # non-prod purges on destroy. Note compliance logging is typically only enabled in prod.
  force_destroy = !local.prod_protected
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
  force_destroy = !local.prod_protected # #79: clean non-prod teardown
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
