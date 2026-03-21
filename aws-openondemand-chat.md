

❯ Questions Only - what other portals, similar to hubzero are there that could use this kind of treatment? What about re-factoring hubzero into a new project using modern approaches and cloud techniques but has a clean migration path from hubzero? Call it hub.2026.1 or something? What about OpenOnDe

pasted

I just developed a project that cleanly deploys hubzero to AWS, https://github.com/scttfrdmn/aws-hubzero
Here is a conversation that followed that:

6:53 PM

Synthesized technical discussion on research computing modernization strategies
Synthesized technical discussion on research computing modernization strategies
This is a really sharp strategic thread, Scott. A few reactions:

The unified portal insight is the key takeaway. The observation that HubZero and OOD are two halves of the same problem — community/publishing vs. computation/interactive apps — is exactly right. The research computing community has been maintaining two aging systems that together cover the full feature set but individually don't. That's the kind of structural insight that makes a rewrite worth doing rather than just patching.

The JupyterHub-as-compute-layer pragmatic path is the right call. JupyterHub has already solved the hardest cloud-native problems (container-based sessions, Kubernetes scheduling, websocket proxying, multi-tenant auth via OIDC). Rebuilding that from scratch would be a waste. Using it as the interactive compute substrate and building the portal/community/job-submission layers on top is the 80/20 play.

On the PAM coupling in OOD — this is the thing that makes aws-openondemand genuinely harder than aws-hubzero. HubZero's debt is mostly in the application layer (PHP/Joomla), but OOD's debt is in the infrastructure coupling. Every assumption about PAM, shared filesystems, and scheduler locality has to be worked around in a cloud deployment. An honest aws-openondemand project would need to ship an opinionated answer to the identity question (probably Cognito + SSSD for the UID mapping bridge) or it'll just be another ad-hoc deployment that breaks when institutions try to customize it.

The sequencing argument is sound — ship aws-openondemand to build credibility and community relationships, then use that position to advocate for modernization. That's how you get from "infrastructure project" to "product project" without needing institutional buy-in on day one.

A couple of things I'd push back on or add:

The hub.2026 / open.2026 idea is compelling but the political dimension might be the binding constraint, not the technical one. Purdue and OSC both have NSF funding relationships tied to their respective projects. A neutral rewrite would need either a new funding vehicle (an NSF CSSI grant, maybe?) or a coalition like ACCESS to champion it. Have you thought about whether this is something you'd want to drive from outside those institutions — maybe as part of your own business?

Also, the Rappture compatibility shim is probably harder than the conversation suggests. Rappture tool manifests aren't just config files — they encode entire UIs with custom widget types. A "Rappture → K8s Job" translator would need to also generate a web frontend for each tool, which is basically a mini product in itself.

What's your instinct on next move — aws-openondemand as the near-term project, or are you more drawn to the bigger rewrite play?

Could this project help with OOD? https://github.com/scttfrdmn/oidc-pam

6:54 PM

Identified potential solution addressing core architectural constraint
Identified potential solution addressing core architectural constraint
Yes — this is actually the missing puzzle piece for decoupling OOD from its PAM dependency. It's a precise fit.

The core problem identified in your conversation was that OOD's PAM coupling is the root of most pain — your web session literally becomes a Unix user session, and everything downstream (file browsing, job submission, interactive apps) depends on that. The conversation concluded that a modern replacement needs OIDC/SAML as first-class auth with the Unix UID/GID mapping being an optional integration layer.

That's exactly what oidc-pam does. It sits at the PAM layer and bridges OIDC identity to Unix identity, which means you could deploy OOD in a cloud environment where:

The user authenticates via Cognito, Okta, or institutional SAML/OIDC — the modern identity path. oidc-pam handles the translation to the Unix user session that OOD expects. The UID/GID mapping happens at the PAM boundary rather than requiring /etc/passwd to be the source of truth. You get audit trails, key lifecycle management, and MFA for free — things OOD has no story for today.

The particularly elegant thing is that this is non-invasive to OOD itself. You don't have to fork or rewrite OOD's auth stack. OOD calls PAM, PAM calls oidc-pam, oidc-pam talks OIDC. From OOD's perspective, the user still has a Unix session. From the infrastructure perspective, identity is cloud-native.

This also makes the aws-openondemand project much more tractable. The original conversation identified the identity question as the thing that had to be solved or else the project would be "just another ad-hoc deployment." With oidc-pam, you have the opinionated answer: Cognito as the OIDC provider, oidc-pam as the bridge to PAM, and OOD runs unmodified on top. That's a deployable, repeatable stack.

