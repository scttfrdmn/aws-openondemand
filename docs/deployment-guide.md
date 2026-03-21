# Deployment Guide

## Deployment Profiles

Profiles set the instance type and Spot vs. on-demand. Choose one per deployment:

| Profile | Instance | Arch | Mode | ~Cost/mo (EC2 only) |
|---------|----------|------|------|---------------------|
| `minimal` | t3.medium | x86 | on-demand | $30 |
| `standard` | m6i.xlarge | x86 | on-demand | $140 |
| `graviton` | m7g.xlarge | ARM64 | on-demand | $115 |
| `spot` | m6i.xlarge | x86 | Spot | $14–28 |
| `large` | m6i.2xlarge | x86 | on-demand | $280 |

Override the instance type independently: `instance_type = "m6i.4xlarge"`

### Spot Profile Prerequisites

`spot` requires three cloud-native levels to be enabled to prevent data loss:

```hcl
deployment_profile   = "spot"
enable_efs           = true   # Level 1: /home survives interruption
enable_dynamodb_uid  = true   # Level 2: identity survives interruption
use_cognito          = true   # Level 3: auth survives interruption
```

## Environments

Environments (`test`, `staging`, `prod`) control sizing only:

| Setting | test | staging | prod |
|---------|------|---------|------|
| EBS volume | 30 GB | 50 GB | 50 GB |
| EFS throughput | elastic | elastic | provisioned |
| Log retention | 7 days | 30 days | 90 days |
| Multi-AZ EFS | no | yes | yes |
| DLM snapshots | 3 | 3 | 14 |

## Feature Toggles

All 17 toggles are independent boolean variables. Common combinations:

### Cheapest functional deployment (~$35/mo)

```hcl
deployment_profile   = "minimal"
enable_efs           = true
enable_dynamodb_uid  = true
use_cognito          = true
enable_alb           = false
enable_waf           = false
enable_vpc_endpoints = false
enable_monitoring    = false
```

### Department deployment (~$250/mo)

```hcl
deployment_profile   = "graviton"
enable_alb           = true
enable_waf           = true
enable_monitoring    = true
enable_s3_browser    = true
enable_cloudwatch_accounting = true
```

### Production deployment (~$600/mo)

```hcl
deployment_profile       = "spot"
enable_alb               = true
enable_waf               = true
enable_vpc_endpoints     = true
enable_monitoring        = true
enable_compliance_logging = true
enable_backup            = true
enable_kms_cmk           = true
enable_session_cache     = true
```

## First Deploy

```bash
# 1. Bootstrap Terraform state backend (once per account/region)
./scripts/bootstrap-terraform-backend.sh

# 2. Initialize Terraform
cd terraform
terraform init

# 3. Deploy test environment
terraform apply \
  -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=YOUR_IP/32'
```

## Upgrading

The ASG min/max is 1/1 — replace the instance by terminating it:

```bash
# Find the instance
aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=ood-test-xxx" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text

# Terminate — ASG replaces it with the new launch template
aws ec2 terminate-instances --instance-ids i-xxx
```

## Teardown

```bash
terraform destroy -var-file=environments/test.tfvars -var='vpc_id=...' ...
./scripts/teardown-terraform-backend.sh
```
