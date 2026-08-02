# INFRA-106 | Helm-Based Release Management: Chart Authoring, Ownership Conflicts, and Infrastructure Layer Separation

**Date:** Day 6
**Ticket:** INFRA-106
**Scope:** Migrate four manually-applied Kubernetes manifests (Deployment, Service, ConfigMap, Secret) into a structured Helm chart. Parameterize all environment-variant values via `values.yaml`. Resolve Helm ownership conflict caused by pre-existing `kubectl`-managed resources. Diagnose and fix a DNS resolution failure in the container runtime layer triggered by cluster recreation without registry configuration. Complete a clean `helm install` with all workload resources in `Running` state.
**Outcome:** All four resources now owned and tracked by Helm. Single-command deploy, upgrade, and rollback operational. Release history versioned. Infrastructure layer (cluster + registry config) and application layer (Helm chart) understood as orthogonal concerns.

---

## Objective

A Kubernetes manifest applied with `kubectl apply` is, operationally, an orphan. It exists in the cluster with no record of who owns it, what version it represents, or what other resources it depends on. Rolling back means keeping a copy of the previous manifest and re-applying it manually. Auditing what is deployed requires diffing live cluster state against whatever is in source control — if source control is even current. Promoting a configuration change across environments means maintaining multiple copies of nearly identical YAML, diverging silently over time.

Helm addresses all of this by introducing a release layer above the raw Kubernetes API. Every group of resources deployed as a Helm chart is tracked as a named release with a versioned history stored in the cluster itself. Upgrade is a single command. Rollback is a single command. The diff between what is deployed and what the chart specifies is computable. The same chart, with different `values.yaml` inputs, deploys consistently to development, staging, and production without duplication.

This day establishes that release management layer for the Next.js workload — replacing four independent `kubectl`-managed objects with a single Helm-owned release, and in doing so, exposing two failure modes that matter in any real environment: resource ownership conflicts during migration, and the strict boundary between cluster infrastructure configuration and application-layer configuration.

---

## Architecture

```
helm/
└── app-chart/                         ← Helm chart root (Chart.yaml lives here)
    ├── Chart.yaml                      ← chart identity and version metadata
    ├── values.yaml                     ← single source of truth for all variant values
    └── templates/                      ← Go-templated Kubernetes manifests
        ├── deployment.yaml             ← parameterized — image, replicas, resources, probes
        ├── service.yaml                ← parameterized — port, type
        ├── configmap.yaml              ← non-sensitive runtime parameters
        └── secret.yaml                 ← credential material

        Helm release: app-chart
              │
              ↓ helm install / helm upgrade
              │
        k3d cluster (devops-lab)
              ├── Deployment: k8s-deployment-1     ← owned by Helm (annotated)
              ├── Service: k8s-deployment-1         ← owned by Helm (annotated)
              ├── ConfigMap: sample-next-app-configmap  ← owned by Helm
              └── Secret: sample-next-app-secret        ← owned by Helm
```

---

## Project Structure

```
sample-next-app/
├── Dockerfile
├── k8s/                            # raw manifests — retained as reference, superseded by Helm
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── helm/
│   └── app-chart/                  # Helm chart — single source of deployment truth going forward
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── configmap.yaml
│           └── secret.yaml
└── infra/
    └── registries.yaml             # k3d registry mirror config — cluster infrastructure layer
```

---

## Pre-Implementation Analysis

### What raw `kubectl apply` does not give you

Before authoring the chart, it is worth being precise about what is missing from a `kubectl apply`-only workflow — not because the answer is obvious, but because understanding the gap determines what Helm is actually solving.

When a resource is applied with `kubectl`, it is stored in etcd with no ownership metadata. There is no record in the cluster of what deployment tool created it, what version it corresponds to, or what other resources belong to the same logical unit. The only history that exists is whatever is in source control — and source control records intent, not cluster state. If someone applies a hotfix directly against the cluster without committing it, the drift is invisible until the next `kubectl diff`.

Helm addresses this by writing ownership metadata into each resource it manages, as annotations:

```
meta.helm.sh/release-name: app-chart
meta.helm.sh/release-namespace: default
```

And by storing the full release manifest as a versioned Secret in the cluster:

```
helm.sh/release.v1   ← revision 1 (install)
helm.sh/release.v2   ← revision 2 (first upgrade)
```

