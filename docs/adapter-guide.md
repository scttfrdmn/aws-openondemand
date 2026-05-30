# Compute Adapter Guide

This guide covers configuring compute backends for aws-openondemand.

## Overview

OOD compute adapters translate OOD job submissions into AWS compute API calls.
Each adapter is a standalone Go binary deployed alongside OOD.

| Adapter | `adapters_enabled` value | Binary | Use case |
|---------|--------------------------|--------|----------|
| AWS Batch | `"batch"` | `ood-aws-batch-adapter` | Container-based HPC jobs |
| SageMaker | `"sagemaker"` | `ood-sagemaker-adapter` | Interactive ML sessions |
| EC2 | `"ec2"` | `ood-ec2-adapter` | Single-node compute |
| ParallelCluster | (separate repo) | SSH/SLURM | Traditional HPC clusters |

## Enabling Adapters

In `terraform/environments/test.tfvars`:

```hcl
adapters_enabled = ["batch"]           # Portal-only (default: [])
adapters_enabled = ["batch", "ec2"]    # Multiple adapters
```

When an adapter is listed in `adapters_enabled`, Terraform creates:
- IAM policies on the OOD instance role for that service's API
- The corresponding AWS infrastructure (Batch compute environment, SageMaker domain, etc.)
- A cluster YAML file in `/etc/ood/config/clusters.d/` at boot

## Deploying adapter binaries & app bundles

Terraform wires up the IAM, infrastructure, and cluster YAML, but the adapter
**binaries** (`/usr/local/lib/ood-adapters/ood-*-adapter`) and the **app bundles**
(`/var/www/ood/apps/sys/aws-*`) are artifacts you install onto the running portal
instance.

**Stage them into the existing artifacts bucket — not a new bucket.** The OOD instance
role's S3 read is scoped to exactly `ood-artifacts-<env>-*`
(`aws_iam_role_policy.artifacts_read`), and when `enable_vpc_endpoints=true` the S3
gateway endpoint policy further restricts the role to `arn:aws:s3:::ood-*`. A separate
scratch bucket (especially one not `ood-`prefixed) is therefore **unreadable** by the
instance — there is no IAM grant for it.

From a workstation with deploy credentials, upload under a prefix in the artifacts
bucket. The bucket policy enforces TLS + SSE, so pass `--sse AES256`:

```bash
ARTIFACTS=$(terraform -chdir=terraform output -raw artifacts_bucket)   # ood-artifacts-<env>-...

# Adapter binaries
aws s3 cp ood-aws-batch-adapter "s3://${ARTIFACTS}/adapters/ood-aws-batch-adapter" --sse AES256

# App bundles (tar a bundle dir from ood-apps/apps/)
aws s3 cp aws-batch.tar.gz "s3://${ARTIFACTS}/ood-apps/aws-batch.tar.gz" --sse AES256
```

Then pull them onto the instance over SSM Session Manager (no SSH):

```bash
aws ssm start-session --target "$INSTANCE_ID"
# on the instance:
sudo aws s3 cp "s3://${ARTIFACTS}/adapters/ood-aws-batch-adapter" \
  /usr/local/lib/ood-adapters/ood-aws-batch-adapter
sudo chmod 0755 /usr/local/lib/ood-adapters/ood-aws-batch-adapter

sudo aws s3 cp "s3://${ARTIFACTS}/ood-apps/aws-batch.tar.gz" /tmp/aws-batch.tar.gz
sudo tar -xzf /tmp/aws-batch.tar.gz -C /var/www/ood/apps/sys/
```

> If you genuinely need a dedicated staging bucket, name it with the `ood-` prefix
> (so the S3 endpoint policy permits it) **and** add an IAM read grant for it to the
> instance role — otherwise the pull will be denied.

## AWS Batch Adapter

Prerequisites:
- `adapters_enabled = ["batch"]`
- A VPC with private subnets (for Batch compute nodes)

The Terraform creates a SPOT Batch compute environment with up to 256 vCPUs.
Job definitions are submitted by users via the OOD job composer.

Binary: [`github.com/scttfrdmn/ood-aws-batch-adapter`](https://github.com/scttfrdmn/ood-aws-batch-adapter)

## SageMaker Adapter

Prerequisites:
- `adapters_enabled = ["sagemaker"]`
- Private subnets (SageMaker Domain requirement)

Creates a SageMaker Domain + default user profile. The adapter generates
presigned Studio URLs for interactive session access through OOD.

Binary: [`github.com/scttfrdmn/ood-sagemaker-adapter`](https://github.com/scttfrdmn/ood-sagemaker-adapter)

## EC2 Adapter

Prerequisites:
- `adapters_enabled = ["ec2"]`
- EC2 Launch Template created separately (or use the default)

Launches single EC2 instances from a Launch Template for on-demand compute.
Suitable for memory-intensive single-node jobs.

Binary: [`github.com/scttfrdmn/ood-ec2-adapter`](https://github.com/scttfrdmn/ood-ec2-adapter)

## ParallelCluster Reference

For traditional SLURM-based HPC clusters, see
[`github.com/scttfrdmn/ood-pcluster-ref`](https://github.com/scttfrdmn/ood-pcluster-ref).

This is a reference configuration repo — not managed by this Terraform.
ParallelCluster clusters appear as additional entries in `/etc/ood/config/clusters.d/`.
