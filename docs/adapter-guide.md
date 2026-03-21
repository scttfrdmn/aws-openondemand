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
