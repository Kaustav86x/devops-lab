# INFRA-202 | Terraform Module Abstraction: Parameterization, Provider Scoping, and State Migration Under Structural Refactor

**Date:** Day 9
**Ticket:** INFRA-202
**Scope:** Refactor the Day 8 monolithic `main.tf` into a reusable module structure under `modules/registry/`. Separate resource definitions, input variable declarations, and output declarations across purpose-specific files. Parameterize all environment-variant values — container name, port, and image — via declared variables with defaults. Wire the root `main.tf` to call the module with explicit input values. Resolve a `required_providers` scoping error surfaced during `terraform init` and a state migration conflict caused by resource address changes during structural refactoring.
**Outcome:** Registry container provisioned through a fully parameterized module. Root `main.tf` reduced to provider configuration and a single module call. Module callable with different inputs to produce independent registry instances. State migration conflict diagnosed, understood as a structural refactor consequence, and resolved cleanly.

---

## Objective

A Terraform configuration that hardcodes its values is not infrastructure-as-code in any operationally meaningful sense — it is a script with a state file. It can recreate one specific resource with one specific configuration. It cannot be reused across environments, cannot be called with different parameters, and cannot be published as a shared component that other teams consume. Every new use case requires a copy, and copies diverge.

The module system is Terraform's mechanism for turning a resource definition into a reusable, parameterized component. A module encapsulates a set of resources behind an interface of declared input variables and output values. The caller — the root configuration — supplies concrete values through that interface. The module implementation is hidden from the caller, just as a function's internal logic is hidden from its call site. The same module, called with different inputs, produces independent infrastructure with no shared state between instances.

This day refactors the Day 8 single-file configuration into that module structure — establishing the pattern that will govern all subsequent Terraform work as infrastructure complexity grows. The registry container remains the concrete target, but the exercise is not about the registry. It is about understanding the boundary between interface and implementation in infrastructure code.

---

## Architecture

```
terraform/
├── main.tf                            ← root module: provider config + module call
└── modules/
    └── registry/                      ← child module: encapsulated registry definition
        ├── main.tf                    ← resource blocks (implementation)
        ├── variables.tf               ← input interface (contract)
        └── outputs.tf                 ← return values (observable state)

    Call graph:
    root main.tf
         │
         └── module "local_registry" (source: ./modules/registry)
                  │   inputs: name, port, image
                  ↓
             modules/registry/main.tf
                  ├── docker_image.registry        (var.registry_image)
                  └── docker_container.registry_container
                            ├── name               (var.registry_container)
                            └── ports 5000:5000    (var.port)

    State addresses after refactor:
    module.local_registry.docker_image.registry
    module.local_registry.docker_container.registry_container
```

---

## Project Structure

```
sample-next-app/
└── terraform/
    ├── main.tf                        # root — provider block + module call only
    ├── .terraform.lock.hcl            # provider version lock
    ├── terraform.tfstate              # state — resource addresses now module-prefixed
    └── modules/
        └── registry/
            ├── main.tf                # docker_image + docker_container resources
            ├── variables.tf           # port, registry_container, registry_image
            └── outputs.tf             # container_name, functional_port
```

---

## Pre-Implementation Analysis

### The limitation of a monolithic configuration

The Day 8 `main.tf` provisions exactly one registry container with exactly one name on exactly one port. To provision a staging registry alongside a production registry, the entire file would need to be duplicated. The two copies would share no code. A change to the container restart policy, volume configuration, or any other structural detail would need to be applied to both copies independently. Drift between them is not a hypothetical — it is the default outcome when duplication is the only available tool.

The module system solves this by separating the resource definition from the values it operates on. The definition lives in the module. The values are supplied by the caller. Two calls to the same module with different inputs produce two independent sets of resources with no shared state:

```hcl
module "prod_registry" {
  source             = "./modules/registry"
  registry_container = "prod_registry"
  port               = 5000
  registry_image     = "registry:2"
}

module "staging_registry" {
  source             = "./modules/registry"
  registry_container = "staging_registry"
  port               = 5001
  registry_image     = "registry:2"
}
```

This is the same principle as the Helm chart with different `values.yaml` per environment — one chart definition, multiple independent releases. The mechanism differs, but the design intent is identical.

### Identifying what to parameterize

Parameterization scope is a design decision, not a mechanical extraction. The correct question is: *would two legitimate uses of this module ever need this value to differ?* If yes, it is a variable. If no, it is a structural constant baked into the module.

For the registry module:

| Value | Decision | Reasoning |
|---|---|---|
| Container name | Variable | Two instances cannot share a name |
| Host port | Variable | Two instances cannot bind the same port |
| Image name and tag | Variable | Version pinning may differ between environments |
| Docker socket path | Constant | Uniform across all Linux hosts in this environment |
| Container internal port | Constant | Registry always listens on 5000 internally |

The image name being a variable is the non-obvious one. A module that hardcodes `registry:2` cannot be used to test a `registry:3` candidate without modifying the module itself — violating the principle that callers configure, modules implement.

