# APP-105 | Externalising Runtime Configuration: ConfigMap, Secrets, and Deployment Wiring

**Date:** Day 5
**Ticket:** APP-105
**Scope:** Extract hardcoded runtime configuration from the containerised Next.js workload into Kubernetes-native configuration objects. Introduce a `ConfigMap` for non-sensitive environment parameters and a `Secret` for credential material. Wire both into the Deployment manifest via explicit environment variable injection. Validate end-to-end configuration propagation inside the running pod.
**Outcome:** Deployment manifest decoupled from environment-specific values. ConfigMap and Secret applied to the cluster and correctly resolved at pod startup. All six injected environment variables verified present inside the container via `printenv`.

---

## Objective

A container image that embeds environment-specific configuration is not a portable artifact — it is a snapshot of one environment. Promoting that image to staging or production requires either a rebuild (breaking the immutability guarantee) or a runtime override mechanism. Neither is acceptable at scale.

Kubernetes addresses this through a clean separation of concerns: the image encodes *what the application does*, configuration objects encode *how it behaves in a given environment*. The cluster wires them together at pod startup. The image never changes. The configuration does.

This day establishes that separation for the Next.js workload — not because the application has complex configuration today, but because the pattern must be muscle memory before the workload grows to the point where retrofitting it becomes dangerous.

---

## Architecture

```
k8s/ (manifests)
│
├── configmap.yaml          → non-sensitive runtime parameters (PORT, HOSTNAME, NODE_ENV)
├── secret.yaml             → credential material (DB_HOST, DB_PASSWORD, DB_PORT)
└── deployment.yaml         → references both objects via env injection
        │
        ↓ kubectl apply (order: ConfigMap → Secret → Deployment)
        │
k3d cluster (devops-lab)
        └── Pod: sample-next-app
                └── container env (resolved at pod startup)
                        ├── PORT=3000          ← from ConfigMap
                        ├── HOSTNAME=0.0.0.0   ← from ConfigMap
                        ├── NODE_ENV=production ← from ConfigMap
                        ├── DB_HOST=localhost   ← from Secret
                        ├── DB_PASSWORD=***    ← from Secret
                        └── DB_PORT=5432       ← from Secret
```

---

## Project Structure

```
sample-next-app/
├── Dockerfile
├── k8s/
│   ├── configmap.yaml       # non-sensitive runtime parameters
│   ├── secret.yaml          # credential material
│   ├── deployment.yaml      # updated — references ConfigMap and Secret
│   └── service.yaml         # unchanged from Day 4
└── infra/
    └── registries.yaml
```

---

## Pre-Implementation Analysis

Before writing any manifest, a configuration audit was conducted across all three layers where hardcoded values can live: the Dockerfile, the application source, and the existing Kubernetes manifests.

### Dockerfile audit

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS production
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

EXPOSE 3000
CMD ["node", "server.js"]
```

**Findings:**

- `EXPOSE 3000` — this is metadata only, not a port binding. The `EXPOSE` instruction documents intent for tooling and humans; it does not cause the container to listen on any port. Removing or changing it has no effect on the running process. Not a configuration concern.
- `CMD ["node", "server.js"]` — Next.js standalone `server.js` natively reads `PORT` and `HOSTNAME` from the environment at startup. Neither is hardcoded in the start command. Both are legitimate ConfigMap candidates.
- No `ENV` instructions — no build-time values baked into the production image layer.

**Conclusion:** The Dockerfile is clean. No values require extraction from the image itself. The configuration gap is in the Deployment manifest, where `NODE_ENV` was hardcoded inline in Day 4.

### Build-time vs runtime distinction

A critical boundary in Next.js configuration that must be understood before any environment variable is externalised:

| Variable type | When resolved | Can ConfigMap override? |
|---|---|---|
| `NEXT_PUBLIC_*` vars | At `npm run build` — baked into JS bundles | ❌ No — frozen in image layer |
| Server-side env vars (`PORT`, `NODE_ENV`) | At process startup — read by `server.js` | ✅ Yes — injected before process starts |

ConfigMaps only affect values read at runtime. Variables consumed during the build step are embedded in the output artifact and cannot be overridden by any cluster-level mechanism. This distinction governs which variables belong in a ConfigMap and which require a rebuild if they need to change.

---

## Implementation

### 1. ConfigMap

Holds non-sensitive runtime parameters. These are values the application reads at startup via `process.env` — not values baked into the image during the build phase.

**`k8s/configmap.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-next-app-configmap
  labels:
    app: sample-next-app