Every `helm upgrade` creates a new revision. `helm rollback` reactivates a previous one. The cluster itself is the release ledger.

### Parameterization scope

The goal of parameterization is not to make every value configurable — it is to make environment-variant values configurable while keeping structural decisions in the template. The boundary is:

| Category | Stays in template | Goes in `values.yaml` |
|---|---|---|
| API version, kind | ✅ | — |
| Resource structure (probe type, env injection method) | ✅ | — |
| Image repository and tag | — | ✅ |
| Replica count | — | ✅ |
| Resource requests and limits | — | ✅ |
| App name, deployment name | — | ✅ |
| Listening port, health endpoint | — | ✅ |
| ConfigMap and Secret reference names | — | ✅ |

Hardcoding the app name in `matchLabels` and `template.metadata.labels` while parameterizing everything else is a common authoring mistake. If the label is hardcoded, two releases of the same chart will produce Deployments with identical label selectors — creating a selector conflict that Kubernetes will reject or, worse, allow with undefined scheduling behaviour. All identity-bearing fields must be parameterized consistently.

---

## Implementation

### 1. Chart structure

`helm create app-chart` scaffolds a full chart skeleton including `ingress.yaml`, `serviceaccount.yaml`, `hpa.yaml`, `_helpers.tpl`, and `NOTES.txt`. In a production chart targeting a platform with ingress controllers, RBAC requirements, and autoscaling policies, all of these have a place. For this workload at this stage, they are noise that obscures the structure being learned. The generated templates directory was cleared and replaced with only the four manifests that represent the actual workload.

`Chart.yaml` carries chart identity and versioning:

```yaml
apiVersion: v2
name: app-chart
version: 0.1.0
appVersion: "1.0"
description: Helm chart for the sample-next-app Next.js workload
```

`version` tracks the chart schema — it increments when the chart structure changes. `appVersion` tracks the application version — it is informational metadata, not used in templating. The two version axes are independent because chart structure changes and application releases are independent events. Conflating them makes chart history unreadable.

### 2. `values.yaml` — the contract surface

```yaml
image:
  repository: host.k3d.internal:5000/my-sample-next-app
  tag: v1
  pullPolicy: Always

replicaCount: 1

resources:
  limits:
    cpu: 500m
    memory: 256Mi
  requests:
    cpu: 250m
    memory: 128Mi

app: sample-next-app
deploymentName: k8s-deployment-1
healthCheckEndPoint: /api/health
appListeningPort: 3000
configMapRef: sample-next-app-configmap
secretRef: sample-next-app-secret
```

`values.yaml` is the contract between the chart operator and the chart template. Every value surfaced here is a knob that can be overridden at install time with `--set`, or per-environment with a separate `values-staging.yaml` passed via `-f`. Values not in `values.yaml` cannot be overridden without modifying the template — which means they are structural decisions, not configuration decisions.

`image.repository` and `image.tag` are deliberately split rather than combined into a single string. In a CI/CD pipeline, only `image.tag` changes between builds — it is injected from the git SHA at deploy time via `--set image.tag=$(git rev-parse --short HEAD)`. Splitting the two means CI can target exactly the field it controls without risk of corrupting the registry path.

### 3. Go templating — the reference pattern

Helm processes every file in `templates/` through the Go `text/template` engine before submitting to Kubernetes. The `.Values` object is the parsed representation of `values.yaml`. References follow the YAML hierarchy of the source file via dot notation.

Helm's built-in objects are case-sensitive. `.Values` (capital V) resolves to `values.yaml`. `.values` (lowercase) resolves to nothing and renders as an empty string — no error, no warning, silent misconfiguration. The failure mode is a pod that starts with blank resource limits or a missing image tag, not a failed deployment.

The image field demonstrates value composition in a template:

```yaml
image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
```

Two separate values, one output string, joined by a literal colon in the template. This is the standard pattern across the Helm ecosystem.

Nested resource references follow the hierarchy exactly:

```yaml
resources:
  requests:
    memory: {{ .Values.resources.requests.memory }}
    cpu: {{ .Values.resources.requests.cpu }}
  limits:
    memory: {{ .Values.resources.limits.memory }}
    cpu: {{ .Values.resources.limits.cpu }}
```

The Go template reference mirrors the YAML path in `values.yaml` — `resources → limits → cpu` becomes `.Values.resources.limits.cpu`. Any mismatch between the template reference and the values key path renders as empty.

