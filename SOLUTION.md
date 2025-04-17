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