data:
  PORT: "3000"
  HOSTNAME: "0.0.0.0"
  NODE_ENV: "production"
```

**On field casing:** keys under `data` are injected verbatim as environment variable names. Environment variable names are case-sensitive. The application and the Next.js runtime expect `PORT`, `HOSTNAME`, and `NODE_ENV` — uppercase. Lowercase keys (`port`, `hostname`) would be injected as different variables that nothing reads. The mismatch would be silent — no error, just missing configuration.

**On value types:** all values under `data` must be strings. Integer-like values such as `3000` must be quoted. Kubernetes rejects unquoted numeric values in ConfigMap `data`.

**On `PORT` and `HOSTNAME` specifically:** these are not arbitrary choices. Next.js standalone server (`server.js`) reads exactly these two environment variables at startup to determine the interface and port to bind. Setting `HOSTNAME: "0.0.0.0"` is operationally significant — it instructs the process to accept connections on all network interfaces, not just loopback. A containerised process that binds only to `localhost` is unreachable from the Service routing layer. This was the root cause of Incident 5 in Day 4 and is now addressed at the configuration layer rather than the application startup script.

---

### 2. Secret

Holds credential material. Structurally similar to ConfigMap but semantically distinct — Kubernetes treats Secret objects with access controls and, depending on cluster configuration, encryption at rest.

**`k8s/secret.yaml`**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sample-next-app-secret
  labels:
    app: sample-next-app
stringData:
  DB_HOST: "localhost"
  DB_PASSWORD: "fiw86f734fuh8"
  DB_PORT: "5432"
type: Opaque
```

**On `stringData` vs `data`:** the `data` field requires base64-encoded values. `stringData` accepts plaintext and Kubernetes encodes it automatically on write. For authoring and review purposes, `stringData` is preferred — base64 encoding is not encryption, provides no security benefit during authoring, and makes code review harder. The stored representation is identical either way.

**On `type: Opaque`:** signals that this Secret contains arbitrary key-value pairs with no structure Kubernetes needs to interpret. Other types (`kubernetes.io/tls`, `kubernetes.io/dockerconfigjson`) trigger specific validation and handling by the cluster. For generic application credentials, `Opaque` is always correct.

**On `DB_HOST: "localhost"`:** this value is environmentally incorrect and intentionally so for this exercise. In a real cluster, the database would run as a separate workload and the host value would be the Kubernetes Service DNS name — `postgres-service` or `postgres.default.svc.cluster.local`. `localhost` inside a pod refers to that pod's own loopback interface. A real database connection using this value would fail at the network layer. This is noted for when an actual data layer is introduced.

---

### 3. Deployment — env block update

The Deployment manifest from Day 4 had `NODE_ENV` hardcoded inline. The updated `env` block removes that inline value and replaces all six environment variables with references to the appropriate configuration objects.

```yaml
env:                    # all values sourced from external config objects — no inline hardcoding
  - name: NODE_ENV
    valueFrom:
      configMapKeyRef:
        name: sample-next-app-configmap
        key: NODE_ENV
  - name: PORT
    valueFrom:
      configMapKeyRef:
        name: sample-next-app-configmap
        key: PORT
  - name: HOSTNAME
    valueFrom:
      configMapKeyRef:
        name: sample-next-app-configmap
        key: HOSTNAME
  - name: DB_HOST
    valueFrom:
      secretKeyRef:
        name: sample-next-app-secret
        key: DB_HOST
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: sample-next-app-secret
        key: DB_PASSWORD
  - name: DB_PORT
    valueFrom:
      secretKeyRef:
        name: sample-next-app-secret
        key: DB_PORT
```

