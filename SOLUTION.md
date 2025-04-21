# Solution

## 0. Setup

### 0.1. Branching strategy

The GitHub Flow model has been adopted for its simplicity (feature branch → PR → main) and suitability for small teams and iterative development. All work for this challenge has been organised into atomic commits on a single feature branch: `feature/sre-challenge-solution`.

### 0.2. Local Kubernetes cluster

All setup steps have been automated for reproducibility and minimal manual intervention.

The [`init.sh`](./init.sh) script installs and starts minikube. OS and architecture are detected automatically, and the appropriate minikube binary is installed if missing.

Minikube is started with the Docker driver and the `containerd` runtime, as Docker runtime has been deprecated in Kubernetes since v1.24.

A `Makefile` is provided to streamline the process. Predefined targets ensure consistency and ease of use. Available commands can be listed with `make help`.

#### 0.2.1. Prerequisites

The following tools must be installed:

- [Docker](https://docs.docker.com/engine/install/) (or a compatible container engine)
- [bash](https://www.gnu.org/software/bash/)
- [make](https://www.gnu.org/software/make/)
- [curl](https://curl.se/docs/install.html) or [wget](https://www.gnu.org/software/wget/)
- \* [kubectl](https://kubernetes.io/docs/tasks/tools/) (optional; minikube provides its own version)
- [jq](https://github.com/jqlang/jq)

> \* If `kubectl` is not installed, minikube's bundled version may be used:
>
> ```sh
> minikube kubectl -- <kubectl commands>
> ```

#### 0.2.2. Makefile targets

The `Makefile` provides these targets:

- **help**: List available targets and descriptions.
- **all**: Run both `init` and `deploy`.
- **init**: Install and start the Kubernetes cluster with required addons.
- **deploy**: Deploy the application using `deploy.sh`.
- **clean**: Delete the minikube cluster and clean up resources.

#### 0.2.3. Networking

Ingress in minikube typically requires DNS resolution for custom domains, which often involves editing `/etc/hosts`. This can be avoided by enabling the `ingress` and `ingress-dns` addons, which provide DNS resolution within the cluster.

The `ingress-dns` addon runs a DNS server inside the cluster, mapping ingress hostnames to the minikube IP. By configuring the host to use the minikube IP as a DNS server, services are resolved automatically.

##### DNS configuration on macOS

On macOS, DNS resolution for custom domains can be configured by adding a resolver:

```sh
sudo tee /etc/resolver/minikube-pleo <<EOF
domain pleo
nameserver $(minikube ip)
search_order 1
timeout 5
EOF
```

## 0.3. Container registry

Before deploying the applications, container images must be built and made accessible to the Kubernetes cluster. This can be achieved by using a local registry (e.g., [registry](https://hub.docker.com/_/registry)), a public registry (e.g., Docker Hub, GCR), or by building images directly inside minikube.

To keep things simple, the following command builds the image using the Docker daemon inside minikube, making it immediately available:

```sh
minikube image build -t "${IMAGE_NAME}" "${PATH_TO_DOCKERFILE}"
```

## 1. Debugging

### 1.1. payment-provider build error

During the build of the `payment-provider` image, errors such as the following may occur:

```sh
/go/pkg/mod/github.com/gin-gonic/gin@v1.9.1/gin.go:20:2: missing go.sum entry for module providing package golang.org/x/net/http2 (imported by github.com/gin-gonic/gin)
```

```sh
error: failed to solve: process "/bin/sh -c go build -o app ." did not complete successfully: exit code: 1
```

These errors are caused by missing entries in the `go.sum` file. To resolve this, dependencies must be downloaded before building:

```dockerfile
RUN go mod download -x
RUN go mod tidy -v
```

### 1.2. Rootless containers

After applying the manifests, pods may enter a `CreateContainerConfigError` state:

```sh
NAME                                READY   STATUS                       RESTARTS   AGE
invoice-app-f864dc848-42cgq         0/1     CreateContainerConfigError   0          15s
...
```

Describing the pods reveals: `Error: container has runAsNonRoot and image will run as root`.

Both deployments are configured with `securityContext.runAsNonRoot: true`, but the Dockerfiles do not specify a non-root user. This conflict is resolved by specifying a non-root user in the Dockerfile or by using a non-root base image.

After updating the Dockerfiles, images must be rebuilt. If the same tag is reused, Kubernetes may not detect changes, since the image pull policy is set to `IfNotPresent`. To force an update:

```sh
kubectl rollout restart deployment invoice-app payment-provider
```

> Note: Avoid using the `latest` tag in production. Instead, use immutable tags (e.g., `v1.0.0`) to ensure predictable and consistent versioning.

Pods should then reach the `Running` state:

```sh
kubectl get pods
NAME                                READY   STATUS    RESTARTS   AGE
invoice-app-f864dc848-42vv7         1/1     Running   0          46s
...
```

## 2. Implementation

### 2.1. Exposing deployments

> Note: Ensure that both the `ingress` and `ingress-dns` addons are enabled in minikube. This is done automatically by running the `init.sh` script or `make init`. You can also enable them manually with:
>
> ```sh
> minikube addons enable ingress
> minikube addons enable ingress-dns
> ```

The requirements for this part are:

1. The `invoice-app` must be accessible from outside the cluster.
2. The `payment-provider` must only be accessible from within the cluster.

To meet these requirements, the following setup was implemented:

#### 2.1.1. `invoice-app`

The `invoice-app` Service is defined as type `ClusterIP`, exposing the application internally on port 80 and forwarding requests to port 8081 on the application container. This allows other resources within the cluster to communicate with the service.

To enable external access, an Ingress resource is defined, which is managed by the NGINX Ingress Controller. It routes HTTP traffic for the host `invoice-app.pleo` to the `invoice-app` Service on port 80.

This configuration allows external clients to access the application via a user-friendly DNS name and benefits from standard ingress capabilities such as routing, TLS termination, and access control.

#### 2.1.2. `payment-provider`

The `payment-provider` Service is also defined as type `ClusterIP`, exposing the application on port 8082 within the cluster. Unlike `invoice-app`, no Ingress resource is defined for it.

This ensures the service is not accessible externally and can only be reached by other internal services.

The `invoice-app` communicates with `payment-provider` using the internal DNS name `http://payment-provider:8082`, which resolves to the corresponding ClusterIP service.

### 2.2. Update deployments

The `deployment.yaml` files for both `invoice-app` and `payment-provider` have been updated to follow Kubernetes best practices for production-grade workloads. The main improvements are:

#### 2.2.1. Rollout strategy

A `rollingUpdate` strategy is specified for both deployments, with:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

Rolling updates ensure zero downtime by incrementally replacing old pods with new ones:

- `maxSurge: 1` allows one extra pod above the desired replica count during updates, ensuring capacity is maintained while new pods become ready.
- `maxUnavailable: 0` guarantees that all existing pods remain available during the update, maximizing service availability and minimizing risk of outages.

#### 2.2.2. Resource requests and limits

Kubernetes uses resource requests and limits to manage CPU and memory allocation for containers:

- **Requests** define the minimum amount of CPU or memory required for a container to be scheduled.
- **Limits** define the maximum amount of CPU or memory a container is allowed to use.

These values are specified per container, as shown below:

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

The resource requests and limits are set as follows:

- **Requests** should be set slightly above the container's observed baseline usage to prevent throttling during normal operation.
- **Memory limits** are set equal to requests to ensure predictable memory consumption and prevent out-of-memory (OOM) kills.
- **CPU limits** are intentionally omitted to avoid throttling, which can negatively impact performance, particularly for latency-sensitive workloads.

#### 2.2.3. Liveness and readiness probes

To enhance deployment reliability, both deployments now include HTTP-based liveness and readiness probes targeting the `/healthz` endpoint:

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

These probes help Kubernetes determine the health and readiness of the application containers:

- **Liveness probes** detect and restart stuck containers that cannot recover on their own. They use a higher `failureThreshold` to tolerate transient issues before triggering a restart.
- **Readiness probes** ensure that traffic is only routed to pods that are fully initialized and healthy. They typically fail faster to quickly remove unhealthy pods from service endpoints.
- Both apps expose a `/healthz` endpoint for these probes, implemented as a simple GET route in `main.go`.

### 2.3. Payment provider URL configuration

Previously, the URL for the payment provider in `invoice-app/main.go` was hardcoded, making it inflexible for different environments. This has been improved by reading the URL from the `PAYMENT_PROVIDER_URL` environment variable, with a sensible default fallback if the variable is not set:

```go
paymentProviderURL = os.Getenv("PAYMENT_PROVIDER_URL")
if paymentProviderURL == "" {
	paymentProviderURL = "http://payment-provider:8082/payments/pay"
}
```

This allows the URL to be configured externally (e.g., via Kubernetes manifests or deployment scripts), improving portability and maintainability.
