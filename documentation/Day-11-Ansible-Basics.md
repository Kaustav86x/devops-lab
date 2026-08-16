# INFRA-204 | Agentless Configuration Management: Ansible Playbook Authoring, Idempotent Task Design, and SSH Authentication Failure Diagnosis on Amazon Linux

**Date:** Day 11
**Ticket:** INFRA-204
**Scope:** Write an Ansible playbook that configures the EC2 instance provisioned on Day 10: install Docker, create an operating system user, and push a configuration file from the local machine to the remote instance. Establish an inventory file decoupling connection parameters from task logic. Diagnose and resolve an SSH authentication failure caused by an incorrect remote user assumption. Validate idempotent execution by running the playbook twice and confirming no changes on the second run.
**Outcome:** Playbook executing three tasks against the Day 10 EC2 instance over SSH with zero manual console interaction. `ansible.builtin.dnf` used correctly for Amazon Linux package management. Idempotent execution confirmed — second run reports `changed=0` across all tasks. SSH authentication failure root-caused to an AMI-specific default user mismatch, not a key or security group issue.

---

## Objective

Terraform's responsibility ends the moment `terraform apply` completes. The instance exists. The network is configured. The key pair is registered. What Terraform does not do is reach inside the running instance and configure the operating system — install software, create users, write configuration files, set permissions, start services. That boundary is intentional: Terraform is an infrastructure provisioning tool, not a configuration management tool. These are distinct operational concerns with distinct tooling.

Ansible operates in the space Terraform vacates. Where Terraform declares what infrastructure should exist, Ansible declares what state the operating system inside that infrastructure should be in. The separation is not academic — it reflects a real division of responsibility that appears in every production environment at scale. Infrastructure teams manage the provisioning layer. Platform teams manage the configuration layer. Both layers are version-controlled, peer-reviewed, and applied through automation. Neither is managed by logging into machines and running commands by hand.

Day 11 establishes the Ansible side of this boundary. The target is the same EC2 instance Terraform provisioned on Day 10. The tooling is different. The discipline is the same: everything declared in code, nothing done manually, every operation verifiable and repeatable.

---

## Architecture

```
WSL2 (Ubuntu)
├── ~/.ssh/day10_key                    ← private key; Ansible uses this for SSH transport
│
└── devops-lab/app/sample-next-app/
    └── ansible/
        ├── inventory.ini               ← host list + connection parameters
        ├── playbook.yml                ← three-task play targeting [webservers] group
        └── files/
            └── app.config              ← file pushed to EC2 by ansible.builtin.copy

Execution model:

  ansible-playbook
       │
       ├── reads inventory.ini          ← resolves: which hosts, which user, which key
       │
       └── connects via SSH to EC2
                │
                ├── Task 1: ansible.builtin.dnf    → installs Docker
                ├── Task 2: ansible.builtin.user   → creates KaustavDev OS user
                └── Task 3: ansible.builtin.copy   → pushes files/app.config to /home/ec2-user/files_from_wsl/

  Idempotency model (per task):

  Module checks current state → compares to declared state → acts only on diff
       │                              │                              │
  "is docker installed?"        state: present               install if absent
  "does user exist?"            state: present               create if absent
  "does file match src?"        content hash comparison      copy only if changed
```

---

## Project Structure

```
sample-next-app/
├── k8s/
├── helm/
├── terraform/
│   ├── main.tf                         # Days 8–9 Docker provider — unchanged
│   ├── modules/registry/               # Day 9 module — unchanged
│   └── ec2-provisioning/
│       └── main.tf                     # Day 10 AWS provisioning — unchanged
└── ansible/                            # introduced this day
    ├── inventory.ini                   # host group [webservers] + connection vars
    ├── playbook.yml                    # single play, three tasks
    └── files/
        └── app.config                  # source file for ansible.builtin.copy task
```

Ansible is a separate directory from Terraform, not nested inside it. The separation reflects the operational boundary between provisioning and configuration management. A Terraform operator working in `ec2-provisioning/` has no reason to be inside `ansible/`, and vice versa. Mixing them in the same directory couples two workflows that are independently triggered, independently versioned, and independently owned in a team environment.

---

## Pre-Implementation Analysis

### The agentless model — how Ansible reaches the target

Terraform communicates with AWS through the AWS API over HTTPS. The target — the EC2 instance — is never directly contacted during provisioning.

Ansible works the opposite way. There is no API intermediary. Ansible SSHes directly into the target machine, transfers small Python scripts representing each task, executes them, reads the result, and disconnects. No agent is installed on the target. No daemon is running on the target. The only requirement is that Python exists on the remote machine and that SSH access is available with the configured credentials.

