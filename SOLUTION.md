# Solution

## 0. Setup

### 0.1. Branching strategy

For this challenge, I adopted the GitHub Flow branching model, which is well-suited for small teams and iterative development. The workflow is as follows:

1. Create a feature branch for each set of related changes.
2. Commit changes to the feature branch in small, atomic commits with clear messages.
3. Open a pull request (PR) from the feature branch to `main` for review and discussion.
4. After review and approval, merge the PR into `main`.

This approach ensures a clean, linear history and makes it easy to track changes, collaborate, and review code. For this solution, all changes are organized on a single feature branch (`feature/sre-challenge-solution`) for clarity and simplicity, but in a larger project, multiple feature branches would be used in parallel.

### 0.2. Local Kubernetes cluster

All setup steps are automated for consistency and minimal manual intervention.

The [`init.sh`](./init.sh) script handles installation and startup of minikube. It automatically detects your OS and architecture to download the correct binary if needed.

minikube is started using the Docker driver and the `containerd` runtime, as Docker runtime is deprecated in Kubernetes v1.24+.

A [`Makefile`](./Makefile) is provided to streamline the workflow, with targets for each step. Run `make help` to see all available commands.

#### 0.2.1. Prerequisites

The following tools must be installed:

- [Docker](https://docs.docker.com/engine/install/) (or compatible container engine)
- [bash](https://www.gnu.org/software/bash/)
- [make](https://www.gnu.org/software/make/)
- [curl](https://curl.se/docs/install.html)
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
- **test**: Run integration tests using `test.sh`.

#### 0.2.3. Networking

minikube ingress typically requires DNS configuration for custom domains, which often involves manually editing the `/etc/hosts` file. To simplify this process, both the `ingress` and `ingress-dns` addons are enabled by default. These addons provide automatic DNS resolution within the cluster, removing the need for manual updates to the hosts file.

The `ingress-dns` addon deploys a DNS server inside the cluster that maps Ingress hostnames to the minikube IP. By configuring your system to use the minikube IP as its DNS server, Services can resolve domain names automatically.

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

Before deploying, container images must be built and made accessible to the cluster. This can be done via a local registry, a public registry, or by building images directly inside minikube.

For simplicity, the container images are built using the Docker daemon inside minikube, making them available to the cluster without requiring additional steps:

```sh
minikube image build -t "${IMAGE_NAME}" "${PATH_TO_DOCKERFILE}"
```

## 1. Debugging

### 1.1. Image build errors

During the build of the container images, you might encounter errors like:

```sh
/go/pkg/mod/github.com/gin-gonic/gin@v1.9.1/gin.go:20:2: missing go.sum entry for module providing package golang.org/x/net/http2 (imported by github.com/gin-gonic/gin)
...
error: failed to solve: process "/bin/sh -c go build -o app ." did not complete successfully: exit code: 1
```

These errors occur when required dependencies are missing from `go.sum`. To fix this, add the following line to the Dockerfile before the `go build` command:

```dockerfile
RUN go mod download -x
```

If `go.mod` and `go.sum` are out of sync, running the following locally (not in the Dockerfile) may also be necessary:

```sh
go mod tidy -v
```

Both Dockerfiles have been updated to efficiently use the build cache: Go modules are cached via `/go/pkg/mod/`, and `go.mod` and `go.sum` are bind-mounted to avoid unnecessary downloads when dependencies haven’t changed. This speeds up rebuilds and ensures reproducibility. For more details, see [2.5. Dockerfile optimisations](./SOLUTION.md#25-dockerfile-optimisations).

### 1.2. Rootless containers

After applying the manifests, Pods may get stuck in the `CreateContainerConfigError` state:

```sh
NAME                                READY   STATUS                       RESTARTS   AGE
invoice-app-f864dc848-42cgq         0/1     CreateContainerConfigError   0          15s
...
```

Inspecting the Pod shows: `Error: container has runAsNonRoot and image will run as root`.

Both Deployments have `securityContext.runAsNonRoot: true` set, but the Dockerfiles don't define a non-root user, causing a conflict with the Pod security context. Fix this by adding a non-root user in the Dockerfile.

After rebuilding the images, Kubernetes may not automatically detect image changes if using the `latest` tag with the `IfNotPresent` image pull policy. This policy prevents re-pulling the image if it already exists locally. To force Kubernetes to use the updated image, run:

```sh
kubectl rollout restart deployment invoice-app payment-provider
```

> **Note**: Avoid the `latest` tag in production. Instead, use immutable tags (e.g., `v1.0.0`) for better predictability and easier rollbacks.

After applying these fixes, the Pods should transition to the `Running` state:

```sh
NAME                                READY   STATUS    RESTARTS   AGE
invoice-app-f864dc848-42vv7         1/1     Running   0          46s
...
```

## 2. Implementation

### 2.1. Exposing deployments

> Ensure both `ingress` and `ingress-dns` addons are enabled. This is automatically handled by `init.sh` or `make init`, or manually:
>
> ```sh
> minikube addons enable ingress
> minikube addons enable ingress-dns
> ```

**Requirements**:

1. `invoice-app` must be accessible from outside the cluster.
2. `payment-provider` must only be accessible from inside the cluster.

#### 2.1.1. `invoice-app`

The `invoice-app` Service is of type `ClusterIP`, exposing the app internally on port 80 and forwarding to container port 8081. An `Ingress` routes HTTP traffic for `invoice-app.pleo` to this Service, making it externally accessible via a user-friendly DNS name.

#### 2.1.2. `payment-provider`

The `payment-provider` Service is also of type `ClusterIP`, exposing port 8082 only within the cluster. No `Ingress` is defined, so it's not externally accessible. `invoice-app` communicates with it via the internal DNS name `http://payment-provider:8082`.

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

- `maxSurge: 1`: Allows one extra Pod during updates for capacity.
- `maxUnavailable: 0`: Ensures all existing Pods remain available.

#### 2.2.2. Resource requests and limits

Resource requests and limits manage resource (CPU and memory) allocation:

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
NAME                                CPU(cores)   MEMORY(bytes)
invoice-app-56c99856b8-8tj6h        2m           6Mi
invoice-app-56c99856b8-br87h        4m           9Mi
invoice-app-56c99856b8-vh86k        4m           9Mi
payment-provider-6586df4b97-4qqhf   3m           5Mi
payment-provider-6586df4b97-87v2w   2m           5Mi
payment-provider-6586df4b97-x6ztk   4m           6Mi
```

- **Requests** should be set slightly above the container's observed baseline usage to ensure there are enough resources available for the container to run smoothly.
- **`memory` limits** are set equal to memory requests to prevent the container from exceeding a predictable memory usage. This approach avoids allocating more memory than the container actually needs.
- **`cpu` limits** are intentionally omitted to avoid throttling, which could negatively impact performance. This allows the container to consume as much CPU as it needs, up to the available capacity of the node.

> **Note**: CPU is a flexible resource that can be throttled without terminating the process. However, memory is non-flexible: each process has an isolated memory space that cannot be directly modified or freed. If a container exceeds its memory limit, the OOM Killer terminates it to reclaim resources.

#### 2.2.3. Liveness and readiness probes

Both Deployments include HTTP liveness and readiness probes on `/healthz` endpoint:

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
- **Readiness probes** ensure that traffic is only routed to Pods that are fully initialized and healthy. They typically fail faster to quickly remove unhealthy Pods from Service endpoints.
- Both apps expose a `/healthz` endpoint for these probes, implemented as a simple GET route in `main.go`.

### 2.3. Payment provider URL configuration

The payment provider URL in [`invoice-app/main.go`](./invoice-app/main.go) is now configurable via the `PAYMENT_PROVIDER_URL` environment variable, with a sensible default:

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

### 2.5. Dockerfile optimisations

The Dockerfiles for both `invoice-app` and `payment-provider` were optimised to improve build performance and reduce image size, following Docker best practices:

- **Multi-stage builds**: The build uses a builder stage (`golang:alpine`) and a minimal final stage (`distroless/static-debian12:nonroot`). This ensures that only the compiled binary is included in the final image, reducing both size and potential attack surface.
- **Efficient cache usage**: Docker's build cache is used for Go modules (`/go/pkg/mod/`), with `go.mod` and `go.sum` files bound to avoid unnecessary downloads when dependencies haven’t changed. This speeds up rebuilds and ensures reproducibility.
- **Cross-platform compatibility**: The `--platform` flag and build arguments (`TARGETOS`, `TARGETARCH`) ensures platform-agnostic builds, making the images portable and CI-friendly.
- **Non-root execution**: The final image is based on a non-root distroless image, aligning with Kubernetes security best practices and the Pod security context (`runAsNonRoot: true`).
- **Minimal final image**: Only the statically compiled binary is copied into the final image, excluding unnecessary files and layers. This keeps the image lightweight and production-ready.

#### Impact and benefits

- **Build time**: Reduced from ~29s to ~11s for both apps (over 2x faster), thanks to improved caching and a streamlined build process. This was measured using the `time docker build --no-cache` command.
- **Image size**: Reduced from ~1.22GB to ~16MB (over 98% reduction), making deployments faster, reducing registry storage, and improving security by minimizing the attack surface:

  ```sh
  docker image ls | grep -E 'invoice-app|payment-provider'
  payment-provider   after     8f6336617d44   About a minute ago   16.3MB
  invoice-app        after     0f993af16743   8 minutes ago        16.9MB
  payment-provider   before    a5ebc1f42484   9 minutes ago        1.22GB
  invoice-app        before    dd811379eff3   10 minutes ago       1.22GB
  ```

## 3. Questions

### 3.1. Production-ready setup

To make the setup production-ready, follow these best practices:

- **Use a managed Kubernetes service** (e.g., GKE, EKS, AKS) to offload infrastructure tasks like node provisioning, health monitoring, and patching, reducing operational overhead.
- **Separate environments** for testing, staging, and production. Use distinct clusters for each, with automated promotion of builds after passing tests and approvals.
- **Adopt a branching strategy** such as GitHub Flow or GitLab Flow. Protect critical branches (e.g., `main`, `staging`) with required reviews and automated tests to ensure only validated code is deployed.
- **Implement a robust CI/CD pipeline** to automate build, test, and deployment. This minimizes human error and ensures consistent, repeatable releases.
- **Avoid the `latest` tag** for container images. Use [semantic versioning](https://semver.org/) to deploy only tested and verified versions, avoiding unpredictable or unstable updates.
- **Enable Horizontal Pod Autoscaling (HPA)** to scale Pods based on CPU or custom metrics, ensuring responsive and efficient resource usage.
- **Centralize monitoring and logging** (e.g., Prometheus, Grafana, ELK, Loki) for visibility into application health and performance, enabling proactive issue detection and debugging.
- **Use TLS encryption** (e.g., cert-manager with Let’s Encrypt) for all internal and external traffic to protect data in transit.
- **Enforce RBAC** for fine-grained access control, aligning with least-privilege principles to reduce the risk of unauthorized access.
- **Secure secrets management** using Kubernetes Secrets (with encryption) or tools like HashiCorp Vault to protect sensitive data such as API keys and credentials.
- **Use persistent databases** (e.g., PostgreSQL, MySQL) instead of in-memory storage to ensure data durability.

### 3.2. Team-specific access to services

To ensure each team can only access their own microservice, use **namespace-based isolation** and **RBAC (Role-Based Access Control)**:

- **Namespaces** logically divide resources within the cluster, providing isolation, resource grouping, and scope for access control and policy enforcement.
- **RBAC** controls access to resources at the namespace level. Define `Roles` and `RoleBindings` to grant each team access only to their respective resources (e.g., Pods, Deployments, Services):

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
  ---
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

Additionally, create dedicated service accounts for CI/CD pipelines, scoped to each namespace, and enable audit logging to track access.

### 3.3. Locking down access to `payment-provider`

By default, Pods can communicate to each other freely. To restrict access to `payment-provider`, implement a `NetworkPolicy`:

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

This policy allows only the `invoice-app` to access the `payment-provider` on port 8082. Set the Service type to `ClusterIP` to avoid external exposure.

For enhanced security, consider adding authentication (API keys or mTLS). If using a service mesh (e.g., Istio, Linkerd), mTLS and traffic policies are provided by default.

So the approach is: Block access at the network level, keep services internal, and enforce authentication between services.
