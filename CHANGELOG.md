# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- PUN 404 after a successful login (#75). With `username_attributes = ["email"]`, the
  `cognito:username` claim chosen in #64 is the Cognito `sub` UUID, which `useradd` rejects as
  an invalid name → no local account → `/pun/sys/dashboard` 404s. Switched the web identity
  to the **email local-part**: `oidc_remote_user_claim: "email ^([^@]+)@"` uses
  mod_auth_openidc's two-argument regex form (ood-portal-generator emits the value verbatim)
  to map `demo@example.com` → `demo` — a useradd-valid name that matches nginx_stage's
  `user_regex`. Applied in both `userdata.sh` and `bake.sh`; the provisioning hook receives
  the same REMOTE_USER via `--user`, so #39/#67/#71 stay consistent. The oidc-auth-broker
  (SSH/PAM path, no regex support) now keys on `email`. Single-domain assumption: same
  local-part across two domains would collide.
- Cognito `redirect_mismatch` at the start of login (#73). The #64 change added
  `X-Forwarded-Port` to `OIDCXForwardedHeaders`, so mod_auth_openidc began appending the
  ALB's `:443` to the redirect_uri (`https://host:443/oidc`) — but the Cognito callback
  registered by Terraform/CDK is port-less (`https://host/oidc`), and Cognito matches the
  redirect_uri by exact string, so login failed before authentication. Dropped
  `X-Forwarded-Port`, keeping only `X-Forwarded-Proto` (which is what fixes the http→https
  scheme; `:443` is the https default and adds nothing). The emitted redirect_uri is now
  byte-identical to the registered callback.
- Web-login account provisioning is now wired through the correct OOD config and mechanism
  (#71). `pre_hook_root_cmd` is a per-invocation `nginx_stage pun` CLI option, not a global
  `nginx_stage.yml` key — so both #67 (right key, wrong file) and #69 (nginx_stage key) were
  rejected as invalid options and the hook never ran. The supported path (verified against
  OOD 4.0.10 source) is `ood_portal.yml`: set `pun_pre_hook_root_cmd` (+ `pun_pre_hook_exports`)
  there → ood-portal-generator emits `SetEnv OOD_PUN_PRE_HOOK_ROOT_CMD` into the Apache vhost
  → mod_ood_proxy passes `--pre-hook-root` to `nginx_stage pun` at PUN staging. Moved the keys
  to `ood_portal.yml`, removed the ineffective `nginx_stage.yml` block, and added a boot
  assertion that the generated `ood-portal.conf` actually carries the `OOD_PUN_PRE_HOOK_ROOT_CMD`
  SetEnv.
- Corrected the nginx_stage pre-hook key so #67 actually takes effect (#69). The #67 fix used
  `pun_pre_hook_root_cmd`, but OOD 4.0.x's nginx_stage option is `pre_hook_root_cmd` (no
  `pun_` prefix) — the prefixed key is rejected as an invalid option and silently ignored, so
  provisioning still never ran on web login. Renamed to `pre_hook_root_cmd` and removed the
  `pun_pre_hook_exports` block entirely (nginx_stage 4.0.x has no exports option; the hook
  receives only `--user`, and the helper already reads the UID table/region from
  `/etc/oidc-auth/provision.env`). Added a boot assertion that fails loudly if nginx_stage
  rejects a config option, so a wrong key name can't silently slip through again.
- Local accounts are now provisioned on **web** login, so the PUN starts (#67). The #39
  provisioning hook was wired only as a `session` `pam_exec` entry in `/etc/pam.d/ood`, but
  OOD's web-auth path (mod_auth_openidc → mod_ood_proxy → nginx_stage) never opens a PAM
  session — so the hook never fired on browser login, no Unix account was created, and
  `nginx_stage` failed with "can't find user" (generic OOD error page after a fully
  successful OIDC login). Wired `nginx_stage`'s `pun_pre_hook_root_cmd` (runs as root before
  the PUN starts, with the mapped user) to `ood-provision-user`, and taught the script to
  accept `--user <name>` in addition to `$PAM_USER`. The web path also creates the home dir
  directly (`useradd --create-home`) since `pam_mkhomedir` doesn't run there. The DynamoDB
  UID-allocation logic is unchanged; only the trigger moved into the web-login lifecycle.
- OIDC callback no longer 400s on a missing identity claim (#64). The portal keyed on the
  `preferred_username` claim, but the Cognito pool signs users in by email
  (`username_attributes = ["email"]`) and never emits `preferred_username`, so
  mod_auth_openidc could not set the remote user → HTTP 400 after a successful auth. Switched
  the identity claim to **`cognito:username`** (always present in the Cognito ID token),
  consistently across `scripts/userdata.sh` (`oidc_remote_user_claim` + the broker
  `username_claim`) and `scripts/bake.sh`, keeping it in sync with the #39 `ood-provision-user`
  hook that derives the local account name from it.
- Quieted mod_auth_openidc forwarded-header warnings (#64, secondary): the #60 fix listed
  `X-Forwarded-Host`, which the ALB does not send. `OIDCXForwardedHeaders` now lists exactly
  what the ALB sends — `X-Forwarded-Proto X-Forwarded-Port` (the Proto header is what fixes
  the http→https redirect_uri).

### Added
- Two meta-adapters wired into `adapters_enabled` (TF + CDK): `router` (#6) dispatches by
  job-spec content to the best AWS backend, and `burst` (#5) submits locally until the local
  scheduler queue is busy then overflows to AWS. Both are dispatchers that shell out to the
  backend adapters and carry **no IAM of their own** — the backends they route to supply the
  permissions, so enable those too. `userdata.sh` generates `aws-router.yml` / `aws-burst.yml`
  cluster configs. Pairs with the new
  [`ood-router-adapter`](https://github.com/scttfrdmn/ood-router-adapter) and
  [`ood-burst-adapter`](https://github.com/scttfrdmn/ood-burst-adapter).

### Fixed
- ALB target group is no longer permanently unhealthy once OIDC is wired (#59). The health
  check on `/pun/sys/dashboard` now accepts `200,301,302` (TF `matcher` / CDK
  `healthyHttpCodes`) — an authenticated dashboard returns a 301/302 auth redirect to an
  unauthenticated prober, which still proves Apache + the OIDC vhost are alive. Previously
  the `200`-only matcher marked the target unhealthy and the ALB returned 502/503.
- OIDC login behind the ALB no longer fails on a scheme/path mismatch (#60). Two fixes,
  both in TF + CDK: (1) `scripts/userdata.sh` adds `oidc_settings.OIDCXForwardedHeaders` so
  mod_auth_openidc honors the ALB's `X-Forwarded-Proto` and builds an **https** redirect_uri
  (TLS is terminated at the ALB; Apache sees plain HTTP and otherwise emitted `http://`,
  which Cognito rejects); (2) the Cognito callback URL is reconciled to `/oidc` (OOD's
  actual `oidc_uri` / `OIDCRedirectURI`), not `/oidc/callback`, so the registered callback
  matches the redirect_uri Cognito receives.

### Added
- Bedrock batch-inference backend wired as a compute adapter (#11): `adapters_enabled`
  accepts `bedrock`, with a scoped IAM policy (`bedrock:*ModelInvocationJob*` +
  `iam:PassRole` to `bedrock.amazonaws.com`) and an `aws-bedrock.yml` OOD cluster generator.
  Pairs with the new [`ood-bedrock-adapter`](https://github.com/scttfrdmn/ood-bedrock-adapter)
  (`CreateModelInvocationJob`/`GetModelInvocationJob`/`StopModelInvocationJob`) and the
  `aws-bedrock` app bundle in ood-apps. Landed in both Terraform and CDK (dual-IaC parity).
- `docs/adapter-guide.md` + `README.md`: documented
  [`ood-staging-wrapper`](https://github.com/scttfrdmn/ood-staging-wrapper) — a transparent
  S3 data-staging layer that wraps an inner adapter so S3-native backends (SageMaker
  Training, EMR Serverless, HealthOmics) accept local filesystem paths. Covers the
  `clusters.d` wiring, flags, and the bring-your-own-bucket instance-role IAM. Optional,
  decoupled composition pattern — no IaC bucket is provisioned (#7).

## [0.1.0] - 2026-05-30

First tagged pre-production release. This is a feasibility / pre-1.0 project: the public
interface (Terraform variables, CDK context, cluster YAML, deploy flow) is still evolving
and may change without a major-version bump until a `1.0.0` stability commitment is made.

Earlier `1.0.x` entries (1.0.0, 1.0.1, 1.0.2) were premature version numbers from before
this convention was adopted; their content is consolidated below. There was never a stable
public release at those numbers — only a single `v1.0.1` tag, now removed. Full detail is in
the git history.

### Fixed
- `scripts/userdata.sh`: add the `auth:` block to the generated `ood_portal.yml` whenever
  OIDC is configured (#52). ood-portal-generator only emits the mod_auth_openidc vhost when
  its `auth?` predicate is true (the `auth` list is non-empty); with the list missing, a
  fully-correct OIDC config (right `oidc_*` keys, loaded module, live broker, ALB-DNS
  servername) still fell back to the `need_auth` page and nobody could log in. The
  post-`update_ood_portal` assertion now checks the rendered `ood-portal.conf` carries the
  `openid-connect` AuthType (not a loose `oidc` substring), so both failure modes — missing
  module (#38) and missing `auth:` block — are caught loudly. Shared script, so the fix
  applies to both the Terraform and CDK deploy paths.
- `terraform/main.tf` + `scripts/userdata.sh`: fixed a `set -u` abort introduced by #39 —
  the provisioning block referenced `${ARTIFACT_BUCKET}`, which the launch-template stub set
  but did not export, so the fetched userdata.sh hit 'unbound variable' and aborted bootstrap
  before the broker unit and ood_portal.yml (#49). Export ARTIFACT_BUCKET in the stub and
  guard the reference (`:-`) so a missing value warns instead of failing the boot.
- `packer/ood.pkr.hcl`: `associate_public_ip_address` is now a `build_public_ip` variable
  (default false) instead of a hardcoded false (#45). IGW-only/default VPCs (single public
  subnet, no NAT) can pass `-var build_public_ip=true` to bake the AMI from a host outside
  the VPC; `ssh_interface` follows the same flag. The secure private-subnet+NAT default is
  unchanged.
- `terraform/main.tf`: `enable_alb=true` now fails fast at plan unless `alb_subnet_ids`
  has >=2 subnets in different AZs — an ALB cannot be created in a single AZ, so the prior
  test-environment single-subnet fallback always failed at `aws_lb` creation with an AWS
  ValidationError (#33). Applies to all environments; message tells the operator to set
  `alb_subnet_ids`.
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
- CDK parity (`cdk/lib/ood-stack.ts`): brought the CDK stack back in line with the
  Terraform source of truth (#51). Added the EMR Serverless application and ECS/Fargate
  cluster, the six previously-missing adapter IAM blocks (omics, emr, sagemaker-training,
  fargate, stepfunctions, braket), the `#37` `broker_token_key` SSM **SecureString** (via a
  custom resource — CloudFormation cannot create a SecureString natively), the `#22`
  CloudWatch dashboard (CPU + conditional EFS widgets), `#31` ALB access logging, and the
  adapter/infra `CfnOutput`s (`BatchJobQueueArn`, `SageMakerDomainId`, `EmrApplicationId`,
  `EcsClusterArn`, `ArtifactsBucket`). Also ported `#39` (uid map re-keyed on `username` +
  provision-user staging), `#49` (`ARTIFACT_BUCKET` exported into user_data), `#25` (the
  ALB is created before the Cognito client so its DNS is the OIDC callback host, with a
  fail-fast guard for the no-ALB/no-domain Cognito case), and `#33` (the >=2-AZ-subnet ALB
  guard). The single intentional divergence: the CDK `broker_token_key` re-generates on each
  synth (CDK has no equivalent of Terraform's stateful `random_password`); benign for a
  token-encryption key — it only forces re-authentication, documented inline.
- `docs/adapter-guide.md` + `README.md`: documented how to scope adapter/job credentials
  with [`aws-role-exec`](https://github.com/scttfrdmn/aws-role-exec) — wrap an adapter's
  cluster-YAML submit (or a Slurm/PBS prolog) so AWS calls run under a narrower, expiring
  per-PI/per-job role instead of the instance role. Optional, decoupled composition pattern
  (closes the documentation half of #10; the tool itself already exists and is published).
- `docs/adapter-guide.md` + `terraform/outputs.tf`: documented how to deploy adapter
  binaries / app bundles — stage them into the existing `ood-artifacts-<env>-*` bucket
  (the instance role and S3 gateway endpoint only permit `ood-*`/the artifacts bucket, so a
  separate scratch bucket is unreadable), pull via SSM. Added an `artifacts_bucket` output
  so the workflow is runnable (#27).
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
- `terraform/main.tf`: launch template no longer inlines the ~18 KB `scripts/userdata.sh` into `user_data`, which exceeded EC2's hard 16,384-byte limit and broke every `terraform apply` (#16). The bootstrap scripts are now staged to a dedicated `ood-artifacts-*` S3 bucket, and `user_data` carries only a ~1.5 KB fetch-verify-exec stub (`aws s3 cp` + `sha256sum -c` + `bash`). Works in no-egress / VPC-endpoint-only deployments via the existing S3 gateway endpoint (the `ood-` bucket prefix is required by the endpoint policy).
- `cdk/lib/ood-stack.ts`: converged the CDK layer onto the same S3-staging mechanism (artifact `s3.Bucket` + `BucketDeployment` + stub) for dual-IaC parity. Replaced the prior GitHub-raw `curl` delivery, which (a) was unreachable in no-egress deployments and (b) verified against `.sha256` sidecar files that did not exist in the repo, so the checksum check silently no-op'd. The SHA256 is now computed at synth time from the exact uploaded file, so verification is intrinsic and a mismatch hard-fails the boot.

### Added
- Open OnDemand on AWS with pluggable compute backends (batch, sagemaker, sagemaker-training, ec2, omics, emr, fargate, stepfunctions, braket), dual Terraform + CDK IaC producing identical infrastructure, cloud-native identity via oidc-pam, and the cloud-native progression toggle model. (Foundational work from the earlier 1.0.0/1.0.1 entries — security hardening rounds and the initial compute-adapter wiring; see git history.)
- `terraform/main.tf`: `aws_s3_bucket.artifacts` (+ public-access block, SSE, versioning, TLS/encryption-deny policy), `aws_s3_object.userdata` / `aws_s3_object.bake`, and `aws_iam_role_policy.artifacts_read` (scoped `s3:GetObject`/`ListBucket`).
- `terraform/main.tf`: `bake.sh` is now staged and run at boot on the base-AMI path (`enable_packer_ami = false`), closing a latent gap where the Terraform inline path omitted it entirely.
- `CHANGELOG.md`: adopting the Keep a Changelog + SemVer 2.0.0 convention used across the project ecosystem.
