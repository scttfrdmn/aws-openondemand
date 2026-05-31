# Reference Step Functions state machines for OOD

These are curated [Amazon States Language](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-amazon-states-language.html)
(ASL) definitions for multi-stage research pipelines that run **behind a single OOD job**.
The user submits one job through the [`ood-stepfunctions-adapter`](https://github.com/scttfrdmn/ood-stepfunctions-adapter)
cluster (or the `AWS Step Functions` app bundle), OOD polls `DescribeExecution`, and the
state machine fans the work across the same AWS backends the other OOD adapters target —
handling retries, branching, and parallelism that a single adapter can't.

This turns OOD from a *job* portal into a *workflow* portal **without changing the adapter
interface** — the `ood-stepfunctions-adapter` already does `StartExecution`/`DescribeExecution`;
this directory is the state-machine library + deployment recipe.

## The library

| File | Pipeline | Stages (backend) |
| --- | --- | --- |
| `genomics-pipeline.asl.json` | Genomics secondary analysis | preprocess (Fargate) → align (HealthOmics) → variant-call (Batch GPU) → annotate (Lambda) |
| `ml-eval-pipeline.asl.json` | LLM evaluation | batch inference (Bedrock) → poll → score (EMR Serverless) |

Each stage targets the **same AWS service an existing OOD adapter uses**, so a site that has
enabled those adapters already has the backends these workflows orchestrate.

## Deploy

1. **Name it `ood-*`.** The portal's Step Functions IAM (see `terraform/main.tf` /
   `cdk/lib/ood-stack.ts`, the `stepfunctions` adapter policy) scopes `states:StartExecution`
   to `stateMachine:ood-*`. A state machine named outside that prefix will be rejected.

2. **Replace the placeholders.** Each definition uses placeholder ARNs/IDs
   (`REGION`, `ACCOUNT`, job queues, workflow IDs, task definitions, Lambda/role ARNs).
   Substitute your own — they are intentionally not real.

3. **Create the state machine** with a role that can invoke the downstream services
   (`ecs:RunTask`, `omics:StartRun`, `batch:SubmitJob`, `lambda:InvokeFunction`,
   `bedrock:CreateModelInvocationJob`, `emr-serverless:StartJobRun`, plus the `iam:PassRole`
   each requires). Example:

   ```bash
   aws stepfunctions create-state-machine \
     --name ood-genomics-pipeline \
     --definition file://genomics-pipeline.asl.json \
     --role-arn arn:aws:iam::ACCOUNT:role/ood-sfn-execution
   ```

4. **Point OOD at it.** Either submit through the `aws-stepfunctions` app bundle (paste the
   state machine ARN + an input JSON), or pre-fill the ARN in a dedicated bundle (see
   `ood-apps/apps/aws-stepfunctions-genomics`).

## Input

Each pipeline reads its parameters from the execution **input JSON** (the `Input (JSON)`
field in the app form), referenced as `$.field` in the definition. See the `"Comment"` at
the top of each file and the per-state `Parameters` for the expected keys (input/output S3
URIs, workflow IDs, role ARNs, etc.).

## Why a state machine instead of chaining adapters

- **One status to the user.** OOD shows a single job; the state machine owns the multi-stage
  lifecycle.
- **Retries & error branches** (`Retry`, `Catch`, `Choice`) live in the definition, not in
  fragile client-side glue.
- **Mixed backends in one flow** — HPC-style steps (Batch/Fargate) alongside managed services
  (HealthOmics/Bedrock/EMR/Lambda) that no single adapter spans.

See [docs/adapter-guide.md](../../docs/adapter-guide.md#orchestrating-multi-stage-pipelines-with-step-functions)
for the full write-up.