This model has a direct operational implication: if SSH does not work, Ansible does not work. The SSH layer is not an Ansible concern — it is a prerequisite that must be verified independently before any playbook is authored or executed. Attempting to diagnose Ansible failures without first verifying raw SSH access is a reliable path to misattributing the root cause.

### Inventory — separating connection topology from task logic

The inventory file answers one question: given a group name used in a playbook, which hosts does that name resolve to, and how should Ansible connect to them?

```ini
[webservers]
<ec2-public-ip> ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/day10_key
```

`[webservers]` is the group name referenced by `hosts:` in the playbook. The two `ansible_` variables are connection parameters — they are read by Ansible's SSH transport layer, not by any task or module. They never appear in the playbook. The playbook declares what to do. The inventory declares where to do it and how to get there. These are distinct concerns and they live in distinct files.

In a production environment, the inventory is not a static file. It is generated dynamically — queried from AWS via Ansible's EC2 dynamic inventory plugin, from a CMDB, or from Terraform outputs written to a known path. A static inventory file is operationally equivalent to hardcoding an IP address: it becomes stale the moment the instance is replaced or the IP changes. The static file used here is a controlled simplification for a single-instance lab environment.

### Idempotency — the contract each module must satisfy

Ansible does not maintain a state file the way Terraform does. There is no equivalent of `terraform.tfstate` tracking what Ansible has applied and to what. Idempotency is not a property of the playbook runner — it is a contract that each individual module must satisfy by design.

The standard library modules satisfy this contract:

- `ansible.builtin.dnf`: queries the package database before acting. If the package is already at the requested version and state, no action is taken. The package manager is not invoked.
- `ansible.builtin.user`: queries `/etc/passwd` before acting. If the user exists with the declared attributes, no action is taken.
- `ansible.builtin.copy`: computes a checksum of the source file and compares it against the destination. If the checksums match, no file transfer occurs.

The exception is `ansible.builtin.shell` and `ansible.builtin.command` — both execute arbitrary shell commands and have no native mechanism for detecting whether an action is necessary. They execute unconditionally on every run. Using them in a playbook breaks idempotency unless the task is explicitly conditioned with a `creates:` argument or a `when:` clause that checks preconditions. For the three tasks in this playbook, no shell execution is required — all operations are handled by modules with native idempotency guarantees.

### Package manager selection — Amazon Linux is not Ubuntu

The module used to install packages depends entirely on the package manager available on the target distribution:

| Distribution | Package manager | Ansible module |
|---|---|---|
| Ubuntu / Debian | `apt` | `ansible.builtin.apt` |
| Amazon Linux 2023 | `dnf` | `ansible.builtin.dnf` |
| Amazon Linux 2 | `yum` | `ansible.builtin.yum` |
| RHEL / CentOS | `dnf` / `yum` | `ansible.builtin.dnf` |

The Day 10 EC2 instance runs Amazon Linux. `ansible.builtin.apt` would fail silently or with a module error because `apt` does not exist on the target. The correct module is `ansible.builtin.dnf`. The package name for Docker on Amazon Linux is `docker` — not `docker.io` (the Ubuntu package name) and not `docker-ce` (the official Docker repository package). For lab purposes the distribution-packaged version is sufficient. In production, the official Docker repository is used because it receives security updates independently of the distribution release cycle.

---

## Implementation

### 1. Inventory file

```ini
[webservers]
<ec2-public-ip> ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/day10_key
```

The group name `webservers` is referenced by `hosts: webservers` in the playbook. The `ansible_user` is `ec2-user` — the default user on all Amazon Linux AMIs. The `ansible_ssh_private_key_file` is the private key generated on Day 10 and registered with AWS via the `aws_key_pair` Terraform resource.

### 2. Configuration file source

```bash
mkdir ansible/files
echo "env=production" > ansible/files/app.config
```

A placeholder configuration file is created locally for the copy task to push. In a real workflow this would be an application configuration file, a systemd unit file, an nginx virtual host definition, or any file that needs to be present on the remote machine at a known path with known content.

### 3. Playbook

```yaml
- hosts: webservers
  become: true
  tasks:
    - name: Install Docker
      ansible.builtin.dnf:
        name: docker
        state: present

    - name: Create application user
      ansible.builtin.user:
        name: KaustavDev
        state: present

    - name: Push configuration file to instance
      ansible.builtin.copy:
        src: files/app.config
        dest: /home/ec2-user/files_from_wsl/app.config
```

`become: true` elevates privilege to root for the duration of the play. Package installation and user creation both require root. It is declared at the play level rather than on individual tasks because all three tasks require elevated privilege either directly or for consistency.

