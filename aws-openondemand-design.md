# aws-openondemand: Design Document

**Author:** Scott Friedman  
**Version:** 0.1.0-draft  
**Date:** March 2026  
**Status:** RFC

---

## 1. Problem Statement

Open OnDemand (OOD) is the de facto web portal for HPC centers. Over 200 institutions run it. Every one of them that wants to deploy on AWS is hand-rolling infrastructure that works for their cluster and breaks for everyone else.

The root causes:

- OOD assumes it lives on the cluster head node — same filesystem, same PAM, same scheduler, same network. That assumption is baked into every layer: authentication, file browsing, job submission, and interactive app proxying.
- No reference architecture exists for OOD on AWS. The closest is a handful of blog posts and institution-specific Terraform that couples OOD to a single compute backend.
- The identity model (PAM → Unix user → scheduler) has no clean mapping to cloud-native identity without a bridging layer.

**aws-openondemand** provides a clean, repeatable, production-grade deployment of Open OnDemand on AWS with pluggable compute backends, cloud-native identity via oidc-pam, and infrastructure-as-code from day one.

---

## 2. Design Principles

1. **The portal tier is backend-agnostic.** Deploy OOD once; configure compute backends independently. A single OOD instance can talk to on-prem Slurm, ParallelCluster, AWS Batch, and SageMaker simultaneously via separate cluster profiles.

2. **Identity is OIDC-first, PAM-bridged.** Users authenticate via institutional SSO (SAML/OIDC). `oidc-pam` translates OIDC tokens to Unix sessions. OOD sees a normal PAM login. No /etc/passwd as source of truth.

3. **No SSH exposure.** Admin access via SSM. Compute backend communication via VPC-internal networking or IAM. When ALB is enabled, the only inbound port is 443 on the ALB. When ALB is disabled (cheapest path), security groups restrict access to the deployer's CIDR.

4. **Infrastructure as code, no exceptions.** Terraform AND CDK (Go) for all AWS resources — both produce identical infrastructure. Every deployment is reproducible. Configuration is parameterized, not hardcoded.

5. **Escape hatches everywhere.** The opinionated defaults work out of the box, but every layer is overridable for institutions that need it.

6. **Profiles for compute, toggles for everything else.** Deployment profiles control the instance type and pricing strategy. Every infrastructure feature — ALB, WAF, EFS, VPC endpoints, monitoring, CDN — is an independent boolean toggle. You compose your deployment, not pick a monolithic tier. A PI gets a $40/month deployment by turning things off. A CIO gets a bulletproof deployment by turning things on. Same codebase, same parameters.

---

## 3. Architecture Overview

```
                              ┌─────────────────────────┐
                              │     Route 53 / DNS      │
                              └────────────┬────────────┘
                                           │
                              ┌────────────▼────────────┐
                              │   ALB (HTTPS, ACM cert) │
                              │   WAF (optional)        │
                              └────────────┬────────────┘
                                           │
                    ┌──────────────────────▼──────────────────────┐
                    │              Portal Tier                     │
                    │  ┌──────────────────────────────────────┐   │
                    │  │         Open OnDemand (Passenger)    │   │
                    │  │         + oidc-pam (OIDC→PAM)        │   │
                    │  │         + NSS module (UID/GID map)   │   │
                    │  └──────────────────────────────────────┘   │
                    │  EC2 (m6i.xlarge) / Private subnet          │
                    │  EFS mount: /home, /scratch                 │
                    │  CloudWatch Agent                           │
                    │  SSM Agent (admin access)                   │
                    └──────────┬──────────┬──────────┬───────────┘
                               │          │          │
              ┌────────────────┤          │          ├────────────────┐
              │                │          │          │                │
   ┌──────────▼───────┐ ┌─────▼────┐ ┌───▼────┐ ┌──▼──────────┐ ┌──▼──────────┐
   │   On-Prem Slurm  │ │ Parallel │ │  AWS   │ │  SageMaker  │ │  Custom EC2 │
   │   (VPN/DX+SSH)   │ │ Cluster  │ │  Batch │ │  Studio     │ │  (Launch    │
   │                   │ │ (VPC)    │ │ (API)  │ │  (API)      │ │   Template) │
   └───────────────────┘ └──────────┘ └────────┘ └─────────────┘ └─────────────┘
```

---

## 4. Component Design

### 4.1 Portal Tier

The portal tier is a single EC2 instance running OOD. This is intentionally not containerized in v1 — OOD's Passenger/Nginx stack, PAM integration, and per-user Ruby apps make containerization a project unto itself with marginal benefit. When `enable_alb=true`, the instance is in a private subnet behind an ALB. When `enable_alb=false` (cheapest path), the instance is in a public subnet with security-group-only protection.

#### Instance Configuration

The instance type is controlled by the deployment profile. All other features are independent toggles.

**Deployment Profiles:**

| Profile | Instance | Arch | Pricing | Est. compute/mo | Best for |
|---|---|---|---|---|---|
| **`minimal`** *(default)* | t3.medium | x86_64 | On-Demand | ~$30 | Development, small labs, PoC |
| **`standard`** | m6i.xlarge | x86_64 | On-Demand | ~$140 | 50-100 concurrent users, production |
| **`graviton`** | m7g.xlarge | ARM64 | On-Demand | ~$112 | Same as standard, ~20% cheaper |
| **`spot`** | m6i.xlarge | x86_64 | Spot | ~$42-56 | Cost-sensitive; requires `enable_efs=true` |
| **`large`** | m6i.2xlarge | x86_64 | On-Demand | ~$280 | 200+ concurrent users, heavy PUN load |

**Override the instance size without changing the profile:**

```bash
# Terraform
deployment_profile = "minimal"
instance_type      = "t3.large"

# CDK
npx cdk deploy -c deploymentProfile=minimal -c instanceType=t3.large
```

**Spot profile note:** When AWS reclaims a spot instance the ASG launches a replacement in ~3-5 minutes. OOD sessions in progress are lost, but user data survives on EFS and UID mappings survive in DynamoDB. The spot profile enforces `enable_efs=true` via a deploy-time precondition.

**Common storage mounts:**

| Mount | Default | Notes |
|---|---|---|
| /home (EFS) | Enabled when `enable_efs=true` | User home directories; shared with compute if needed |
| /scratch (EFS or FSx) | Optional | Scratch space for job staging |
| Root volume | 50 GB gp3 | OS + OOD + system packages |

#### Software Stack

```
Amazon Linux 2023
├── Open OnDemand (latest stable via ondemand-release RPM)
│   ├── Nginx (reverse proxy, SSL termination at ALB)
│   ├── Passenger (Ruby app server, per-user app spawning)
│   ├── OOD Dashboard (Rails app)
│   ├── OOD Shell (websocket terminal)
│   ├── OOD Files (file browser)
│   ├── OOD Job Composer + Active Jobs
│   └── S3 Browser app (when enable_s3_browser=true)
├── oidc-pam
│   ├── PAM module (pam_oidc.so)
│   ├── Authentication broker (oidc-auth-broker.service)
│   └── NSS module (UID/GID resolution from DynamoDB)
├── Compute adapters (installed from GitHub releases)
│   ├── ood-batch-adapter (when batch in adapters_enabled)
│   ├── ood-sagemaker-adapter (when sagemaker in adapters_enabled)
│   └── ood-ec2-adapter (when ec2 in adapters_enabled)
├── CloudWatch Agent
├── SSM Agent
└── EFS utils (amazon-efs-utils)
```

#### Provisioning

User data script (cloud-init) handles:

1. Mount EFS filesystems
2. Install OOD from YUM repo
3. Install oidc-pam from release binary
4. Apply OOD configuration templates (ERB/YAML generated by CDK)
5. Configure Nginx for ALB health checks
6. Start services

Configuration is injected via SSM Parameter Store — the instance pulls its config at boot rather than baking it into the AMI. This allows config changes without AMI rebuilds.

#### Scaling Note (v2+)

Horizontal scaling of OOD is blocked by per-user PUN (Per-User Nginx) processes that bind to the local filesystem. A future version could use ECS with EFS-backed PUN state, but this is a known hard problem in the OOD community and not a v1 goal.

---

### 4.2 Identity Layer

This is the critical innovation. OOD's PAM dependency is the #1 barrier to cloud deployment. oidc-pam eliminates it without modifying OOD.

#### Authentication Flow

```
User (browser)
  │
  ├─1─► ALB (443) ─► OOD Dashboard
  │                     │
  │                     ├─2─► OOD calls Apache OIDC module
  │                     │     (mod_auth_openidc configured for Cognito/Okta/etc.)
  │                     │
  │  ◄──3── OIDC redirect to IdP ◄──┘
  │
  ├─4─► IdP login (Cognito, Okta, Azure AD, institutional SAML via Cognito federation)
  │
  │  ──5──► OIDC callback to OOD with id_token
  │                     │
  │                     ├─6─► mod_auth_openidc validates token, sets REMOTE_USER
  │                     │
  │                     ├─7─► OOD maps REMOTE_USER to Unix user via oidc-pam NSS
  │                     │     (OIDC claim → UID/GID mapping)
  │                     │
  │                     └─8─► Per-User Nginx spawns as mapped Unix user
  │                           (file browser, shell, job composer all run as this user)
```

#### Two-Layer Identity Design

**Layer 1: Web Authentication (mod_auth_openidc)**

OOD already supports `mod_auth_openidc` for web SSO. This handles the browser-side OIDC flow. We configure it to talk to a Cognito User Pool (default) or any OIDC provider.

```yaml
# /etc/ood/config/ood_portal.yml (generated by CDK)
auth:
  - "AuthType openid-connect"
oidc_uri: "/oidc"
oidc_provider_metadata_url: "https://cognito-idp.{region}.amazonaws.com/{pool_id}/.well-known/openid-configuration"
oidc_client_id: "{{ client_id }}"
oidc_client_secret: "{{ from SSM Parameter Store }}"
oidc_remote_user_claim: "email"  # or preferred_username, sub, etc.
oidc_scope: "openid email profile"
```

**Layer 2: Unix Identity Mapping (oidc-pam + NSS)**

Once `mod_auth_openidc` sets `REMOTE_USER`, OOD needs to map that to a Unix UID/GID. This is where `oidc-pam`'s NSS module comes in:

```yaml
# /etc/oidc-auth/broker.yaml
identity_mapping:
  strategy: "claim"          # Map OIDC claim to Unix username
  claim: "email"             # Use email prefix as username
  transform: "email_prefix"  # scott.friedman@university.edu → scott.friedman
  
  uid_allocation:
    mode: "dynamic"          # Auto-assign UIDs from range
    range_start: 10000
    range_end: 65000
    persistence: "dynamodb"  # Store UID mappings in DynamoDB for consistency
    
  group_mapping:
    source: "cognito_groups"  # Map Cognito/OIDC groups to Unix GIDs
    default_group: "researchers"
    
  home_directory:
    create: true
    base: "/home"
    skeleton: "/etc/skel"
```

**UID Consistency Across Nodes**

For compute backends that need matching UIDs (ParallelCluster, on-prem), the UID mapping table lives in DynamoDB. The NSS module on each node queries DynamoDB to resolve username → UID. This replaces LDAP/AD in the traditional HPC stack.

```
┌──────────┐     ┌──────────┐     ┌──────────────┐
│ OOD Node │     │ Compute  │     │  DynamoDB     │
│ (NSS)    │────►│ Nodes    │────►│  UID Map      │
│          │     │ (NSS)    │     │  Table        │
└──────────┘     └──────────┘     └──────────────┘
     │                │                   ▲
     │                │                   │
     └────────────────┴───────────────────┘
       All nodes resolve UIDs from same source
```

#### Supported Identity Providers

| Provider | Integration | Notes |
|---|---|---|
| Amazon Cognito | Native OIDC | Default. Supports SAML federation for institutional IdPs |
| Okta | OIDC | Direct integration via mod_auth_openidc |
| Azure AD / Entra ID | OIDC | Direct integration |
| Google Workspace | OIDC | Direct integration |
| InCommon/Shibboleth | SAML via Cognito | Cognito acts as SAML→OIDC bridge |
| CILogon | OIDC | Common in research computing; direct integration |
| Keycloak | OIDC | Self-hosted option |

**InCommon/Shibboleth note:** Most R1 universities use InCommon for federated SAML. Cognito can federate with SAML IdPs directly, acting as a protocol bridge. This means institutions don't need to change their IdP — they register Cognito as a SAML SP in their IdP, and Cognito presents as OIDC to OOD.

---

### 4.3 Compute Adapters

Each compute backend is an OOD "cluster configuration" — a YAML file in `/etc/ood/config/clusters.d/` that tells OOD how to submit jobs, check status, and connect to interactive sessions. aws-openondemand ships adapter modules for each backend.

#### 4.3.1 On-Premises Cluster (VPN / Direct Connect)

**Use case:** University has an existing HPC cluster. They want OOD in AWS as the portal but compute stays on-prem.

**Architecture:**

```
┌──────────────── AWS VPC ────────────────┐     ┌─── Campus Network ───┐
│                                          │     │                      │
│  OOD Instance ──SSH──► Transit GW/VPN ───┼─────┼──► Slurm Head Node  │
│       │                                  │     │       │              │
│       └──EFS (/home)                     │     │       └── /home (NFS)│
│                                          │     │                      │
└──────────────────────────────────────────┘     └──────────────────────┘
```

**Connectivity options (ranked):**

1. **AWS Direct Connect** — dedicated, predictable latency, best for production
2. **Site-to-Site VPN** — encrypted tunnel over internet, adequate for most
3. **Client VPN + routing** — lighter weight, sufficient for smaller deployments

**Cluster config:**

```yaml
# /etc/ood/config/clusters.d/campus-hpc.yml
---
v2:
  metadata:
    title: "Campus HPC Cluster"
    priority: 10
  login:
    host: "hpc-login.university.edu"    # Reachable via VPN
    
  job:
    adapter: "slurm"
    host: "hpc-login.university.edu"
    bin: "/opt/slurm/bin"
    conf: "/etc/slurm/slurm.conf"
    
  batch_connect:
    basic:
      script_wrapper: |
        module purge
        %s
    vnc:
      script_wrapper: |
        module purge
        export PATH="/opt/TurboVNC/bin:$PATH"
        %s
```

**Identity bridge:**

The on-prem cluster still expects UIDs from its own LDAP/AD. Two strategies:

- **UID sync:** oidc-pam's DynamoDB UID table is seeded from the institution's existing LDAP, so UIDs match. The NSS module on the OOD node resolves to the same UIDs the on-prem cluster uses.
- **SSH key provisioning:** oidc-pam provisions short-lived SSH keys (per session) authorized on the on-prem login node. The OOD node SSH's to the on-prem node using these keys.

**Filesystem:**

For the file browser to work, OOD needs to see the user's files. Options:

- **NFS over VPN:** Mount the on-prem /home on the OOD node. Works but latency-sensitive.
- **EFS as shared home:** If the institution is willing to migrate home directories to EFS, mount EFS on both sides. Better performance, cleaner architecture.
- **sshfs / FUSE mount:** Last resort. Fragile but functional for read-mostly workloads.

**CDK module:** `OnPremAdapter` construct that provisions the VPN/DX endpoint, security groups allowing SSH from OOD to the on-prem network, and generates the cluster YAML.

---

#### 4.3.2 AWS ParallelCluster

**Use case:** Institution wants a fully cloud-based HPC cluster with familiar Slurm semantics.

**Architecture:**

```
┌──────────────────── AWS VPC ────────────────────────┐
│                                                      │
│  ┌────────────┐         ┌────────────────────────┐  │
│  │ OOD Node   │──SSH──► │ ParallelCluster        │  │
│  │            │         │   Head Node             │  │
│  │            │         │   ├── Slurm Controller  │  │
│  │            │         │   ├── Slurm Accounting  │  │
│  │            │         │   └── slurmctld         │  │
│  └─────┬──────┘         └──────────┬─────────────┘  │
│        │                           │                 │
│        │         ┌─────────────────┤                 │
│        │         │                 │                 │
│  ┌─────▼─────┐  ┌▼──────────┐  ┌──▼───────────┐    │
│  │    EFS    │  │  Compute   │  │   Compute    │    │
│  │  (/home)  │  │  Queue 1   │  │   Queue 2    │    │
│  │           │  │  (c6i)     │  │   (p4d/GPU)  │    │
│  └───────────┘  └────────────┘  └──────────────┘    │
│                                                      │
│  ┌───────────────────────────────────────────────┐  │
│  │  FSx for Lustre (/scratch) — optional         │  │
│  └───────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

**Integration points:**

- OOD SSH's to ParallelCluster head node for sbatch/squeue/scancel
- EFS is mounted on OOD node, head node, and all compute nodes (shared /home)
- FSx for Lustre provides /scratch for high-throughput jobs
- ParallelCluster's Slurm is configured with the same UID mapping (DynamoDB NSS) so job ownership is correct

**ParallelCluster config (shipped as reference):**

```yaml
Region: us-east-1
Image:
  Os: alinux2023
  CustomAmi: ami-xxxxx   # Pre-baked with oidc-pam NSS module

HeadNode:
  InstanceType: m6i.xlarge
  Networking:
    SubnetId: {{ portal_subnet }}    # Same VPC as OOD
  Ssh:
    KeyName: {{ generated_keypair }}
  CustomActions:
    OnNodeConfigured:
      Script: s3://{{ bucket }}/pcluster/head-node-setup.sh
      # Installs oidc-pam NSS, mounts EFS, configures Slurm accounting

Scheduling:
  Scheduler: slurm
  SlurmQueues:
    - Name: general
      ComputeResources:
        - Name: c6i-xlarge
          InstanceType: c6i.xlarge
          MinCount: 0
          MaxCount: 100
      Networking:
        SubnetIds:
          - {{ compute_subnet }}

SharedStorage:
  - MountDir: /home
    Name: home
    StorageType: Efs
    EfsSettings:
      FileSystemId: {{ efs_id }}    # Same EFS as OOD node
      
  - MountDir: /scratch
    Name: scratch
    StorageType: FsxLustre
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
```

**CDK module:** `ParallelClusterAdapter` construct that creates the ParallelCluster configuration, shared EFS, optional FSx for Lustre, security groups for SSH from OOD to head node, and the OOD cluster YAML.

---

#### 4.3.3 AWS Batch

**Use case:** Cloud-native job submission without managing a Slurm cluster. Spot instances, automatic scaling, no head node.

**This is the adapter that doesn't exist yet.** OOD has no AWS Batch adapter. aws-openondemand ships one.

**Architecture:**

```
┌──────────────────── AWS VPC ──────────────────────────┐
│                                                        │
│  ┌────────────┐        ┌─────────────────────────┐    │
│  │ OOD Node   │──API──►│  Batch Adapter Service   │   │
│  │            │        │  (Go binary on OOD node) │   │
│  │            │        │  Translates:              │   │
│  │            │        │    sbatch → Batch API     │   │
│  │            │        │    squeue → Batch status  │   │
│  │            │        │    scancel → Batch cancel │   │
│  └────────────┘        └────────────┬────────────┘    │
│                                      │                 │
│                          ┌───────────▼───────────┐    │
│                          │     AWS Batch          │    │
│                          │  ┌─────────────────┐  │    │
│                          │  │ Job Queue: cpu   │  │    │
│                          │  │ CE: Fargate      │  │    │
│                          │  └─────────────────┘  │    │
│                          │  ┌─────────────────┐  │    │
│                          │  │ Job Queue: gpu   │  │    │
│                          │  │ CE: EC2 (p-type) │  │    │
│                          │  └─────────────────┘  │    │
│                          │  ┌─────────────────┐  │    │
│                          │  │ Job Queue: spot  │  │    │
│                          │  │ CE: Spot Fleet   │  │    │
│                          │  └─────────────────┘  │    │
│                          └───────────────────────┘    │
│                                                        │
│  ┌───────────────────────────────────────────────┐    │
│  │  EFS (/home) — mounted in Batch containers    │    │
│  └───────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────┘
```

**Batch Adapter Design:**

The adapter is a Go binary that implements OOD's job adapter interface. It lives on the OOD node and OOD shells out to it (same pattern as how OOD calls sbatch).

```
OOD Job Composer
    │
    ├── calls adapter CLI:
    │   $ ood-batch-adapter submit --script job.sh --queue cpu --cores 4 --mem 8G
    │   $ ood-batch-adapter status --job-id <batch-job-id>
    │   $ ood-batch-adapter delete --job-id <batch-job-id>
    │   $ ood-batch-adapter list --user scott.friedman
    │
    └── adapter translates to Batch API:
        submit  → batch:SubmitJob (job definition, queue, container overrides)
        status  → batch:DescribeJobs → mapped to OOD status (queued/running/completed/failed)
        delete  → batch:CancelJob / batch:TerminateJob
        list    → batch:ListJobs with tag filter on username
