# APP-104 | Kubernetes Workload Manifests: Deployment, Service, and Cluster-Registry Integration

**Date:** Day 4
**Ticket:** APP-104
**Scope:** Author production-grade Kubernetes Deployment and Service manifests by hand, integrate the local OCI registry established on Day 3 with the k3d cluster network, and validate end-to-end reachability of the containerised Next.js application through the cluster's networking layer.
**Outcome:** Application pod running `1/1 Ready` inside k3d. Cluster-to-registry connectivity resolved via k3s mirror config. Service wired correctly to pod via label selector. Application verified responsive from inside the cluster network.

---

## Objective

Raw `kubectl run` commands and auto-generated manifests abstract away the decisions that matter operationally — resource guardrails, health signalling, label topology, and network exposure strategy. In a real environment, every workload that ships to a cluster goes through a manifest review. That manifest encodes the operational contract between the application and the cluster: how much resource it gets, when it should be restarted, when it should receive traffic, and how other services find it.

This day establishes that contract from scratch, by hand, with full awareness of why each field exists — not just what it does.

---

## Architecture

```
Developer Machine (WSL2)
│
├── localhost:5000          → Local OCI Registry (registry:2 container)
│       ↑ docker push
│
└── k3d cluster (devops-lab)
        ├── Node: k3d-devops-lab-server-0
        ├── Node: k3d-devops-lab-agent-0
        └── Node: k3d-devops-lab-agent-1
                └── Pod: sample-next-app
                        ↑ image pull via host.k3d.internal:5000
                        └── Service: NodePort → forwards external traffic to pod
```

---

## Project Structure

Manifests are maintained in a dedicated `k8s/` directory at the project root, separate from application source. Infrastructure config (registry mirror, cluster setup files) lives under `infra/`. This separation ensures `kubectl apply -f k8s/` is a clean, targeted operation with no risk of applying non-manifest files.

```
sample-next-app/
├── app/
│   └── api/health/route.ts     # health endpoint — required for probe targets
├── Dockerfile
├── k8s/
│   ├── deployment.yaml
│   └── service.yaml
└── infra/
    └── registries.yaml         # k3s mirror config — baked into cluster at creation
```

---

## Implementation

### 1. Cluster-to-Registry Network Resolution

Before any manifest could be applied, a foundational network problem needed to be solved: k3d worker nodes are Docker containers. From inside those containers, `localhost:5000` does not resolve to the host machine — it resolves to the container's own loopback interface, where no registry is running.

k3d provides a reserved hostname for this exact case: `host.k3d.internal`. This hostname is DNS-resolvable from inside any k3d node and always routes to the host machine. The solution is a k3s registry mirror config that maps image pull requests for `host.k3d.internal:5000` to the actual registry endpoint.

**`infra/registries.yaml`**
```yaml
mirrors:
  "host.k3d.internal:5000":
    endpoint:
      - "http://host.k3d.internal:5000"
```

This file must be present inside every node at `/etc/rancher/k3s/registries.yaml` before k3s starts. The correct way to guarantee this across cluster restarts is to pass it at cluster creation time via the `--registry-config` flag — not via `docker cp` post-creation, which is wiped on every cluster restart.

```bash
k3d cluster create devops-lab \
  --agents 2 \
  --registry-config ~/devops-lab/infra/registries.yaml
```

With this in place, image references in manifests use `host.k3d.internal:5000` as the registry host, while all `docker build` and `docker push` operations from the host terminal continue to use `localhost:5000`. They point to the same registry — the hostname simply differs based on network perspective.

| Caller | Registry hostname |
|---|---|
| Host terminal (`docker push`) | `localhost:5000` |
| k3d node (image pull) | `host.k3d.internal:5000` |

---

### 2. Deployment Manifest

The Deployment is the primary workload primitive for stateless applications. It manages a ReplicaSet, which in turn manages pods. The operational contract encoded in this manifest covers four concerns: identity (labels), compute allocation (resources), health signalling (probes), and runtime configuration (env).

**`k8s/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k8s-deployment-1
  labels:
    app: sample-next-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-next-app      # binds this Deployment to pods carrying this label
  template:
    metadata:
      labels:
        app: sample-next-app    # pods inherit this label — Service selector targets it
    spec:
      containers:
        - name: sample-next-app
          image: host.k3d.internal:5000/my-sample-next-app:v1
          imagePullPolicy: Always
          ports:
            - containerPort: 3000

          resources:
            requests:
              memory: "128Mi"
              cpu: "250m"       # scheduler uses this to find a node with capacity
            limits:
              memory: "256Mi"
              cpu: "500m"       # enforced at runtime — exceed memory → OOMKilled

          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3   # 3 consecutive failures → container restart

          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3   # 3 consecutive failures → removed from load balancer

          env:
            - name: NODE_ENV
              value: "production"
```