And if you eventually pursue the bigger open.2026 rewrite, oidc-pam is still useful as the identity bridge for any component that still needs POSIX user semantics (shared filesystems, Slurm job submission under a real UID, etc.) while the portal layer itself speaks pure OIDC.

You're building a coherent stack here: aws-hubzero, oidc-pam, and a future aws-openondemand aren't isolated projects — they're layers that compose.

I also want an aws-openondemand because its deployment on AWS is a mess. I want it as clean as it can be and point to either an on-prem cluster(s) or something in the cloud, parallelcluster (even though that is aging and mostly dumb for the cloud), AWS Batch, or something else, custom, or Sagemaker window.

6:57 PM

Architected pluggable compute backend strategy for clean deployment
Architected pluggable compute backend strategy for clean deployment
This is the right project at the right time. The OOD-on-AWS situation right now is basically every institution hand-rolling their own Terraform/CloudFormation that works for their specific cluster and breaks for everyone else. You already proved with aws-hubzero that you can take a messy on-premises application and produce a clean, repeatable AWS deployment. OOD is the same problem with one added dimension: the compute backend is variable.

The architecture that makes sense is to treat OOD as a portal tier that's cleanly separated from a pluggable compute tier, with oidc-pam sitting at the boundary handling identity. Something like:

The OOD tier is the part you fully own and make clean — a single EC2 instance (or ECS task eventually), deployed via CDK or Terraform, with OOD installed and configured, oidc-pam handling auth, EFS for the shared home directory illusion, SSM for access, CloudWatch for logging. This part is the same regardless of what compute backend sits behind it. That's the core deliverable and it should be rock solid.

The compute adapter layer is where it gets interesting. OOD talks to compute through "cluster configs" — basically YAML files that define how to submit jobs and where interactive sessions run. Today those assume localhost sbatch or SSH to a head node. Your project would ship multiple adapter profiles:

For on-prem clusters, OOD connects over VPN or Direct Connect and SSH's to the existing Slurm/PBS head node. This is the most conservative path and what most universities will want first — they're not moving their cluster, they just want a better portal in front of it. The oidc-pam bridge is critical here because the on-prem cluster still expects Unix UIDs, and you need those to match across the VPN boundary.

For ParallelCluster, you're right that it's aging and the abstraction is leaky — it's essentially "pretend you have an on-prem cluster but in EC2." But it's what a lot of institutions are already using for cloud burst, so supporting it is pragmatic. The adapter here is OOD SSH'ing to the ParallelCluster head node, same as on-prem but over a VPC peering instead of a VPN. You'd ship a reference ParallelCluster config that's known-good with your OOD deployment.

For AWS Batch, this is the genuinely cloud-native path and the most interesting one. OOD doesn't have a Batch adapter today, so you'd need to write one — a custom OOD job adapter that translates OOD job submission into Batch API calls and maps Batch job states back to what OOD expects. This is real work but not enormous; the OOD adapter interface is documented and people have written custom ones before. The payoff is huge: no head node to manage, no Slurm to maintain, spot instances for cost, and it actually makes sense for the cloud.

For SageMaker, this is a smart inclusion because a lot of the "interactive apps" use case in OOD (Jupyter, RStudio, VS Code) maps directly to SageMaker notebook instances or Studio. Rather than OOD launching a Jupyter session as a Slurm job and reverse-proxying to it, you'd launch a SageMaker instance and redirect the user. This sidesteps OOD's most fragile piece — the interactive app reverse proxy — entirely.

Custom/direct EC2 is worth having as an option too. Some workloads just need a beefy instance for a few hours. An adapter that spins up an EC2 instance from a launch template, runs the job, and terminates it is simpler than Batch for single-node work.

The thing that makes this project cohere rather than being five separate projects is that the OOD tier is identical across all backends. You deploy aws-openondemand once, you get the portal, and then you configure which compute backends are available — maybe all of them simultaneously for different job queues. A university could have "on-prem-gpu" pointing at their local DGX cluster, "cloud-burst-cpu" pointing at Batch, and "interactive" pointing at SageMaker, all from the same OOD instance.

The oidc-pam piece ties it together at the identity layer. The user authenticates once via institutional SSO, oidc-pam gives them a Unix session on the OOD node, and each compute adapter handles credential propagation to its backend in its own way — SSH keys for on-prem, IAM roles for Batch/SageMaker, SSSD for ParallelCluster.

Where I'd start: ship the OOD tier plus the on-prem-via-VPN adapter first. That's useful immediately to the largest number of institutions and proves the deployment is clean. Then add Batch as the first cloud-native backend, because that's the differentiating feature no one else has packaged. ParallelCluster and SageMaker can follow as the community asks for them.