```

**Job submission mapping:**

| OOD Concept | Batch Concept |
|---|---|
| Job script | Container command (script mounted from EFS or injected) |
| Queue/partition | Batch Job Queue |
| Cores / memory | Container resource requirements (vcpus, memory) |
| Walltime | Batch attempt timeout |
| Job name | Batch job name |
| Working directory | Container working directory (EFS mount) |
| Environment variables | Container environment overrides |
| Job array | Batch array job |
| Dependencies | Batch job dependencies |

**Container strategy:**

Batch jobs run in containers. The adapter uses a base job definition with:
- EFS mounted at /home (user's home directory available)
- User's UID/GID set via container properties (Batch supports `user` in container overrides)
- Institution-provided container images registered as job definitions for specific software

**OOD cluster config for Batch:**

```yaml
# /etc/ood/config/clusters.d/aws-batch.yml
---
v2:
  metadata:
    title: "AWS Cloud (Batch)"
    priority: 20
    
  job:
    adapter: "linux_host"
    submit_host: "localhost"
    
    # Custom adapter script path
    bin: "/opt/ood-batch-adapter/bin"
    
    # Adapter-specific config
    batch_config:
      region: "us-east-1"
      job_queues:
        cpu: "ood-cpu-queue"
        gpu: "ood-gpu-queue"
        spot: "ood-spot-queue"
      default_job_definition: "ood-base-job"
      efs_filesystem_id: "fs-xxxxx"
      tag_prefix: "ood"
```

**CDK module:** `BatchAdapter` construct that creates Batch compute environments, job queues, base job definition, IAM roles (OOD node role needs batch:SubmitJob etc.), EFS access points for Batch containers, and the adapter binary deployment.

---

#### 4.3.4 SageMaker (Interactive Sessions)

**Use case:** Jupyter, RStudio, VS Code sessions without the fragile OOD reverse proxy. SageMaker handles the session lifecycle; OOD is just the launcher.

**Architecture:**

```
┌──────────── AWS VPC ────────────────────────────────┐
│                                                      │
│  ┌────────────┐       ┌───────────────────────┐     │
│  │ OOD Node   │──API─►│  SageMaker Adapter    │     │
│  │            │       │  (Go binary)           │     │
│  │ Dashboard  │       │  - Launch notebooks    │     │
│  │ shows      │       │  - Track sessions      │     │
│  │ active     │◄──────│  - Return presigned URL│     │
│  │ sessions   │       └───────────┬───────────┘     │
│  └────────────┘                   │                  │
│                                   ▼                  │
│                     ┌─────────────────────────┐      │
│                     │  SageMaker               │     │
│                     │  ┌───────────────────┐  │      │
│                     │  │ Notebook Instance  │  │     │
│                     │  │ (ml.t3.medium)     │  │     │
│                     │  │ Jupyter / RStudio  │  │     │
│                     │  └───────────────────┘  │      │
│                     │  ┌───────────────────┐  │      │
│                     │  │ Studio Domain      │  │     │
│                     │  │ (JupyterLab)       │  │     │
│                     │  └───────────────────┘  │      │
│                     └─────────────────────────┘      │
│                                                      │
│  EFS (/home) mounted on notebook instances           │
└──────────────────────────────────────────────────────┘
```

**How it works:**

Instead of OOD launching a Jupyter session as a Slurm job and reverse-proxying to it (OOD's standard batch_connect flow, which is the most fragile part of the system), the SageMaker adapter:

1. User clicks "Launch Jupyter" in OOD dashboard
2. Adapter calls SageMaker API to create a notebook instance (or Studio user profile)
3. EFS is attached to the notebook instance — user sees their files
4. Adapter returns a presigned URL to the running session
5. OOD redirects the user's browser to the presigned URL
6. Session runs entirely in SageMaker — no reverse proxy, no websocket tunneling through OOD

**This sidesteps OOD's hardest problem.** The interactive app reverse proxy is the most fragile piece of OOD's architecture. It depends on the compute node being reachable from OOD over a specific port, which breaks in autoscaling environments. SageMaker handles all of this natively.

**Session types:**

| OOD Interactive App | SageMaker Backend |
|---|---|
| Jupyter Notebook | Notebook Instance (ml.t3/m5/p3) or Studio |
| JupyterLab | Studio |
| RStudio | Notebook Instance with RStudio lifecycle config |
| VS Code | Studio with Code Editor |
| Custom app | Notebook Instance with custom lifecycle config |

**Lifecycle management:**

- **Auto-stop:** SageMaker notebook instances support idle timeout (auto-stop after N minutes of inactivity)
- **Cost tracking:** Tag instances with user identity, group, project for cost allocation
- **GPU sessions:** Users can request GPU instances (ml.p3.2xlarge, ml.g5.xlarge) for ML/DL work

**CDK module:** `SageMakerAdapter` construct that creates the SageMaker domain, default user profile template, EFS access, VPC configuration, IAM roles, lifecycle configs, and the adapter binary.

---

#### 4.3.5 Custom EC2 (Direct Launch)

**Use case:** Single-node workloads that need a beefy instance for a few hours. Simpler than Batch for tasks that don't need a job queue.

**How it works:**

1. User submits a job specifying instance type and duration
2. Adapter launches an EC2 instance from a pre-defined Launch Template
3. User data script mounts EFS, installs oidc-pam NSS, runs the job script
4. Adapter monitors instance, streams CloudWatch logs back as job output
5. Instance terminates when job completes (or walltime expires)

**Launch Templates (shipped as defaults):**

- `ood-compute-cpu` — general purpose (m6i, c6i families)
- `ood-compute-gpu` — GPU workloads (p4d, g5 families)
- `ood-compute-memory` — memory-intensive (r6i, x2idn families)
- `ood-compute-custom` — user-specified AMI + instance type

**Spot integration:**

The adapter supports Spot instances with automatic fallback to On-Demand. Configured per launch template.

**CDK module:** `EC2Adapter` construct that creates launch templates, IAM instance profiles, security groups, and the adapter binary.

---

### 4.4 Storage Layer

#### Shared Filesystem

```
┌──────────────────────────────────────────────────────┐
│                    Amazon EFS                         │
│                                                       │
│  /home                                                │
│  ├── scott.friedman/      (UID 10001)                │
│  ├── jane.doe/            (UID 10002)                │
│  └── ...                                              │
│                                                       │
│  Access Points:                                       │
│  ├── ap-portal  (OOD node, root access for PUN)      │
│  ├── ap-batch   (Batch containers, per-user)         │
│  └── ap-compute (ParallelCluster nodes)              │
│                                                       │
│  Performance mode: generalPurpose (default)           │
│  Throughput mode: elastic (scales with usage)         │
│  Encryption: at-rest (AWS managed key) + in-transit  │
└──────────────────────────────────────────────────────┘
```

#### High-Performance Scratch (Optional)

For HPC workloads that need parallel filesystem performance:

```
┌──────────────────────────────────────────────────────┐
│              FSx for Lustre                           │
│                                                       │
│  /scratch                                             │
│  Deployment: SCRATCH_2 (200 MB/s/TiB)               │
│  Capacity: 1.2 TiB minimum                           │
│  Linked to S3 bucket for data import/export          │
│                                                       │
│  Mounted on:                                          │
│  ├── ParallelCluster compute nodes                   │
│  └── OOD node (optional, for file browser access)    │
└──────────────────────────────────────────────────────┘
```

#### Object Storage

```
┌──────────────────────────────────────────────────────┐
│                  Amazon S3                            │
│                                                       │
│  s3://ood-{account}-data/                            │
│  ├── datasets/          (shared research data)       │
│  ├── job-outputs/       (archived job results)       │
│  └── software/          (container images, modules)  │
│                                                       │
│  Access: IAM roles, presigned URLs via OOD file app  │
│  OOD file browser extended to browse S3 prefixes     │
└──────────────────────────────────────────────────────┘
```

---

### 4.5 Networking

```
┌────────────────────────── VPC (10.0.0.0/16) ──────────────────────────┐
│                                                                        │
│  ┌─── Public Subnets (10.0.0.0/24, 10.0.1.0/24) ───────────────────┐ │
│  │  ALB (internet-facing)                                            │ │
│  │  NAT Gateway(s)                                                   │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                        │
│  ┌─── Private Subnets (10.0.10.0/24, 10.0.11.0/24) ────────────────┐ │
│  │  OOD Instance                                                     │ │
│  │  ParallelCluster Head Node                                        │ │
│  │  Batch Compute Environments                                       │ │
│  │  SageMaker Notebook Instances                                     │ │
│  │  EFS Mount Targets                                                │ │
│  │  VPC Endpoints (SSM, S3, Batch, SageMaker, DynamoDB, CloudWatch) │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                        │
│  ┌─── Optional: VPN/DX Subnets ────────────────────────────────────┐  │
│  │  Virtual Private Gateway / Transit Gateway                       │  │
│  │  Routing to on-prem (10.x.x.x/16 campus range)                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

**Security Groups:**

| SG Name | Inbound | Outbound | Attached To |
|---|---|---|---|
| `sg-alb` | 443 from 0.0.0.0/0 | Portal SG:80 | ALB |
| `sg-portal` | 80 from ALB SG | All (NAT) | OOD instance |
| `sg-compute` | SSH from Portal SG | All (NAT) | ParallelCluster, EC2 compute |
| `sg-efs` | 2049 from Portal SG + Compute SG | — | EFS mount targets |
| `sg-batch` | — (Fargate managed) | All | Batch compute environments |

**VPC Endpoints (PrivateLink):**

No internet traversal for AWS API calls. All service communication stays in VPC.

- `com.amazonaws.{region}.ssm` — SSM access
- `com.amazonaws.{region}.ssmmessages` — SSM sessions
- `com.amazonaws.{region}.s3` — S3 (gateway endpoint)
- `com.amazonaws.{region}.batch` — Batch API
- `com.amazonaws.{region}.sagemaker.api` — SageMaker API
- `com.amazonaws.{region}.dynamodb` — DynamoDB (gateway endpoint)
- `com.amazonaws.{region}.logs` — CloudWatch Logs
- `com.amazonaws.{region}.monitoring` — CloudWatch Metrics
- `com.amazonaws.{region}.elasticfilesystem` — EFS