**On `configMapKeyRef` vs `secretKeyRef`:** both follow the same structure. The distinction is the source object type. `name` identifies the ConfigMap or Secret by its `metadata.name`. `key` identifies the specific entry within that object. The outer `name` field is what the environment variable will be called inside the container — it does not need to match the `key`, but keeping them consistent eliminates a class of debugging confusion where the application expects `PORT` but the container receives it as `APP_PORT`.

**On `envFrom` as an alternative:** Kubernetes supports bulk injection via `envFrom`, which pulls all keys from a ConfigMap or Secret into the container's environment in one block. This is operationally convenient but reduces explicitness — a reviewer cannot determine which variables a container receives without reading the referenced object. Per-key injection via `valueFrom` makes the contract visible in the manifest itself. That explicitness is worth the verbosity.

---

### 4. Apply sequence and verification

```bash
# apply in dependency order — referenced objects must exist before the Deployment
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/deployment.yaml

# verify pod reached Ready state
kubectl get pods -w

# verify all six variables are present inside the container
kubectl exec -it <pod-name> -- printenv | grep -E "PORT|HOSTNAME|NODE_ENV|DB_HOST|DB_PASSWORD|DB_PORT"
```

Expected output:
```
PORT=3000
HOSTNAME=0.0.0.0
NODE_ENV=production
DB_HOST=localhost
DB_PASSWORD=fiw86f734fuh8
DB_PORT=5432
```

---

## Key Concepts Documented

**Configuration externalisation is an immutability strategy, not a convenience feature.** An image that embeds environment-specific configuration cannot be promoted across environments without modification. The moment a rebuild is required to change an environment variable, the artifact being deployed to production is not the same artifact that was tested in staging. Kubernetes ConfigMaps and Secrets exist specifically to remove that requirement — the image is built once, configuration is applied at deployment time, and the promotion pipeline moves the same binary through every environment.

**`EXPOSE` is documentation, not binding.** A persistent industry misconception is that `EXPOSE` in a Dockerfile causes the container to listen on a port. It does not. The port the application listens on is determined entirely by the server process — in this case, Next.js's `server.js` reading the `PORT` environment variable. `EXPOSE` is a hint to tooling and a communication to humans. Changing it has no effect on network behaviour.

**Apply order encodes the dependency graph.** Kubernetes does not validate references at apply time — it attempts to resolve them when the pod starts. Applying a Deployment that references a ConfigMap before the ConfigMap exists produces pods that fail immediately with `CreateContainerConfigError`. The correct apply order mirrors the dependency graph: dependencies first, dependents after. In production environments managed through GitOps tools like ArgoCD, this ordering is handled by sync waves and resource hooks. In direct `kubectl apply` workflows, it is the operator's responsibility.

**ConfigMap and Secret are not interchangeable.** Both store key-value pairs. The difference is operational, not structural. Secrets are access-controlled, can be encrypted at rest, and are excluded from certain logging and audit paths. Putting a database password in a ConfigMap is not a Kubernetes error — it is an operational risk. Auditors, RBAC policies, and secret scanning tools all treat the two object types differently. The classification decision made during authoring has downstream consequences in access control, compliance, and incident response.

**Namespace is an implicit constraint on all object references.** A ConfigMap and the Deployment that references it must exist in the same namespace. Cross-namespace references via `configMapKeyRef` are not supported. In a multi-tenant cluster where workloads are namespace-isolated, configuration objects must be replicated or managed per namespace. This is a non-issue in a single-namespace lab environment but becomes a configuration management problem at scale — one of the reasons tools like External Secrets Operator and Vault Agent Injector exist.

---

## Deliverable Status

✅ Dockerfile audited — confirmed no build-time values requiring extraction
✅ Build-time vs runtime variable boundary understood and documented
✅ `configmap.yaml` authored with `PORT`, `HOSTNAME`, `NODE_ENV` — all uppercase, all quoted strings
✅ `secret.yaml` authored with `DB_HOST`, `DB_PASSWORD`, `DB_PORT` using `stringData` and `type: Opaque`
✅ Deployment `env` block updated — all six variables sourced from external config objects via `valueFrom`
✅ Apply sequence: ConfigMap → Secret → Deployment
✅ Configuration propagation verified via `printenv` inside running container