This plus aws-hubzero plus oidc-pam is becoming a portfolio that says "I'm the person who makes research computing software actually deployable on cloud." That's a credible foundation for the business you're building.

I am that person.
Think about each of these elements and spec out a design for aws-openondemand with all the various elements we discussed

7:00 PM

Architected comprehensive AWS-OpenOndemand design across all components
Architected comprehensive AWS-OpenOndemand design across all components
You are. Let me build this out properly.


Synthesized architectural components for AWS design specification
Synthesized architectural components for AWS design specification
Here's the full design spec. A few things I want to call out about the decisions baked in:

The Batch adapter is the real differentiator. The on-prem and ParallelCluster adapters are "make existing patterns cleaner" — useful but incremental. The Batch adapter is something that doesn't exist anywhere. It's a genuine new capability: submit HPC jobs from OOD without running Slurm at all. That's the thing that gets attention.

The SageMaker adapter sidesteps OOD's hardest problem rather than trying to solve it. The interactive app reverse proxy is where most OOD cloud deployments break. Instead of fixing that (which would require forking OOD), the SageMaker path just redirects the user to a presigned URL. OOD becomes the launcher, SageMaker handles the session. Elegant because it's less code, not more.

The DynamoDB UID table replacing LDAP is a quiet but important decision. Every HPC center maintains LDAP or AD for UID consistency across nodes. Replacing that with a DynamoDB table that oidc-pam's NSS module queries is simpler, serverless, and eliminates an entire infrastructure component. It also means UID mappings survive instance replacement — there's no LDAP server to lose.

The roadmap is sequenced for credibility-building. v0.1 (portal only) is useful immediately as a demo. v0.2 (on-prem adapter) serves the largest existing audience. v0.3 (Batch) is the marquee feature. Each version is independently deployable and valuable, so you're never six months from something you can show.

The adapters are standalone Go binaries with a CLI interface, which means they survive a portal rewrite. When open.2026 happens, these plug in unchanged.

Aws openondemand design
Document · MD 
Should the batch, sagemaker pieces be their own projects? I think so unless they depend on this deployment

7:08 PM

Validated architectural separation based on adapter independence
Validated architectural separation based on adapter independence
You're right, and for a clear reason: the adapters are useful to anyone running OOD on AWS, not just people who deploy via aws-openondemand.

An institution that hand-rolled their own OOD-on-EC2 setup two years ago — they're not going to tear it down and redeploy with your CDK stack. But they absolutely would install ood-batch-adapter as a standalone binary and add a cluster config. Same for SageMaker. The value of those adapters isn't coupled to the deployment automation. They're coupled to OOD itself.

So the project structure becomes:

ood-batch-adapter — standalone Go binary. Implements OOD's job adapter CLI interface. Takes OOD job specs, translates to Batch API calls. Ships as a release binary and a YUM/APT package. Zero dependency on aws-openondemand. Its README says "install this on your OOD node, add this cluster YAML, configure your Batch queues."

ood-sagemaker-adapter — same pattern. Standalone Go binary. Launches SageMaker sessions, returns presigned URLs. Works with any OOD installation.

ood-ec2-adapter — same again. Launches EC2 instances from launch templates, monitors them, streams output.

aws-openondemand — the CDK deployment project. It consumes oidc-pam, ood-batch-adapter, ood-sagemaker-adapter, and ood-ec2-adapter as dependencies. It installs them, configures them, and wires up the AWS infrastructure they need (Batch queues, SageMaker domains, IAM roles, etc.). But it's the composition layer, not the only way to use those pieces.

This mirrors what you already did with oidc-pam — it's a separate project that aws-openondemand depends on, not a subdirectory of it. The dependency graph is:

oidc-pam              (standalone)
ood-batch-adapter     (standalone)
ood-sagemaker-adapter (standalone)
ood-ec2-adapter       (standalone)
    │
    └──► aws-openondemand (composes all of the above + CDK infrastructure)
The on-prem and ParallelCluster adapters don't need their own projects because they use OOD's built-in Slurm adapter — the work there is purely infrastructure (VPN, SSH connectivity, shared filesystems), which lives naturally in the CDK stacks.

This also changes the audience for each project. The adapters target OOD administrators and the OOD developer community directly. aws-openondemand targets institutions doing greenfield AWS deployments or full migrations. Different people, different entry points, same ecosystem.

And it makes the portfolio even more legible: six repos, each with a tight scope, each independently useful, all composable. That's exactly the pattern that builds trust in open source — people adopt the piece they need, then discover the rest.

