# Solution

## 0. Setup

### 0.1. Branching strategy

I used the GitHub Flow model (feature branch → PR → main) for its simplicity and suitability for small teams and iterative work. All changes for this challenge are organized as atomic commits on a single feature branch for simplicity: `feature/sre-challenge-solution`.

### 0.2. Local Kubernetes cluster

All setup steps are automated for reproducibility and minimal manual effort.

The [`init.sh`](./init.sh) script installs and starts minikube, automatically detecting OS and architecture to fetch the correct binary if needed.

Minikube is started with the Docker driver and the `containerd` runtime, since Docker runtime is deprecated in Kubernetes v1.24+.

A `Makefile` streamlines the process, with targets for each step. Run `make help` to see available commands.

#### 0.2.1. Prerequisites

The following tools must be installed:

- [Docker](https://docs.docker.com/engine/install/) (or compatible container engine)
- [bash](https://www.gnu.org/software/bash/)
- [make](https://www.gnu.org/software/make/)
- [curl](https://curl.se/docs/install.html) or [wget](https://www.gnu.org/software/wget/)
- [jq](https://github.com/jqlang/jq)
- \*[kubectl](https://kubernetes.io/docs/tasks/tools/) (optional; minikube provides its own)

> \*If `kubectl` isn't installed, you can use minikube's version:
>
> ```sh
> minikube kubectl -- <kubectl commands>
> ```

#### 0.2.2. Makefile targets

- **help**: List available targets.
- **all**: Run both `init` and `deploy`.
- **init**: Install and start the Kubernetes cluster with required addons.
- **deploy**: Deploy the application using `deploy.sh`.
- **clean**: Delete the minikube cluster and clean up resources.

#### 0.2.3. Networking

Minikube ingress typically requires DNS for custom domains, often involving manual edits to `/etc/hosts`. To simplify this process, both the `ingress` and `ingress-dns` addons are enabled. These provide DNS resolution within the cluster, eliminating the need for manual host file changes.

The `ingress-dns` addon runs a DNS server inside the cluster that maps ingress hostnames to the Minikube IP. By configuring your system to use the Minikube IP as a DNS server, services can resolve automatically.

##### Configuring DNS resolution for custom domains

- **Linux**:
  On Linux, DNS resolution for custom domains depends on the system's domain resolution method (e.g., `systemd-resolved`, `NetworkManager`, or direct edits to `/etc/resolv.conf`).
  Refer to the [minikube documentation](https://minikube.sigs.k8s.io/docs/handbook/addons/ingress-dns/#Linux) for detailed instructions.

- **macOS**:
  On macOS, DNS resolution for custom domains can be configured by adding a resolver:

  ```sh
  sudo tee /etc/resolver/minikube-pleo <<EOF
  domain pleo
  nameserver $(minikube ip)
  search_order 1
  timeout 5
  EOF
  ```

### 0.3. Container registry

Before deploying, images must be built and made available to the cluster. This can be done via a local registry, a public registry, or by building images directly inside minikube.

For simplicity, I build images using the Docker daemon inside minikube, making them available to the cluster without additional steps:

```sh
minikube image build -t "${IMAGE_NAME}" "${PATH_TO_DOCKERFILE}"
```

## 1. Debugging

### 1.1. Image build errors

During the build of the container images, you might see errors like:

```sh
/go/pkg/mod/github.com/gin-gonic/gin@v1.9.1/gin.go:20:2: missing go.sum entry for module providing package golang.org/x/net/http2 (imported by github.com/gin-gonic/gin)
...
error: failed to solve: process "/bin/sh -c go build -o app ." did not complete successfully: exit code: 1
```

This is due to missing entries in `go.sum`. Fix it by downloading dependencies before building:

```dockerfile
RUN go mod download -x
RUN go mod tidy -v
```

### 1.2. Rootless containers

After applying the manifests, pods may get stuck in `CreateContainerConfigError`:

```sh
NAME                                READY   STATUS                       RESTARTS   AGE
invoice-app-f864dc848-42cgq         0/1     CreateContainerConfigError   0          15s
...
```

Describing the pod shows: `Error: container has runAsNonRoot and image will run as root`.

Both deployments have `securityContext.runAsNonRoot: true` set, but the Dockerfiles don't define a non-root user, causing a conflict with the pod security context. Fix this by adding a non-root user in the Dockerfile.

After rebuilding images, Kubernetes may not detect changes if using the `latest` tag and `IfNotPresent` pull policy. Force an update with:

```sh
kubectl rollout restart deployment invoice-app payment-provider
```

> **Note:** Avoid `latest` in production. Use immutable tags (e.g., `v1.0.0`) for predictability and rollback.

Pods should then reach `Running` state:

```sh
kubectl get pods
NAME                                READY   STATUS    RESTARTS   AGE
invoice-app-f864dc848-42vv7         1/1     Running   0          46s
...
```

## 2. Implementation

### 2.1. Exposing deployments

> Ensure both `ingress` and `ingress-dns` addons are enabled. This is handled by `init.sh` or `make init`, or manually:
>
> ```sh
> minikube addons enable ingress
> minikube addons enable ingress-dns
> ```

**Requirements**:

1. `invoice-app` must be accessible from outside the cluster.
2. `payment-provider` must only be accessible from inside the cluster.

#### 2.1.1. `invoice-app`

The Service is type `ClusterIP`, exposing the app internally on port 80 and forwarding to container port 8081. An Ingress routes HTTP traffic for `invoice-app.pleo` to this service, making it externally accessible via a friendly DNS name.

#### 2.1.2. `payment-provider`

The Service is also `ClusterIP`, exposing port 8082 only within the cluster. No Ingress is defined, so it's not externally accessible. `invoice-app` communicates with it via the internal DNS name `http://payment-provider:8082`.

### 2.2. Deployment best practices

Both `deployment.yaml` files are updated for production-readiness:

#### 2.2.1. Rollout strategy

A rolling update strategy ensures zero downtime:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

- `maxSurge: 1`: Allows one extra pod during updates for capacity.
- `maxUnavailable: 0`: Ensures all existing pods remain available.

#### 2.2.2. Resource requests and limits

Resource requests and limits manage CPU/memory allocation:

```yaml
resources:
  requests:
    cpu: "20m"
    memory: "64Mi"
  limits:
    memory: "64Mi"
```

This configuration is based on actual resource consumption, gathered using `kubectl top pod` (requires the `metrics-server` addon):

```sh
kubectl top pod
NAME                                CPU(cores)   MEMORY(bytes)
invoice-app-56c99856b8-8tj6h        2m           6Mi
invoice-app-56c99856b8-br87h        4m           9Mi
invoice-app-56c99856b8-vh86k        4m           9Mi
payment-provider-6586df4b97-4qqhf   3m           5Mi
payment-provider-6586df4b97-87v2w   2m           5Mi
payment-provider-6586df4b97-x6ztk   4m           6Mi
```

- **Requests** should be set slightly above the container's observed baseline usage to prevent throttling during normal operation.
- **Memory limits** are set equal to requests to ensure predictable memory consumption and prevent out-of-memory (OOM) kills.
- **CPU limits** are intentionally omitted to avoid throttling, which can negatively impact performance, particularly for latency-sensitive workloads.

#### 2.2.3. Liveness and readiness probes

Both deployments include HTTP liveness and readiness probes on `/healthz` endpoint:

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: <port>
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 5
readinessProbe:
  httpGet:
    path: /healthz
    port: <port>
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 2
```

- **Liveness probes** detect and restart stuck containers that cannot recover on their own. They use a higher `failureThreshold` to tolerate transient issues before triggering a restart.
- **Readiness probes** ensure that traffic is only routed to pods that are fully initialized and healthy. They typically fail faster to quickly remove unhealthy pods from service endpoints.
- Both apps expose a `/healthz` endpoint for these probes, implemented as a simple GET route in `main.go`.

### 2.3. Payment provider URL configuration

The payment provider URL in `invoice-app/main.go` is now configurable via the `PAYMENT_PROVIDER_URL` environment variable, with a sensible default:

```go
paymentProviderURL = os.Getenv("PAYMENT_PROVIDER_URL")
if paymentProviderURL == "" {
  paymentProviderURL = "http://payment-provider:8082/payments/pay"
}
```

This allows the URL to be configured externally (e.g., via Kubernetes manifests or deployment scripts), improving portability and maintainability.

### 2.4. Automation scripts

#### 2.4.1. `deploy.sh`

[`deploy.sh`](./deploy.sh) automates deployment of both apps:

- Checks if minikube is running; starts it if not.
- Builds Docker images inside minikube (if not already present).
- Applies Kubernetes manifests for each app.
- Waits for deployments to roll out successfully.

#### 2.4.2. `test.sh`

[`test.sh`](./test.sh) verifies the deployed applications:

- Waits for the `invoice-app` endpoint to become available.
- Checks for at least one unpaid invoice.
- Triggers payment via `/invoices/pay`.
- Verifies all invoices are marked as paid.

Uses `curl` and `jq` for HTTP requests and JSON parsing. Exits non-zero on failure—ideal for CI/CD or local checks.

### 2.5. Dockerfile optimisations

Both `invoice-app` and `payment-provider` Dockerfiles were optimised to significantly improve build performance and reduce image size, following Docker best practices. The changes outlined below contributed to a faster, more secure, and more efficient container build process.

#### Key optimisations

- **Multi-stage builds**: The Dockerfiles use a builder stage (`golang:alpine`) and a minimal final stage (`distroless/static-debian12:nonroot`). This ensures that only the compiled binary and essential files are included in the final image, reducing both size and potential attack surface.
- **Efficient use of build cache**: The build stage leverages Docker’s build cache for Go modules (`/go/pkg/mod/`) and binds `go.mod` and `go.sum` to avoid unnecessary downloads when dependencies haven’t changed. This speeds up rebuilds and ensures reproducibility.
- **Cross-platform compatibility**: The use of `--platform` along with build arguments (`TARGETOS`, `TARGETARCH`) enables platform-agnostic builds, making the images portable and CI-friendly.
- **Non-root execution**: The final image is based on a non-root distroless image, aligning with Kubernetes security best practices and the pod security context (`runAsNonRoot: true`).
- **Minimal final image**: Only the statically compiled binary is copied into the final image, excluding unnecessary files and layers. This keeps the image lightweight and production-ready.

#### Impact and benefits

- **Build time**: Build times were reduced from ~29s to ~11s for both apps (over 2x faster), thanks to improved caching and a streamlined build process. This was measured using the `time docker build --no-cache` command.
- **Image size**: Image sizes dropped from ~1.22GB to ~16MB (over 98% reduction), making deployments faster, reducing registry storage, and improving security by minimizing the attack surface:

  ```sh
  docker image ls | grep -E 'invoice-app|payment-provider'
  payment-provider   after     8f6336617d44   About a minute ago   16.3MB
  invoice-app        after     0f993af16743   8 minutes ago        16.9MB
  payment-provider   before    a5ebc1f42484   9 minutes ago        1.22GB
  invoice-app        before    dd811379eff3   10 minutes ago       1.22GB
  ```

## 3. Questions

### 3.1. Production-ready setup

To make this production-ready:

- Use a managed Kubernetes service (GKE, EKS, AKS) to reduce operational overhead.
- Set up a proper CI/CD pipeline (GitHub Actions, GitLab CI) to automate builds, tests, and deployments.
- Avoid the `latest` tag; use semantic versioning for images.
- Enable HPA for autoscaling.
- Centralize monitoring/logging (Prometheus, Grafana, ELK, or Loki).
- Use TLS everywhere, even internally (Cert-Manager, Let's Encrypt).
- Separate services into namespaces for organization and access control.
- Manage secrets securely (Kubernetes Secrets or Vault).
- Replace in-memory DB with a persistent store (Postgres, MySQL) for data durability.

### 3.2. Team-specific access to services

Give each team its own namespace for natural resource boundaries. Use Kubernetes RBAC to restrict access:

```yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: invoice-app-namespace
  name: invoice-app-role
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "deployments"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]

kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: invoice-app-namespace
  name: invoice-app-binding
subjects:
  - kind: User
    name: invoice-team
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: invoice-app-role
  apiGroup: rbac.authorization.k8s.io
```

Also, create dedicated service accounts for CI/CD pipelines, scoped to each namespace, and enable audit logging to track access.

### 3.3. Locking down access to `payment-provider`

By default, pods can talk to each other freely. To restrict access to `payment-provider`, use a network policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-provider-policy
  namespace: payment-provider-namespace
spec:
  podSelector:
    matchLabels:
      app: payment-provider
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: invoice-app-namespace
          podSelector:
            matchLabels:
              app: invoice-app
      ports:
        - protocol: TCP
          port: 8082
```

This allows only `invoice-app` to talk to `payment-provider` on port 8082. Keep the service as `ClusterIP` to prevent external exposure. For extra security, add authentication (API keys or mTLS). If using a service mesh (e.g., Istio, Linkerd), you get mTLS and traffic policies out of the box.

So the approach is: Block at the network level, keep services internal, and require authentication between services.
