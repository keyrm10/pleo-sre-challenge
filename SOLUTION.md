# Solution

## 0. Setup

### 0.1. Branching strategy

The GitHub Flow branching model was chosen for its simplicity (feature branch → PR → main) and effectiveness for small teams and iterative development. All work for this challenge was organized into atomic commits on a single feature branch: `feature/sre-challenge-solution`.

### 0.2. Kubernetes local cluster setup

All steps are automated for reproducibility and minimal manual intervention.

The [`init.sh`](./init.sh) script automates the installation and startup of minikube. It detects the OS and architecture, downloads the appropriate minikube binary, and installs it if missing.

Minikube is started with the Docker driver and the `containerd` runtime, as the Docker runtime has been deprecated in Kubernetes since v1.24.

Additionally, a `Makefile` is provided to streamline this process. By using `make`, you can automate the setup with predefined targets, ensuring consistency and ease of use. Run `make help` for a list of available commands.

#### 0.2.1. Prerequisites

Ensure the following tools are installed on your system:

- [Docker](https://docs.docker.com/engine/install/) (or a compatible container engine)
- [bash](https://www.gnu.org/software/bash/)
- [make](https://www.gnu.org/software/make/)
- [curl](https://curl.se/docs/install.html) or [wget](https://www.gnu.org/software/wget/)
- \* [kubectl](https://kubernetes.io/docs/tasks/tools/) (optional, as minikube provides its own version)

> \* If `kubectl` is not installed locally, you can use minikube's bundled version:
>
> ```sh
> minikube kubectl -- <kubectl commands>
> ```

#### 0.2.2. Makefile targets

The `Makefile` provides the following targets:

- **help**: Display available targets and their descriptions.

  ```sh
  make help
  ```

- **init**: Install and start the Kubernetes cluster with required addons.

  ```sh
  make init
  ```

- **deploy**: Deploy the application using the `deploy.sh` script.

  ```sh
  make deploy
  ```

- **clean**: Delete the minikube cluster and clean up resources.

  ```sh
  make clean
  ```

- **all**: Run both `init` and `deploy` targets.

  ```sh
  make all
  ```

#### 0.2.3. Networking

Using ingress in minikube typically requires DNS resolution for custom domains, which often means manually editing `/etc/hosts`. This can lead to clutter and maintenance issues.

The `ingress` and `ingress-dns` addons are enabled to simplify service exposure and DNS resolution within the cluster.

The `ingress-dns` addon runs a DNS server inside the cluster that maps ingress hostnames to the minikube IP. By configuring your host to use the minikube IP as a DNS server, services are resolved automatically, eliminating the need to edit `/etc/hosts`.

##### DNS configuration on macOS

On macOS, DNS resolution for custom domains can be configured by adding a resolver:

```sh
sudo tee /etc/resolver/minikube-test <<EOF
domain test
nameserver $(minikube ip)
search_order 1
timeout 5
EOF
```

## 0.3. Container registry

Before deploying the applications, we first need to build the container images and push them to a container registry that is accessible from the Kubernetes cluster.

We can either deploy a local registry (e.g., [registry:2](https://hub.docker.com/_/registry)) or use a public container registry (e.g., Docker Hub, GCR). Additionally, the minikube documentation offers several methods for [pushing images](https://minikube.sigs.k8s.io/docs/handbook/pushing/) to the minikube cluster.

To keep things simple, we can use the `minikube image build` command. This command builds the image using the Docker daemon inside the minikube VM, making it immediately accessible to the Kubernetes cluster:

```sh
minikube image build -t "${IMAGE_NAME}" "${PATH_TO_DOCKERFILE}"
```

## 1. Debugging

### 1.1. payment-provider build error

During the build process of the `payment-provider` image, the build fails and returns error messages like the following:

```sh
/go/pkg/mod/github.com/gin-gonic/gin@v1.9.1/gin.go:20:2: missing go.sum entry for module providing package golang.org/x/net/http2 (imported by github.com/gin-gonic/gin)
```

```sh
error: failed to solve: process "/bin/sh -c go build -o app ." did not complete successfully: exit code: 1
```

These errors occurs because, during the build process inside the container, Go attemps to verifiy the integrity of dependencies listed in the `go.sum` file. If any required entries are missing, the build fails.

To resolve this, we need to ensure that all dependencies are properly downloaded before the application is built. This can be done by adding the following instructions to the Dockerfile:

```dockerfile
RUN go mod download -x
RUN go mod tidy -v
```

The `go mod download -x` command downloads all dependencies specified in the `go.mod` file and updates the `go.sum` file with the necessary entries. The `go mod tidy -v` command ensures that the module dependencies are cleaned up and consistent, removing any unused dependencies.

I've included these instructions in both Dockerfiles. While this resolves the immediate issue, there are further improvements that could be made to optimise the process. These enhancements are addresses in later sections.

### 1.2. Rootless containers

After applying the manifests, I noticed the following status errors:

```sh
NAME                                READY   STATUS                       RESTARTS   AGE
invoice-app-f864dc848-42cgq         0/1     CreateContainerConfigError   0          15s
invoice-app-f864dc848-bs69f         0/1     CreateContainerConfigError   0          15s
invoice-app-f864dc848-jc2sp         0/1     CreateContainerConfigError   0          15s
payment-provider-699d59df56-bm2ph   0/1     CreateContainerConfigError   0          7s
payment-provider-699d59df56-kvl4d   0/1     CreateContainerConfigError   0          7s
payment-provider-699d59df56-qwv9l   0/1     CreateContainerConfigError   0          7s
```

The `kubectl describe pods` output revealed this error: `Error: container has runAsNonRoot and image will run as root`.

Both deployments are configured with `securityContext.runAsNonRoot: true`, which enforces that containers run as non-root users. This is a good security practice, but the Dockerfiles for these containers do not define a user, so the applications run as root by default. This leads to a conflict with the Kubernetes security context.

To fix this issue, specify a non-root user in the Dockerfile using the `USER` instruction, or use a pre-configured non-root image, such as one of the [distroless](https://github.com/GoogleContainerTools/distroless) images with the `nonroot` tag.

After updating the Dockerfiles, we need to rebuild the images. If you reuse the same tag (`invoice-app:latest` , `payment-provider:latest`), Kubernetes may treat them as unchanged.

> Note: Avoid using the `latest` tag in production. Instead, use immutable tags (e.g., 1.0) to ensure predictable and consistent versioning.

Since the Deployment's image pull policy is `IfNotPresent`, updated images won't be pulled unless you delete the pods, change the tag, or restart the pods manually. To force a deployment update, run:

```sh
kubectl rollout restart deployment invoice-app payment-provider
```

This restarts the deployments and pulls the updated images. After a few seconds, the pods will be running:

```sh
kubectl get pods
NAME                                READY   STATUS    RESTARTS   AGE
invoice-app-f864dc848-42vv7         1/1     Running   0          46s
invoice-app-f864dc848-bsngx         1/1     Running   0          46s
invoice-app-f864dc848-dhdwd         1/1     Running   0          46s
payment-provider-699d59df56-mwwhl   1/1     Running   0          43s
payment-provider-699d59df56-pwzzd   1/1     Running   0          43s
payment-provider-699d59df56-vnhqc   1/1     Running   0          43s
```
