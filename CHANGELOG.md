# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `terraform/main.tf`: CloudWatch dashboard apply no longer fails with
  `enable_monitoring = true` (#22). Metric widgets now declare the required `region`
  and explicit `x`/`y`/`width`/`height` layout, and the EFS widget is omitted entirely
  (rather than emitted with an empty `metrics` array) when `enable_efs = false`.

### Security
- `terraform/main.tf`: enabled `drop_invalid_header_fields` on the ALB and added
  `abort_incomplete_multipart_upload` + noncurrent-version expiration lifecycle rules
  to the artifacts, alb_logs, cdn_logs, and ssm_sessions S3 buckets (real hardening
  surfaced once the Security Scan was unblocked).
- `.checkov.yaml`: documented suppressions for the remaining checkov findings that are
  by-design (CMK opt-in via `enable_kms_cmk`, off-by-default feature toggles, public
  research-portal ALB, append-only log buckets, ALB→backend HTTP hop) or scanner false
  positives on count-indexed resources. Added matching inline `#tfsec:ignore` comments
  in `terraform/main.tf`. Result: checkov and tfsec both clean with every finding either
  fixed or justified. No security posture weakened.

## [1.0.2] - 2026-05-29

### Fixed
- `terraform/main.tf`: launch template no longer inlines the ~18 KB `scripts/userdata.sh` into `user_data`, which exceeded EC2's hard 16,384-byte limit and broke every `terraform apply` (#16). The bootstrap scripts are now staged to a dedicated `ood-artifacts-*` S3 bucket, and `user_data` carries only a ~1.5 KB fetch-verify-exec stub (`aws s3 cp` + `sha256sum -c` + `bash`). Works in no-egress / VPC-endpoint-only deployments via the existing S3 gateway endpoint (the `ood-` bucket prefix is required by the endpoint policy).
- `cdk/lib/ood-stack.ts`: converged the CDK layer onto the same S3-staging mechanism (artifact `s3.Bucket` + `BucketDeployment` + stub) for dual-IaC parity. Replaced the prior GitHub-raw `curl` delivery, which (a) was unreachable in no-egress deployments and (b) verified against `.sha256` sidecar files that did not exist in the repo, so the checksum check silently no-op'd. The SHA256 is now computed at synth time from the exact uploaded file, so verification is intrinsic and a mismatch hard-fails the boot.

### Added
- `terraform/main.tf`: `aws_s3_bucket.artifacts` (+ public-access block, SSE, versioning, TLS/encryption-deny policy), `aws_s3_object.userdata` / `aws_s3_object.bake`, and `aws_iam_role_policy.artifacts_read` (scoped `s3:GetObject`/`ListBucket`).
- `terraform/main.tf`: `bake.sh` is now staged and run at boot on the base-AMI path (`enable_packer_ami = false`), closing a latent gap where the Terraform inline path omitted it entirely.
- `CHANGELOG.md`: this file, adopting the Keep a Changelog + SemVer 2.0.0 convention used across the project ecosystem.

## [1.0.1]

### Added
- Security hardening rounds and compute adapter wiring (see git history).

## [1.0.0]

### Added
- Initial release: Open OnDemand on AWS with pluggable compute backends, dual Terraform + CDK IaC, cloud-native identity via oidc-pam, and the cloud-native progression toggle model.