Did you include a parallel cluster adapter (example) in the design? We should.
The differentiator for aws-openondemand is that I know what I am doing with AWS and that team that deployed it two years ago almost certainly does not (I see this first hand at AWS). One feature of aws-hubzero are the deployment options, from super cheap to bullet proof. I want to do the same thing here.

7:10 PM

Reconciled ParallelCluster documentation needs and tiered deployment options
Reconciled ParallelCluster documentation needs and tiered deployment options
Yes, ParallelCluster is in the design (section 4.3.2, v0.5.0 in the roadmap), but you're right to flag it — it should be more prominent. And the point about deployment tiers is exactly the kind of thing that separates "someone who knows AWS" from "someone who deployed a thing on AWS once."

Let me update the design doc with both.


Restructured documentation to showcase ParallelCluster adapter and deployment tier options
Restructured documentation to showcase ParallelCluster adapter and deployment tier options
Now let me make the updates. First, adding a new design principle and the deployment tiers section:


Restructured documentation to emphasize flexible deployment options
Restructured documentation to emphasize flexible deployment options
Now replace the cost model section with full deployment tiers:


Restructured project architecture to highlight adapter modularity
Restructured project architecture to highlight adapter modularity
Now update the project relationship section to reflect standalone adapter repos and add the ParallelCluster reference:


Reconsidered architecture to incorporate tiered deployment flexibility
Reconsidered architecture to incorporate tiered deployment flexibility
Now update the CDK configuration to include the tier parameter:


Revised deployment interface to showcase tiered configuration examples
Revised deployment interface to showcase tiered configuration examples
Update the deployment interface to show tier-based deployments:


Reconsidered architecture to incorporate parallel cluster adapter example
Reconsidered architecture to incorporate parallel cluster adapter example
Now update the roadmap to reflect standalone adapter repos and add ood-pcluster-ref:


Pivoted portal tier section toward deployment flexibility awareness
Pivoted portal tier section toward deployment flexibility awareness
Now update the portal tier to be tier-aware instead of hardcoding m6i.xlarge:


Reconsidered architectural framework to incorporate tiered deployment options
Reconsidered architectural framework to incorporate tiered deployment options
Now update the CDK source tree to include tier logic and reflect standalone adapter consumption:


Synthesized feature requirements and deployment flexibility considerations
Synthesized feature requirements and deployment flexibility considerations
Updated design doc with both additions. Here's what changed:

Deployment tiers replace the flat cost model. Four profiles — Lab ($75/mo), Department ($235/mo), Center ($500/mo), Enterprise ($1,200/mo) — all from one CDK codebase with a single context parameter. The Lab tier is the key insight: a PI with an AWS credit grant and 10 students can deploy OOD for the cost of a t3.large by skipping the ALB, using single-AZ EFS, and putting the instance in a public subnet with SG-only protection. That's the kind of decision you make when you know which corners are safe to cut — and it's the kind of thing the team that deployed OOD two years ago absolutely did not do. They either over-provisioned (triple NAT gateways for a 10-person lab) or under-provisioned (no recovery, no monitoring, wide-open security groups).

ParallelCluster gets its own reference repo (ood-pcluster-ref) rather than being buried as a CDK construct. The reasoning: PCluster uses OOD's native Slurm adapter, so there's no custom binary to write. The value is the infrastructure wiring — tested PCluster configs (basic, GPU, burst, hybrid), head/compute node setup scripts for oidc-pam NSS, OOD cluster YAML generators, and interactive app templates. That's independently useful to anyone running PCluster + OOD, even if they never touch aws-openondemand.

The full repo map is now seven projects:

oidc-pam ← exists
ood-batch-adapter ← new, standalone
ood-sagemaker-adapter ← new, standalone
ood-ec2-adapter ← new, standalone
ood-pcluster-ref ← new, standalone reference configs
aws-openondemand ← composition layer, consumes all the above
aws-hubzero ← exists, sibling project
Aws openondemand design
Document · MD 
It is worth you looking closely at the aws-hubzero solution to see exactly what I am talking about.

7:18 PM

Reconsidered architecture philosophy from profiles and toggles rather than tiers
Reconsidered architecture philosophy from profiles and toggles rather than tiers
Good — now I see exactly what you mean. The aws-hubzero pattern is fundamentally different from what I put in the design doc, and it's better.

The key differences:

Profiles, not tiers. aws-hubzero has deployment profiles (minimal, graviton, spot) that control the compute strategy — instance type, architecture, pricing model. That's it. They don't dictate the rest of the infrastructure.

