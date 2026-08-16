# INFRA-203 | Cloud Infrastructure Provisioning: Terraform Against AWS, IAM Authentication, and the Cost of Untracked State

**Date:** Day 10
**Ticket:** INFRA-203
**Scope:** Provision a real AWS EC2 instance — including security group and SSH key pair — entirely via Terraform using the `hashicorp/aws` provider. Configure IAM authentication through the AWS CLI credential chain in WSL2. Resolve resource type selection errors, cross-resource reference mistakes, and a large binary commit that polluted the Git repository history. SSH into the running instance to verify end-to-end provisioning. Document production requirements for remote state and locking that the local workflow does not satisfy.
**Outcome:** EC2 instance, security group, and key pair provisioned entirely through Terraform with zero manual console interaction. SSH access verified from WSL2 terminal using the Terraform-registered key pair. Git history cleaned of provider binary pollution. Production gap between local state and a team-grade remote backend identified and documented.

---

## Objective

Days 8 and 9 established the Terraform workflow against a local Docker daemon — a controlled environment where mistakes cost nothing, latency is zero, and the blast radius of any error is a container on a development machine. The workflow is identical regardless of target. The provider changes. The resource types change. The authentication model changes. The state reconciliation model — declare intent, plan the delta, apply, inspect state — does not.

Day 10 removes the local abstraction and points the same workflow at real AWS infrastructure. The consequences of errors are no longer contained to a local environment: a misconfigured security group exposes a public IP address to the internet, a forgotten running instance accrues billing charges, and an IAM credential committed to version control is a security incident with a clock attached. These are not hypothetical risks introduced for pedagogical effect — they are the routine operational realities of cloud infrastructure management, encountered here at the smallest possible scale so that the habits formed are correct ones.

The target is a free-tier EC2 instance. The exercise is not about EC2. It is about the discipline of treating cloud infrastructure the same way the previous two days treated Docker containers: declared in code, owned by Terraform, verifiable, and destroyable with a single command.

---

## Architecture

```
WSL2 (Ubuntu)
├── ~/.aws/credentials              ← IAM access key + secret (aws configure)
├── ~/.ssh/day10_key                ← private key (never leaves this machine)
├── ~/.ssh/day10_key.pub            ← public key (registered with AWS via Terraform)
│
└── terraform/ec2-provisioning/
    ├── main.tf                     ← provider + three resource declarations
    ├── .terraform.lock.hcl         ← hashicorp/aws provider version lock
    └── terraform.tfstate           ← state: EC2 ID, SG ID, key pair name

    Provisioning graph (Terraform-resolved):
    aws_key_pair.deployer ──────────────────────────────────┐
    aws_security_group.web_sg ──────────────────────────────┤
                                                             ↓
                                              aws_instance.example
                                                  │
                                                  ↓
                                         EC2: t3.micro, ap-south-1
                                         AMI: ami-00d2dbb426772b03a
                                         Public IP → SSH verified ✅

    Authentication chain:
    terraform apply
         └── hashicorp/aws provider
                  └── ~/.aws/credentials (written by aws configure)
                           └── IAM user: programmatic access
                                    └── EC2FullAccess policy
```

---

## Project Structure

```
sample-next-app/
├── k8s/
├── helm/
├── terraform/
│   ├── main.tf                     # Day 8-9 Docker provider config — unchanged
│   └── modules/registry/           # Day 9 module — unchanged
└── terraform/ec2-provisioning/     # introduced this day — separate Terraform root
    ├── main.tf                     # AWS provider + security group + EC2 + key pair
    ├── .terraform/                 # provider plugin cache — .gitignored
    ├── .terraform.lock.hcl         # provider version lock — committed
    └── terraform.tfstate           # infrastructure state — .gitignored
```

The EC2 provisioning configuration is a separate Terraform root from the Docker configuration. They have independent state files and independent provider configurations. Terraform's working directory model enforces this boundary — running `terraform apply` in one root has no awareness of, and no effect on, the other.

---

## Pre-Implementation Analysis

### The authentication layer — what changes when the target is cloud

The Docker provider authenticates via a Unix socket on the local machine. There is no credential to manage, no IAM policy to reason about, and no network boundary between Terraform and the Docker daemon. The security model is filesystem permissions.

