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

## Scoping job credentials with aws-role-exec

By default, adapters make AWS API calls under the **OOD instance role**. If you want a
job (or a specific adapter) to run under a *narrower, per-PI or per-job* role instead —
with credentials that expire at the end of the job — wrap the call with
[`aws-role-exec`](https://github.com/scttfrdmn/aws-role-exec).

`aws-role-exec` assumes an IAM role via `sts:AssumeRole` and execs a child process with
the temporary credentials in its environment (`syscall.Exec` on Unix). No daemon, no
config files, and nothing written to disk unless you ask for it; the credentials expire
automatically at the end of the session. This is **optional and decoupled** — neither
project depends on the other; it's a composition pattern.

Why it fits OOD/HPC: credential lifetime can be tied to job walltime, scoping is
per-identity rather than instance-wide (which an instance profile can't do), and it's a
single static binary.

**Wrap an adapter's submit (cluster YAML).** Point the cluster's `script:` at
`aws-role-exec` and pass the real adapter as the child after `--`, so the adapter's AWS
calls run under the assumed role:

```yaml
# /etc/ood/config/clusters.d/aws-batch.yml (excerpt)
v2:
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/bin/aws-role-exec"
      args:
        - "--role-arn=arn:aws:iam::123456789012:role/ood-pi-smithlab"
        - "--duration=8h"
        - "--"
        - "/usr/local/lib/ood-adapters/ood-aws-batch-adapter"
        - submit
        - "--region=us-west-2"
```

(The OOD instance role must be allowed to `sts:AssumeRole` the target role, and the
target role's trust policy must permit it.)

**Slurm / PBS prolog** (ParallelCluster jobs needing scoped AWS access):

```bash
aws-role-exec --role-arn arn:aws:iam::123456789012:role/researcher-s3-read -- srun "$@"
```

**Other patterns** (from the `aws-role-exec` README):

```bash
# Export into the current shell
eval "$(aws-role-exec --role-arn arn:... --format env)"

# Write a ~/.aws/credentials-style file for tools that read it
aws-role-exec --role-arn arn:... --format credentials-file --output-file /tmp/job/.aws/credentials
```

Flags: `--role-arn` (required), `--duration` (default 1h, max 12h), `--session-name`,
`--region`, `--format` (`env` | `json` | `credentials-file`), `--output-file`. See the
[aws-role-exec README](https://github.com/scttfrdmn/aws-role-exec) for the full reference.

## Staging local data to/from S3 with ood-staging-wrapper

The S3-native backends (SageMaker Training, EMR Serverless, HealthOmics) expect job inputs
and outputs in S3. Researchers working on a shared cluster filesystem (EFS, Lustre, NFS)
think in local paths. [`ood-staging-wrapper`](https://github.com/scttfrdmn/ood-staging-wrapper)
bridges that gap: it uploads local input paths to S3 before submission, rewrites the job
spec to the S3 URIs, runs the inner adapter, and on completion syncs the results back to a
local directory.

Like aws-role-exec, this is **optional and decoupled** — neither repo depends on the other;
you compose them by prefixing an adapter's `clusters.d` `submit`/`status` with the wrapper
and passing the real adapter after `--`.

```yaml
# /etc/ood/config/clusters.d/aws-sagemaker-training.yml (excerpt)
v2:
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/bin/ood-staging-wrapper"
      args:
        - "submit"
        - "--staging-bucket=my-ood-staging"
        - "--"
        - "/usr/local/lib/ood-adapters/ood-sagemaker-training-adapter"
        - "submit"
        - "--region=us-west-2"
```

On `submit` the wrapper uploads local input fields (`input`, `input_path`, `input_dir`,
`data`, `data_path`) to `s3://<bucket>/<prefix>/<job>/input/` and rewrites them; output
fields (`output`, `output_path`, `results`, …) are rewritten to the staged S3 output URI and
synced back to the local path on a `completed` `status`. Fields already holding an `s3://`
value are left untouched.

Flags: `--staging-bucket` (required), `--staging-prefix` (default `ood-staging`),
`--sync-tool` (`s5cmd` default, or `aws`), `--cleanup` (default true). See the
[ood-staging-wrapper README](https://github.com/scttfrdmn/ood-staging-wrapper) for details.

**Required IAM.** The OOD instance role must be able to read/write the staging bucket. This
is bring-your-own-bucket — aws-openondemand does not provision it — so add a policy scoped to
your bucket:

```json
{
  "Effect": "Allow",
  "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
  "Resource": ["arn:aws:s3:::my-ood-staging", "arn:aws:s3:::my-ood-staging/*"]
}
```

(`s3:DeleteObject` is only needed when `--cleanup` is enabled, which is the default.)

## Orchestrating multi-stage pipelines with Step Functions

A single adapter maps one OOD job to one AWS backend. Some research workflows are
*multi-stage* — preprocess on Fargate, align on HealthOmics, variant-call on Batch, annotate
on Lambda — with retries and branching between stages. Rather than chaining adapters with
fragile client-side glue, model the whole pipeline as an **AWS Step Functions state machine**
and submit it through the [`ood-stepfunctions-adapter`](https://github.com/scttfrdmn/ood-stepfunctions-adapter):
OOD starts one execution and polls `DescribeExecution`, so the user sees a single job while
the state machine owns the multi-stage lifecycle.

The adapter already works (`submit` → `StartExecution`, `status` → `DescribeExecution`,
`delete` → `StopExecution`). What this adds is a **library of reference state machines** plus
the deployment recipe — see [`examples/state-machines/`](../examples/state-machines/):

| Pipeline | Stages (backend) |
| --- | --- |
| `genomics-pipeline.asl.json` | preprocess (Fargate) → align (HealthOmics) → variant-call (Batch GPU) → annotate (Lambda) |
| `ml-eval-pipeline.asl.json` | batch inference (Bedrock) → poll → score (EMR Serverless) |

Each stage targets the same AWS service an existing OOD adapter uses, so the backends are
ones an adapter-enabled deployment already has.

### Building & deploying a custom state machine

1. **Name it `ood-*`.** The portal's Step Functions IAM (the `stepfunctions_adapter` policy
   in `terraform/main.tf` and the matching block in `cdk/lib/ood-stack.ts`) scopes
   `states:StartExecution` to `stateMachine:ood-*` and `DescribeExecution` to
   `execution:ood-*:*`. A state machine outside that prefix is rejected by the portal role.

2. **Target the adapter backends in your Task states.** Step Functions' AWS SDK service
   integrations (`arn:aws:states:::aws-sdk:omics:startRun`, `:::bedrock:createModelInvocationJob`,
   `:::emrserverless:startJobRun`) and the optimized integrations (`:::batch:submitJob.sync`,
   `:::ecs:runTask.sync`, `:::lambda:invoke`) let one definition span every backend the
   adapters cover. The state machine's **execution role** (not the OOD instance role) needs
   permission for whatever it invokes, plus `iam:PassRole` where the service requires it.

3. **Create it** (`aws stepfunctions create-state-machine --name ood-... --definition file://...`),
   then submit through the `AWS Step Functions` app bundle (paste the ARN + input JSON) or a
   pre-filled per-pipeline bundle.

4. **Pass parameters via the execution input.** Definitions read `$.field` from the input
   JSON the form supplies (input/output S3 URIs, workflow IDs, role ARNs).

See [`examples/state-machines/README.md`](../examples/state-machines/README.md) for the full
deploy walkthrough and the per-pipeline input keys.
