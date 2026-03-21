# Cost Guide

Approximate monthly costs by toggle (us-east-1, March 2026).

## Baseline

| Component | Always On | ~$/mo |
|-----------|-----------|-------|
| EC2 t3.medium (minimal profile) | yes | $30 |
| SSM Session Manager | yes | $0 |
| CloudWatch bootstrap logs | yes | <$1 |

## Toggle Costs

| Toggle | Resource | ~$/mo |
|--------|----------|-------|
| `enable_efs=true` | EFS (elastic, single-AZ) | $3–5 |
| `enable_dynamodb_uid=true` | DynamoDB (on-demand) | $1 |
| `use_cognito=true` | Cognito (free tier covers most uses) | $0–5 |
| `enable_alb=true` | ALB | $20 |
| `enable_waf=true` | WAF v2 (requires ALB) | $10 + $0.60/M requests |
| `enable_vpc_endpoints=true` | Interface endpoints (5×) | $36 |
| `enable_monitoring=true` | CloudWatch logs + alarms | $5–10 |
| `enable_session_cache=true` | ElastiCache t3.micro | $15 |
| `enable_s3_browser=true` | S3 bucket | $1–5 (data-dependent) |
| `enable_fsx=true` | FSx Lustre 1.2 TB SCRATCH_2 | $140 |
| `enable_cdn=true` | CloudFront | $1 + $0.0085/GB |
| `enable_compliance_logging=true` | CloudTrail + Flow Logs | $5–10 |
| `enable_backup=true` | AWS Backup | ~$5/100 GB |
| `enable_kms_cmk=true` | KMS CMK | $1 + $0.03/10K API calls |

## Profile Upgrade Costs

| Profile change | Additional EC2 cost |
|---------------|---------------------|
| minimal → standard | +$110/mo |
| minimal → graviton | +$85/mo |
| minimal → spot | −$20/mo (variable) |
| minimal → large | +$250/mo |

## Common Deployment Totals

| Use case | Toggles | ~$/mo |
|----------|---------|-------|
| Lab/test | minimal, EFS, DynamoDB, Cognito, no ALB | $35 |
| Department | graviton, ALB, WAF, monitoring, S3 browser | $235 |
| Production | standard/spot, all features, compliance, backup, KMS | $600 |

## Cost Reduction Tips

1. Use `graviton` profile — ~20% cheaper than x86 equivalent
2. Use `spot` profile with `enable_session_cache=true` — 70-80% cheaper EC2
3. Disable `enable_vpc_endpoints` if you have an Internet Gateway (default VPCs do)
4. Set `enable_efs_one_zone=true` for test/staging — 47% cheaper EFS
5. Disable `enable_fsx` — only needed for /scratch-intensive workflows
