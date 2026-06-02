# OOD on AWS — Reference Architecture

This document is the **prescriptive design** for deploying Open OnDemand (OOD) on AWS the
best-practice way. It is the source of truth the Terraform/CDK and bootstrap scripts implement
against; where the code and this document disagree, this document states the intent.

It is also the basis for the AWS Marketplace listing: an opinionated, account-aware deployment
("deploy OOD on AWS the right way"), not an undifferentiated pile of toggles.

> **Status.** The identity model described here is being adopted in stages (see
> [Migration & cutover](#migration--cutover)). Some of the bespoke pieces it replaces still
> ship default-on until the cutover; new toggles (`enable_directory`, `use_sssd`) are additive
> and default-off today.

---

## 1. Purpose & scope

OOD is a portal in front of compute. The hard problems in deploying it on AWS are not the web
app — they are **identity** (who is the user, and what Unix account does their per-user NGINX
run as) and **account boundaries** (where the portal lives vs where jobs run vs where users
are defined). This document prescribes both.

**Guiding principle: OOD *defers* identity; it is not the identity authority.** OOD
authenticates users against an external IdP and resolves their POSIX identity against an
external directory. It does **not** manufacture accounts. Every place the current code tried to
be the authority (a login-time `useradd`, a DynamoDB UID counter, a hand-rolled OIDC vhost)
produced bugs and, in the account-provisioning case, an architecturally impossible design
(see [§7](#7-what-ood-provisions-vs-consumes) and the migration section).

**Prescribed vs optional**

| Layer | Prescribed (best practice) | Optional / eval-only |
| --- | --- | --- |
| Web auth | OIDC via OOD's bundled **Dex** | (Cognito user-pool path — legacy, being retired) |
| POSIX identity | **SSSD/NSS** against a directory | — |
| Directory | **Bring your own** (corporate AD / LDAP) | In-account **Simple AD** for demos |
| AWS compute identity | **Per-user cross-account AssumeRole** | OOD instance role (single-account on-ramp) |
| Account model | **Multi-account** (identity / portal / compute) | Single account (eval / small sites) |

---

## 2. The two deployment modes

The architecture has one identity *mechanism* and two *modes*. **The plumbing is identical;
only the LDAP endpoint differs.** That single fact is what makes the demo a faithful
representation of production rather than a throwaway path.

```
                    ┌──────────────── OOD host ────────────────┐
   user ──OIDC──▶   │  Dex (LDAP connector) ──┐                 │
                    │                          ├──▶  LDAP/AD  ◀──┤── SSSD (getpwnam)
   PUN runs as  ◀───│  nginx_stage / PUN  ─────┘   directory     │
                    └───────────────────────────────────────────┘
                                                    ▲
        demo mode:     in-account AWS Simple AD ─────┤
        production:    customer's existing AD/LDAP ──┘   (directory_ldap_uri)
```

### Demo / eval mode — single account, self-contained
- Deploy **AWS Simple AD** in the same account (`enable_directory=true`). ~$36/mo. Simple AD is
  appropriate here precisely *because* nothing is shared across accounts.
- Dex and SSSD both point at it. `terraform apply` (or `cdk deploy`) yields a working OOD with
  real, directory-backed identity and **zero external dependencies** — ideal for evaluation and
  for the Marketplace "try it" path.
- This is the only mode in which OOD provisions a directory, and it is explicitly **eval
  scaffolding**, not the recommended production shape.

### Production / best-practice mode — bring your own directory, multi-account
- OOD **consumes** the customer's existing directory (corporate Active Directory, on-prem
  LDAP, or their own AWS Managed Microsoft AD) via the [config contract](#the-byo-directory-config-contract).
  OOD provisions **no** directory.
- The directory lives in the customer's identity account/network. How the OOD portal reaches it
  (VPC peering, Transit Gateway, VPN, Direct Connect) is the customer's network design — see
  [§5](#5-network).

Selecting the mode is a single decision: set `directory_ldap_uri` to an external endpoint
(production) **or** set `enable_directory=true` to have the eval Simple AD provisioned and
wired automatically (demo).

---

## 3. Identity

OOD identity is **three independent concerns, each deferred outward.** Collapsing them into the
portal (as the legacy stack did) is the root cause of the #39→#77 bug chain.

| Concern | Question | Source of truth | Mechanism |
| --- | --- | --- | --- |
| **Web authentication** | "Who are you?" | OIDC IdP | **Dex** (OIDC), LDAP connector → directory |
| **POSIX identity** | "What uid/home does the PUN run as?" | the **directory** | **SSSD/NSS** + `oddjob-mkhomedir` |
| **AWS compute identity** | "Whose AWS account do jobs run in?" | the **user's own account** | per-user cross-account `AssumeRole` |

Because web auth and POSIX identity resolve against the **same directory**, the OIDC username
equals the POSIX account **by construction** — no claim-to-username mapping, no UUID/email
local-part hacks (the #64/#75 class cannot recur).

### Web auth: Dex with an LDAP connector
OOD ships [**Dex**](https://osc.github.io/ood-documentation/latest/authentication/dex.html), a
lightweight OIDC provider, configured declaratively under the `dex:` key in `ood_portal.yml`.
`ood-portal-generator` emits the Apache `mod_auth_openidc` vhost from that block — so the
scheme/`X-Forwarded`/callback details are **generator-owned**, and the hand-maintained-vhost
bug class (#52, #60, #73) cannot recur. Dex's native **`ldap` connector** binds directly to the
directory (AD speaks LDAP), so Dex authenticates users against the same source SSSD reads.

### POSIX identity: SSSD against the directory
The OOD host runs **SSSD** joined to the directory (`authselect select sssd with-mkhomedir`),
so `getpwnam(user)` resolves directory-side and `oddjob-mkhomedir` creates the home on first
login. **No account is created at request time.** This is the only model that works:
`nginx_stage` calls `getpwnam` *before* any pre-hook, so a login-time `useradd` can never
satisfy it (the #77 root cause).

### The BYO-directory config contract
Production deployments point OOD at an existing directory through this surface (Terraform vars;
CDK context mirrors them). This *is* the product interface for identity:

| Variable | Meaning |
| --- | --- |
| `directory_ldap_uri` | LDAP(S) endpoint SSSD + Dex bind to (e.g. `ldaps://ad.corp.example.com:636`). The mode selector: set this for BYO/production. |
| `directory_name` | The AD/Kerberos domain / SSSD domain (e.g. `corp.example.com`). |
| `directory_ldap_schema` | `ad` for Active Directory; `rfc2307bis` for a POSIX LDAP. |
| *(bind credentials)* | The directory bind DN + password, supplied via Secrets Manager (never in user_data). |
| `use_sssd` | Enable SSSD/NSS on the OOD host (on for any directory-backed deployment). |
| `enable_directory` | **Eval only** — provision an in-account Simple AD and wire the above to it automatically. |

### Rejected alternatives (and why)
All of these authenticate users but leave **POSIX identity unsolved** — `getpwnam` still has
nothing to resolve against. *Authentication ≠ POSIX identity* is the recurring lesson.

- **Keycloak** — heaviest option, and **not an LDAP server for SSSD** (it federates *to* LDAP;
  it does not serve its users as LDAP). Would need a separate LDAP bolted on.
- **AWS IAM Identity Center** — not an LDAP server, so SSSD can't resolve against it; it also
  **cannot use Simple AD**, must live in the Org management account, and still needs Managed AD
  behind it. Strictly more infrastructure, for only the auth half.
- **Cognito federation to AD** — Cognito federates only via SAML/OIDC, **not LDAP/AD directly**;
  bridging to AD needs AD FS or IAM Identity Center. The legacy Cognito user-pool path also made
  the portal the identity store, which is the model we are retiring.

---

## 4. Account model

The best-practice baseline is **multi-account**; a single account is the simplified on-ramp for
evaluation and small sites.

| Account | Owns | Notes |
| --- | --- | --- |
| **Identity account** | the directory (AD/LDAP) | **Customer-owned. Out of OOD's IaC scope.** OOD only consumes its LDAP endpoint. |
| **OOD portal account** | ALB, ASG, portal EFS, Dex/auth front, SSSD-joined hosts | Holds no standing credentials it does not need. |
| **Per-user compute account(s)** | the user's AWS compute (Batch/SageMaker/EC2/…) | Adapter jobs run here via per-user cross-account `AssumeRole` keyed on the OIDC identity — **not** the OOD instance role. |

**Credential flow (compute identity).** The portal vends **short-lived, per-user STS
credentials** into the adapter at submit time by assuming a role in the *user's* account
(web-identity / cross-account `AssumeRole` keyed on the OIDC `sub`/email, with an `externalId`).
The portal holds no standing credentials for user accounts. (This is roadmap #10, the "STS
credential injector," which this architecture makes **core**, not optional.)

**Single-account on-ramp.** For eval/small deployments, everything collapses into one account:
the eval Simple AD, the portal, and compute share the account, and adapters use the OOD instance
role directly. This is the current default and a valid starting point — but the design must not
*assume* it (the multi-account shape above is the target, and the IaC keeps account/role/
directory references configurable so a deployment can grow into it without a rewrite).

---

## 5. Network

How the OOD portal account reaches a directory in another account/on-prem is **the customer's
network design, not OOD IaC**. The directory is an LDAP(S) endpoint; OOD needs IP/DNS
reachability and the bind credentials. Common, non-prescribed options:

- **VPC peering / Transit Gateway** between the portal VPC and the identity VPC (AWS-resident
  directory).
- **VPN / AWS Direct Connect** to an on-prem AD/LDAP (the typical "OOD in front of an on-prem
  cluster" case — the directory the cluster already uses for POSIX identity).
- **AWS Managed Microsoft AD directory sharing** (if the customer runs Managed AD and wants AWS
  to broker the cross-account join). Note Simple AD **cannot** be shared cross-account — which
  is why Simple AD is eval-only and BYO production directories are Managed AD / on-prem.

OOD documents what it needs (LDAP URI, base DN, bind secret, network reachability) and leaves
the topology to the operator.

---

## 6. What this looks like end to end

```
1. User hits https://<portal>/  →  Apache (mod_auth_openidc, generator-emitted) → Dex
2. Dex authenticates the user via its LDAP connector against the directory
3. OOD maps REMOTE_USER = the directory username (same value SSSD will resolve)
4. nginx_stage calls getpwnam(user) → SSSD answers from the directory (no useradd)
5. oddjob-mkhomedir creates /home/<user> on first login (EFS-backed)
6. The PUN starts as the user; the dashboard renders
7. User submits a job → adapter assumes a role in the user's AWS account (per-user STS) → job runs there
```

Steps 1–6 are identity (this document's focus). Step 7 is the compute-identity layer
(per-user AssumeRole), designed in here and implemented in a later phase.

---

## 7. What OOD provisions vs consumes

The dividing line, stated explicitly:

**OOD consumes (never provisions in production):**
- The directory — auth and POSIX identity both resolve against it.
- The user's AWS account — jobs run there via assumed roles.

**OOD provisions:**
- The portal (ALB, ASG, EFS for homes, Dex, SSSD config on its hosts).
- Adapter-side infrastructure in the portal/compute account (queues, domains, etc.).
- **Eval mode only:** an in-account Simple AD, as a convenience so an evaluator without a
  directory can stand up a complete working system.

The legacy stack violated this line by making the portal the account authority (login-time
`useradd` + a DynamoDB UID counter). That is what this architecture retires.

---

## 8. How the repo implements this

| Piece | Where |
| --- | --- |
| Eval directory (Simple AD) | `terraform/directory.tf` / CDK `Directory` construct, gated `enable_directory` |
| BYO-directory contract | `directory_ldap_uri` / `directory_name` / `directory_ldap_schema` + bind secret |
| SSSD / NSS / oddjob-mkhomedir | `scripts/bake.sh` (packages) + `scripts/userdata.sh` (`use_sssd` block: realm join, authselect) |
| Dex web auth | `ood_portal.yml` `dex:` block in `scripts/userdata.sh` (generator-owned vhost) — *PR B* |
| Per-user compute AssumeRole | adapter IAM rework — *later phase (roadmap #10)* |
| Operator how-to | [identity-guide.md](identity-guide.md) |

---

## Migration & cutover

This architecture replaces the bespoke identity stack (Cognito user pool as the store +
oidc-pam + DynamoDB UID counter + login-time `useradd` / `ood-provision-user.sh`) that the
#39→#77 issue chain proved unworkable. The rollout is staged so the working path is never
removed before the replacement is validated live:

1. **Foundation (done):** `enable_directory` (AWS Directory Service) + `use_sssd` (SSSD/NSS +
   oddjob-mkhomedir), additive and default-off.
2. **Web auth (next):** Dex + LDAP connector, generator-owned vhost, wired to the directory
   (BYO or eval).
3. **Compute identity (later):** per-user cross-account `AssumeRole` in the adapters.
4. **Cutover:** once a brand-new directory user can log in via OIDC and reach
   `/pun/sys/dashboard` with a working PUN — **no `useradd`, zero manual steps** — flip the
   defaults, retire the Cognito-store/oidc-pam/DynamoDB-UID/`ood-provision-user.sh` stack, and
   close the root-cause issue (#77).

The acceptance gate for the whole identity model is that single end-to-end test in step 4.