---

## Implementation

### 1. `modules/registry/variables.tf` — the input interface

Three variables are declared: `port` (type `number`, default `5000`), `registry_container` (type `string`, default `"registry_container"`), and `registry_image` (type `string`, default `"registry:2"`).

The `default` value serves two purposes: it documents the expected value for the common case, and it makes the variable optional at the call site. A caller that does not supply a value receives the default. A caller that supplies a value overrides it. This is the Terraform equivalent of a function parameter with a default argument.

Type declarations (`string`, `number`, `bool`) are enforced by Terraform at plan time. Passing a string where a number is expected produces an error before any infrastructure is touched.

### 2. `modules/registry/main.tf` — the implementation

The two resource blocks from Day 8 are moved here with hardcoded values replaced by variable references using the `var.` prefix. The `terraform { required_providers {} }` block is retained in this file — see Incident 1 for why this is required. The `provider "docker" {}` block is not present here — provider configuration is the root module's responsibility.

### 3. `modules/registry/outputs.tf` — the return values

Two outputs are declared: `container_name` (the running container's name from `docker_container.registry_container.name`) and `functional_port` (the external port from `docker_container.registry_container.ports[0].external`). The `[0]` index is required because `ports` is a list in the provider's schema — even when only one port mapping is defined, the attribute is accessed as the first element of a list.

Outputs serve two purposes: they surface observable state to the operator via `terraform output`, and they allow other modules or root configurations to reference the module's created resources without knowing the module's internal resource addresses.

### 4. Root `main.tf` — the caller

The root `main.tf` retains the `terraform` block and `provider "docker" {}` block. The resource blocks are replaced entirely by a single `module` block:

```hcl
module "local_registry" {
  source             = "./modules/registry"
  registry_container = "registry_container"
  registry_image     = "registry:2"
  port               = 5000
}
```

The argument names on the left side of each assignment must exactly match the variable names declared in `modules/registry/variables.tf`. Terraform does not infer mappings — a misspelled argument name is an error.

---

## Incident 1 — Provider Resolution Failure in Module

### Symptom

`terraform init` from the correct root directory failed:

```
Error: Failed to query available provider packages

Could not retrieve the list of available versions for provider hashicorp/docker:
provider registry registry.terraform.io does not have a provider named
registry.terraform.io/hashicorp/docker

Did you intend to use kreuzwerker/docker? If so, you must specify that source
address in each module which requires that provider.
```

### Root Cause Analysis

The root `main.tf` correctly declared `kreuzwerker/docker` in its `required_providers` block. The module's `main.tf` contained only resource blocks — `docker_image` and `docker_container` — with no `required_providers` declaration.

When Terraform initialises a configuration that includes modules, it resolves provider requirements for every module independently. The module's resource blocks reference a provider type called `docker`. Without a `required_providers` declaration in the module, Terraform cannot determine which registry and namespace that provider comes from. It defaults to `registry.terraform.io/hashicorp/docker` — the conventional default namespace — which does not exist. The provider is published under `kreuzwerker/docker`, not `hashicorp/docker`.

The root module's declaration is not inherited by child modules. Each module that uses a provider must declare it.

### Resolution

The `terraform { required_providers {} }` block was added to `modules/registry/main.tf` with the same `kreuzwerker/docker` source and version as the root. The `provider "docker" {}` configuration block was not added to the module — that remains exclusively in the root. The distinction is:

- `required_providers` — declares which provider a module depends on. Required in every module that uses the provider.
- `provider` block — configures the provider (credentials, endpoint, socket path). Lives only in the root module.

`terraform init` completed after this addition.

### Operational Principle

Provider declarations are module-scoped, not configuration-scoped. A module is a self-contained unit with its own dependency declarations. In a published, versioned module — one consumed from the Terraform Registry by other teams — the `required_providers` block is the module's contract with Terraform: "to use me, you need this provider at this version." Without it, the module cannot be initialised in isolation, cannot be tested independently, and produces ambiguous errors when the default provider namespace resolution fails.

---

## Incident 2 — Orphaned Resource Destruction Conflict During State Migration

### Symptom

`terraform apply` after the refactor attempted to destroy the Day 8 top-level resources simultaneously with creating the new module-scoped resources. Destruction of `docker_image.registry` failed:

```
Error: Unable to remove Docker image: Error response from daemon: conflict:
unable to delete registry:2 (must be forced) - container b207cbd3f452 is
using its referenced image
```

### Root Cause Analysis

This is a state migration conflict — a class of failure specific to structural refactoring of Terraform configurations.

The `tfstate` from Day 8 recorded two resources at the root level:
```
docker_image.registry
docker_container.registry_container
```

After refactoring into a module, the same logical resources are addressed as:
```
module.local_registry.docker_image.registry
module.local_registry.docker_container.registry_container
```

From Terraform's perspective, these are four distinct resources — not two resources that have moved. The old addresses no longer appear in the configuration. Terraform scheduled them for destruction. The new addresses did not yet exist in state. Terraform scheduled them for creation. Both operations ran in the apply phase simultaneously.

The destruction of `docker_image.registry` failed because `docker_container.registry_container` — the old root-level container — was still running and holding a reference to the image. Terraform's parallel execution graph did not account for the dependency between the old container and the old image at destruction time, because the container had already been destroyed earlier in the apply. The error was triggered by a different container (`b207cbd3f452`) — a remnant from a prior state that was still running outside Terraform's awareness.

The correct production resolution for this class of problem is `terraform state mv` — instructing Terraform to rename a resource address in state without destroying and recreating the underlying infrastructure:

```bash
terraform state mv docker_image.registry module.local_registry.docker_image.registry
terraform state mv docker_container.registry_container module.local_registry.docker_container.registry_container
```

This tells Terraform the resource has moved, not been replaced. No infrastructure change occurs. The apply then produces no diff — current state matches desired state.

### Resolution

The blocking container was removed manually:

```bash
docker rm -f b207cbd3f452
```

`terraform apply` was re-executed. The orphaned root-level resources were destroyed cleanly. The module-scoped resources were created. The state now reflects the correct module-prefixed addresses.

### Operational Principle

Structural refactoring of Terraform — moving resources between modules, renaming modules, splitting configurations — changes resource addresses in state. Terraform interprets an address change as deletion of the old resource and creation of a new one. In production, this means infrastructure is destroyed and recreated during what the engineer intended as a purely organisational change. For stateful resources — databases, persistent volumes, load balancers with long-lived DNS entries — this is a production incident, not a recoverable inconvenience.

`terraform state mv` is the correct tool for address migration. It should be applied before `terraform apply` whenever a refactor changes resource addresses. In CI/CD pipelines where `terraform apply` runs automatically on merge, a structural refactor without a corresponding `state mv` will trigger unintended destruction on the next pipeline run. The plan output must be read carefully for unexpected `-/+` (destroy-and-recreate) operations before any refactor apply is confirmed.

---

## Key Concepts Documented

**Modules are interfaces, not just file organisation.** The distinction matters operationally. A module's `variables.tf` is a published contract — it defines what the caller is permitted to configure. Everything not in `variables.tf` is a structural decision made by the module author that the caller cannot override without modifying the module. In a platform engineering context, this is the mechanism by which a platform team publishes a module that enforces organisational standards — mandatory tags, required security group rules, enforced resource limits — while allowing application teams to configure their specific values. The interface is the enforcement boundary.

**`required_providers` is module-scoped; `provider` configuration is root-scoped.** These are two distinct concepts that appear in similar blocks. The `required_providers` block declares a dependency — "this module needs provider X at version Y." The `provider` block configures the dependency — "provider X should connect to this endpoint with these credentials." Child modules declare dependencies. Root modules configure them. Mixing the two — putting a `provider` block in a child module — is valid Terraform but produces unexpected behaviour when the same provider is used with different configurations across the same root.

**Resource addresses are identities, not labels.** When Terraform writes a resource to state, it writes it under a fully-qualified address: `module.local_registry.docker_container.registry_container`. That address is how Terraform matches a state record to a configuration block on every subsequent plan. Changing the address — by renaming a module, moving a resource into a module, or splitting a module — severs that match. Terraform sees a new resource to create and an old resource to destroy. The infrastructure is unchanged. The state is not. `terraform state mv` reconciles them without touching infrastructure.

**Module outputs are the only sanctioned external interface.** A caller cannot directly reference a resource inside a child module — `module.local_registry.docker_container.registry_container.ports[0].external` is not valid from the root. The caller can only access what the module explicitly exposes via `outputs.tf`. This enforces encapsulation: the module's internal resource structure can change — resources renamed, split, replaced — without breaking callers, as long as the outputs remain stable. Designing outputs as a stable interface, not an implementation detail, is what makes modules composable over time.

---

## Deliverable Status

✅ Module directory structure created — `modules/registry/` with `main.tf`, `variables.tf`, `outputs.tf`
✅ Three input variables declared — `port` (number), `registry_container` (string), `registry_image` (string) — with types and defaults
✅ Resource blocks parameterised — all hardcoded values replaced with `var.` references
✅ `required_providers` scoping error diagnosed and resolved — block added to module `main.tf`, provider block retained in root only
✅ Output values declared — `container_name` and `functional_port` with correct resource attribute references
✅ Root `main.tf` reduced to provider config and single `module` block
✅ `terraform init` completed after provider scoping fix
✅ State migration conflict diagnosed — orphaned root-level resources understood as address-change consequence, not configuration error
✅ `terraform apply` completed — module-scoped resources created, state addresses confirmed as `module.local_registry.*`
✅ `terraform output` verified — `container_name` and `functional_port` returned correctly
✅ Module callable with different inputs confirmed — interface and parameterisation model validated
