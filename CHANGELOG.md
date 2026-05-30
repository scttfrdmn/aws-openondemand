# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `terraform/main.tf`: `enable_alb=true` now fails fast at plan unless `alb_subnet_ids`
  has >=2 subnets in different AZs — an ALB cannot be created in a single AZ, so the prior
  test-environment single-subnet fallback always failed at `aws_lb` creation with an AWS
  ValidationError (#33). Applies to all environments; message tells the operator to set
  `alb_subnet_ids`.

### Fixed
- `scripts/userdata.sh` + `terraform/main.tf`: rewrote `broker.yaml` to the oidc-auth-broker
  v0.3.x nested schema (`server`/`oidc.providers`/`authentication`/`security`/`audit`). The
  old flat top-level schema was rejected with "at least one OIDC provider must be configured"
  and the broker crash-looped (#37). Generates a `token_encryption_key` (new
  `broker_token_key` SSM SecureString) and injects it at boot; added a broker-active boot
  assertion. Dropped the obsolete dynamodb/uid/home keys (no place in the v0.3.x schema).
- `scripts/bake.sh`: install and assert `mod_auth_openidc` so OOD's `update_ood_portal`
  emits the OIDC Apache vhost instead of silently falling back to `need_auth` (#38). Added a
  matching boot-time warning in `userdata.sh` when the generated `ood-portal.conf` has no
  OIDC directives.
- Corrected the oidc-pam integration to match what v0.3.x actually provides
  (scttfrdmn/oidc-pam#87): removed the `/etc/nsswitch.conf` `oidc` wiring (v0.3.x is
  PAM-only — there is no NSS module) and the invalid
  `user_map_cmd: /usr/local/bin/oidc-pam map-user` (no such binary; identity maps via
  `oidc_remote_user_claim` in the Apache/mod_auth_openidc layer). Kept the `pam_oidc.so`
  PAM stack. Bumped default `oidc_pam_version` to v0.3.3. Local-account provisioning
  (which NSS previously implied) is tracked as a separate issue.
- `scripts/userdata.sh` + `scripts/bake.sh`: corrected the oidc-pam download so the
  `oidc-auth-broker` binary actually installs (#34). The release assets are
  `oidc-pam-<ver>-linux-<arch>.tar.gz` with a per-asset `.sha256` sidecar (not
  `oidc-pam_linux_<arch>.tar.gz` / `checksums.txt`), and the tarball extracts to a
  versioned subdir — so the binaries (`oidc-auth-broker`, `oidc-pam-helper`,
  `oidc-admin`) and `pam_oidc.so` are now placed explicitly after extraction. Removed
  dead assumptions (`oidc-pam` binary, `libnss_oidc.so.2`) that v0.3.x does not ship.
  Default `oidc_pam_version` bumped to v0.3.2.
- `scripts/userdata.sh` + `terraform/main.tf`: generate the Apache web-auth layer
  (`ood_portal.yml` + `update_ood_portal`) whenever OIDC is configured, not only when a
  domain is set (#35). With `enable_alb=true` and no domain the portal was stuck on the
  `need_auth` page. `servername` now resolves domain → ALB DNS → instance hostname, with
  the ALB DNS injected via the new `OOD_ALB_DNS` user_data export (aligning with the
  Cognito callback, which already uses the ALB DNS).
- `terraform/main.tf`: ALB-logs bucket policy no longer rejected as malformed (#31).
  Removed the `DenyVersioningDisable` statement — it used a non-existent S3 condition
  key (`s3:VersionStatus`), so S3 rejected the entire policy on PutBucketPolicy and
  blocked every `enable_alb=true` apply. Versioning stays enforced by the
  `aws_s3_bucket_versioning` resource; keeping it on belongs to an SCP/permissions
  boundary or S3 Object Lock, not a bucket-policy condition.
- `scripts/userdata.sh`: SSM Parameter Store values are no longer lost to a pipe
  subshell — the `OOD_*` assignments now persist, so the oidc-auth-broker is actually
  configured and started (#24).
- `scripts/userdata.sh`: open http/https in firewalld at boot — the AMI ships firewalld
  active, so without this the portal was unreachable (`ERR_CONNECTION_REFUSED`) despite
  httpd listening (#29).
- `scripts/userdata.sh` + `terraform`: runtime fallback to install oidc-pam/
  oidc-auth-broker at boot (checksum-verified, via new `oidc_pam_version` variable) when
  the baked AMI is missing the binary, so cloud-native OIDC→PAM identity works regardless
  of AMI vintage (#26).
- `terraform/main.tf`: fail fast at plan when `use_cognito && !enable_alb && domain_name==""` —
  a no-ALB/no-domain deploy has no stable OIDC callback and produced a portal with no
  working browser login. Removed the misleading `localhost` callback fallback (#25).
- `terraform/main.tf`: CloudWatch dashboard apply no longer fails with
  `enable_monitoring = true` (#22). Metric widgets now declare the required `region`
  and explicit `x`/`y`/`width`/`height` layout, and the EFS widget is omitted entirely
  (rather than emitted with an empty `metrics` array) when `enable_efs = false`.

### Added
- Local-account provisioning (#39): a `pam_exec` hook (`ood-provision-user`) +
  `pam_mkhomedir` in `/etc/pam.d/ood` now materialize the local Unix account on first
  login, since oidc-pam v0.3.x is PAM-only and does not create accounts. UIDs are
  allocated from the DynamoDB UID map (`oid-uid-map-<env>`, re-keyed on `username`, atomic
  counter + conditional put) so they are stable across the EFS `/home` and compute nodes.
  Completes the OIDC login chain. Requires `enable_dynamodb_uid` (default on).
- braket compute backend fully wired: `adapters_enabled` accepts `braket`, with a scoped
  IAM policy (`braket:*QuantumTask*` + device discovery + results S3) and an `aws-braket.yml`
  OOD cluster generator. Pairs with the `aws-braket` app bundle in ood-apps (#28).

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