---

### 4.6 Observability

#### CloudWatch Dashboard

```
┌─────────────────────────────────────────────────────────────┐
│  aws-openondemand Dashboard                                  │
│                                                              │
│  Portal Health                                               │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │ Active Users   │  │ Active PUNs    │  │ ALB Requests  │ │
│  │     47         │  │     23         │  │   1,204/hr    │ │
│  └────────────────┘  └────────────────┘  └───────────────┘ │
│                                                              │
│  Compute Backends                                            │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │ Batch Jobs     │  │ PCluster Nodes │  │ SageMaker     │ │
│  │ R:12 Q:5 F:1  │  │ Active: 24     │  │ Sessions: 8   │ │
│  └────────────────┘  └────────────────┘  └───────────────┘ │
│                                                              │
│  Cost (MTD)                                                  │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │ Compute: $3.2K │  │ Storage: $180  │  │ Total: $3.8K  │ │
│  └────────────────┘  └────────────────┘  └───────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

#### Log Groups

| Log Group | Source | Retention |
|---|---|---|
| `/ood/portal/nginx` | OOD Nginx access + error logs | 30 days |
| `/ood/portal/pun` | Per-User Nginx logs (per user) | 30 days |
| `/ood/auth/oidc-pam` | Authentication events, UID mappings | 90 days |
| `/ood/adapter/batch` | Batch adapter operations | 30 days |
| `/ood/adapter/sagemaker` | SageMaker adapter operations | 30 days |
| `/ood/jobs/*` | Job stdout/stderr (streamed) | 7 days (configurable) |

#### Metrics (Custom CloudWatch Metrics)

```
Namespace: OOD/Portal
  - ActiveUsers (count)
  - ActivePUNs (count)
  - AuthenticationFailures (count)
  - SessionDuration (seconds, per user)
  
Namespace: OOD/Jobs
  - JobsSubmitted (count, by backend)
  - JobsCompleted (count, by backend)
  - JobsFailed (count, by backend)
  - QueueWaitTime (seconds, by backend)
  - JobCost (dollars, by backend + user)
  
Namespace: OOD/Compute
  - BatchvCPUUtilization
  - ParallelClusterNodeCount
  - SageMakerActiveSessions
  - SpotInterruptions (count)
```

#### Alarms

| Alarm | Condition | Action |
|---|---|---|
| Portal unhealthy | ALB target unhealthy > 5 min | SNS → ops team |
| High auth failures | > 10 failures in 5 min | SNS → security team |
| Cost threshold | MTD compute > $X | SNS → PI / admin |
| Disk full | OOD root volume > 85% | SNS → ops team |
| EFS throughput | Burst credits exhausted | SNS → ops team |

---

### 4.7 Session Cache (Level 5)

OOD's Per-User Nginx (PUN) processes keep session tokens and per-user state in local memory and on local disk (`/var/lib/ondemand-nginx/`). When the instance dies — Spot reclaim, AZ failure, or just a bad deploy — every active user is logged out and loses their in-progress dashboard state. This is the equivalent of HubZero losing its database on instance death before the RDS toggle.

**What gets externalized:**

| State | Current location | Externalized to |
|---|---|---|
| PUN session tokens | Nginx shared memory zone | ElastiCache Redis |
| OOD app session cookies | Rails cookie store (encrypted) | No change needed (client-side) |
| Active Jobs cache | SQLite in /home (already on EFS) | No change needed |
| Recently Used Apps | SQLite in /home (already on EFS) | No change needed |
| Per-user Nginx PID/socket | /var/lib/ondemand-nginx/ | Local (recreated on boot) |

The key insight: most of OOD's per-user state is already in /home (on EFS) via SQLite databases. The main thing that doesn't survive is the **PUN session token** — the thing that maps "this browser cookie" to "this Unix user's Nginx process." Without it, users have to re-authenticate and OOD has to re-spawn their PUN. With it, the replacement instance restores sessions seamlessly.

**Implementation:**

```
┌─────────────┐      ┌──────────────────────┐
│ OOD (PUN)   │─────►│ ElastiCache Redis     │
│             │      │ (cache.t3.micro)      │
│ Session     │      │ Single-node           │
│ tokens      │      │ encryption in-transit │
│ stored in   │      │ ~$12/mo               │
│ Redis       │      │                       │
└─────────────┘      └──────────────────────┘
       or
┌─────────────┐      ┌──────────────────────┐
│ OOD (PUN)   │─────►│ DynamoDB              │
│             │      │ (existing UID table   │
│ Session     │      │  + session partition) │
│ tokens      │      │ ~$0 additional        │
│ stored in   │      │ higher latency        │
│ DynamoDB    │      └──────────────────────┘
└─────────────┘
```

**How it works:** OOD's Apache `mod_auth_openidc` stores session state. We configure it to use a Redis or DynamoDB backend via a session store module instead of the default server-side cache. When the instance is replaced, the new instance connects to the same session store and existing browser cookies remain valid.

**Toggle behavior:**
- `enable_session_cache=false` (default): local session storage, standard OOD behavior
- `enable_session_cache=true` + Redis: creates a single-node ElastiCache Redis instance in the same VPC (~$12/mo)
- `enable_session_cache=true` + DynamoDB: uses a session partition in the existing DynamoDB UID table ($0 additional, higher latency)

The session cache backend is selected via `session_cache_backend = "redis"` (default when enabled) or `session_cache_backend = "dynamodb"`.

---

### 4.8 S3 Browser (Level 6)

OOD's file browser only speaks POSIX. Researchers increasingly have data in S3 — shared datasets, job outputs archived from Batch, instrument data landed by pipelines. Today, accessing that data from OOD requires SSH'ing in and running `aws s3 ls`. That's not a portal experience.

**What it does:**

An OOD Passenger app (Ruby, using `aws-sdk-s3`) registered as a file browser alternative. Users see both "Home Directory" (EFS/POSIX) and "Cloud Storage" (S3) in the file browser navigation.

**Capabilities:**

| Action | Implementation |
|---|---|
| Browse buckets/prefixes | `s3:ListBucket` via instance role |
| Download files | Presigned GET URL (expires in 1 hour) |
| Upload files | Presigned POST / multipart upload from browser |
| Copy between S3 and /home | Server-side: `s3:GetObject` → write to EFS |
| Delete | `s3:DeleteObject` (controlled by IAM policy) |
| Preview (text, images) | Presigned URL rendered in iframe |

**Access control:**

S3 access is governed by the OOD instance's IAM role. The role policy scopes access based on the user's identity:

```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::research-data-${aws:PrincipalTag/project}/*",
    "arn:aws:s3:::research-data-${aws:PrincipalTag/project}"
  ]
}
```

Users see only the buckets/prefixes their project has access to. Project tags are set in Cognito groups and propagated through oidc-pam to IAM session tags.

**Shipped as:** an OOD app in the `configs/ood/apps/` directory of this project, installed during bootstrap. Not a separate repo — it's tightly coupled to the aws-openondemand deployment because it depends on the IAM role and S3 bucket configuration.

```
configs/ood/apps/s3-browser/
├── manifest.yml          # OOD app manifest
├── app.rb                # Sinatra/Rails app
├── views/
│   ├── index.erb         # Bucket/prefix listing
│   └── _file_row.erb     # File entry with download/preview/delete
├── lib/
│   └── s3_client.rb      # aws-sdk-s3 wrapper with presigned URL generation
└── public/
    └── upload.js          # Client-side multipart upload handler
```

---

### 4.9 CloudWatch Accounting (Level 7)

HPC centers track usage in CPU-hours via `sacct`. Cloud compute is billed in dollars. PIs managing AWS credit grants need dollar-denominated accounting, not CPU-hours. This doesn't exist in OOD or in any HPC portal.

**What it does:**

Every job submitted through a cloud compute adapter (Batch, SageMaker, EC2) is tagged with cost allocation metadata. CloudWatch Metrics aggregate costs. Dashboards and reports surface them.

**Tagging:**

Each adapter tags its resources with:

| Tag | Source | Example |
|---|---|---|
| `ood:user` | OIDC username | `scott.friedman` |
| `ood:group` | Cognito group / OIDC claim | `computational-biology` |
| `ood:project` | OOD job metadata (user-provided) | `grant-NIH-R01-12345` |
| `ood:backend` | Adapter type | `batch`, `sagemaker`, `ec2` |
| `ood:instance_type` | Compute resource | `c6i.xlarge`, `ml.g5.xlarge` |
| `ood:spot` | Pricing model | `true`, `false` |
| `ood:queue` | Job queue / partition | `gpu`, `cpu-spot` |

**Cost aggregation:**

```
AWS Cost Explorer (tag-based)
    │
    ├── Per-user daily cost → CloudWatch custom metric
    ├── Per-project monthly cost → CloudWatch custom metric
    └── Per-backend cost breakdown → CloudWatch custom metric
         │
         ▼
CloudWatch Dashboard
    ├── "Who is spending what" — bar chart by user
    ├── "Where is the money going" — pie chart by backend
    ├── "Project burn rate" — time series by project
    └── "Spot savings" — on-demand equivalent vs actual
         │
         ▼
Lambda (monthly digest)
    └── SES email to each PI:
        "Your group used $X in March.
         $Y on Batch (72% spot savings).
         $Z on SageMaker.
         Top user: jane.doe ($W)."
```

**Budget alarms:**

When `enable_cloudwatch_accounting=true`, the deployment creates AWS Budgets:

| Budget | Threshold | Action |
|---|---|---|
| Account total | Configurable (`cost_alert_threshold`) | SNS → admin |
| Per-project (if project tags used) | Configurable per project | SNS → PI |
| Spot vs On-Demand ratio | < 50% Spot (warning) | SNS → admin |

**Implementation:** A Lambda function (Go, deployed by CDK/Terraform) runs daily. It queries Cost Explorer for the tagged resources, publishes CloudWatch metrics, and generates the monthly digest. The Lambda is bundled in the `scripts/` directory and deployed as part of the observability module when the toggle is enabled.

---

## 5. Infrastructure as Code

### CDK Stack Architecture (Go)

```
aws-openondemand/
├── terraform/
│   ├── main.tf                  # Provider, backend, module composition
│   ├── variables.tf             # All variables: profile, toggles, environment, adapters
│   ├── outputs.tf               # SSM connect command, ALB URL, endpoints
│   ├── locals.tf                # Profile → instance type mapping, toggle logic
│   ├── modules/
│   │   ├── network/             # VPC, subnets, endpoints, security groups
│   │   ├── identity/            # Cognito, DynamoDB UID table, oidc-pam config
│   │   ├── storage/             # EFS (toggle: one-zone vs multi-AZ), S3, optional FSx
│   │   ├── portal/              # OOD EC2 instance, ASG, ALB (togglable), ACM, Route53
│   │   ├── session_cache/       # ElastiCache Redis or DynamoDB session store (Level 5)
│   │   ├── accounting/          # CloudWatch accounting Lambda, Budgets, dashboards (Level 7)
│   │   ├── adapters/
│   │   │   ├── onprem/          # VPN/DX, SSH connectivity
│   │   │   ├── parallelcluster/ # PCluster provisioning, consumes ood-pcluster-ref
│   │   │   ├── batch/           # Batch CEs, queues, job defs; installs ood-batch-adapter
│   │   │   ├── sagemaker/       # SageMaker domain, user profiles; installs ood-sagemaker-adapter
│   │   │   └── ec2/             # Launch templates; installs ood-ec2-adapter
│   │   └── observability/       # CloudWatch, alarms, SNS (togglable: basic vs advanced vs compliance)
│   └── environments/
│       ├── test.tfvars          # Minimal toggles, small sizing (~$35/mo)
│       ├── staging.tfvars       # Moderate toggles, medium sizing
│       └── prod.tfvars          # Full toggles, production sizing
├── cdk/
│   ├── main.go                  # CDK app entrypoint
│   ├── stacks/
│   │   ├── config.go            # Profile definitions, toggle parsing, environment defaults
│   │   ├── network.go           # VPC, subnets, endpoints, security groups
│   │   ├── identity.go          # Cognito, DynamoDB UID table, oidc-pam config
│   │   ├── storage.go           # EFS, S3, optional FSx
│   │   ├── portal.go            # OOD EC2 instance, ASG, ALB (togglable), ACM, Route53
│   │   ├── session_cache.go     # ElastiCache Redis or DynamoDB session store (Level 5)
│   │   ├── accounting.go        # CloudWatch accounting Lambda, Budgets, dashboards (Level 7)
│   │   ├── adapters/
│   │   │   ├── onprem.go
│   │   │   ├── parallelcluster.go
│   │   │   ├── batch.go
│   │   │   ├── sagemaker.go
│   │   │   └── ec2.go
│   │   └── observability.go
│   ├── cdk.json
│   ├── cdk.context.example.json # Example context with all toggles documented
│   ├── package.json
│   └── go.mod
├── packer/
│   ├── ood.pkr.hcl              # Packer template: AL2023 + OOD + oidc-pam + adapters
│   ├── scripts/
│   │   ├── bake.sh              # Install OOD, Apache, Passenger, PHP deps
│   │   ├── install-adapters.sh  # Download adapter binaries from GitHub releases
│   │   └── install-oidc-pam.sh  # Install oidc-pam from release
│   └── README.md
├── configs/
│   ├── ood/                     # OOD configuration templates
│   │   ├── ood_portal.yml.tmpl
│   │   ├── clusters/            # Cluster YAML templates per adapter
│   │   └── apps/                # Interactive app configs
│   │       └── s3-browser/      # S3 file browser OOD app (Level 6)
│   │           ├── manifest.yml
│   │           ├── app.rb       # Sinatra app: browse, presigned URLs, upload
│   │           ├── views/
│   │           └── lib/
│   │               └── s3_client.rb
│   └── oidc-pam/                # oidc-pam configuration templates
│       └── broker.yaml.tmpl
├── lambda/
│   └── accounting/              # Cost accounting Lambda (Level 7, Go)
│       ├── main.go              # Queries Cost Explorer, publishes CW metrics
│       ├── digest.go            # Monthly email digest via SES
│       └── go.mod
├── scripts/
│   ├── portal-setup.sh          # OOD instance user-data (boot-time config from SSM)
│   ├── bootstrap-terraform-backend.sh  # One-time S3 + DynamoDB for TF state
│   ├── teardown-terraform-backend.sh   # Clean up state backend after destroy
│   └── test/
│       ├── smoke-test-minimal.sh      # Verify minimal deployment works
│       ├── smoke-test-production.sh   # Verify full-toggle deployment works
│       └── smoke-test-adapters.sh     # Verify each adapter submits/launches
├── docs/
│   ├── getting-started-aws.md   # AWS newcomer guide (account, IAM, VPC, CLI)
│   ├── deployment-guide.md      # Profiles, toggles, environments explained
│   ├── adapter-guide.md         # How to configure each compute backend
│   ├── identity-guide.md        # OIDC provider setup, oidc-pam config, UID mapping
│   ├── architecture.md          # Architecture diagrams and design decisions
│   ├── cost-guide.md            # Toggle-by-toggle cost breakdown, example configurations
│   └── troubleshooting.md       # Common mistakes, bootstrap monitoring, WAF debugging
├── Makefile
├── LICENSE
├── CHANGELOG.md
└── README.md

# Standalone repos (separate GitHub repositories):
# github.com/scttfrdmn/ood-batch-adapter
# github.com/scttfrdmn/ood-sagemaker-adapter
# github.com/scttfrdmn/ood-ec2-adapter
# github.com/scttfrdmn/ood-pcluster-ref
# github.com/scttfrdmn/oidc-pam
```

### Deployment Interface

```bash
# Terraform — test environment, minimal defaults (~$35/mo)
cd terraform
terraform init
terraform apply -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=YOUR_IP/32'

# Terraform — production, all features
terraform apply -var-file=environments/prod.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='domain_name=ood.university.edu' \
  -var='alarm_email=ops@university.edu'

# CDK — test environment
cd cdk
npx cdk deploy -c environment=test -c vpcId=vpc-xxx -c allowedCidr=YOUR_IP/32

# CDK — production with specific overrides
npx cdk deploy -c environment=prod -c deploymentProfile=graviton \
  -c enableWaf=true -c enableComplianceLogging=true \
  -c domainName=ood.university.edu

# Deploy specific stacks only (portal, no compute backends yet)
terraform apply -var-file=environments/test.tfvars -target=module.network \
  -target=module.identity -target=module.storage -target=module.portal

# Add ParallelCluster to existing deployment
terraform apply -var-file=environments/prod.tfvars -var='adapters_enabled=["batch","parallelcluster"]'
```

### Configuration (cdk.json context)

```json
{
  "context": {
    "environment": "test",
    "deploymentProfile": "minimal",
    
    "vpcId": "vpc-xxx",
    "subnetId": "subnet-xxx",
    "allowedCidr": "0.0.0.0/0",
    "domainName": "ood.university.edu",
    "certificateArn": "arn:aws:acm:...",
    
    "identityProvider": "cognito",
    "cognitoSamlMetadataUrl": "https://idp.university.edu/metadata",
    "adminEmail": "hpc-admin@university.edu",
    
    "enableAlb": true,
    "enableWaf": false,
    "enableEfs": true,
    "enableEfsOneZone": false,
    "enableFsx": false,
    "enableVpcEndpoints": true,
    "enableCdn": false,
    "enableMonitoring": true,
    "enableAdvancedMonitoring": false,
    "enableComplianceLogging": false,
    "enableBackup": false,
    "enableKmsCmk": false,
    "enablePackerAmi": false,
    "enableSessionCache": false,
    "sessionCacheBackend": "redis",
    "enableS3Browser": false,
    "enableCloudwatchAccounting": false,
    
    "adaptersEnabled": ["batch", "sagemaker"],
    
    "onpremEnabled": false,
    "onpremVpnCidr": "10.100.0.0/16",
    "onpremHeadNode": "hpc-login.university.edu",
    
    "parallelclusterMaxNodes": 100,
    "parallelclusterGpuQueue": true,
    
    "batchSpotEnabled": true,
    "batchMaxVcpus": 256,
    
    "sagemakerDefaultInstanceType": "ml.t3.medium",
    
    "costAlertThreshold": 5000,
    "alarmEmail": "hpc-admin@university.edu"
  }
}
```

The same parameters work as Terraform variables in `.tfvars` files:

```hcl
# terraform/environments/test.tfvars
deployment_profile  = "minimal"
enable_alb          = false
enable_waf          = false
enable_efs          = true
enable_efs_one_zone = true
enable_vpc_endpoints = false
enable_monitoring   = false
# Total: ~$35/month
```

```hcl
# terraform/environments/prod.tfvars
deployment_profile        = "standard"
enable_alb                = true
enable_waf                = true
enable_efs                = true
enable_fsx                = true
enable_vpc_endpoints      = true
enable_monitoring         = true
enable_advanced_monitoring = true
enable_compliance_logging = true
enable_backup             = true
enable_packer_ami         = true
enable_session_cache      = true
enable_s3_browser         = true
enable_cloudwatch_accounting = true
# Total: ~$600/month (before compute)
```

---

## 6. Cloud-Native Progression

Each toggle independently tips OOD a little further into the cloud without rewriting the application. Together, they transform OOD from "bare-metal software running on a VM" to "cloud-native research computing portal." This is the same pattern as [aws-hubzero](https://github.com/scttfrdmn/aws-hubzero), where moving the database to RDS and the web root to EFS made the instance stateless enough for Spot — each toggle is valuable on its own, and they unlock new capabilities in combination.

### The Progression

```
Level 0          Level 1        Level 2         Level 3        Level 4
─────────────────────────────────────────────────────────────────────────
OOD on EC2       + EFS          + DynamoDB      + Cognito      + Spot
(bare-metal      /home          UID map         OIDC auth      Instance is
on a VM)         survives       replaces        replaces       stateless;
                 instance       LDAP            PAM/LDAP       ~70% cheaper
                 death                          auth           compute
     │                │              │              │              │
     ▼                ▼              ▼              ▼              ▼
Level 5          Level 6        Level 7
─────────────────────────────────────────
+ Session        + S3           + CloudWatch
  Cache            Browser       Accounting
  PUN state        Cloud data    Cloud-native
  survives         accessible    job cost
  instance         from OOD      tracking
  replacement
```

**Level 0: Just running on EC2** — `deployment_profile="minimal"`, all toggles off except basics.

OOD works the same as on bare metal, just on a cloud VM. This is what everyone does today when they put OOD on AWS. The instance is a pet — if it dies, everything dies.

**Level 1: `enable_efs=true`** — /home moves to EFS.

The instance becomes replaceable. OOD's file browser, user data, job scripts, and results all survive instance death. The ASG auto-recovery actually means something now — a replacement instance boots, mounts EFS, and users see their files. Still lose active sessions, but no data loss.

This is the equivalent of aws-hubzero's EFS toggle for the web root. It's the foundational move.

**Level 2: `enable_dynamodb_uid=true`** — UID mapping moves to DynamoDB.

This eliminates LDAP. In traditional OOD deployments, LDAP (or AD) is an entire server that someone maintains just to map usernames to Unix UIDs. The DynamoDB table does the same thing — oidc-pam's NSS module queries it on every node. It's serverless, it's backed up automatically, and there's no LDAP server to patch, replicate, or lose.

UIDs are now consistent across the OOD node, ParallelCluster compute nodes, Batch containers, and any future node that runs the NSS module. That's the prerequisite for multi-backend compute — without consistent UIDs, file ownership breaks across the OOD → compute boundary.

**Level 3: `use_cognito=true`** — Authentication moves to Cognito.

Local PAM authentication is replaced by OIDC. Cognito federates with the institution's SAML IdP (InCommon, Shibboleth, Azure AD, Okta) — users see their university login page, not a Linux password prompt. MFA is enforced at the IdP layer, not bolted onto PAM. oidc-pam bridges the OIDC token to a Unix session so OOD's Passenger/PUN model works unchanged.

This is the identity decoupling. The OOD instance no longer needs to be on the campus network or joined to the campus directory. It can run in any VPC, any region, any account.

**Level 4: `deployment_profile="spot"`** — Spot pricing, ~70% cheaper compute.

Now that /home is on EFS (Level 1), UIDs are in DynamoDB (Level 2), auth is in Cognito (Level 3), and config is in SSM Parameter Store, the OOD instance is stateless. When AWS reclaims a Spot instance, the ASG launches a replacement in ~3-5 minutes. Users lose active sessions but no data, no identity state, no configuration.

The `spot` profile enforces Levels 1-3 as deploy-time preconditions — you can't enable Spot without the external state stores that make it safe.

This is the same pattern as aws-hubzero, where the `spot` profile enforces `use_rds=true` and `enable_efs=true`.

**Level 5: `enable_session_cache=true`** — PUN session state moves to ElastiCache (Redis) or DynamoDB.

This is the toggle that makes Spot *transparent* to users, not just *survivable*. OOD's Per-User Nginx (PUN) processes keep session tokens and per-user state in local memory. When the instance dies, every active user is logged out and loses their in-progress work in the dashboard. With session caching, PUN state is externalized. A replacement instance restores user sessions from the cache. Users see a brief interruption, not a full re-login.

This is the equivalent of aws-hubzero's RDS toggle — it's the thing that moves from "the instance can die without data loss" to "the instance can die without users noticing much." It's also the prerequisite for future horizontal scaling: two OOD instances behind an ALB sharing session state.

Adds ElastiCache Redis (single-node, `cache.t3.micro`, ~$12/mo) or uses the existing DynamoDB table (~$0/mo additional but higher latency).

**Level 6: `enable_s3_browser=true`** — S3 browsing in OOD's file manager.

OOD's file browser speaks only POSIX. Researchers increasingly have data in S3. This toggle adds an S3 panel to OOD's file browser app — users can browse buckets, download via presigned URLs, upload from the browser, and drag files between their /home (EFS) and S3.

This is the first toggle that makes OOD cloud-aware rather than just cloud-hosted. It requires a small OOD app extension (a Rails engine that uses the AWS SDK instead of filesystem calls) shipped as part of this project.

Implementation: an OOD Passenger app (Ruby, using `aws-sdk-s3`) registered as a file browser alternative. Users see both "Home Directory" (EFS/POSIX) and "Cloud Storage" (S3) in the file browser navigation. The S3 access is controlled by the instance role — users see buckets tagged for their group or project.

**Level 7: `enable_cloudwatch_accounting=true`** — Cloud-native job accounting.

For cloud compute backends (Batch, SageMaker, EC2 adapter), job accounting goes to CloudWatch Metrics and Cost Allocation Tags instead of (or alongside) Slurm's sacct. Every job is tagged with username, group, project, backend, instance type, and whether it used Spot.

This produces:
- Per-user cost dashboards (CloudWatch dashboard or QuickSight)
- Per-project cost allocation reports (AWS Cost Explorer)
- Monthly cost digest emails per PI (Lambda + SES)
- Budget alarms per user or project (AWS Budgets)

This doesn't exist in the HPC world. Slurm tracks CPU-hours; this tracks dollars. For PIs managing cloud credit grants, this is the feature that matters.

### The Toggle Dependency Chain

```
Level 0: EC2 only (no toggles)
    │
    ├── Level 1: enable_efs ──────────────────┐
    │       │                                  │
    │       ├── Level 2: enable_dynamodb_uid   │
    │       │       │                          │
    │       │       ├── Level 3: use_cognito   │
    │       │       │       │                  │
    │       │       │       └── Level 4: spot profile
    │       │       │              (enforces 1+2+3)
    │       │       │                   │
    │       │       │                   └── Level 5: enable_session_cache
    │       │       │                          (most valuable with spot)
    │       │       │
    │       │       └── Level 6: enable_s3_browser
    │       │              (needs instance role, benefits from efs)
    │       │
    │       └── Level 7: enable_cloudwatch_accounting
    │              (independent, but most useful with cloud backends)
    │
    └── All levels are independently valuable
        The dependency chain shows the optimal order, not hard requirements
        (except spot, which enforces its preconditions)
```

### Migration Path: Existing OOD On-Prem → Cloud

For institutions currently running OOD on a bare-metal head node, the cloud-native progression doubles as a migration path:

**Phase 1: Lift and shift (weeks)** — Deploy at Level 0-3. OOD runs on EC2 with EFS, DynamoDB UIDs, and Cognito auth. On-prem adapter connects to existing cluster over VPN. Users see the same OOD, different URL, modern auth.

**Phase 2: Add cloud compute (months)** — Enable Batch and/or SageMaker adapters. Users choose "Campus HPC" or "AWS Cloud" as submission target. Enable `enable_cloudwatch_accounting` for cloud job cost tracking. Enable `enable_s3_browser` so users can access cloud datasets.

**Phase 3: Cloud-primary (when ready)** — Switch to `spot` profile (Level 4) for the OOD instance. Enable `enable_session_cache` (Level 5) for transparent failover. Migrate burst workloads to Batch, interactive sessions to SageMaker, steady-state stays on-prem.

**Phase 4: Cloud-native (optional)** — On-prem cluster decommissioned or kept for legacy. OOD on Spot with session caching, S3 browser, CloudWatch accounting, all cloud backends. The thing runs itself.

### From No OOD (Greenfield)

1. Deploy at Level 4-5 immediately (spot + session cache)
2. Enable Batch + SageMaker
3. Enable S3 browser and CloudWatch accounting
4. Add ParallelCluster only if Slurm compatibility is required
5. You skip levels 0-3 because you have no legacy to migrate from

---

## 7. Security Model

### Network Security

- No public IP on compute resources; OOD instance is private when `enable_alb=true`, public-subnet with SG lockdown when `enable_alb=false`
- When ALB enabled: all traffic ingresses via ALB (HTTPS only, TLS 1.2+)
- When ALB disabled: direct HTTPS on instance (certbot or self-signed for test)
- Admin access via SSM only (no SSH, no bastion)
- VPC endpoints for all AWS API calls when `enable_vpc_endpoints=true` (no internet traversal)
- WAF on ALB when `enable_waf=true` (CommonRuleSet, KnownBadInputs, SQLi in Block mode)

### Identity Security

- No static credentials anywhere
- OIDC tokens with configurable lifetime (default 8h)
- Short-lived SSH keys for on-prem connectivity (oidc-pam managed)
- IAM roles for all AWS API access (compute adapters, S3, etc.)
- MFA enforced at the IdP layer
- Session recording via CloudWatch Logs

### Data Security

- EFS encrypted at rest (AWS managed or CMK)
- EFS encrypted in transit (TLS mount)
- S3 bucket policies restrict access to VPC endpoint
- S3 browser access scoped by IAM session tags (user/group/project) — users see only their project's data
- Job outputs tagged with owner for access control
- DynamoDB UID table encrypted, access restricted to OOD + compute node roles
- Session cache (when enabled): ElastiCache Redis encrypted in-transit and at-rest; or DynamoDB with existing encryption
- No session tokens stored on local disk when session cache is enabled

### Compliance

- All authentication events logged (who, when, from where)
- All job submissions logged (who, what, which backend, cost)
- CloudTrail for AWS API activity
- Designed for FedRAMP Moderate environments (all services in-scope)
- HIPAA-eligible services throughout (EFS, S3, Batch, SageMaker, DynamoDB)

---

## 8. Deployment Profiles, Feature Toggles, and Environments

Following the same pattern as [aws-hubzero](https://github.com/scttfrdmn/aws-hubzero): profiles control compute strategy, feature toggles control infrastructure, environments control sizing. Everything is composable.

### Deployment Profiles

The profile sets the EC2 instance type and compute strategy. All other features are controlled independently.

| Profile | Instance | Arch | Pricing | Est. compute/mo | Best for |
|---|---|---|---|---|---|
| **`minimal`** *(default)* | t3.medium | x86_64 | On-Demand | ~$30 | Development, small labs, proof-of-concept |
| **`standard`** | m6i.xlarge | x86_64 | On-Demand | ~$140 | 50-100 concurrent users, production |
| **`graviton`** | m7g.xlarge | ARM64 | On-Demand | ~$112 | Same as standard, ~20% cheaper |
| **`spot`** | m6i.xlarge | x86_64 | Spot | ~$42-56 | Cost-sensitive; requires `enable_efs=true` |
| **`large`** | m6i.2xlarge | x86_64 | On-Demand | ~$280 | 200+ concurrent users, heavy PUN load |

**Override the instance size without changing the profile:**

```bash
# Terraform
deployment_profile = "standard"
instance_type      = "m6i.2xlarge"

# CDK
npx cdk deploy -c deploymentProfile=standard -c instanceType=m6i.2xlarge
```

### Feature Toggles

Every infrastructure feature is independently togglable. The defaults below produce a cost-optimized test deployment. Turn on what you need.

| Toggle | Default | What it controls | Cost impact |
|---|---|---|---|
| **Cloud-native progression (Level 1-3)** | | | |
| `enable_efs` | `true` | EFS for /home — Level 1: instance becomes replaceable | ~$30/mo per 100 GB |
| `enable_efs_one_zone` | `false` | Single-AZ EFS (~47% cheaper, less durable) | saves ~$14/mo per 100 GB |
| `enable_dynamodb_uid` | `true` | DynamoDB UID mapping — Level 2: replaces LDAP | ~$1/mo |
| `use_cognito` | `true` | Cognito OIDC — Level 3: replaces PAM/LDAP auth | free tier (50K MAU) |
| `enable_session_cache` | `false` | PUN session state in ElastiCache/DynamoDB — Level 5: Spot becomes transparent | ~$12/mo (Redis) or ~$0 (DynamoDB) |
| `enable_s3_browser` | `false` | S3 browsing in OOD file manager — Level 6: cloud data accessible | ~$0 (uses instance role) |
| `enable_cloudwatch_accounting` | `false` | Per-user/project cost tracking for cloud jobs — Level 7 | ~$5/mo |
| **Infrastructure** | | | |
| `enable_alb` | `true` | ALB with ACM cert, HTTPS termination, health checks | ~$20/mo |
| `enable_waf` | `false` | WAF v2 on ALB (CommonRuleSet, KnownBadInputs, SQLi) | ~$5/mo + $0.60/M requests |
| `enable_fsx` | `false` | FSx for Lustre scratch filesystem | ~$140/mo per 1.2 TiB |
| `enable_vpc_endpoints` | `true` | Interface endpoints for SSM, Secrets, Logs, etc. | ~$50/mo (5 endpoints) |
| `enable_cdn` | `false` | CloudFront distribution for static assets | ~$1/mo + data transfer |
| `enable_packer_ami` | `false` | Use pre-baked AMI (3-5 min boot vs 10-15 min) | $0 (AMI storage ~$0.50/mo) |
| **Observability & compliance** | | | |
| `enable_monitoring` | `true` | CloudWatch dashboard, alarms, SNS notifications | ~$10/mo |
| `enable_advanced_monitoring` | `false` | Per-user cost tracking, job metrics, anomaly detection | ~$20/mo |
| `enable_compliance_logging` | `false` | VPC Flow Logs, CloudTrail, Config Rules, Security Hub | ~$30-100/mo |
| `enable_backup` | `false` | AWS Backup for EFS + DynamoDB, cross-region copy | ~$10-50/mo |
| `enable_kms_cmk` | `false` | Customer-managed KMS keys (EFS, DynamoDB, S3, logs) | ~$1/mo per key |

**Spot profile preconditions:** the `spot` profile enforces `enable_efs=true`, `enable_dynamodb_uid=true`, and `use_cognito=true` at deploy time (Levels 1-3). When AWS reclaims a spot instance, the ASG launches a replacement in ~3-5 minutes. Without `enable_session_cache`, users lose active sessions but no data. With it, sessions survive.

### Environments

Environments control sizing — how big things are, not which features are on. Ship three defaults: `test`, `staging`, `prod`.

| Parameter | test | staging | prod |
|---|---|---|---|
| EBS root volume | 30 GB gp3 | 50 GB gp3 | 50 GB gp3 |
| EFS throughput | Elastic (burst) | Elastic (burst) | Provisioned |
| DynamoDB capacity | On-Demand | On-Demand | On-Demand |
| CloudWatch log retention | 7 days | 30 days | 90 days |
| Alarm email | optional | required | required |
| Multi-AZ EFS | no (unless toggled) | yes | yes |
| ASG health check grace | 600s | 300s | 300s |

### Example Deployments

**"I'm a PI with a credit grant and 10 students" — ~$35/month (Level 1-3):**

```bash
deployment_profile  = "minimal"
enable_alb          = false    # Direct access, no ALB cost
enable_waf          = false
enable_efs          = true     # Level 1: home dirs survive instance replacement
enable_efs_one_zone = true     # Single-AZ, cheaper
enable_dynamodb_uid = true     # Level 2: no LDAP needed
use_cognito         = true     # Level 3: institutional SSO
enable_vpc_endpoints = false
enable_monitoring   = false
```

**"Department cluster, 50 users, real workloads" — ~$235/month (Level 1-3 + infrastructure):**

```bash
deployment_profile  = "graviton"   # ARM64, 20% cheaper
enable_alb          = true
enable_waf          = true
enable_efs          = true         # Level 1
enable_dynamodb_uid = true         # Level 2
use_cognito         = true         # Level 3
enable_vpc_endpoints = true
enable_monitoring   = true
enable_s3_browser   = true         # Level 6: researchers access S3 data
enable_cloudwatch_accounting = true # Level 7: per-user cost tracking
domain_name         = "ood.cs.university.edu"
```

**"Institutional production, 200+ users, Spot, compliance" — ~$600/month (Level 1-7):**

```bash
deployment_profile        = "spot"            # Level 4: ~70% cheaper compute
instance_type             = "m6i.2xlarge"     # Override for user count
enable_alb                = true
enable_waf                = true
enable_efs                = true              # Level 1 (enforced by spot)
enable_dynamodb_uid       = true              # Level 2 (enforced by spot)
use_cognito               = true              # Level 3 (enforced by spot)
enable_session_cache      = true              # Level 5: sessions survive spot reclaim
enable_s3_browser         = true              # Level 6: cloud data accessible
enable_cloudwatch_accounting = true           # Level 7: dollar-denominated accounting
enable_fsx                = true
enable_vpc_endpoints      = true
enable_monitoring         = true
enable_advanced_monitoring = true
enable_compliance_logging = true
enable_backup             = true
enable_kms_cmk            = true
enable_packer_ami         = true
domain_name               = "ood.university.edu"
alarm_email               = "hpc-ops@university.edu"
```

**"Maximum cost savings, Spot, Batch only" — ~$40/month (Level 1-4):**

```bash
deployment_profile  = "spot"              # Level 4
enable_alb          = false
enable_efs          = true                # Level 1 (enforced)
enable_efs_one_zone = true                # Cheaper EFS
enable_dynamodb_uid = true                # Level 2 (enforced)
use_cognito         = true                # Level 3 (enforced)
enable_vpc_endpoints = false
enable_monitoring   = false
adapters_enabled    = ["batch"]
# Users lose sessions on spot reclaim but data is safe
# Add enable_session_cache=true (+$12/mo) for transparent failover
```

### Dual IaC: Terraform AND CDK

Both tools produce identical infrastructure. Users pick the one they know.

```bash
# Terraform
cd terraform
terraform init
terraform apply -var-file=environments/test.tfvars \
  -var='vpc_id=vpc-xxx' \
  -var='subnet_id=subnet-xxx' \
  -var='allowed_cidr=YOUR_IP/32'

# CDK (Go)
cd cdk
npx cdk deploy -c environment=test -c vpcId=vpc-xxx -c allowedCidr=YOUR_IP/32

# CDK with overrides
npx cdk deploy -c environment=prod -c deploymentProfile=graviton \
  -c enableWaf=true -c domainName=ood.university.edu
```

### Packer AMI

Pre-baked AMI drops boot time from 10-15 minutes to 3-5 minutes and ensures identical environments across instance replacements.

```bash
cd packer
packer init .
GIT_SHA=$(git rev-parse --short HEAD) packer build ood.pkr.hcl
```

The AMI includes OOD, oidc-pam, all adapter binaries, Apache, Nginx, Passenger, and the CloudWatch agent. Configuration is still pulled from SSM Parameter Store at boot — the AMI is the software, Parameter Store is the config.

### Variable Costs (Compute — Independent of Profile)

Compute costs are the same regardless of deployment profile. The profile controls portal infrastructure reliability, not compute pricing.

| Scenario | Backend | Monthly Cost |
|---|---|---|
| 10 users, light Jupyter use | SageMaker (ml.t3.medium) | ~$200 |
| 50 users, moderate HPC | Batch (c6i, Spot) | ~$2,000 |
| 100 users, heavy HPC + GPU | ParallelCluster + Batch | ~$15,000 |
| Burst: 1000 cores for 48 hours | Batch (Spot) | ~$500 per burst |

---

## 9. Project Roadmap

### v0.1.0 — Foundation (Month 1-2)

- [ ] Terraform modules: network, identity (Cognito + oidc-pam), storage (EFS), portal (OOD instance + ASG)
- [ ] CDK stacks: identical infrastructure to Terraform
- [ ] Cloud-native progression Levels 1-3: EFS /home, DynamoDB UID mapping, Cognito OIDC auth
- [ ] Deployment profiles: `minimal` and `standard` working
- [ ] Feature toggles: `enable_alb`, `enable_efs`, `enable_efs_one_zone`, `enable_vpc_endpoints`, `enable_monitoring`
- [ ] Environment configs: `test.tfvars`, `staging.tfvars`, `prod.tfvars`
- [ ] OOD installed and running with OIDC auth via oidc-pam
- [ ] SSM access, CloudWatch logging
- [ ] Documentation: getting-started-aws.md, deployment guide, cost guide
- [ ] **Deliverable:** A working OOD portal on AWS, cloud-native identity (no LDAP), deployable from $35/mo to $300/mo via toggles

### v0.2.0 — On-Prem Adapter (Month 2-3)

- [ ] VPN/DX integration in CDK
- [ ] On-prem cluster YAML template
- [ ] SSH key provisioning for OOD → on-prem connectivity (via oidc-pam)
- [ ] NFS-over-VPN mount for file browser
- [ ] UID sync tooling (LDAP → DynamoDB)
- [ ] **Deliverable:** University can point AWS-hosted OOD at their existing cluster

### v0.3.0 — Batch Adapter (Month 3-5) ← separate repo: ood-batch-adapter

- [ ] Batch adapter Go binary (submit, status, list, cancel)
- [ ] OOD job composer integration
- [ ] Standalone installation docs (works without aws-openondemand)
- [ ] Batch CDK construct in aws-openondemand (compute environments, queues, job definitions)
- [ ] EFS mounting in Batch containers
- [ ] Spot instance support
- [ ] Job output streaming to CloudWatch → OOD
- [ ] **Deliverable:** Cloud-native job submission from OOD, no Slurm required; installable on any OOD instance

### v0.4.0 — SageMaker Adapter (Month 5-6) ← separate repo: ood-sagemaker-adapter

- [ ] SageMaker adapter Go binary (launch, status, URL generation)
- [ ] OOD interactive apps integration (Jupyter, RStudio, VS Code)
- [ ] Standalone installation docs (works without aws-openondemand)
- [ ] SageMaker CDK construct in aws-openondemand (domain, user profiles, lifecycle configs)
- [ ] EFS integration with SageMaker notebooks
- [ ] Auto-stop configuration
- [ ] **Deliverable:** Interactive sessions without OOD reverse proxy; installable on any OOD instance

### v0.5.0 — ParallelCluster Reference (Month 6-7) ← separate repo: ood-pcluster-ref

- [ ] Reference PCluster configs: basic, GPU, burst, hybrid profiles
- [ ] Head node and compute node setup scripts (oidc-pam NSS, EFS)
- [ ] OOD cluster YAML generator (from PCluster outputs)
- [ ] Interactive app templates (Jupyter, RStudio) for PCluster batch_connect
- [ ] Shared EFS between OOD and PCluster
- [ ] FSx for Lustre scratch integration
- [ ] Standalone docs: works with hand-deployed OOD or aws-openondemand
- [ ] PCluster CDK construct in aws-openondemand for automated deployment
- [ ] **Deliverable:** Tested, documented PCluster + OOD integration; usable standalone or via CDK

### v0.6.0 — EC2 Adapter (Month 7-8) ← separate repo: ood-ec2-adapter

- [ ] EC2 adapter Go binary (launch, monitor, terminate)
- [ ] Launch templates for CPU/GPU/memory instance families
- [ ] Spot with On-Demand fallback
- [ ] Job output streaming
- [ ] **Deliverable:** All five compute backends operational; installable on any OOD instance

### v0.7.0 — Cloud-Native Progression (Month 8-9)

This milestone implements the features that tip OOD into the cloud without rewriting it — the same approach as aws-hubzero's RDS/EFS/Spot progression.

- [ ] **Level 4: `spot` profile** — deploy-time precondition enforcement (validates enable_efs + enable_dynamodb_uid + use_cognito)
- [ ] **Level 5: `enable_session_cache`** — PUN session state externalized to ElastiCache Redis (single-node cache.t3.micro) or DynamoDB; sessions survive instance replacement; Spot becomes transparent to users
- [ ] **Level 6: `enable_s3_browser`** — OOD Passenger app (Ruby + aws-sdk-s3) registered as file browser alternative; browse buckets, download via presigned URLs, upload via multipart; access controlled by instance role + resource tags
- [ ] **Level 7: `enable_cloudwatch_accounting`** — cost allocation tags on all Batch/SageMaker/EC2 adapter jobs (username, group, project, backend, instance type, spot); CloudWatch dashboard for per-user/project costs; monthly cost digest via Lambda + SES; per-PI budget alarms via AWS Budgets
- [ ] `graviton` profile
- [ ] Packer AMI template (OOD + oidc-pam + all adapters pre-installed)
- [ ] Remaining infrastructure toggles: `enable_compliance_logging`, `enable_backup`, `enable_kms_cmk`, `enable_cdn`
- [ ] **Deliverable:** Full cloud-native progression from Level 0 to Level 7; Spot with transparent failover; S3 data accessible from OOD; dollar-denominated job accounting

### v1.0.0 — Production Ready (Month 10-12)

- [ ] All profiles tested: minimal, standard, graviton, spot, large
- [ ] All cloud-native levels tested in combination (especially spot + session cache)
- [ ] Multi-backend simultaneous operation tested (on-prem + Batch + SageMaker + PCluster)
- [ ] Terraform AND CDK parity verified for all toggle combinations
- [ ] Security review (compliance-logging configurations)
- [ ] Performance testing (100+ concurrent users, spot failover under load)
- [ ] S3 browser tested with large datasets (10K+ objects, multi-GB files)
- [ ] CloudWatch accounting tested with multi-PI, multi-project workloads
- [ ] Complete documentation: getting-started, deployment, adapters, identity, cost, cloud-native progression, troubleshooting
- [ ] Reference deployment at a partner institution
- [ ] **Deliverable:** Production-grade, documented, tested deployment; composable from $35/mo bare-metal-on-cloud to $600/mo fully cloud-native with transparent Spot failover

---

## 10. Relationship to Other Projects

### Project / Repository Structure

The adapters are standalone projects. They're useful to anyone running OOD on AWS, regardless of whether they deployed via aws-openondemand. An institution that hand-rolled their OOD-on-EC2 two years ago isn't going to tear it down and redeploy — but they will install `ood-batch-adapter` as a binary and add a cluster config.

```
Standalone projects (each its own repo, independently useful):

  oidc-pam                 OIDC → PAM identity bridge for Linux
  ood-batch-adapter        OOD job adapter for AWS Batch (Go binary)
  ood-sagemaker-adapter    OOD interactive session launcher for SageMaker (Go binary)
  ood-ec2-adapter          OOD single-node compute via EC2 Launch Templates (Go binary)
  ood-pcluster-ref         Reference ParallelCluster configs + setup scripts for OOD
                           (not a custom adapter — OOD's native Slurm adapter works —
                            but the infrastructure wiring, shared storage, NSS setup,
                            and known-good PCluster config is the value)

Composition layer:

  aws-openondemand         Terraform + CDK deployment that wires everything together:
                           installs OOD, oidc-pam, and whichever adapters are enabled;
                           creates the Batch queues, SageMaker domains, PCluster configs,
                           VPN connectivity, EFS, IAM roles, observability;
                           profiles control compute, toggles control features,
                           environments control sizing
```

**Why ParallelCluster gets a reference repo, not a custom adapter:**

ParallelCluster is Slurm. OOD already knows how to talk to Slurm. There's no translation layer needed — OOD SSH's to the head node and runs sbatch. The hard part isn't the adapter; it's everything around it: the PCluster config that actually works with OOD, the shared EFS mount setup, the oidc-pam NSS installation on compute nodes so UIDs match, the security groups allowing SSH from OOD to the head node, and the FSx for Lustre scratch config. That's what `ood-pcluster-ref` packages: a tested, documented reference deployment that an admin can clone and customize.

```
ood-pcluster-ref/
├── configs/
│   ├── pcluster-basic.yaml        # Single queue, no GPU, EFS only
│   ├── pcluster-gpu.yaml          # CPU + GPU queues, Spot
│   ├── pcluster-burst.yaml        # Max autoscaling, Spot-heavy, FSx scratch
│   └── pcluster-hybrid.yaml       # Minimal always-on + burst to Spot
├── scripts/
│   ├── head-node-setup.sh         # Post-install: oidc-pam NSS, EFS, Slurm accounting
│   ├── compute-node-setup.sh      # Post-install: oidc-pam NSS, EFS mount
│   └── ood-cluster-config.sh      # Generates OOD cluster YAML from PCluster outputs
├── ood-configs/
│   ├── cluster.yml.tmpl           # OOD cluster config template
│   └── interactive-apps/          # Jupyter, RStudio batch_connect templates for PCluster
├── docs/
│   ├── QUICKSTART.md
│   ├── ARCHITECTURE.md
│   └── TROUBLESHOOTING.md
└── README.md
```

### Dependency Graph

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Scott Friedman's Stack                             │
│                                                                       │
│  Standalone tools:                                                    │
│  ┌──────────────┐ ┌───────────────┐ ┌────────────────┐              │
│  │ oidc-pam     │ │ ood-batch-    │ │ ood-sagemaker- │              │
│  │              │ │ adapter       │ │ adapter        │              │
│  │ Identity     │ │               │ │                │              │
│  │ OIDC → PAM   │ │ OOD → Batch   │ │ OOD → SM      │              │
│  └──────┬───────┘ └──────┬────────┘ └───────┬────────┘              │
│         │                │                   │                       │
│  ┌──────┴──┐     ┌──────┴────────┐  ┌───────┴────────┐             │
│  │ ood-ec2-│     │ ood-pcluster- │  │                │             │
│  │ adapter │     │ ref           │  │                │             │
│  └────┬────┘     └──────┬────────┘  │                │             │
│       │                 │           │                │             │
│  ─────┴─────────────────┴───────────┴────────────────┘             │
│       │                                                             │
│       ▼                                                             │
│  Deployment layer:                                                   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ aws-openondemand                                             │   │
│  │ Terraform + CDK (Go) — composes all above + AWS infrastructure │   │
│  │ Profiles: minimal → standard → graviton → spot → large        │   │
│  │ Toggles: ALB, WAF, EFS, VPC endpoints, monitoring, compliance │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  Sibling project:                                                     │
│  ┌──────────────┐                                                    │
│  │ aws-hubzero  │  Same deployment patterns, same identity layer     │
│  └──────────────┘                                                    │
│                                                                       │
│  Future:                                                              │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ open.2026 — Unified research computing portal                │   │
│  │ Consumes: oidc-pam, all adapters (portable Go binaries)     │   │
│  │ Replaces: OOD portal layer, HubZero community layer          │   │
│  │ Keeps: JupyterHub for interactive, adapters for compute     │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**oidc-pam** is the linchpin. It's not just a dependency — it's the architectural decision that makes everything else possible. Without it, every project reinvents the identity bridge. With it, the portal layer and the compute layer are cleanly decoupled.

**The adapters are portable.** Each is a Go binary with a CLI interface. They work with any OOD installation — deployed by aws-openondemand, deployed by hand, deployed by someone's two-year-old Terraform. When open.2026 replaces the portal layer, the adapters plug in unchanged.

**aws-hubzero** proves the deployment pattern. Same VPC design, same ALB + private subnet topology, same SSM access model, same profile/toggle/environment philosophy. Institutions that deploy one are pre-educated on the other.

**The composable deployment model is the differentiator.** Anyone can write a Terraform module that puts OOD on an EC2 instance. What they can't do — because they don't know AWS well enough — is design the right toggle set so a PI deploys for $35/month and a CIO deploys for $600/month with compliance logging, and both use the same codebase with the same upgrade path. That's the value of having done this for 200+ institutions at AWS: knowing which services to make optional, which defaults to set, and which corners are safe to cut.