Every feature is an independent boolean toggle. use_rds, enable_alb, enable_efs, enable_vpc_endpoints, enable_waf, enable_cdn — each one stands alone. You compose your deployment from toggles, not by selecting a monolithic tier. A PI can run minimal profile with no ALB and no RDS for $35/month. An HPC center can run graviton profile with RDS + ALB + WAF + EFS + VPC endpoints. Those aren't different "tiers" — they're different toggle combinations.

Environments set sizing, not topology. test.tfvars, staging.tfvars, prod.tfvars control how big things are (EBS volume, RDS instance class, RDS storage, multi-AZ) — not which features are on or off.

Dual IaC — Terraform AND CDK. Both produce identical infrastructure. Users pick the tool they already know.

Packer for AMI baking. Pre-baked AMI drops boot time from 10-15 minutes to 3-5 minutes and ensures identical environments across replacements.

Instance type is overridable independent of profile. You can run minimal profile but bump to t3.large without changing anything else.

My design doc's monolithic "Lab/Department/Center/Enterprise" tier system is the wrong pattern. It locks features to tiers in ways that don't make sense — why should WAF require "Center" tier? An institution might want WAF on a $75/month deployment. The aws-hubzero approach of composable toggles is more honest about how people actually deploy.

Let me rework the design doc to match this pattern.


Orchestrated configuration updates to eliminate tier nomenclature
Orchestrated configuration updates to eliminate tier nomenclature
Now update the CDK config section and deployment interface to match:


Pivoted toward examining AWS HubZero deployment interface specifics
Pivoted toward examining AWS HubZero deployment interface specifics
Now update the roadmap and CDK tree to remove tier references. Let me also note the key changes and what I'd flag to update in a next pass. The updated doc is at the same output path.

The critical patterns I pulled from aws-hubzero that change the design:

Composable, not monolithic. aws-hubzero doesn't have tiers. It has profiles (compute strategy), toggles (boolean features), and environments (sizing). You compose by turning things on/off. A $35/month deployment and a $600/month deployment use the same code — one just has more toggles flipped. This is fundamentally more flexible than "pick a tier."

Dual IaC. Terraform AND CDK, both producing identical infrastructure. The design doc was CDK-only. Universities already have Terraform expertise; forcing CDK adoption is a barrier. Both should be first-class.

Packer AMI baking. Pre-baked AMIs drop boot from 10-15 minutes to 3-5 minutes. The design now includes this.

Instance type override independent of profile. You can run minimal but bump to t3.large for a bigger lab without switching profiles.

SSM Parameter Store for config, not baked AMI. The AMI has the software, Parameter Store has the config. Instance replacement pulls fresh config at boot.

Getting-started docs for AWS newcomers. aws-hubzero has a 550-line getting-started guide that walks through account setup, IAM, VPC/subnet discovery, and common mistakes. aws-openondemand needs the same.

There are still a few references to tiers in the roadmap and the CDK source tree that I'd clean up in a next pass, plus adding terraform/ and packer/ directories to the project structure to match the dual-IaC pattern. Want me to continue with those updates?

Continue

7:26 PM

Deliberated on streamlining documentation structure
Deliberated on streamlining documentation structure
Now update the roadmap:


Strategized removal of tier references from project relationships
Strategized removal of tier references from project relationships
Now update the project relationships section:


Refined configuration details and updated principles
Refined configuration details and updated principles
Good — that one is the principle statement saying "not a monolithic tier," which is correct. Now let me also update the architecture diagram section header to mention the ALB being toggleable, and fix the security model to acknowledge the ALB-off path:


Validated terminology across multiple architectural contexts
Validated terminology across multiple architectural contexts
All clean — "portal tier" is an architectural layer name, "monolithic tier" is explicitly saying we don't do that, and "free tier" is AWS terminology.


Reconciling section ordering with infrastructure-as-code structure
Reconciling section ordering with infrastructure-as-code structure
Changes Made
1. CDK-only replaced with dual IaC: Terraform + CDK (Go). Both produce identical infrastructure. The project tree now has terraform/ with modules, environments, and .tfvars files alongside cdk/ with Go stacks. Users pick the tool they know. This matches aws-hubzero exactly.

2. Monolithic tiers replaced with composable profiles + toggles + environments. Three independent axes:

Profiles (minimal, standard, graviton, spot, large) — control instance type and pricing strategy
Toggles (16 independent booleans) — each feature is on or off: enable_alb, enable_waf, enable_efs, enable_vpc_endpoints, enable_compliance_logging, etc.
Environments (test, staging, prod) — control sizing only (EBS, throughput, log retention)
3. Packer AMI baking added. packer/ood.pkr.hcl pre-bakes OOD + oidc-pam + all adapter binaries. Boot drops from 10-15 minutes to 3-5 minutes. Config still comes from SSM Parameter Store at boot.

