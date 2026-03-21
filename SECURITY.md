# Security Policy

## Supported Versions

| Version | Security Updates |
|---------|-----------------|
| Latest (`main`) | Yes |
| Tagged releases | Yes (patch releases) |
| Older releases | Community best-effort |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

If you discover a security issue in aws-openondemand — including vulnerabilities
in the Terraform modules, CDK stack, AMI bake scripts, or documentation — please
report it responsibly:

1. **Email:** Open a [GitHub Security Advisory](https://github.com/scttfrdmn/aws-openondemand/security/advisories/new)
   (preferred — keeps the report private until patched).

2. **Include in your report:**
   - A clear description of the vulnerability
   - The affected component(s) and version(s)
   - Steps to reproduce or a proof-of-concept
   - Your assessment of severity and potential impact
   - Any suggested mitigations (optional but appreciated)

3. **Response timeline:**
   - Acknowledgement within **5 business days**
   - Initial severity assessment within **10 business days**
   - Patch or mitigation plan within **90 days** (critical issues targeted at 30 days)
   - We will coordinate public disclosure timing with you

## Security Controls Overview

This project implements the following controls. Operators deploying this infrastructure
should verify these are active in their deployment:

| Control | Location | Notes |
|---------|----------|-------|
| IMDSv2 enforcement | `terraform/main.tf`, `packer/ood.pkr.hcl` | `http_tokens = "required"` |
| KMS CMK encryption | `terraform/main.tf` | Enable with `enable_kms_cmk=true` for prod |
| MFA enforcement | `terraform/main.tf` | Set `cognito_mfa_required=true` for prod |
| WAF v2 | `terraform/main.tf` | Rate limit + managed rule groups |
| VPC endpoint policies | `terraform/main.tf` | Scoped to OOD instance role |
| Supply chain pinning | `scripts/bake.sh`, `packer/ood.pkr.hcl` | SHA-verified binaries, pinned versions |
| Rotation monitoring | `terraform/main.tf` | CloudWatch alarm on Secrets Manager rotation failures |
| Audit logging | `terraform/main.tf` | CloudTrail, VPC Flow Logs, SSM session transcripts |

## Production Security Checklist

Before deploying to production, verify the following are set in `terraform/environments/prod.tfvars`:

```
cognito_mfa_required         = true
enable_kms_cmk               = true
enable_compliance_logging    = true
enable_backup                = true
enable_monitoring            = true
enable_vpc_endpoints         = true
enable_waf                   = true
oidc_secret_rotation_lambda_arn = "<rotation-lambda-arn>"
alb_subnet_ids               = ["<subnet-az1>", "<subnet-az2>"]
```

## Dependency Updates

This repository uses [Dependabot](.github/dependabot.yml) to automatically open
pull requests for updates to GitHub Actions and npm dependencies.

For Terraform provider updates, run:
```bash
terraform init -upgrade
```

For Packer plugin updates:
```bash
packer init -upgrade packer/ood.pkr.hcl
```
