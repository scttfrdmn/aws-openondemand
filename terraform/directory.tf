# ---------------------------------------------------------------------------
# #78: AWS Directory Service — POSIX identity source for SSSD/NSS
#
# Retires the bespoke login-time-useradd + DynamoDB-UID stack (#39->#77, which can't work:
# nginx_stage's getpwnam runs before any provisioning hook). The OOD host resolves users via
# NSS/SSSD against this managed directory, so getpwnam succeeds with NO account creation at
# login. AWS Directory Service is managed (no servers/containers/DB to operate):
#   - non-prod: Simple AD (Samba 4, ~$36/mo for Small) — fine for the prototype/smoke test.
#   - prod:     Managed Microsoft AD — production-grade, multi-AZ, trust-capable.
# SSSD uses id_provider=ad + ldap_id_mapping=True (algorithmic uids — no manual POSIX attrs).
# Web auth is OOD's bundled Dex with an LDAP connector bound to THIS SAME directory (no
# Cognito), so the OIDC username == the AD account SSSD resolves, by construction.
# directory_ldap_uri can override the SSSD/Dex target with an on-prem AD/LDAP (no code change).
#
# Requires >=2 subnets in different AZs (same constraint as the ALB).
# ---------------------------------------------------------------------------

resource "random_password" "directory_admin" {
  count   = var.enable_directory ? 1 : 0
  length  = 32
  special = true
  # Directory Service admin password complexity: keep to a shell/AD-safe special set.
  override_special = "!@#$%^&*()-_=+"
}

# The admin password is stored in Secrets Manager; the OOD host fetches it at boot to perform
# the SSSD domain join (the only consumer). Never written to user_data in clear text.
resource "aws_secretsmanager_secret" "directory_admin" {
  count                   = var.enable_directory ? 1 : 0
  name                    = "ood/${var.environment}/directory-admin-password"
  description             = "#78: AWS Directory Service admin password (SSSD domain join)"
  kms_key_id              = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
  recovery_window_in_days = local.prod_protected ? 30 : 0 # #79: non-prod deletes immediately
}

resource "aws_secretsmanager_secret_version" "directory_admin" {
  count         = var.enable_directory ? 1 : 0
  secret_id     = aws_secretsmanager_secret.directory_admin[0].id
  secret_string = random_password.directory_admin[0].result
}

# #78 PR B: the Dex LDAP connector binds to the directory with this password. In eval mode
# (enable_directory) it auto-fills from the Simple AD admin password; in BYO/production mode
# the operator populates this secret out-of-band (the secret is created so the OOD host's read
# policy + the userdata fetch are stable regardless of mode). The OOD host fetches it at boot
# to write the Dex bindPW; it is never in user_data or SSM.
resource "aws_secretsmanager_secret" "directory_bind" {
  count                   = var.use_sssd ? 1 : 0
  name                    = "ood/${var.environment}/directory-bind-password"
  description             = "#78: LDAP bind password for the Dex connector"
  kms_key_id              = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : null
  recovery_window_in_days = local.prod_protected ? 30 : 0
}

# Eval mode: seed the bind secret from the Simple AD admin password. BYO mode: the operator
# sets it (so we do NOT manage a version here when there's no provisioned directory).
resource "aws_secretsmanager_secret_version" "directory_bind" {
  count         = var.use_sssd && var.enable_directory ? 1 : 0
  secret_id     = aws_secretsmanager_secret.directory_bind[0].id
  secret_string = random_password.directory_admin[0].result
}

# Simple AD for non-prod, Managed Microsoft AD for prod — selected by environment.
resource "aws_directory_service_directory" "ood" {
  count    = var.enable_directory ? 1 : 0
  name     = var.directory_name
  password = random_password.directory_admin[0].result
  edition  = local.prod_protected ? "Standard" : null # edition applies to MicrosoftAD only
  type     = local.prod_protected ? "MicrosoftAD" : "SimpleAD"
  size     = local.prod_protected ? null : "Small" # size applies to SimpleAD only

  vpc_settings {
    vpc_id     = data.aws_vpc.selected.id
    subnet_ids = slice(local.private_subnets, 0, 2) # AWS requires exactly 2 subnets in 2 AZs
  }

  tags = {
    Name = "ood-directory-${var.environment}"
  }

  lifecycle {
    precondition {
      condition     = length(distinct(slice(local.private_subnets, 0, length(local.private_subnets) >= 2 ? 2 : 1))) >= 2
      error_message = "enable_directory requires at least 2 subnets in different AZs. Provide >=2 private_subnet_ids (AWS Directory Service is multi-AZ by design)."
    }
  }
}

# SSM parameters the OOD host reads at boot to configure SSSD (non-secret). The admin password
# itself comes from Secrets Manager above; these are the directory coordinates.
resource "aws_ssm_parameter" "directory_name" {
  count = var.enable_directory && var.enable_parameter_store ? 1 : 0
  name  = "/ood/${var.environment}/directory_name"
  type  = "String"
  value = var.directory_name
}

resource "aws_ssm_parameter" "directory_dns_ips" {
  count = var.enable_directory && var.enable_parameter_store ? 1 : 0
  name  = "/ood/${var.environment}/directory_dns_ips"
  type  = "StringList"
  value = join(",", aws_directory_service_directory.ood[0].dns_ip_addresses)
}

# #78 PR B: directory coordinates the OOD host reads to configure SSSD + the Dex LDAP
# connector. Published whenever use_sssd (so BYO mode without a provisioned directory still
# gets them). directory_ldap_uri prefers the explicit override, else the provisioned endpoint.
resource "aws_ssm_parameter" "directory_ldap_uri" {
  count = var.use_sssd && var.enable_parameter_store ? 1 : 0
  name  = "/ood/${var.environment}/directory_ldap_uri"
  type  = "String"
  value = local.directory_ldap_uri
}

resource "aws_ssm_parameter" "directory_coords" {
  for_each = (var.use_sssd && var.enable_parameter_store) ? {
    directory_bind_dn       = var.directory_bind_dn
    directory_user_base_dn  = var.directory_user_base_dn
    directory_user_filter   = var.directory_user_filter
    directory_username_attr = var.directory_username_attr
  } : {}
  name = "/ood/${var.environment}/${each.key}"
  type = "String"
  # SSM rejects empty String values; emit a single space for unset (the script treats it as unset).
  value = each.value != "" ? each.value : " "
}

# Allow the OOD instance role to read the directory admin + bind passwords (domain join + Dex bind).
resource "aws_iam_role_policy" "directory_secrets_read" {
  count       = var.use_sssd || var.enable_directory ? 1 : 0
  name_prefix = "ood-directory-secrets-"
  role        = aws_iam_role.ood.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = compact([
        var.enable_directory ? aws_secretsmanager_secret.directory_admin[0].arn : "",
        var.use_sssd ? aws_secretsmanager_secret.directory_bind[0].arn : "",
      ])
    }]
  })
}
