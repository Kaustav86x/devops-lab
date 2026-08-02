# INFRA-103 | Local Container Registry: Setup, Push, and Verification

**Date:** Day 3  
**Ticket:** INFRA-103  
**Scope:** Establish a local private container registry, tag and push the production image from Day 2, and verify pullability for downstream k3d cluster use  
**Outcome:** Image successfully pushed to `localhost:5000`, verified via registry API and UI. Registry operational as the source of truth for local cluster deployments.

---

## Objective

In a real deployment pipeline, images are never pulled directly from a developer's local Docker daemon into a cluster. They go through a registry — the single source of truth that CI/CD, orchestrators, and deployment tools all point to. This day establishes that registry locally, mirrors the pattern used in production environments (ECR, GCR, Artifact Registry), and validates the full push-verify loop before k3d integration in subsequent days.

---

## Architecture

```
Docker Build  →  Local Image  →  Tag for Registry  →  Push  →  localhost:5000
                                                                      ↓
                                                              k3d pulls from here
```

---

## Implementation

### 1. Start the Local Registry

```bash
docker run -d -p 5000:5000 --name registry registry:2
```

`registry:2` is the official Docker-maintained OCI-compliant registry. It runs as a container, exposes port 5000, and persists images in its internal volume for the lifetime of the container.

### 2. Tag the Image for the Registry

```bash
docker tag my-sample-next-app:v1 localhost:5000/my-sample-next-app:v1
```

**What tagging actually does:**

Tagging does not copy or duplicate the image. It creates an alias that encodes routing information — specifically, where this image should be pushed to and pulled from. Docker reads the registry address from the image name prefix.

```
localhost:5000/my-sample-next-app:v1
│              │                  │
registry host  image name         tag
```

Without a registry prefix (e.g., plain `my-sample-next-app:v1`), Docker defaults to Docker Hub for push/pull operations.

### 3. Push the Image

```bash
docker push localhost:5000/my-sample-next-app:v1
```

This uploads the image layers to the registry. Layers already present in the registry are skipped (deduplication via content-addressable storage). Only new or changed layers are transferred.

---

## Verification

### Via Registry HTTP API

The registry exposes a standard OCI Distribution API. No authentication required for a local insecure registry:

```bash
# List all repositories in the registry
curl http://localhost:5000/v2/_catalog
# {"repositories":["my-sample-next-app"]}

# List all tags for the image
curl http://localhost:5000/v2/my-sample-next-app/tags/list
# {"name":"my-sample-next-app","tags":["v1"]}
```

This is the same API surface used by Kubernetes, ArgoCD, and other tooling to discover and pull images. Knowing it exists is operationally useful for debugging pull failures in cluster environments.

### Via Registry UI

`registry:2` ships with no visual interface. A lightweight UI was added for observability:

```bash
docker run -d -p 8080:80 \
  -e REGISTRY_URL=http://localhost:5000 \
  joxit/docker-registry-ui
```

Accessible at `http://localhost:8080` — displays all repositories, tags, image sizes, and manifest digests. Useful for quickly auditing what is available in the registry without constructing curl commands.

---

## Key Concepts Documented

**Registry as the handoff point:** The registry decouples the build environment from the runtime environment. The Docker daemon that built the image and the k3d cluster that runs it never communicate directly — the registry is the intermediary. This is why tagging with the registry address is a required step, not optional housekeeping.

**Image naming convention:** Tag images with meaningful, immutable identifiers in real pipelines. `latest` is mutable and creates ambiguity — two pulls of `latest` at different times may yield different images. The industry convention is to use the git commit SHA:

```bash
docker tag my-sample-next-app:v1 localhost:5000/my-sample-next-app:<git-sha>
```

This makes every build traceable to the exact commit that produced it — critical for rollback and incident diagnosis.

**Insecure registry config:** By default, Docker requires HTTPS for registry communication. `localhost` is exempt from this requirement. For any non-localhost address (e.g., a registry on another machine), the address must be added to Docker's `insecure-registries` list in `daemon.json`, or the push/pull will be rejected with a TLS error.

---

## Deliverable Status

✅ Local registry running at `localhost:5000`  
✅ Image tagged with registry-prefixed name  
✅ Image pushed and verified via API response  
✅ Registry UI running at `localhost:8080` for visual inspection  
✅ Image pullable by k3d cluster in subsequent days  
