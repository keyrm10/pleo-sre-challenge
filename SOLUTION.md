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

