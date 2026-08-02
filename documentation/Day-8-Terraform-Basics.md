# INFRA-201 | Infrastructure Lifecycle Ownership: Terraform State, Provider Wiring, and the Transition from Imperative to Declarative Resource Management

**Date:** Day 8
**Ticket:** INFRA-201
**Scope:** Replace manually-executed `docker run` commands for the local registry container with a fully Terraform-managed provisioning workflow. Author a `main.tf` defining the Docker provider, image pull, and container resource. Execute the complete `init → plan → apply → destroy → apply` lifecycle. Inspect `terraform.tfstate` to understand state as Terraform's authoritative record of managed infrastructure.
**Outcome:** Local registry container fully owned by Terraform. Lifecycle — creation, inspection, teardown, and recreation — driven entirely through declarative config. State file read and understood as the mechanism by which Terraform reconciles desired state against real-world infrastructure.

---

## Objective

A `docker run` command creates a container. It does not record that it did so. There is no artifact that encodes which flags were used, what the container is named, what port was mapped, or whether the container is currently running. If the container is removed — accidentally, by a system restart, or by a colleague — recreating it requires either memory or documentation, both of which drift from reality. There is no tool that can look at what exists and tell you whether it matches what was intended.

Terraform addresses this by introducing a state layer between configuration and infrastructure. The configuration file declares what should exist. The state file records what Terraform has created. Every subsequent operation — plan, apply, destroy — is computed as a diff between these two artifacts and the live system. The result is infrastructure that is reproducible, auditable, and recoverable without relying on tribal knowledge or manual runbooks.

This day establishes the foundational Terraform workflow against the Docker provider — a local, low-stakes target that makes the mechanics visible without the latency and cost of cloud infrastructure. The registry container that was previously started with a single `docker run` command becomes the first resource managed by Terraform, and the first entry in a state file that will grow to track progressively more complex infrastructure across subsequent days.

---

## Architecture

```
terraform/
└── main.tf                        ← single source of infrastructure truth

    Provider wiring:
    main.tf (kreuzwerker/docker)
         │
         ↓ terraform init
    .terraform/providers/          ← downloaded provider plugin (auto-generated)
         │
         ↓ terraform apply
    Docker daemon (unix socket)
         ├── docker_image.registry     ← registry:2 pulled and tracked
         └── docker_container.registry_container
                  └── port 5000:5000  ← registry endpoint, consumed by k3d

    terraform.tfstate              ← Terraform's record of what it owns
```

---

## Project Structure

```
sample-next-app/
├── k8s/                           # Kubernetes manifests — unchanged
├── helm/                          # Helm chart — unchanged
└── terraform/                     # Terraform root — introduced this day
    ├── main.tf                    # provider + resource declarations
    ├── .terraform/                # provider plugin cache — never committed
    ├── .terraform.lock.hcl        # provider version lock — committed
    └── terraform.tfstate          # infrastructure state — never committed
```

---

## Pre-Implementation Analysis

### What `docker run` does not give you

The registry container running on `localhost:5000` was started imperatively. From Terraform's perspective — and from any tooling that depends on declared state — it does not exist. There is no machine-readable record of its configuration, no mechanism to detect if it has drifted from the intended state, and no single command that can tear it down and recreate it identically.

The operational cost of this becomes visible at scale: a team of three engineers, each with a locally-running registry configured slightly differently, produces three environments that behave differently in ways that are invisible until something fails. The fix is not documentation — documentation drifts. The fix is codifying the resource in a format that a tool can read, verify, and enforce.

Terraform's model for this is the resource block — a declarative description of a piece of infrastructure that the provider translates into API calls. The Docker provider translates `docker_container` resource blocks into Docker daemon API calls. The result is identical to `docker run`, but with a state record attached.

### The two-resource dependency model

Docker requires an image to exist before a container can be created from it. In an imperative workflow this is managed by ordering commands — `docker pull` before `docker run`. In Terraform, ordering is managed by resource references.

Declaring `docker_image` and `docker_container` as separate resources, and referencing the image resource's output attribute (`image_id`) from the container resource, creates an explicit dependency edge in Terraform's graph. Terraform resolves the graph before executing any operations — the image is always pulled before the container is created, and the container is always destroyed before the image when running `terraform destroy`. Ordering is encoded in the configuration, not in the operator's memory.

---

## Implementation

### 1. Provider configuration

The `terraform` block declares the `kreuzwerker/docker` provider as a required dependency. The provider block configures the Docker socket path — on WSL2 Ubuntu, the Unix socket at `/var/run/docker.sock`. This is the same socket the Docker CLI uses. Terraform communicates with the Docker daemon through the provider plugin, which abstracts the Docker API into Terraform resource primitives.

`terraform init` downloads the provider plugin from the Terraform Registry and writes the resolved version to `.terraform.lock.hcl`. The lock file pins the provider version — subsequent `init` runs on any machine will use the same provider binary, preventing silent behaviour changes from provider version drift.

### 2. Resource blocks

Two resources are declared in `main.tf`:

**`docker_image "registry"`** — instructs the provider to pull `registry:2` from Docker Hub and track it in state. The resource does not create the image in the traditional sense — the image is pulled from a remote registry — but from Terraform's perspective, pulling and tracking an image is a creation event. The resource exists in state once the pull completes.

**`docker_container "registry_container"`** — instructs the provider to create and start a container from the tracked image, mapping port `5000` on the host to port `5000` in the container. The `image` argument references `docker_image.registry.image_id` — the output attribute of the image resource. This reference is what creates the dependency edge.

### 3. The `terraform plan` output — reading it correctly

`terraform plan` produces a diff between desired state (`.tf` files) and current state (`tfstate`). On first run, the state is empty — everything in the config is a net-new creation. The output marks each resource with `+`, meaning it will be created. Attributes marked `(known after apply)` — such as `image_id`, `id`, and `repo_digest` — are computed by the provider at runtime and cannot be known until the operation executes.

Reading plan output before every apply is not optional discipline — it is the mechanism that prevents unintended changes from reaching infrastructure.

---

## Incident — Port Allocation Conflict on `terraform apply`

### Symptom

`terraform apply` failed during container creation:

```
Error: Unable to start container: Error response from daemon: failed to set up
container networking: driver failed programming external connectivity on endpoint
registry_container: Bind for 0.0.0.0:5000 failed: port is already allocated
```

### Root Cause Analysis

The registry container had been running prior to this exercise, started manually with `docker run`. Terraform had no record of it — it did not exist in `tfstate`. When Terraform attempted to create the container declared in `main.tf`, the Docker daemon rejected the port binding because port `5000` was already held by the existing manually-started container.

This is the canonical conflict between imperative and declarative resource management. Terraform's state was empty. The real world was not. The delta between the two manifested as a collision at the Docker networking layer.

This failure mode has a more serious analogue in production: an engineer manually creates a resource in a cloud console before Terraform is adopted. Terraform has no record of it. The first `terraform apply` attempts to create a duplicate and either fails with a conflict or, worse, creates a second resource with an identical name — depending on whether the provider enforces uniqueness. Neither outcome is acceptable in a production environment. The correct resolution is `terraform import` — pulling the existing resource into Terraform's state without recreating it. For a lab environment, deletion and recreation is operationally equivalent.

### Resolution

The manually-created container was stopped and removed:

```bash
docker stop registry
docker rm registry
```

`terraform apply` then completed cleanly — Terraform created the container, mapped the port, and wrote both the image and container resources to `tfstate`.

### Operational Principle

Terraform cannot manage resources it did not create unless they are explicitly imported. A resource that exists in the real world but not in `tfstate` is, from Terraform's perspective, absent. The moment Terraform is adopted as the management layer for a resource, all other management paths — CLI commands, console clicks, scripts — must be retired. Two management paths against the same resource produce divergence that is only visible when they collide.

---

## Key Concepts Documented

**Terraform state is the source of truth — not the configuration files.** The `.tf` files declare intent. The `tfstate` file records what Terraform has actually created. When `terraform plan` runs, it compares three things: the configuration, the state, and the live infrastructure. The plan is the union of all deltas between them. Editing `tfstate` manually breaks this model — Terraform will believe the recorded state is real and plan against a false baseline.

**`terraform destroy` followed by `terraform apply` is a proof of reproducibility.** If the second apply produces infrastructure that is functionally identical to what existed before the destroy, the configuration is the source of truth in a meaningful sense — not just in theory. If it does not, something is hardcoded or environment-dependent that should be declared in configuration.

**Provider plugins are not Terraform — they are translators.** Terraform is a generic state reconciliation engine. It has no native knowledge of Docker, AWS, or any other system. The provider plugin translates Terraform's resource model into the target system's API. The `kreuzwerker/docker` provider translates `docker_container` resource blocks into Docker daemon API calls. Swapping the provider — from Docker to AWS — changes the target system but not the Terraform workflow. This is why the same mental model applies on Day 10 when the target becomes EC2.

**`.terraform/` is never committed.** It contains provider binaries — platform-specific, large, and auto-generated by `terraform init`. Committing it couples the repository to a specific OS and architecture, bloats version history, and provides no value since anyone cloning the repo will run `terraform init` and receive the correct binary for their platform. It belongs in `.gitignore` before the first commit.

---

## Deliverable Status

✅ `main.tf` authored — terraform block, provider block, `docker_image`, `docker_container` resources
✅ `terraform init` completed — `kreuzwerker/docker` v4.5.0 downloaded, lock file written
✅ `terraform plan` reviewed — two resources marked for creation, `(known after apply)` attributes understood
✅ `terraform apply` completed — registry container running on `localhost:5000`, verified with `docker ps`
✅ `terraform.tfstate` inspected — image and container resources located in state, port mapping confirmed
✅ Port conflict diagnosed and resolved — manually-created container removed, Terraform took ownership
✅ `terraform destroy` executed — container and image removed, `resources: []` in state confirmed
✅ `terraform apply` re-executed — registry recreated identically, reproducibility proven