### 4. Rendering and validation sequence

Three verification steps exist before any manifest touches the cluster:

```bash
# Step 1 — structural lint: catches schema violations, missing required fields, broken YAML
helm lint ./app-chart

# Step 2 — local render: prints final manifests with all values substituted, no cluster contact
helm template ./app-chart

# Step 3 — dry run: validates rendered manifests against the live cluster API, no apply
helm install app-chart ./app-chart --dry-run
```

`helm template` is the most operationally useful of the three during authoring. It makes the rendered output visible for inspection — every `{{ .Values.* }}` reference should be replaced by its concrete value, with no blank fields. Blank fields that pass `helm lint` indicate a reference that exists in the template but has no corresponding key in `values.yaml`.

---

## Incident 1 — Helm Ownership Conflict on Install

### Symptom

`helm install` failed immediately. All four resources — Deployment, Service, ConfigMap, Secret — already existed in the cluster. Helm refused to take ownership of them.

### Root Cause

Resources applied via `kubectl apply` carry no Helm ownership annotations. When Helm attempts to create the same resources as part of a new release, it detects that objects with those names already exist but are not annotated as belonging to any Helm release. Helm's behaviour in this case is to abort rather than silently adopt resources it did not create — a correct safety default. Silently adopting unowned resources would mean Helm could accidentally take control of infrastructure it should not manage, with no audit trail.

This is not a Helm limitation. It is the boundary between two resource management models: imperative (`kubectl apply`) and declarative-with-ownership (Helm). The two models cannot manage the same resource simultaneously.

### Resolution

The four manually-created resources were deleted from the cluster:

```bash
kubectl delete deployment k8s-deployment-1
kubectl delete service k8s-deployment-1
kubectl delete configmap sample-next-app-configmap
kubectl delete secret sample-next-app-secret
```

Helm then recreated all four as part of the release, annotating each with ownership metadata. From this point, `kubectl apply` against any of these resources is operationally incorrect — it would modify the resource without updating the Helm release record, creating silent drift between what Helm believes is deployed and what actually is.

### Operational Principle

Migration from `kubectl`-managed resources to Helm is a one-way transition. Once Helm owns a resource, it must be the only management path. All changes go through `helm upgrade`. The release history in the cluster becomes the authoritative record of what was deployed, when, and by whom.

---

## Incident 2 — ImagePullBackOff After Cluster Recreation

### Symptom

After the clean `helm install`, pods entered `ImagePullBackOff`. The event log surfaced:

```
failed to resolve reference "host.k3d.internal:5000/my-sample-next-app:v1":
failed to do request: Head "http://host.k3d.internal:5000/v2/...":
dial tcp: lookup host.k3d.internal: no such host
```

The image existed in the registry. The Helm chart was correctly configured. The pull was failing at DNS resolution — `host.k3d.internal` was not resolving inside the cluster nodes.

### Root Cause Analysis

This failure requires understanding the two distinct layers of the lab environment:

```
Layer 1: k3d cluster infrastructure
         └── node containers (k3d-devops-lab-server-0, agent-0, agent-1)
               └── containerd (container runtime)
                     └── /etc/rancher/k3s/registries.yaml  ← injected at cluster creation ONLY

Layer 2: Kubernetes workload layer
         └── Helm chart → Deployment → Pod → image pull request
               └── resolved by containerd on the node
```

The `registries.yaml` file tells containerd how to resolve `host.k3d.internal:5000` — it maps the hostname to the host machine's IP via the Docker bridge network. This configuration is injected into each k3d node container at **cluster creation time** via `--registry-config`. It is not a Kubernetes resource. It cannot be applied with `kubectl`. It does not survive a `k3d cluster delete`.

When the cluster was recreated — either to resolve a prior issue or as part of environment reset — the `--registry-config` flag was not passed. The nodes booted without the registry mirror configuration. containerd had no mapping for `host.k3d.internal`, DNS resolution failed, and the image pull never reached the registry.

The Helm chart was entirely correct. The failure was entirely in the infrastructure layer beneath it.

### Resolution

The cluster was recreated with the registry configuration baked in:

```bash
k3d cluster delete devops-lab

k3d cluster create devops-lab \
  --registry-config ~/devops-lab/app/sample-next-app/infra/registries.yaml \
  -p "8080:80@loadbalancer" \
  --agents 2
```

