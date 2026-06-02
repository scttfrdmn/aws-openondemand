# Identity Guide

This guide covers identity configuration for aws-openondemand — how the portal authenticates
users and resolves their POSIX accounts.

> **Designing a deployment?** Read [reference-architecture.md](reference-architecture.md)
> first — it explains the model and the trade-offs. This guide is the operator how-to.

## Overview

OOD **defers identity**; it does not manufacture accounts. Two concerns, both pointed at a
**directory** (Active Directory / LDAP):

- **Web auth** — OOD's bundled **Dex** authenticates users via an **LDAP connector** bound to
  the directory. `ood-portal-generator` reads the `dex:` block in `ood_portal.yml` and emits
  the Apache `mod_auth_openidc` vhost automatically.
- **POSIX identity** — **SSSD/NSS** resolves `getpwnam` against the **same** directory, and
  `oddjob-mkhomedir` creates homes on first login. No account creation at login time.

Because both use the same directory, the OIDC username **equals** the Unix account by
construction — no claim-to-username mapping.

This replaced the previous Cognito + `oidc-pam` + DynamoDB-UID + login-time-`useradd` stack,
which could not work on OOD 4.x (`nginx_stage` resolves the user before any provisioning hook
runs). See the reference architecture's *Migration & cutover* section for the history.

## Two modes (see reference-architecture.md §2)

| Mode | Directory | Toggles |
|------|-----------|---------|
| **Eval** (single account) | in-account **AWS Simple AD**, provisioned for you | `enable_directory=true`, `use_sssd=true` |
| **Production** (bring your own) | your existing AD / LDAP | `use_sssd=true`, `directory_ldap_uri=ldaps://...` (+ bind/search vars) |

## Configuration

| Variable | Purpose |
|----------|---------|
| `use_sssd` | enable SSSD/NSS + the Dex LDAP connector on the OOD host |
| `enable_directory` | (eval only) provision an in-account Simple AD and wire to it |
| `directory_ldap_uri` | LDAP(S) endpoint Dex + SSSD bind to (BYO; the mode selector) |
| `directory_name` | the AD / SSSD domain (e.g. `corp.example.com`) |
| `directory_bind_dn` / `directory_user_base_dn` / `directory_user_filter` | Dex userSearch coordinates |
| `directory_username_attr` | attribute used as the OOD/Unix username (default `sAMAccountName` — a bare name that matches the POSIX account) |
| *(bind password)* | Secrets Manager `ood/<env>/directory-bind-password` (operator-populated for BYO; auto-filled in eval) |

## How it works at boot

`userdata.sh` reads the directory coordinates from SSM (`/ood/<env>/directory_*`), fetches the
bind password from Secrets Manager, and:

1. Joins the host to the directory and enables SSSD (`authselect select sssd with-mkhomedir`),
   so `getpwnam` resolves users and `oddjobd` creates homes under `/home` on first login.
2. Writes the `dex:` block (with the LDAP connector) into `/etc/ood/config/ood_portal.yml` and
   runs `update_ood_portal`, which emits the Apache OIDC vhost and starts `ondemand-dex`.

There is **no** `useradd`, no DynamoDB UID map, no `oidc-auth-broker`, and no hand-maintained
`oidc_*` Apache config — the directory is the single source of truth and the generator owns the
vhost.

## Username alignment

The OOD username comes from the Dex connector's `userSearch.username` attribute
(`directory_username_attr`, default `sAMAccountName`). Use a bare-name attribute (not
`userPrincipalName`/email) so REMOTE_USER matches the POSIX account SSSD resolves. UIDs come
from the directory (SSSD `ldap_id_mapping` for AD, or the directory's `uidNumber`), so they are
stable across the portal and any compute nodes that read the same directory.

## Per-job AWS credentials

To give a *job* narrower, expiring AWS credentials under a per-PI/per-job IAM role instead of
the instance role, see
[Scoping job credentials with aws-role-exec](adapter-guide.md#scoping-job-credentials-with-aws-role-exec).
(Per-user cross-account `AssumeRole` for the compute adapters is a planned follow-up — see
[reference-architecture.md](reference-architecture.md) §4.)

## Troubleshooting

- **"can't find user" / PUN won't start**: `getpwnam` isn't resolving. Check
  `id <user>` and `systemctl status sssd`; verify the host joined the realm (`realm list`) and
  the directory is reachable on LDAP(S).
- **Login fails at Dex**: check `journalctl -u ondemand-dex`; verify the bind DN/password and
  `userSearch` baseDN/filter match your directory.
- **Generator fell back to need_auth**: `grep openid-connect /etc/httpd/conf.d/ood-portal.conf`
  — if absent, the `dex:` block didn't render; check `ondemand-dex` is installed and the block
  is valid YAML.
