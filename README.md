# Open OnDemand AWS Deployment

Deploy [Open OnDemand](https://openondemand.org/) on AWS with pluggable compute
backends using either Terraform or AWS CDK (Go). Both tools produce identical
infrastructure.

Cloud-native identity via [oidc-pam](https://github.com/scttfrdmn/oidc-pam)
replaces the traditional PAM/LDAP model — users authenticate with institutional
SSO (SAML/OIDC) and get mapped to Unix sessions automatically.

> **New to AWS?** Start with [docs/getting-started-aws.md](docs/getting-started-aws.md)
> — it walks through account setup, CLI configuration, and finding the IDs you need
> before running any deployment commands.

## Deployment Profiles

Choose a profile to match your cost and reliability needs. The profile sets the
EC2 instance type and compute strategy; all other features (ALB, WAF, EFS, etc.)
are controlled independently.

| Profile | Instance | Arch | Pricing | Est. compute/mo | Best for |
| --- | --- | --- | --- | --- | --- |
| **`minimal`** *(default)* | t3.medium | x86_64 | On-Demand | ~$30 | Development, small labs |
| **`standard`** | m6i.xlarge | x86_64 | On-Demand | ~$140 | 50–100 concurrent users |
| **`graviton`** | m7g.xlarge | ARM64 | On-Demand | ~$112 | Same as standard, ~20% cheaper |
| **`spot`** | m6i.xlarge | x86_64 | Spot | ~$42–56 | Cost-sensitive; requires EFS |
| **`large`** | m6i.2xlarge | x86_64 | On-Demand | ~$280 | 200+ concurrent users |

**Override the instance size without changing the profile:**

```bash
# Terraform — use a larger instance, keep all other profile settings
deployment_profile = "minimal"
instance_type      = "t3.large"
```

```bash
# CDK
npx cdk deploy -c deploymentProfile=minimal -c instanceType=t3.large
```

**Spot profile note:** when AWS reclaims a spot instance the ASG launches a
replacement in ~3–5 minutes. OOD sessions in progress are lost, but user data
survives on EFS and UID mappings survive in DynamoDB. The spot profile enforces
`enable_efs=true` via a deploy-time precondition.

---

## Architecture

```
Internet ──► ALB (HTTPS, optional)
             AWS WAF v2 (optional)
                 │
                 ▼
         Auto Scaling Group (min=1 / max=1)
         ┌───────────────────────────────────┐
         │  EC2 — Amazon Linux 2023          │
         │  Open OnDemand + Passenger/Nginx  │
         │  oidc-pam (OIDC → Unix identity)  │
         │  Compute adapter binaries         │
         └───────────────────────────────────┘
              │            │           │
              ▼            ▼           ▼
         EFS (/home)   DynamoDB    Cognito
         (shared)      (UID map)   (OIDC IdP)
              │
    ┌─────────┼──────────┬──────────┬──────────┐
    ▼         ▼          ▼          ▼          ▼
 On-Prem   Parallel   AWS Batch  SageMaker  Custom
 Slurm     Cluster    (Fargate/  (Jupyter/  EC2
 (VPN/DX)  (Slurm)    EC2/Spot)  RStudio)  (Launch
                                            Template)
```

**Key properties:**

| Property | Detail |
| --- | --- |
| OS | Amazon Linux 2023 |
| Web | Nginx + Passenger (OOD standard stack) |
| Identity | Cognito (default) or any OIDC provider → oidc-pam → Unix session |
| UID persistence | DynamoDB table (replaces LDAP) |
| TLS | ACM certificate on ALB — no certbot required (when ALB enabled) |
| Access | SSM Session Manager only — no SSH port exposed |
| AMI | Pre-baked with Packer (optional); falls back to base AL2023 |
| Recovery | ASG min=1/max=1 with health check — auto-replaces failed instances |

---

## Compute Backends

Each backend is a separate OOD cluster configuration. Enable any combination —
they work simultaneously.

| Backend | Adapter | Type | What it does |
| --- | --- | --- | --- |
| **On-Prem Slurm** | OOD built-in | Infrastructure | OOD submits to existing campus cluster over VPN/Direct Connect |
| **ParallelCluster** | OOD built-in | Infrastructure | Slurm-in-cloud via AWS ParallelCluster; reference configs in [ood-pcluster-ref](https://github.com/scttfrdmn/ood-pcluster-ref) |
| **AWS Batch** | [ood-batch-adapter](https://github.com/scttfrdmn/ood-batch-adapter) | Custom adapter | Cloud-native job submission — no Slurm, Spot instances, auto-scaling |
| **SageMaker** | [ood-sagemaker-adapter](https://github.com/scttfrdmn/ood-sagemaker-adapter) | Custom adapter | Interactive Jupyter/RStudio/VS Code via presigned URL — no OOD reverse proxy |
| **Custom EC2** | [ood-ec2-adapter](https://github.com/scttfrdmn/ood-ec2-adapter) | Custom adapter | Single-node compute from Launch Templates; Spot with On-Demand fallback |

The custom adapters are standalone projects — they work with any OOD
installation, not just this deployment.

---

## Feature Toggles

Every infrastructure feature is independently togglable. The first group
tips OOD incrementally into the cloud — each is valuable alone, and together
they unlock Spot pricing and transparent failover (same pattern as
[aws-hubzero](https://github.com/scttfrdmn/aws-hubzero), where RDS + EFS
made the instance stateless enough for Spot).

| Toggle | Default | What it controls | Cost impact |
| --- | --- | --- | --- |
| **Cloud-native progression** | | | |
| `enable_efs` | `true` | EFS /home — instance becomes replaceable | ~$30/mo per 100 GB |
| `enable_efs_one_zone` | `false` | Single-AZ EFS (~47% cheaper) | saves ~$14/mo |
| `enable_dynamodb_uid` | `true` | DynamoDB UID map — replaces LDAP | ~$1/mo |
| `use_cognito` | `true` | Cognito OIDC — replaces PAM/LDAP auth | free (50K MAU) |
| `enable_session_cache` | `false` | PUN sessions externalized — Spot becomes transparent | ~$12/mo |
| `enable_s3_browser` | `false` | S3 browsing in OOD file manager | ~$0 |
| `enable_cloudwatch_accounting` | `false` | Per-user/project cost tracking for cloud jobs | ~$5/mo |
| **Infrastructure** | | | |
| `enable_alb` | `true` | ALB with ACM cert, HTTPS termination | ~$20/mo |
| `enable_waf` | `false` | WAF v2 managed rules on ALB | ~$5/mo + requests |
| `enable_fsx` | `false` | FSx for Lustre scratch filesystem | ~$140/mo per 1.2 TiB |
| `enable_vpc_endpoints` | `true` | Interface endpoints (SSM, Secrets, Logs) | ~$50/mo |
| `enable_cdn` | `false` | CloudFront for static assets | ~$1/mo + transfer |
| `enable_packer_ami` | `false` | Pre-baked AMI (3–5 min boot) | ~$0.50/mo |
| **Observability & compliance** | | | |
| `enable_monitoring` | `true` | CloudWatch dashboard, alarms, SNS | ~$10/mo |
| `enable_advanced_monitoring` | `false` | Job metrics, anomaly detection | ~$20/mo |
| `enable_compliance_logging` | `false` | VPC Flow Logs, CloudTrail, Config, Security Hub | ~$30–100/mo |
| `enable_backup` | `false` | AWS Backup for EFS + DynamoDB | ~$10–50/mo |
| `enable_kms_cmk` | `false` | Customer-managed KMS keys | ~$1/mo per key |

The `spot` profile enforces `enable_efs`, `enable_dynamodb_uid`, and
`use_cognito` as preconditions. Add `enable_session_cache` to make Spot
transparent to users (sessions survive instance replacement).

---

## Prerequisites

* AWS account with permissions to create EC2, EFS, IAM, and related resources
  (see [docs/getting-started-aws.md](docs/getting-started-aws.md) for IAM setup)
* AWS CLI v2 configured (`aws configure`)
* Terraform >= 1.5 **or** Node.js >= 18 + Go >= 1.21 with AWS CDK

Verify your credentials:

```bash
aws sts get-caller-identity
```

---

## Quick Start — Test Environment

The fastest path is a test deployment with all defaults. You need a VPC ID,
one public subnet ID, and your current public IP.

**Find your VPC and subnet:**

```bash
# List VPCs
aws ec2 describe-vpcs \
  --query 'Vpcs[*].[VpcId,IsDefault,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# List public subnets in a VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc-id>" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]' \
  --output table

# Your current public IP
curl -s https://checkip.amazonaws.com
```

### Terraform

```bash
# Bootstrap state backend (one-time per account/region)
bash scripts/bootstrap-terraform-backend.sh

cd terraform
terraform init

# Edit environments/test.tfvars and add your three required values:
#   vpc_id       = "vpc-..."
#   subnet_id    = "subnet-..."
#   allowed_cidr = "YOUR_IP/32"
#
# test.tfvars uses deployment_profile=minimal with cost-saving toggles:
#   enable_alb=false, enable_vpc_endpoints=false, enable_monitoring=false
# Total: ~$35/mo

terraform apply -var-file=environments/test.tfvars
```

### CDK

```bash
cd cdk
go mod download
cp cdk.context.example.json cdk.context.json
# Edit cdk.context.json: set vpcId and allowedCidr

npx cdk bootstrap   # one-time per account/region
npx cdk deploy -c environment=test
```

> **Deployment takes 10–15 minutes.** Infrastructure creates in 2–3 minutes,
> then the EC2 instance bootstraps in the background — installing OOD,
> oidc-pam, and adapter binaries. With a pre-baked AMI (`enable_packer_ami=true`),
> bootstrap drops to 3–5 minutes. See [Monitoring the Bootstrap](#monitoring-the-bootstrap).

---

## Deployment Guide

### Terraform Environments

```bash
cd terraform
terraform init

# Test (minimal, single subnet OK, ~$35/mo)
terraform apply -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=1.2.3.4/32'

# Staging (ALB + WAF, 2 subnets in different AZs)
terraform apply -var-file=environments/staging.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=0.0.0.0/0' \
  -var='domain_name=ood-staging.university.edu'

# Production (all features, compliance logging)
terraform apply -var-file=environments/prod.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='domain_name=ood.university.edu' \
  -var='alarm_email=hpc-ops@university.edu'
```

### CDK Environments

```bash
cd cdk

npx cdk deploy -c environment=test
npx cdk deploy -c environment=staging -c domainName=ood-staging.university.edu
npx cdk deploy -c environment=prod -c domainName=ood.university.edu \
  -c alarmEmail=hpc-ops@university.edu
```

### Configuring Compute Backends

After the portal deploys, enable compute backends by setting `adapters_enabled`:

```bash
# Terraform — add Batch and SageMaker backends
terraform apply -var-file=environments/prod.tfvars \
  -var='adapters_enabled=["batch","sagemaker"]'

# Add on-prem cluster over VPN
terraform apply -var-file=environments/prod.tfvars \
  -var='adapters_enabled=["batch","sagemaker","onprem"]' \
  -var='onprem_vpn_cidr=10.100.0.0/16' \
  -var='onprem_head_node=hpc-login.university.edu'

# Add ParallelCluster
terraform apply -var-file=environments/prod.tfvars \
  -var='adapters_enabled=["batch","sagemaker","parallelcluster"]'
```

Each adapter creates its own OOD cluster YAML in `/etc/ood/config/clusters.d/`.
Users see all enabled backends as submission targets in the OOD dashboard.

### Configuring Identity

Default: Cognito User Pool as the OIDC provider. For institutional SSO:

```bash
# Cognito with SAML federation (most R1 universities)
terraform apply -var-file=environments/prod.tfvars \
  -var='cognito_saml_metadata_url=https://idp.university.edu/metadata'

# External OIDC provider (Okta, Azure AD, CILogon)
terraform apply -var-file=environments/prod.tfvars \
  -var='use_cognito=false' \
  -var='oidc_issuer=https://university.okta.com' \
  -var='oidc_client_id=0oaXXXXXXXXXXXXX'
```

See [docs/identity-guide.md](docs/identity-guide.md) for provider-specific
setup including InCommon/Shibboleth, CILogon, and multi-provider configurations.

---

## Monitoring the Bootstrap

After `terraform apply` completes, the EC2 instance bootstraps in the background.
**Total time: 10–15 minutes** (base AMI) or **3–5 minutes** (baked AMI).

```bash
# 1. Find the instance
ASG_NAME=$(terraform -chdir=terraform output -raw asg_name)
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
echo "Instance: $INSTANCE_ID"

# 2. Stream bootstrap logs (requires SSM Session Manager plugin)
aws ssm start-session --target "$INSTANCE_ID"
# Inside the session:
sudo tail -f /var/log/cloud-init-output.log
sudo tail -f /var/log/ood-bootstrap.log
```

Bootstrap is complete when you see:

```
=== Open OnDemand bootstrap completed at <timestamp> ===
```

---

## Instance Access

There is no SSH port — access is exclusively via **SSM Session Manager**.
No EC2 key pair is required.

The deploy outputs a ready-to-run `ssm_connect_command` that looks up the
running instance dynamically:

```bash
# Terraform — copy the ssm_connect_command output, e.g.:
aws ec2 describe-instances \
  --filters 'Name=tag:aws:autoscaling:groupName,Values=ood-test-...' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text \
  | xargs -I{} aws ssm start-session --target {}
```

---

## Environments

Instance type is set by `deployment_profile` (default: t3.medium). Use
`instance_type` to override. Storage sizing is per-environment:

| Environment | EBS | EFS Throughput | CW Log Retention | Multi-AZ EFS |
| --- | --- | --- | --- | --- |
| test | 30 GB | Elastic (burst) | 7 days | No |
| staging | 50 GB | Elastic (burst) | 30 days | Yes |
| prod | 50 GB | Provisioned | 90 days | Yes |

---

## Example Deployments

Each deployment shows which cloud-native progression levels are active.
See [Section 6 of the design doc](aws-openondemand-design.md#6-cloud-native-progression)
for the full progression story.

| Scenario | Profile | Cloud-native level | Key toggles | Est. fixed cost |
| --- | --- | --- | --- | --- |
| PI with credit grant, 10 students | `minimal` | 1-3 | EFS, DynamoDB UID, Cognito; ALB off | ~$35/mo |
| Department, 50 users | `graviton` | 1-3, 6-7 | + ALB, WAF, S3 browser, CW accounting | ~$250/mo |
| Production, 200+ users, Spot | `spot` (override 2xlarge) | 1-5, 6-7 | + session cache, compliance, backup | ~$600/mo |
| Maximum savings, Batch only | `spot` | 1-4 | EFS, DynamoDB, Cognito; ALB off | ~$40/mo |

---

## Building a Baked AMI (Packer)

Pre-baked AMI drops boot from 10–15 minutes to 3–5 minutes and ensures
identical environments across instance replacements.

```bash
cd packer
packer init .

# Build (requires AWS credentials with EC2 permissions)
GIT_SHA=$(git rev-parse --short HEAD) packer build ood.pkr.hcl
```

The AMI includes OOD, oidc-pam, all adapter binaries, Nginx, Passenger,
and the CloudWatch agent. Configuration is pulled from SSM Parameter Store
at boot — the AMI is the software, Parameter Store is the config.

Set `enable_packer_ami=true` to use the baked AMI.

---

## Security Features

* **No SSH port** — SSM Session Manager is the only access path
* **IMDSv2 enforced** — token-based instance metadata, hop limit 1
* **ALB + WAF v2** (when enabled) — CommonRuleSet, KnownBadInputsRuleSet, SQLiRuleSet in Block mode
* **ACM TLS** — AWS-managed certificate with automatic renewal
* **OIDC authentication** — oidc-pam bridges institutional SSO to Unix identity; no static SSH keys
* **UID persistence** — DynamoDB table replaces LDAP; consistent UIDs across OOD and compute nodes
* **VPC endpoints** (when enabled) — S3 (gateway), SSM, SSMMessages, EC2Messages, SecretsManager, Logs; no internet egress for AWS API calls
* **Encrypted storage** — EBS, EFS, S3, DynamoDB all encrypted at rest
* **SSM Parameter Store** — runtime configuration injected at boot, not hard-coded
* **Compliance logging** (when enabled) — VPC Flow Logs, CloudTrail, AWS Config Rules, Security Hub
* **KMS CMK** (when enabled) — customer-managed keys for EFS, DynamoDB, S3; FIPS 140-2 validated

---

## Destroying the Stack

```bash
cd terraform

# Pass the same vars used at apply time
terraform destroy -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-...' \
  -var='subnet_id=subnet-...' \
  -var='allowed_cidr=0.0.0.0/0'
```

After `terraform destroy` completes, check for resources Terraform does not delete:

```bash
# EBS snapshots created by DLM
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:Project,Values=ood" \
  --query 'Snapshots[*].[SnapshotId,StartTime]' --output table
```

To remove the Terraform state backend:

```bash
TF_STATE_BUCKET=ood-terraform-state-<account-id> \
TF_LOCK_TABLE=ood-terraform-locks \
bash scripts/teardown-terraform-backend.sh
```

---

## Related Projects

| Project | What it does |
| --- | --- |
| [oidc-pam](https://github.com/scttfrdmn/oidc-pam) | OIDC → PAM identity bridge for Linux (used by this project) |
| [ood-batch-adapter](https://github.com/scttfrdmn/ood-batch-adapter) | OOD job adapter for AWS Batch (standalone Go binary) |
| [ood-sagemaker-adapter](https://github.com/scttfrdmn/ood-sagemaker-adapter) | OOD interactive session launcher for SageMaker (standalone Go binary) |
| [ood-ec2-adapter](https://github.com/scttfrdmn/ood-ec2-adapter) | OOD single-node compute via EC2 Launch Templates (standalone Go binary) |
| [ood-pcluster-ref](https://github.com/scttfrdmn/ood-pcluster-ref) | Reference ParallelCluster configs + setup scripts for OOD |
| [aws-hubzero](https://github.com/scttfrdmn/aws-hubzero) | Sister project: HubZero on AWS with the same deployment pattern |

---

## Documentation

* [Getting Started with AWS](docs/getting-started-aws.md) — account setup, IAM, finding VPC/subnet IDs
* [Deployment Guide](docs/deployment-guide.md) — profiles, toggles, environments explained
* [Adapter Guide](docs/adapter-guide.md) — configuring each compute backend
* [Identity Guide](docs/identity-guide.md) — OIDC provider setup, oidc-pam config, UID mapping
* [Architecture](docs/architecture.md) — diagrams and design decisions
* [Cost Guide](docs/cost-guide.md) — toggle-by-toggle cost breakdown, example configurations
* [Troubleshooting](docs/troubleshooting.md) — common mistakes, WAF debugging, bootstrap monitoring

---

## License

MIT

---

**Built for the research computing community by someone who's been doing this for 30 years.**