`registries.yaml` contains the mirror configuration:

```yaml
mirrors:
  "host.k3d.internal:5000":
    endpoint:
      - "http://host.k3d.internal:5000"
```

After cluster recreation, `helm install app-chart ./app-chart` completed cleanly with pods reaching `Running` state.

### Operational Principle

Cluster infrastructure configuration and application configuration are orthogonal concerns. A Helm chart parameterizes the application layer — what image to run, how many replicas, what resources to allocate. It has no mechanism to configure the container runtime on the nodes it runs on. The registry mirror config is infrastructure — it belongs to the cluster provisioning step, not the application deployment step.

In production environments this boundary is managed by the platform team: the cluster is handed to application teams with the container runtime pre-configured, trusted registries already mirrored, and pull credentials already injected. The application team never touches containerd configuration. In a lab environment where both roles collapse to one person, the boundary must be held mentally — and the failure mode when it is crossed is exactly this: a correctly-authored chart failing because of an infrastructure misconfiguration that looks, on the surface, like an application problem.

---

## Key Concepts Documented

**Helm does not manage resources — it manages releases.** A release is a versioned, named collection of Kubernetes resources deployed as a unit. The resources are the implementation detail. The release is the operational primitive. This distinction matters when reasoning about upgrades (a new release revision, not individual resource patches), rollbacks (reactivating a previous revision, not manually reverting manifests), and drift (the delta between the current release revision and live cluster state).

**`values.yaml` is a contract, not a configuration file.** In a team environment, `values.yaml` defines what the chart operator is allowed to configure without modifying the chart itself. Fields not in `values.yaml` are structural decisions locked by the chart author. This boundary is the mechanism by which platform teams can publish charts that enforce organizational standards (resource limits, security contexts, probe requirements) while allowing application teams to configure their specific values.

**Go template case sensitivity is a silent failure mode.** `.Values` and `.values` are different objects. `.Values.resources.limits.cpu` and `.Values.Resources.Limits.Cpu` are different references. Neither produces an error — the wrong one renders as empty. In a statically-typed language, this would be a compile error. In Helm, it is a correctly-deployed pod with blank resource limits that will be evicted under node pressure with no obvious cause. `helm template .` before every install makes this class of error visible before it reaches the cluster.

**`kubectl apply` and Helm are mutually exclusive managers for any given resource.** Not because of a technical constraint, but because of an ownership model constraint. Helm's release ledger records the authoritative intended state. A `kubectl apply` that modifies a Helm-owned resource without going through `helm upgrade` creates silent divergence — Helm believes the resource matches revision N, the cluster holds a state that matches neither revision N nor revision N+1. The next `helm upgrade` will overwrite the manual change without warning, or fail with a conflict, depending on the nature of the change. Either outcome is operationally worse than having discovered the correct change process beforehand.

**Cluster provisioning flags are not recoverable from within the cluster.** The `--registry-config` flag on `k3d cluster create` configures the container runtime inside each node container. Once the cluster is running, there is no Kubernetes API call, no ConfigMap, no annotation that can inject that configuration retroactively. The window for infrastructure configuration is cluster creation. Missing it means tearing down and rebuilding. In production, this is why cluster configuration is codified in infrastructure-as-code from the start — not because rebuilding is catastrophic at lab scale, but because the habit of treating cluster provisioning as a repeatable, scripted operation is what prevents a 2 AM rebuild from being a 6-hour incident.

---

## Deliverable Status

✅ Chart scaffolded — `Chart.yaml`, `values.yaml`, `templates/` with four manifests
✅ All environment-variant values parameterized — image, tag, replicas, resources, probes, labels, external refs
✅ `helm lint` passed — clean with cosmetic icon warning only
✅ `helm template` verified — all `.Values.*` references resolved to concrete values, no blank fields
✅ Helm ownership conflict diagnosed and resolved — manually-applied resources deleted, Helm recreated with ownership annotations
✅ `ImagePullBackOff` root-caused to infrastructure layer — DNS resolution failure in containerd, not chart misconfiguration
✅ Cluster recreated with `--registry-config` baked in — registry mirror restored at the correct layer
✅ `helm install app-chart` completed — `STATUS: deployed`, pod `1/1 Running`
✅ Infrastructure layer vs application layer boundary understood and documented
