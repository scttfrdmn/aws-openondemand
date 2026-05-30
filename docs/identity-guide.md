# Identity Guide

This guide covers OIDC provider setup and `oidc-pam` configuration for aws-openondemand.

## Overview

aws-openondemand replaces traditional LDAP/NIS with a cloud-native identity stack:

- **Cognito User Pool** — OIDC identity provider (or bring your own IdP)
- **oidc-pam** — translates OIDC tokens into PAM/NSS Unix identity
- **DynamoDB** — UID mapping table (`oid-uid-map-<env>`) replacing `/etc/passwd`

## Cloud-Native Progression Levels

| Level | Toggle | What it unlocks |
|-------|--------|----------------|
| 0 | (base) | OOD on EC2, local auth |
| 2 | `enable_dynamodb_uid=true` | OIDC sub → UID mapping in DynamoDB |
| 3 | `use_cognito=true` | Cognito OIDC replaces local PAM/LDAP |

## Cognito Setup

When `use_cognito=true` (default), Terraform/CDK creates:
- A Cognito User Pool (`ood-<env>`)
- An App Client with PKCE/code flow
- SSM Parameters with the OIDC client ID, secret, and issuer URL

The `userdata.sh` script reads these SSM parameters at boot and configures:
- `/etc/oidc-auth/broker.yaml` — oidc-auth-broker config
- `/etc/pam.d/ood` — PAM module config (`pam_oidc.so`)

> **PAM-only (oidc-pam v0.3.x).** oidc-pam ships no NSS module, so there is no
> `/etc/nsswitch.conf` `oidc` entry. The broker authenticates an OIDC identity for an
> *existing* local account and provisions `~/.ssh`; it does not resolve
> identity→username via NSS or create the Unix account. Web identity mapping is handled
> by Apache `mod_auth_openidc` via `oidc_remote_user_claim` in `ood_portal.yml`.

### Local account provisioning

Because oidc-pam does not create accounts, OOD materializes them itself on first login
(replacing the dropped NSS/LDAP model). The PAM stack runs, in order:

1. `pam_oidc.so` — authenticate the OIDC identity (broker, device flow).
2. `pam_exec.so /usr/local/bin/ood-provision-user` — allocate a **stable UID** from the
   DynamoDB UID map (`oid-uid-map-<env>`, keyed on `username`, atomic counter +
   conditional put) and `useradd` the account if it doesn't exist. Idempotent.
3. `pam_mkhomedir.so` — create the home directory under `/home` (EFS-backed, so homes and
   UIDs are consistent across the portal and any compute nodes).

UID allocation uses a `__uid_counter__` sentinel item in the table, so the same username
gets the same UID on every instance. Requires `enable_dynamodb_uid = true` (the default);
with it off, the hook no-ops and accounts must be provisioned by other means
(SSSD/directory sync). See `scripts/ood-provision-user.sh`.

## InCommon / Shibboleth Federation

Set `cognito_saml_metadata_url` to your institution's InCommon metadata URL:

```hcl
cognito_saml_metadata_url = "https://incommon.org/federation/metadata/..."
```

Cognito acts as a SAML SP and presents OIDC to OOD — no changes needed to the OOD config.

## oidc-pam Configuration

`/etc/oidc-auth/broker.yaml` (generated at boot):

```yaml
issuer: "https://cognito-idp.us-east-1.amazonaws.com/<pool-id>"
client_id: "<app-client-id>"
client_secret: "<app-client-secret>"
dynamodb_table: "oid-uid-map-test"
aws_region: "us-east-1"
uid_range_min: 10000
uid_range_max: 60000
home_dir_prefix: /home
```

UIDs in the range 10000–60000 are allocated automatically on first login and persisted in DynamoDB.

## Troubleshooting

- **"User not found" errors**: check `systemctl status oidc-auth-broker` and `journalctl -u oidc-auth-broker`
- **UID not assigned**: check DynamoDB table `oid-uid-map-<env>` for the user's OIDC sub
- **PAM rejecting tokens**: verify `OOD_OIDC_ISSUER_URL` in SSM matches the Cognito User Pool endpoint