**On resource requests and limits:** In a shared cluster, unguarded containers are a blast radius risk. A memory leak in one pod can exhaust node memory and trigger cascading evictions across unrelated workloads. Requests guarantee the scheduler places the pod on a node that can actually support it. Limits cap the damage if the application misbehaves. Both are mandatory in any manifest that ships to a shared environment.

**On probes:** Liveness and readiness serve distinct operational purposes and must not be conflated.

- `livenessProbe` answers: *is this process still functional?* Failure triggers a container restart. It handles pathological states — deadlocks, hung goroutines, infinite loops — where the process is running but incapable of doing useful work.

- `readinessProbe` answers: *is this process ready to serve traffic?* Failure removes the pod from the Service endpoint list without restarting it. It handles transient unavailability — startup time, downstream dependency reconnection, cache warming.

A pod can be alive but not ready. Both states are operationally distinct and require separate handling. Conflating them — using only liveness — results in traffic being sent to pods that are technically running but not yet capable of handling requests.

---

### 3. Service Manifest

The Service provides a stable network identity for a dynamic set of pods. Pods are ephemeral — their IPs change on every restart. The Service address does not. It uses a label selector to maintain a live list of matching pod endpoints and load-balances traffic across them.

**`k8s/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: k8s-deployment-1
spec:
  selector:
    app: sample-next-app    # targets all pods carrying this label
  ports:
    - protocol: TCP
      port: 80              # Service's cluster-internal port
      targetPort: 3000      # container port traffic is forwarded to
      nodePort: 30080       # host-accessible port (range: 30000–32767)
  type: NodePort
```

`NodePort` was chosen for local cluster access. In a production cluster, the equivalent pattern is `ClusterIP` behind an Ingress controller, with TLS termination at the Ingress layer. NodePort is operationally equivalent for non-production validation — it exposes the same application on a host-accessible port without requiring a cloud load balancer.

**The label chain** is the core wiring mechanism across all three Kubernetes objects:

```
Deployment.spec.selector.matchLabels.app: sample-next-app
                    ↕ must match
Pod.metadata.labels.app: sample-next-app
                    ↕ must match
Service.spec.selector.app: sample-next-app
```

A mismatch anywhere in this chain silently breaks traffic routing. The Service will show `Endpoints: <none>` — it can't find any pods to forward to. This is the most common hand-authoring mistake.

---

### 4. Apply and Verify

```bash
kubectl apply -f k8s/

# watch pod reach Ready state
kubectl get pods -w

# verify service has endpoints (pod IP should appear)
kubectl describe svc k8s-deployment-1

# verify application is reachable inside the cluster network
kubectl exec -it <pod-name> -- sh
wget -O - http://<pod-ip>:3000
```

The application must be verified from inside the cluster network before troubleshooting host-level access. This isolates the failure domain — if the app responds to in-cluster requests, any access failure from the host is a network bridging problem, not an application problem.

---

## Incidents and Resolutions

### Incident 1 — `ErrImagePull`: `host.k3d.internal` unresolvable from nodes

**Observed:**
```
failed to resolve reference "host.k3d.internal:5000/my-sample-next-app:v1":
dial tcp: lookup host.k3d.internal: no such host
```

**Root cause:** The k3s registry mirror config (`registries.yaml`) was applied post-cluster-creation via `docker cp`. k3d node containers are recreated on every `cluster stop/start`, wiping any files copied in at runtime. The mirror config was absent on restart.

**Resolution:** The registry config must be baked into the cluster at creation time using the `--registry-config` flag. k3d handles propagating the file to all nodes — including after restarts.

```bash
k3d cluster create devops-lab \
  --agents 2 \
  --registry-config ~/devops-lab/infra/registries.yaml
```

**Operational note:** Any cluster configuration that is applied post-creation via imperative commands (docker cp, kubectl exec) is volatile. Configuration that must survive restarts belongs in cluster creation parameters, bootstrap scripts, or GitOps-managed resources — never in one-off commands.

---

### Incident 2 — `docker cp` reported success but file was absent

**Observed:**
```
Successfully copied 88B to k3d-devops-lab-agent-0:/etc/rancher/k3s/registries.yaml
Error response from daemon: Could not find the file /etc/rancher/k3s
```

**Root cause:** `docker cp` does not create intermediate directories. The destination path `/etc/rancher/k3s/` did not exist inside the node container. Docker reported a misleading success for the copy operation before failing on the path resolution.

**Resolution:** Explicitly create the directory inside the container before copying.

```bash
docker exec k3d-devops-lab-agent-0 mkdir -p /etc/rancher/k3s
docker cp registries.yaml k3d-devops-lab-agent-0:/etc/rancher/k3s/registries.yaml
```

---

### Incident 3 — Manifest apply failed with unknown field errors

**Observed:**
```
unknown field "spec.ports", unknown field "spec.selector.app", unknown field "spec.type"
```

**Root cause:** Service-level fields (`ports`, `type: NodePort`, flat `selector`) were authored inside the Deployment manifest. Additionally, `nodePort` was cased as `nodeport` — Kubernetes field names are camelCase and strictly case-sensitive. Unrecognised fields are rejected at apply time under strict decoding.