4. Instance type override independent of profile. deployment_profile=minimal + instance_type=t3.large works — you keep the pricing strategy but change the size.

5. Four concrete example deployments showing how toggles compose: $35/month PI lab, $235/month department, $600/month institutional production, $40/month maximum-savings spot.

6. Project source tree includes docs/getting-started-aws.md (AWS newcomer guide), scripts/bootstrap-terraform-backend.sh / teardown-terraform-backend.sh, smoke tests per configuration, and .tfvars environment files — all matching the aws-hubzero pattern.

7. Security model updated to acknowledge the ALB-off path (public subnet with SG lockdown) as a valid cheap deployment rather than a missing feature.

Aws openondemand design
Document · MD 
Continue

7:49 PM

Prioritized README creation following established documentation patterns
Prioritized README creation following established documentation patterns
The design doc is the RFC. What people actually see first is the README. Let me produce one that follows the aws-hubzero README pattern exactly — deployment profiles up front, architecture diagram, quick start, feature toggles, environments, monitoring bootstrap, security features, and clean destroy instructions.


Architected documentation framework adapting existing patterns
Architected documentation framework adapting existing patterns
Now the getting-started-aws.md — this is the doc that makes the project accessible to people who aren't AWS experts, which is most of the OOD community:


Devised concrete examples demonstrating configuration toggle patterns
Devised concrete examples demonstrating configuration toggle patterns
Now the environment tfvars files — these are the things people actually copy and edit:


Inventoried completed deliverables
Inventoried completed deliverables
Six files. Here's what each one is and why it matters:

README.md — the front door. Follows the aws-hubzero README structure almost line-for-line: deployment profiles table up top, architecture diagram, feature toggles table, quick start for both Terraform and CDK, environment configs, bootstrap monitoring, SSM access, security features, clean destroy instructions. Someone who's used aws-hubzero will immediately recognize the pattern.

aws-openondemand-design.md — the RFC. Now fully updated: profiles/toggles/environments instead of monolithic tiers, dual IaC throughout, Packer AMI baking, composable deployment examples, standalone adapter repos, ood-pcluster-ref as a reference repo.

docs/getting-started-aws.md — the AWS newcomer guide. Account setup, IAM, CLI config, VPC/subnet discovery, what-this-creates tree diagram, cost estimates, common mistakes with specific error messages and fixes. This is the document that makes the project accessible to the OOD community, most of whom are HPC sysadmins not cloud engineers.

test.tfvars — $35/month. Every toggle has a comment explaining why it's on or off. Someone copies this file, fills in three values, and runs terraform apply. That's it.

staging.tfvars — $235/month. Graviton, ALB, WAF, VPC endpoints, monitoring. The department deployment.

prod.tfvars — $600/month. Everything on. Compliance logging, backup, KMS CMK, Packer AMI, all three compute backends. The institutional deployment. The comments note where to uncomment on-prem VPN settings.

The tfvars files are the key UX insight from aws-hubzero: people don't read design documents to figure out how to deploy. They copy a .tfvars file, change three variables, and run terraform apply. The toggle comments in the file are the documentation for most users.

Readme
Document · MD 
Aws openondemand design
Document · MD 
Getting started aws
Document · MD 
Test
TFVARS 
Staging
TFVARS 
Prod
TFVARS 
One of the other differentiators on aws-hubzero is that some of the options tip hubzero into the cloud a little without rewriting the whole thing (even though it needs it), RDS, EFS, even Spot! Do we have that kind of thing going on here?

7:55 PM

Inventoried cloud-native toggles for OOD, identified gaps versus HubZero
Inventoried cloud-native toggles for OOD, identified gaps versus HubZero
Yes and no. We have some of it but we're not calling it out the way aws-hubzero does, and we're missing a few moves that are right there for the taking.

In aws-hubzero, the incremental cloud-native story is clear: local MariaDB → RDS (database survives instance death), local web root → EFS (filesystem survives instance death), and once both of those are external, Spot becomes possible because the instance is stateless. Each toggle independently makes the deployment more resilient, and together they unlock a pricing strategy that wouldn't be safe without them. The spot profile enforces the preconditions. That's elegant.

Here's what we have in the design that does the same thing, and what we're missing:

What we already have:

EFS for /home is the direct equivalent of aws-hubzero's EFS for web root — it makes the instance replaceable. DynamoDB for UID mapping replaces LDAP, which is actually a bigger deal than RDS replacing MariaDB, because LDAP is an entire server that someone has to maintain. Cognito replacing local PAM auth is another managed-service substitution. SSM Parameter Store externalizing config is the same pattern. And Spot works because of all of the above.