AWS is the opposite. Every API call that creates, modifies, or destroys infrastructure must be authenticated and authorised. Terraform does not maintain its own AWS credentials. It reads from the credential chain that the AWS CLI populates — the files written by `aws configure`. This means verifying AWS CLI authentication with `aws sts get-caller-identity` is a prerequisite to any Terraform operation against AWS: if the CLI cannot reach AWS, Terraform cannot either.

The IAM principal running Terraform must have the permissions required by every resource being managed. For this exercise: `AmazonEC2FullAccess`. In production, the principle of least privilege applies — a Terraform IAM role with precisely the permissions required for the specific resources it manages, nothing more. An overpermissioned Terraform principal is a privilege escalation vector.

### The three-resource dependency model

Provisioning an accessible EC2 instance requires three resources with a clear dependency chain:

```
aws_key_pair        → registered with AWS before instance creation
aws_security_group  → firewall rules established before instance creation
aws_instance        → references both; cannot be created without them
```

Terraform resolves this graph automatically through the reference expressions in the `aws_instance` resource block. `vpc_security_group_ids = [aws_security_group.web_sg.id]` and `key_name = aws_key_pair.deployer.key_name` create explicit dependency edges. The plan output reflects the correct creation order without any manual ordering by the operator.

An EC2 instance created without a `key_name` is permanently inaccessible via SSH. AWS injects the public key into the instance at boot through the instance metadata service — it does not provide a recovery path if no key was specified at creation time. The instance must be terminated and recreated. This is not a recoverable error. It is a design constraint that makes the key pair resource non-optional in any provisioning workflow that requires SSH access.

### Security group scope

The security group declares two ingress rules — SSH on port 22 and HTTP on port 80 — and a permissive egress rule allowing all outbound traffic. Port 22 is exposed to `0.0.0.0/0` for lab accessibility. In a production environment, SSH access is restricted to a bastion host CIDR, a VPN egress range, or removed entirely in favour of AWS Systems Manager Session Manager, which provides shell access without requiring an open SSH port. The `0.0.0.0/0` CIDR on port 22 is an explicit lab trade-off, not a pattern to carry forward.

`protocol = "-1"` on the egress rule is an AWS convention meaning all protocols. This is the standard permissive egress configuration — restricting outbound traffic requires explicit allow rules for every external service the instance communicates with, which is operationally complex and rarely applied at the instance level outside highly regulated environments.

---

## Implementation

### 1. Provider configuration

The `hashicorp/aws` provider is declared with version constraint `~> 6.0` — permitting patch and minor version upgrades within the 6.x line without allowing a major version change. The provider block declares `region = "ap-south-1"`. All resources are provisioned in this region. AMI IDs, availability zones, and default VPC configuration are all region-scoped — a configuration valid in `ap-south-1` is not portable to `us-east-1` without updating region-specific values.

### 2. `aws_security_group` resource

The security group is created with two ingress blocks and one egress block declared inline. Each ingress block specifies a protocol, port range, and CIDR. The security group is named via a hardcoded string — `project-security-sg` — with a comment noting this as a temporary simplification pending parameterisation into a variable.

The security group's `id` attribute is an output computed by AWS at creation time. It is referenced in the `aws_instance` resource as `aws_security_group.web_sg.id` — the same cross-resource reference pattern used in Days 8 and 9 for the Docker image-to-container dependency.

### 3. `aws_key_pair` resource

The public key generated locally via `ssh-keygen` is registered with AWS under the name `Kaustav_void_aws`. AWS stores the public key and associates it with this name in the `ap-south-1` region. When the EC2 instance is launched with `key_name` referencing this pair, AWS injects the public key into the instance's `~/.ssh/authorized_keys` at boot. The corresponding private key (`~/.ssh/day10_key`) never leaves the local machine and is never declared in Terraform configuration.

The `key_name` argument in `aws_key_pair` is a plain string label — the name under which the key is registered in AWS. It is not a reference to another resource and does not follow the `resource_type.local_name.attribute` reference syntax.

### 4. `aws_instance` resource

The instance is declared with the `ap-south-1` AMI ID for Amazon Linux, `t3.micro` instance type (free-tier eligible in `ap-south-1`), the security group attached via `vpc_security_group_ids`, and the key pair attached via `key_name`. A `Name` tag is applied — in AWS, the Name tag is the human-readable identifier visible in the console and in CLI output. Resources without Name tags are operationally invisible in environments with many resources.

### 5. SSH verification

After `terraform apply` completed, the instance public IP was retrieved from `terraform show`. SSH access was verified:

```bash
ssh -i ~/.ssh/day10_key ec2-user@<public-ip>
```

`ec2-user` is the default user on Amazon Linux AMIs. Ubuntu AMIs use `ubuntu`. The username is AMI-specific — an incorrect username produces a permission denied error that is frequently misdiagnosed as a key or security group problem.

---

## Incident 1 — Wrong Security Group Resource Type

### Symptom

Initial `main.tf` used `aws_security_group_rule` as the resource type for the firewall configuration. The block structure attempted to define ingress rules with a `security_group_id` referencing a group that did not exist in the configuration.

### Root Cause Analysis

The AWS provider exposes two distinct resources for security group management: `aws_security_group` creates a security group and optionally defines rules inline. `aws_security_group_rule` adds a single rule to an *existing* security group — it is an additive resource that requires a pre-existing group to attach to.

The first implementation used the additive resource where the creating resource was required. The `security_group_id` argument attempted to reference a security group that was not declared anywhere in the configuration — meaning the reference resolved to nothing and the rule had no group to attach to.

This class of error — selecting the wrong resource from a set of similarly-named resources in the same provider — is common when working from documentation without reading the resource description before the argument list. The resource name encodes its purpose. `aws_security_group` creates. `aws_security_group_rule` modifies. Reading the description before the arguments is not optional discipline; it is the step that determines whether the correct resource is being used at all.

### Resolution

Replaced `aws_security_group_rule` with `aws_security_group`. Moved ingress and egress rule definitions into inline blocks within the security group resource. The group and its rules are now declared as a single unit, created atomically by a single resource block.

### Operational Principle

Provider resource naming conventions are semantically significant. In the AWS provider, the pattern `aws_<service>` typically creates a primary resource; `aws_<service>_<modifier>` typically creates an associated or dependent resource. `aws_instance` vs `aws_launch_template`. `aws_security_group` vs `aws_security_group_rule`. `aws_iam_role` vs `aws_iam_role_policy_attachment`. Misidentifying which resource to use produces errors that look like configuration problems but are actually resource selection problems. The fix is always the same: read the resource documentation before writing the block.

---

## Incident 2 — Self-Referencing `key_name` in `aws_key_pair`

### Symptom

The `aws_key_pair` resource was authored with:

```hcl
key_name = aws_key_pair.deployer_key.key_name
```

This referenced a resource called `deployer_key` that did not exist in the configuration. The actual resource local name was `deployer`.

### Root Cause Analysis

The `key_name` argument carries different semantics depending on which resource it appears in. In `aws_instance`, `key_name` is a reference — it tells AWS which registered key pair to inject into the instance, and it should reference the `aws_key_pair` resource's `key_name` output attribute. In `aws_key_pair` itself, `key_name` is a declaration — it is the plain string name under which the key pair is registered in AWS.

The error applied the cross-resource reference syntax (`resource_type.local_name.attribute`) to an argument that expected a plain string. The result was a reference to a non-existent resource and a misspelled local name simultaneously.

### Resolution

Replaced the reference expression with a plain string literal: `key_name = "Kaustav_void_aws"`. AWS registers the key pair under this name in the `ap-south-1` region.

### Operational Principle

Argument semantics are resource-specific. An argument named `key_name` in `aws_key_pair` is not the same kind of value as an argument named `key_name` in `aws_instance`, even though they share a name. The former is an identifier being assigned. The latter is a pointer to an existing identifier. The Terraform documentation for each resource defines what each argument expects — a reference, a plain value, or a computed expression. Reading the argument type before writing the value is what prevents this class of error.

---

## Incident 3 — Provider Binary Committed to Git, Exceeding GitHub File Size Limit

### Symptom

`git push` to the remote repository was rejected:

```
remote: error: File app/sample-next-app/terraform/ec2-provisioning/.terraform/providers/
registry.terraform.io/hashicorp/aws/6.57.1/linux_amd64/terraform-provider-aws_v6.57.1_x5
is 844.01 MB; this exceeds GitHub's file size limit of 100.00 MB

remote: error: GH001: Large files detected.
```

### Root Cause Analysis

The `.terraform/` directory was not present in `.gitignore` before the first `git add`. The entire provider plugin cache — including the AWS provider binary at 844MB — was staged and committed as part of the initial commit. GitHub's file size limit of 100MB per file caused the push to be rejected entirely.

