# Getting Started with AWS — Open OnDemand Deployment Guide

This guide is for people who are new to AWS or have used it only occasionally.
It covers everything you need before running your first `terraform apply` or
`cdk deploy`: account setup, CLI configuration, understanding the key services
this project uses, and finding the resource IDs you will be asked to provide.

If you are already comfortable with AWS, VPCs, IAM, and the CLI, skip to the
[Prerequisites section of the README](../README.md#prerequisites).

---

## Table of Contents

1. [What AWS services does this project use?](#1-what-aws-services-does-this-project-use)
2. [Create an AWS account](#2-create-an-aws-account)
3. [Set up IAM — create a deployment user](#3-set-up-iam--create-a-deployment-user)
4. [Install and configure the AWS CLI](#4-install-and-configure-the-aws-cli)
5. [Understand regions and availability zones](#5-understand-regions-and-availability-zones)
6. [Find your VPC and subnet IDs](#6-find-your-vpc-and-subnet-ids)
7. [Understand what this deployment creates](#7-understand-what-this-deployment-creates)
8. [Estimated costs](#8-estimated-costs)
9. [Common first-timer mistakes](#9-common-first-timer-mistakes)
10. [Next step: deploy](#10-next-step-deploy)

---

## 1. What AWS services does this project use?

You do not need deep expertise in all of these — the Terraform/CDK code creates
and wires them together. Knowing what each service is helps when reading deploy
output or troubleshooting.

| Service | What it does in this project |
| --- | --- |
| **EC2** | Virtual machine that runs Open OnDemand (Nginx, Passenger, oidc-pam) |
| **EFS** | Network file system — shared /home across OOD and compute nodes, survives instance replacement |
| **ALB** | Application Load Balancer — terminates HTTPS, health checks (optional) |
| **ACM** | Manages the TLS certificate (free, auto-renewed) |
| **WAF** | Web Application Firewall — blocks common web attacks (optional) |
| **Cognito** | Identity service — OIDC provider for user authentication, SAML federation |
| **DynamoDB** | Key-value store — maps OIDC usernames to Unix UIDs consistently |
| **IAM** | Identity and access control — EC2 gets a role to call AWS APIs |
| **SSM** | Systems Manager — shell access to EC2 without SSH |
| **S3** | Object storage — Terraform state, job outputs, shared datasets |
| **CloudWatch** | Logs, metrics, and alarms |
| **VPC** | Your private network inside AWS — required before anything else |
| **Batch** | Managed job scheduler — cloud-native compute backend (optional) |
| **SageMaker** | Managed ML platform — interactive Jupyter/RStudio sessions (optional) |
| **ParallelCluster** | Managed HPC cluster — Slurm in the cloud (optional) |

---

## 2. Create an AWS account

If you already have an AWS account, skip to section 3.

1. Go to https://aws.amazon.com and choose **Create an AWS Account**.
2. You will need an email address, phone number, and credit card. AWS will not
   charge you unless you deploy resources beyond the free tier.
3. Choose the **Basic (free) support plan** unless you need paid support.
4. After your account is active, sign in to the **AWS Management Console**.

**Enable MFA on the root account immediately.** The root account has unrestricted
access to everything. Go to the top-right menu → Security Credentials →
Multi-factor authentication → Assign MFA device.

---

## 3. Set up IAM — create a deployment user

Never use your root account for day-to-day work. Create an IAM user (or role)
with enough permissions to deploy this project.

### Option A: Quick start (AdministratorAccess)

Fastest path. Acceptable for personal or lab accounts; not appropriate for
shared or production accounts.

1. In the AWS Console, search for **IAM** and open the service.
2. Go to **Users** → **Create user**.
3. Username: `ood-deploy` (or any name you prefer).
4. Select **Attach policies directly** and search for `AdministratorAccess`.
5. Attach it and create the user.
6. On the user page, go to **Security credentials** → **Create access key**.
7. Select **Command Line Interface (CLI)** as the use case.
8. Download the CSV file — you will not be able to see the secret key again.

### Option B: Least-privilege policy

For team or production use, create a custom policy. The services required are:

```
ec2:*, efs:*, elasticloadbalancing:*, autoscaling:*, iam:*,
cognito-idp:*, dynamodb:*, s3:*, acm:*, wafv2:*, cloudfront:*,
cloudwatch:*, logs:*, sns:*, ssm:*, kms:*, batch:*, sagemaker:*,
sts:GetCallerIdentity, sts:AssumeRole
```

The AWS [policy generator](https://awspolicygen.s3.amazonaws.com/policygen.html)
and [IAM policy simulator](https://policysim.aws.amazon.com) can help you
build and validate a minimal policy.

---

## 4. Install and configure the AWS CLI

### Install

**macOS (Homebrew):**

```bash
brew install awscli
```

**macOS / Linux (official installer):**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
```

**Windows:** Download the MSI installer from https://aws.amazon.com/cli/.

Verify:

```bash
aws --version
# aws-cli/2.x.x ...
```

### Configure

```bash
aws configure
```

Enter the four values when prompted:

```
AWS Access Key ID [None]:     <paste your access key ID>
AWS Secret Access Key [None]: <paste your secret access key>
Default region name [None]:   us-east-1
Default output format [None]: json
```

Verify it works:

```bash
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/ood-deploy"
}
```

### Multiple AWS accounts or profiles

```bash
aws configure --profile ood
export AWS_PROFILE=ood
aws sts get-caller-identity
```

---

## 5. Understand regions and availability zones

**Region** — a geographic area containing AWS data centers. Examples:
`us-east-1` (N. Virginia), `us-west-2` (Oregon), `eu-west-1` (Ireland).
Every resource you create lives in one region.

**Availability Zone (AZ)** — a physically separate data center within a region.
Each region has 2–6 AZs named like `us-east-1a`, `us-east-1b`.

**Why this matters:**

- All resources must be in the same region.
- EFS mount targets are created per AZ.
- Multi-AZ EFS (default for staging/prod) needs subnets in 2+ AZs.
- ParallelCluster compute nodes can span AZs.

**Choose a region close to your users.** For most US deployments, `us-east-1`
or `us-west-2` are safe defaults.

---

## 6. Find your VPC and subnet IDs

Every AWS account gets a **default VPC** in each region with public subnets.
For test deployments, the default VPC works fine.

### Find your default VPC

```bash
aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[*].[VpcId,CidrBlock]' \
  --output table
```

### Find public subnets

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]' \
  --output table
```

### Find your current public IP

```bash
curl -s https://checkip.amazonaws.com
# 203.0.113.42
```

Use as `203.0.113.42/32` for the `allowed_cidr` variable (restricts access
to your IP only). For production with a real domain, use `0.0.0.0/0` — the
WAF managed rules handle filtering.

---

## 7. Understand what this deployment creates

When you run `terraform apply` with `test.tfvars` defaults:

```
VPC (yours, existing)
  ├── Security Groups
  │   ├── ood-ec2        — allows HTTP from ALB SG (or allowed_cidr when ALB off)
  │   └── ood-efs        — allows NFS from EC2 SG
  │
  ├── EC2 (via Auto Scaling Group)
  │   └── Launch Template → Amazon Linux 2023
  │       ├── Open OnDemand + Passenger/Nginx
  │       ├── oidc-pam (OIDC → Unix identity)
  │       ├── Compute adapter binaries
  │       ├── IAM instance profile
  │       └── user-data bootstrap script
  │
  ├── EFS File System
  │   └── Mount target in your subnet
  │
  ├── Cognito User Pool
  │   └── OIDC App Client (for mod_auth_openidc)
  │
  ├── DynamoDB Table
  │   └── oidc-uid-map (username → UID/GID)
  │
  ├── S3 Bucket (Terraform state — created by bootstrap script)
  │
  ├── SSM Parameter Store
  │   └── /ood/<environment>/{domain,oidc_issuer,efs_id,...}
  │
  ├── CloudWatch (when enable_monitoring=true)
  │   ├── Log groups (bootstrap, nginx, passenger)
  │   └── Alarms (CPU, StatusCheck)
  │
  └── IAM
      ├── EC2 instance role + profile
      └── Policies for EFS, SSM, DynamoDB, CloudWatch, S3
```

With more toggles enabled (ALB, WAF, VPC endpoints, etc.), additional
resources appear. Each toggle's resources are documented in the toggle table
in the README.

---

## 8. Estimated costs

These are rough on-demand estimates for `us-east-1`. The default `test.tfvars`
with `deployment_profile=minimal` and cost-saving toggles gives you:

| Resource | Cost | Notes |
| --- | --- | --- |
| EC2 t3.medium (minimal) | ~$30/mo | |
| EFS (One Zone, 10 GB typical) | ~$2/mo | |
| DynamoDB (on-demand) | ~$1/mo | |
| Cognito | $0 | Free tier: 50K MAU |
| EBS 30 GB gp3 | ~$2.40/mo | |
| **Total** | **~$35/mo** | |

To go cheaper, use the `graviton` profile (m7g.medium ARM64, ~$24/mo compute)
with ALB off — total ~$29/month.

To go production, enable ALB + WAF + VPC endpoints + monitoring + compliance:
~$600/month fixed before compute.

---

## 9. Common first-timer mistakes

**"I got an error about insufficient IAM permissions"**

Your deploy user is missing a permission. The error message says which action
is denied. Add the missing permission, or use `AdministratorAccess` for test.

**"Terraform says it can't find my VPC / subnet"**

Make sure `aws_region` matches the region where your VPC exists.

**"The instance is unhealthy / I can't reach OOD"**

The instance may still be bootstrapping (10–15 minutes from base AMI). Check
the bootstrap log via SSM:

```bash
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/ood-bootstrap.log
```

**"ACM certificate is stuck in 'Pending validation'"**

Add the DNS CNAME record from the `acm_certificate_validation_cname` output to
your DNS provider. Wait a few minutes for validation.

**"I can't connect via SSM"**

- VPC endpoints may still be provisioning (2–5 minutes).
- If `enable_vpc_endpoints=false`, the instance needs outbound internet access
  (NAT gateway or internet gateway) to reach SSM.
- Verify the instance has `AmazonSSMManagedInstanceCore` policy (attached by default).

**"The Cognito login page looks generic / I want my university branding"**

Cognito's hosted UI is functional but plain. For institutional branding,
configure Cognito to federate with your SAML IdP — users get redirected to
your university's login page directly. See [docs/identity-guide.md](identity-guide.md).

**"I destroyed the stack but I'm still being charged"**

Check for EBS snapshots, CloudWatch log groups created outside Terraform,
and the Terraform state backend (S3 + DynamoDB). See
[Destroying the Stack](../README.md#destroying-the-stack) for cleanup commands.

---

## 10. Next step: deploy

You now have:

- An AWS account with MFA enabled
- An IAM user with credentials configured in the CLI
- Your VPC ID, subnet ID, and public IP

Go back to the [Quick Start in the README](../README.md#quick-start--test-environment)
and run your first deployment. The test environment with all defaults takes
about 15 minutes and costs less than $2/day.

After OOD is running, see [docs/adapter-guide.md](adapter-guide.md) to connect
your first compute backend.