What we're missing — and these are the good ones:

OOD has state that we're not externalizing yet. The Per-User Nginx (PUN) processes keep session state in local memory and on local disk. When the instance dies — or when Spot reclaims it — every active user session is killed. That's the equivalent of HubZero losing its database on instance death before RDS. We should have a toggle for that.

There's also OOD's built-in SQLite databases — the active jobs tracking, the recently used apps, the user preferences. Those are local files right now. They could be on EFS (trivially, since /home is already EFS) or in DynamoDB.

And the big one nobody has done: OOD's file browser only speaks POSIX. Researchers increasingly have data in S3. An S3 browser panel — even just mounting S3 via a FUSE layer or adding presigned URL generation — would be a cloud-native improvement that makes OOD actually useful for cloud data, not just cloud compute.

Here's what the toggle progression should look like, where each one tips OOD further into cloud without rewriting it:

Level 0: Just running on EC2 — OOD works the same as on bare metal, just on a cloud VM. This is what everyone does today.

Level 1: enable_efs=true — /home moves to EFS. Instance is replaceable. PUN processes still die on instance loss but user data survives. This is the minimum for the ASG auto-recovery to be meaningful.

Level 2: enable_dynamodb_uid=true — UID mapping moves from /etc/passwd or LDAP to DynamoDB. No LDAP server to run. UIDs are consistent across OOD and any compute node that runs the NSS module. This eliminates an entire infrastructure component.

Level 3: use_cognito=true — Authentication moves from local PAM + LDAP to Cognito + oidc-pam. Institutional SAML federation happens in Cognito, not in Apache modules with hand-edited XML. MFA comes free.

Level 4: enable_spot=true (the spot profile) — Now that /home is on EFS, UIDs are in DynamoDB, and auth is in Cognito, the instance is stateless enough for Spot. Same pattern as aws-hubzero: the spot profile enforces levels 1-3 as preconditions.

Level 5: enable_session_cache=true — This is the new one. PUN session tokens and OOD's per-user state go to ElastiCache (Redis) or DynamoDB instead of local disk. Active user sessions survive instance replacement. This is the equivalent of aws-hubzero's RDS toggle — it's the thing that makes Spot genuinely transparent to users instead of merely survivable. And it's the first step toward horizontal scaling (two OOD nodes behind an ALB), even though we don't do that in v1.

Level 6: enable_s3_browser=true — OOD's file browser gets an S3 panel alongside the POSIX filesystem view. Users can browse S3 buckets, download via presigned URLs, upload from the browser. This doesn't exist in OOD today but it's a relatively small addition (OOD's file browser is a Rails app with a filesystem backend — adding an S3 backend is a known pattern). This makes OOD actually cloud-aware rather than just cloud-hosted.

Level 7: enable_cloudwatch_accounting=true — Job accounting for cloud backends (Batch, SageMaker, EC2) goes to CloudWatch metrics and cost allocation tags instead of Slurm's sacct. PIs can see per-user, per-project costs in a CloudWatch dashboard. This is cloud-native accounting that doesn't exist in the HPC world.

That's the story. Each toggle independently makes the deployment better, and together they transform OOD from "bare-metal software running on a VM" to "cloud-native research computing portal" — without forking or rewriting OOD.

The design doc should present this as a progression, the same way someone reading aws-hubzero's README can see the path from "everything on one instance" to "stateless spot instance with managed services." Want me to add this to the design doc and update the toggle tables?

Incorporate these

8:16 PM

Orchestrated comprehensive documentation restructuring across multiple components
Orchestrated comprehensive documentation restructuring across multiple components
First, the big one — rewrite the migration path section to tell the cloud-native progression story:


Orchestrated toggle table integration
Orchestrated toggle table integration
Now update the toggle table with the three new toggles:


Orchestrated example deployments with progressive toggle integration
Orchestrated example deployments with progressive toggle integration
Update the example deployments to show the progression:


Orchestrated documentation and configuration updates
Orchestrated documentation and configuration updates
Now update the README toggle table:


Recalibrated text replacement strategy
Recalibrated text replacement strategy
Now update the README example deployments table:


Orchestrated configuration file updates across multiple environments
Orchestrated configuration file updates across multiple environments
Now update the tfvars files:


Orchestrated roadmap updates with new feature integration
Orchestrated roadmap updates with new feature integration
Now update the roadmap to include the new features:


Restructured roadmap versioning for feature integration
Restructured roadmap versioning for feature integration
The roadmap needs the cloud-native features slotted in. v0.6.0 should be split: the EC2 adapter is one milestone, and the cloud-native progression features (session cache, S3 browser, CloudWatch accounting) are another — probably v0.7.0. Here's what should go there:

v0.7.0 — Cloud-Native Features (Month 8-9):

enable_session_cache: PUN session state in ElastiCache Redis or DynamoDB. This + spot profile = transparent failover.
enable_s3_browser: OOD Passenger app (Ruby + aws-sdk-s3) that adds S3 panel to the file browser. Presigned URLs for download, multipart upload from browser.
enable_cloudwatch_accounting: Per-user/project cost tags on Batch/SageMaker/EC2 jobs. CloudWatch dashboard. Monthly cost digest via Lambda+SES. Budget alarms per PI.
spot profile precondition enforcement (validates levels 1-3 at deploy time)
Packer AMI + graviton profile
Then v1.0.0 moves to Month 10-12 and includes testing all the cloud-native levels in combination.

Copy the updated files down — the design doc, README, getting-started guide, and all three tfvars now tell a coherent story: each toggle independently tips OOD further into the cloud, the spot profile enforces its preconditions, and the session cache is the thing that makes spot transparent rather than merely survivable. Same pattern as aws-hubzero, but with more levels because OOD has more state to externalize.

Continue

8:51 PM

Identified need to expand component design documentation
Identified need to expand component design documentation
Now add component design sections for the three new features. They need the same level of detail as the adapters:


Orchestrated software stack refinement with emerging components
Orchestrated software stack refinement with emerging components
Update the portal software stack to include the new components:


Orchestrated infrastructure updates across deployment frameworks
Orchestrated infrastructure updates across deployment frameworks
Update the source tree to include the new components:


Deliberated security model enhancements
Deliberated security model enhancements
Update security model to cover the new components:


Orchestrated integration of toggles into configuration framework
Orchestrated integration of toggles into configuration framework
Update the CDK context JSON to include new toggles:


Orchestrated file compilation and presentation
Orchestrated file compilation and presentation
Now copy everything to outputs:


Synthesized prior contributions
Synthesized prior contributions
Here's what changed in this round:

Section 6 is now "Cloud-Native Progression" instead of "Migration Path." It tells the story as a seven-level toggle progression — the same pattern as aws-hubzero where RDS + EFS unlocked Spot, but with more levels because OOD has more state to externalize. Each level is described with what it does, why it matters, what it replaces, and what it unlocks. The dependency chain is explicit: Spot enforces Levels 1-3, session cache is most valuable with Spot, S3 browser needs the instance role, CloudWatch accounting needs cloud backends.

Three new component designs (4.7, 4.8, 4.9):

Session Cache (4.7) — The key insight is that most OOD per-user state is already on EFS (SQLite databases in /home). The only thing that doesn't survive instance death is the PUN session token. Externalizing just that one thing — to ElastiCache Redis ($12/mo) or a DynamoDB partition ($0) — is what makes Spot transparent instead of merely survivable. It's a surgical fix, not a rewrite.

S3 Browser (4.8) — A Sinatra/Rails OOD app that uses aws-sdk-s3. Browse, download via presigned URLs, upload via multipart, copy between S3 and /home. Access scoped by IAM session tags propagated from Cognito groups through oidc-pam. This is the first feature that makes OOD cloud-aware rather than cloud-hosted. Shipped as part of aws-openondemand, not a standalone repo, because it depends on the IAM role configuration.

CloudWatch Accounting (4.9) — The thing that doesn't exist in HPC: dollar-denominated job accounting. Every cloud job is tagged with user/group/project/backend/instance-type/spot. A Lambda queries Cost Explorer daily, publishes CloudWatch metrics, and sends monthly digest emails to PIs. Budget alarms per project. This is the feature PIs managing credit grants actually need.

The migration path is now embedded in the progression — Phase 1 is "deploy at Levels 0-3," Phase 2 is "add cloud compute + Levels 6-7," Phase 3 is "go Spot + Level 5," Phase 4 is "fully cloud-native." Greenfield deployments skip straight to Level 4-5 because there's no legacy.

Roadmap v0.7.0 is the new cloud-native milestone (Month 8-9) that ships session cache, S3 browser, CloudWatch accounting, spot preconditions, Packer AMI, and the remaining infrastructure toggles. v1.0.0 moves to Month 10-12 and tests all levels in combination.

Aws openondemand design
Document · MD 
Readme
Document · MD 
Getting started aws
Document · MD 
Test
TFVARS 
Staging
TFVARS 
Prod
TFVARS 





Claude is AI and can make mistakes. Please double-check responses.
1Password menu is available. Press down arrow to select.