**Resolution:** Deployment and Service are separate API objects with distinct spec schemas. They must exist in separate manifests. The Deployment spec accepts `replicas`, `selector.matchLabels`, and `template`. The Service spec accepts `selector`, `ports`, and `type`. There is no overlap.

`nodePort` (capital P) is the correct field name.

---

### Incident 4 — Pod `Running` but application unreachable from host browser

**Observed:** Pod status `1/1 Running`. `kubectl port-forward svc/nextjs-service 3000:80` produced no output. Browser at `localhost:3000` returned nothing.

**Root cause (layered):**

1. The port-forward was targeting `svc/nextjs-service` — a service name that did not exist. The actual service was named `k8s-deployment-1`. The command failed silently.

2. The k3d cluster was created without a `--port` mapping for the NodePort range. NodePort `30080` was accessible inside the cluster network but not exposed through the k3d load balancer container to the host. `localhost:30080` on the host machine had no listener.

3. The environment is WSL2. `localhost` inside WSL2 does not always bridge to the Windows host. Port-forward needed to bind on `0.0.0.0` to be reachable from the Windows browser.

**Resolution:**

```bash
# correct service name, bind on all interfaces for WSL2 compatibility
kubectl port-forward svc/k8s-deployment-1 3000:80 --address 0.0.0.0
```

For NodePort to work natively from the Windows host via k3d, the port mapping must be declared at cluster creation:

```bash
k3d cluster create devops-lab \
  --agents 2 \
  --port "30080:30080@loadbalancer" \
  --registry-config ~/devops-lab/infra/registries.yaml
```

---

### Incident 5 — `wget localhost:3000` inside pod returned connection refused

**Observed:**
```
Connecting to localhost:3000 ([::1]:3000)
wget: can't connect to remote host: Connection refused
```

**Root cause:** `localhost` resolved to the IPv6 loopback `[::1]` inside the container. The Next.js process was bound to an IPv4 interface only. Additionally, the application was not explicitly binding to `0.0.0.0` — a required configuration for containerised workloads where the process must accept connections on all interfaces, not just the loopback.

**Verification:** Direct connection to the pod's IPv4 address succeeded:
```bash
wget -O - http://10.42.2.17:3000   # ✅ returned full HTML response
```

**Resolution:** Force Next.js to bind all interfaces via the start script:

```json
"scripts": {
  "start": "next start -H 0.0.0.0 -p 3000"
}
```

**Operational note:** Any server process running inside a container must bind to `0.0.0.0`, not `localhost` or a specific hostname. Binding to `localhost` inside a container only exposes the process on the container's loopback — unreachable from any external network path, including the Service routing layer.

---

## Key Concepts Documented

**The label chain is the cluster's wiring:** Kubernetes has no explicit references between objects. Deployments don't point to Services; Services don't point to Deployments. Everything is connected through labels and selectors. A Deployment's `matchLabels` selects which pods it owns. A Service's `selector` selects which pods receive its traffic. If those labels drift — through a rename, a copy-paste error, or an environment-specific override — the connection silently breaks. No error is raised. Traffic simply stops routing. Auditing the label chain is the first step in any connectivity investigation.

**Volatile vs. durable cluster configuration:** Configuration applied to a running cluster via imperative commands is operationally invisible and volatile. It does not survive restarts, does not appear in version control, and cannot be audited. Any configuration that the cluster depends on for correct behaviour — registry mirrors, admission webhooks, CNI config — must be declared at cluster creation time or managed through a reconciled mechanism (Helm, ArgoCD, Terraform). This is not a local dev inconvenience — it is the same principle that governs production cluster bootstrapping.

**Network perspective determines the correct hostname:** In a layered network environment (host → Docker → k3d node → container), the correct address for any resource depends on who is making the request. The same registry is `localhost:5000` from the host terminal and `host.k3d.internal:5000` from inside a k3d node. Using the wrong hostname from the wrong network context produces a resolution failure that has nothing to do with the registry's availability. Debugging network failures requires identifying the caller's network namespace first.

**Manifest authoring is an operational contract, not configuration:** A Deployment manifest is not a deployment script. It is a declarative specification of the operational contract between an application and the cluster — what resources it gets, when it is considered healthy, when it should be restarted, and how traffic reaches it. Every field is a decision with operational consequences. Omitting resource limits is a blast radius decision. Omitting probes is an availability decision. The manifest is the artifact that on-call engineers read at 3am.

---

## Deliverable Status

✅ Cluster recreated with `--registry-config` — registry mirror survives restarts
✅ Deployment manifest authored with resources, livenessProbe, and readinessProbe
✅ Service manifest authored with correct NodePort and label selector
✅ Label chain verified: Deployment → Pod → Service consistent across all three objects
✅ Application verified responsive inside cluster network (`wget` to pod IP returned full HTML)
✅ Port-forward confirmed working with `--address 0.0.0.0` for WSL2 host access