`src: files/app.config` is a path relative to the playbook file's location. A leading `/` would make it an absolute path on the local machine, causing Ansible to look for `/files/app.config` at the filesystem root and fail with a file not found error.

The destination directory `/home/ec2-user/files_from_wsl/` was created manually on the EC2 instance prior to the playbook run. If the directory does not exist, `ansible.builtin.copy` creates a file named `files_from_wsl` instead of placing `app.config` inside a directory of that name — a silent misbehaviour with no error output. In a production playbook, a preceding task using `ansible.builtin.file` with `state: directory` would ensure the destination directory exists before the copy task runs, removing the dependency on manual pre-creation.

### 4. Dry run before apply

```bash
ansible-playbook -i inventory.ini playbook.yml --check
```

`--check` instructs Ansible to connect to the target, evaluate every task, and report what would change — without making any changes. It is the equivalent of `terraform plan`. The output reports predicted state transitions per task. A clean dry run with the expected changes reported confirms that the playbook is correctly structured and targeting the right hosts before any modification is made.

---

## Incident — SSH Authentication Failure on Initial Connectivity Test

### Symptom

The connectivity smoke test executed before any playbook authoring:

```bash
ansible -i inventory.ini webservers -m ping
```

returned:

```
13.203.210.57 | UNREACHABLE! => {
    "changed": false,
    "msg": "Failed to connect to the host via ssh: ubuntu@13.203.210.57: Permission denied (publickey).",
    "unreachable": true
}
```

The same failure was reproduced by direct SSH:

```bash
ssh -i ~/.ssh/day10_key ubuntu@13.203.210.57
# ubuntu@13.203.210.57: Permission denied (publickey,gssapi-keyex,gssapi-with-mic)
```

### Investigation

The error output contains two elements that must be read separately.

The first — a warning about post-quantum key exchange algorithms — is an OpenSSH client advisory about a future cryptographic concern. It has no relationship to the authentication failure and can be disregarded entirely.

The second — `Permission denied (publickey)` — is the actual rejection. It means the server received the connection attempt, evaluated the offered public key against its `authorized_keys` file, and rejected it. This is not a network connectivity failure (the host was reached), not a security group failure (port 22 accepted the connection), and not a key file permission failure (the key was read and offered successfully).

The rejection at the public key evaluation step narrows the cause to one of two possibilities: the key offered does not match any key in `authorized_keys`, or the username determines a different home directory whose `authorized_keys` the offered key is not in.

Checking key file permissions:

```bash
ls -la ~/.ssh/day10_key
# -rw------- 1 xrig xrig 3389 Jul 31 20:43 /home/xrig/.ssh/day10_key
```

Permissions are `600` — SSH accepts both `400` and `600`. The key file is readable and not the cause.

The inventory was configured with `ansible_user=ubuntu`. The Day 10 Terraform configuration provisioned an Amazon Linux instance. On Amazon Linux AMIs, the default user is `ec2-user`. The `ubuntu` user does not exist on this instance. SSH attempted to authenticate as a user that has no home directory and no `authorized_keys` file, producing a permission denied rejection that is behaviourally identical to a key mismatch but is in fact a user mismatch.

### Root Cause

`ansible_user=ubuntu` in the inventory referenced a user that does not exist on an Amazon Linux AMI. The correct default user for Amazon Linux is `ec2-user`. The SSH key was correct. The target host was reachable. The failure was entirely attributable to an incorrect assumption about the default user carried over from Ubuntu AMI conventions.

### Resolution

Updated `inventory.ini`:

```ini
[webservers]
<ec2-public-ip> ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/day10_key
```

SSH verified manually before re-running the Ansible ping:

```bash
ssh -i ~/.ssh/day10_key ec2-user@13.203.210.57
# connected successfully
```

Ansible ping returned `pong`. Playbook authoring proceeded from a confirmed working SSH baseline.

### Operational Principle

AMI default users are not standardised across distributions. `ubuntu` is the default for Ubuntu AMIs. `ec2-user` is the default for Amazon Linux AMIs. `admin` is the default for Debian AMIs. `centos` for CentOS AMIs. `fedora` for Fedora AMIs. There is no universal default.

The Ansible `unreachable` error with a `Permission denied (publickey)` message is frequently misread as a key problem, prompting investigation of key permissions, key registration, and security group rules — none of which are at fault when the actual cause is a non-existent user. The correct diagnostic sequence is:

1. Verify the host is reachable at the network level (`ping` or `nc -zv <ip> 22`)
2. Verify port 22 accepts connections (security group)
3. Verify the key file exists and has correct permissions (`ls -la`)
4. Verify the username with an explicit SSH attempt (`ssh -i <key> <user>@<host>`)