The problem was compounded by Git's content-addressable history model: once a file is committed, it exists in the repository's object store regardless of whether it is subsequently removed from the working tree or unstaged. A `git rm --cached` removes the file from future tracking but does not remove it from the commit history. GitHub inspects the full history on push, not just the current working tree state — the 844MB binary was still present in the prior commit and triggered the rejection.

### Resolution

The provider binary was removed from the entire Git history using `git filter-branch`, rewriting every commit that contained the file. The rewritten history was force-pushed to the remote. The `.gitignore` was confirmed to contain the correct entries before any subsequent commit.

The standard `.gitignore` for any Terraform project:

```
# Provider plugin cache — platform-specific binary, auto-generated by terraform init
.terraform/

# State files — may contain sensitive resource attributes
*.tfstate
*.tfstate.backup

# Variable files — may contain credentials or environment-specific secrets
*.tfvars

# Lock file exception — this IS committed; it pins provider versions
# !.terraform.lock.hcl
```

### Operational Principle

`.terraform/` is to Terraform what `node_modules/` is to Node.js — a dependency cache that is auto-generated, platform-specific, and never committed to version control. Anyone cloning the repository runs `terraform init` and receives the correct provider binary for their platform and architecture. Committing the cache couples the repository to a specific OS and processor architecture, bloats version history with hundreds of megabytes of binary content that cannot be diffed or reviewed, and provides zero value over the auto-generation that `init` provides.

The `.gitignore` must exist and must include `.terraform/` before the first `git add` in any Terraform project. This is not a best practice that can be applied retroactively without history rewriting — and history rewriting in a shared repository requires coordination with everyone who has cloned it, since their local histories diverge from the rewritten remote. The cost of the omission scales with the size of the team.

`*.tfstate` in `.gitignore` is equally non-negotiable. State files contain computed resource attributes — and depending on the resources managed, may contain sensitive values such as database passwords, private key material, or IAM secret keys written into state by providers that expose them as resource outputs. State belongs in a remote backend with access controls and encryption at rest, not in version control.

---

## Production Gap Analysis — What This Workflow Does Not Satisfy

The local workflow used in this exercise is not suitable for a team environment or a production system. Two specific gaps must be addressed before this configuration could manage real production infrastructure.

**Remote state backend (S3)**

`terraform.tfstate` currently lives on the local filesystem in WSL2. This creates three operational risks: if the machine is lost or the file is deleted, Terraform loses its record of what it manages — subsequent applies will attempt to create duplicate resources and fail, or succeed and create duplicates depending on the provider's uniqueness enforcement. No other engineer can run Terraform operations because they have no access to the state. There is no audit trail of who applied what change and when.

The resolution is an S3 backend with versioning enabled:

```hcl
terraform {
  backend "s3" {
    bucket = "terraform-state-bucket"
    key    = "ec2-provisioning/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

State is stored in S3, accessible to any principal with the appropriate IAM permissions, versioned so that any previous state can be recovered, and encrypted at rest using S3 server-side encryption.

**State locking (DynamoDB)**

The S3 backend alone does not prevent concurrent applies. If two engineers run `terraform apply` simultaneously against the same state, both read the current state, both compute a plan, and both write the result — the second write overwrites the first, producing a state file that does not reflect what either apply actually did. The result is state corruption.

A DynamoDB table configured as a lock provider ensures that only one apply can hold the state at a time. The apply acquires a lock before reading state, holds it through the plan and apply phases, and releases it on completion. Any concurrent apply that attempts to acquire the lock receives an error and waits or exits, depending on configuration.

```hcl
terraform {
  backend "s3" {
    bucket         = "terraform-state-bucket"
    key            = "ec2-provisioning/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-state-lock"
  }
}
```

These two components — S3 for storage, DynamoDB for locking — are the minimum viable remote backend for any Terraform configuration managed by more than one person or run from more than one machine.

---

## Key Concepts Documented

**Terraform's authentication model is credential-chain delegation, not embedded credentials.** Terraform does not store AWS credentials. It reads them from the environment — the credential file populated by `aws configure`, environment variables, or an instance profile if running on EC2. This design means Terraform inherits the security posture of the credential it reads. A long-lived IAM user access key in `~/.aws/credentials` is as long-lived as the file. An IAM role assumed via an instance profile expires with the session. In CI/CD pipelines, OIDC-based role assumption with short-lived tokens is the correct model — no static credentials, no rotation management, no credential leak risk.

**AMI IDs are region-scoped and not stable across time.** The same operating system release is represented by different AMI IDs in different AWS regions. Additionally, AWS periodically deprecates AMIs as new releases supersede them — an AMI ID that resolves today may not resolve in six months. In production, AMI IDs are not hardcoded in Terraform configuration. They are resolved at plan time using a `data "aws_ami"` data source that queries the AWS API for the latest AMI matching specified filters — owner, name pattern, architecture. This ensures the configuration always provisions the current release without requiring manual AMI ID updates.

**Free-tier instance type eligibility is region-specific.** `t2.micro` is the free-tier instance type in most AWS regions. In `ap-south-1`, `t3.micro` is the free-tier eligible type. Assuming a globally-applicable free tier instance type and not verifying against the target region's current free tier documentation is a reliable path to unexpected charges. Free tier terms are documented per-region and subject to change.

**`terraform destroy` is not optional after verification in a cost-incurring environment.** A running EC2 instance consumes free tier hours regardless of whether it is being actively used. The free tier allocation of 750 hours per month is consumed by calendar time, not utilisation time. An instance left running for 31 days exhausts the monthly allocation entirely. The habit of destroying infrastructure immediately after the deliverable is verified is not caution for its own sake — it is the operational discipline that prevents a learning exercise from generating a billing surprise at the end of the month.

**Security group ingress rules are a trust boundary, not a firewall configuration detail.** Opening port 22 to `0.0.0.0/0` means any IP address on the internet can attempt an SSH connection to the instance. The connection will fail without the private key — but the attempt will succeed in reaching the port. This exposes the instance to automated scanning, brute-force attempts against any other authentication mechanisms, and exploitation of any SSH implementation vulnerabilities. In production, port 22 is either restricted to known CIDR ranges or removed entirely. The lab trade-off is acceptable because the instance is ephemeral and key-only authentication is enforced. The principle is not.

---

## Commands Reference

```bash
# IAM and CLI verification
aws configure                                        # write IAM credentials to ~/.aws/credentials
aws sts get-caller-identity                          # verify Terraform can authenticate to AWS

# SSH key generation
ssh-keygen -t rsa -b 4096 -f ~/.ssh/day10_key       # generate key pair; pub registered with AWS

# Terraform workflow
terraform init                                       # download hashicorp/aws provider (~844MB)
terraform plan                                       # review what will be created — read before applying
terraform apply                                      # provision EC2, SG, key pair in ap-south-1
terraform show                                       # inspect full state including public IP
terraform destroy                                    # tear down all resources — run immediately after verification

# SSH verification
ssh -i ~/.ssh/day10_key ec2-user@<public-ip>         # ec2-user for Amazon Linux; ubuntu for Ubuntu AMIs

# Git hygiene
git rm -r --cached .terraform/                       # remove provider cache from Git tracking
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch '<file-path>'" \
  --prune-empty --tag-name-filter cat -- --all       # rewrite history to remove large binary
git push origin main --force                         # force push rewritten history
```

---

## Deliverable Status

✅ `main.tf` authored — AWS provider, security group, EC2 instance, key pair
✅ IAM credentials configured in WSL2 — `aws configure` completed, `aws sts get-caller-identity` verified
✅ SSH key pair generated — `~/.ssh/day10_key` and `day10_key.pub` present in WSL2
✅ Wrong resource type (`aws_security_group_rule`) diagnosed and replaced with `aws_security_group`
✅ Self-referencing `key_name` error diagnosed and corrected to plain string literal
✅ `key_name` added to `aws_instance` — key pair attached at instance creation, SSH access possible
✅ `terraform init` completed — `hashicorp/aws` v6.x downloaded, lock file written
✅ `terraform plan` reviewed — three resources confirmed for creation, dependency order verified
✅ `terraform apply` completed — EC2 instance, security group, and key pair provisioned in `ap-south-1`
✅ SSH access verified — `ssh -i ~/.ssh/day10_key ec2-user@<public-ip>` connected successfully
✅ Provider binary Git pollution diagnosed — `.terraform/` removed from history via `git filter-branch`
✅ `.gitignore` updated — `.terraform/`, `*.tfstate`, `*.tfstate.backup` excluded from all future commits
✅ `terraform destroy` executed — all resources terminated, no billable resources left running
✅ Production gaps documented — S3 remote backend and DynamoDB state locking requirements articulated