Step 4 is the step most commonly skipped. A manual SSH attempt with the explicit username produces a clear error that removes ambiguity. Ansible connectivity should never be diagnosed before raw SSH is verified to work.

---

## Key Concepts Documented

**Ansible is agentless by design, which makes SSH a hard dependency, not a transport detail.** Every Ansible operation — from the initial ping module to multi-task playbooks — passes through SSH. The SSH configuration (user, key, host, permissions) must be correct before any Ansible troubleshooting is meaningful. An `UNREACHABLE` error from Ansible is always an SSH-layer problem. It should be diagnosed at the SSH layer, not the Ansible layer.

**Idempotency in Ansible is a per-module guarantee, not a framework guarantee.** The Ansible runner does not track state between runs. Idempotency is the responsibility of each individual module, implemented by checking the current state of the system before deciding whether to act. The standard library modules (`dnf`, `user`, `copy`, `service`, `file`) satisfy this contract. `shell` and `command` do not. A playbook's idempotency is only as strong as the least idempotent module it contains.

**`state: present` is declarative intent, not an imperative instruction.** Writing `state: present` does not mean "install this" or "create this." It means "after this task executes, this thing should exist." The module determines whether any action is required to reach that state. This maps directly to Terraform's apply model — desired state is declared, current state is inspected, and the delta is applied. The mental model is identical. The implementation mechanism differs.

**Package names are distribution-specific and not interchangeable.** `docker.io` installs Docker on Ubuntu. `docker` installs Docker on Amazon Linux. `docker-ce` installs the official Docker release from Docker's own repository on any supported distribution. Using the wrong package name produces a module failure on `dnf` and `apt` alike. The package manager's repository, not the Ansible module, determines what package names are valid.

**`src:` paths in `ansible.builtin.copy` are relative to the playbook file, not the project root.** A leading `/` produces an absolute path on the control node — Ansible looks for the file at the filesystem root, not in the project directory. The correct convention is a relative path from the playbook's location, typically via a `files/` subdirectory that Ansible resolves automatically.

**The `--check` flag is not optional before applying a playbook to a system with running workloads.** `--check` reports predicted changes without making them — the equivalent of `terraform plan`. On a machine running production services, a playbook that unexpectedly restarts a service or modifies a configuration file can cause downtime. The dry run makes predicted changes visible before they occur. Skipping it treats configuration management as a one-shot command rather than a reviewable operation.

---

## Commands Reference

```bash
# Inventory smoke test — verify SSH connectivity before writing any playbook
ansible -i inventory.ini webservers -m ping

# Dry run — inspect what would change without making changes
ansible-playbook -i inventory.ini playbook.yml --check

# Apply playbook
ansible-playbook -i inventory.ini playbook.yml

# Idempotency verification — second run should report changed=0 on all tasks
ansible-playbook -i inventory.ini playbook.yml

# Manual SSH verification — always run this before diagnosing Ansible connectivity
ssh -i ~/.ssh/day10_key ec2-user@<ec2-public-ip>

# Confirm destination directory exists on EC2 before copy task
ssh -i ~/.ssh/day10_key ec2-user@<ec2-public-ip> "ls /home/ec2-user/files_from_wsl/"

# Verify Docker was installed by the playbook
ssh -i ~/.ssh/day10_key ec2-user@<ec2-public-ip> "docker --version"

# Verify user was created by the playbook
ssh -i ~/.ssh/day10_key ec2-user@<ec2-public-ip> "id KaustavDev"
```

---

## Deliverable Status

✅ `ansible/` directory created as sibling to `terraform/` — configuration management separated from provisioning  
✅ `inventory.ini` authored — `[webservers]` group, `ec2-user` username, `day10_key` private key referenced  
✅ `ansible/files/app.config` created — source file for copy task  
✅ SSH authentication failure diagnosed — `ubuntu` user does not exist on Amazon Linux; corrected to `ec2-user`  
✅ Ansible ping smoke test passed — `pong` returned; SSH baseline confirmed before any playbook authoring  
✅ `playbook.yml` authored — single play, `become: true`, three tasks with correct modules  
✅ `ansible.builtin.dnf` used correctly — Amazon Linux package manager; `docker` package name verified  
✅ `ansible.builtin.user` task authored — `KaustavDev` user, `state: present`  
✅ `ansible.builtin.copy` task authored — relative `src` path, explicit `dest` with filename  
✅ Dry run executed — `--check` output reviewed before apply  
✅ Playbook applied — `ok=4 changed=3 unreachable=0 failed=0` on first run  
✅ Idempotency confirmed — second run reports `changed=0` across all tasks  
✅ Production gap noted — static inventory becomes stale on instance replacement; dynamic inventory (EC2 plugin or Terraform output) is the production pattern  
