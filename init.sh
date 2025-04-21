#!/usr/bin/env bash
# init.sh: Install and starts minikube on Linux/macOS (sorry, Windows users)
set -euo pipefail

MINIKUBE_VERSION="v1.35.0"
DRIVER="docker"
RUNTIME="containerd"
ADDONS=("ingress" "ingress-dns" "metrics-server")
INSTALL_PATH="/usr/local/bin/minikube"

# logging functions
info() { echo -e "\033[1;32mINFO:\033[0m $*"; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; }

# detect platform (linux|darwin) and architecture (amd64|arm64)
detect_platform_arch() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux) PLATFORM="linux" ;;
    Darwin) PLATFORM="darwin" ;;
    *) error "Unsupported OS: $os"; exit 1 ;;
  esac

  case "$arch" in
    x86_64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $arch"; exit 1 ;;
  esac
}

# download and install minikube binary
download_minikube() {
  local url tmpfile
  url="https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-${PLATFORM}-${ARCH}"
  tmpfile="$(mktemp)"
  info "Downloading minikube..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmpfile" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmpfile" "$url"
  else
    error "Neither curl nor wget is installed"
    exit 1
  fi

  sudo install -m 0755 "$tmpfile" "$INSTALL_PATH"
  rm -f "$tmpfile"
  info "Installed minikube to $INSTALL_PATH"
}

# build container images
build_image() {
  local image_name="$1"
  local app_dir="$2"
  info "Building image $image_name..."
  minikube image build -t "$image_name" "$app_dir"
}

# start minikube cluster with the specified driver, runtime, and addons
start_minikube() {
  info "Starting minikube cluster..."
  minikube start \
    --driver="$DRIVER" \
    --container-runtime="$RUNTIME" \
    --addons="$(IFS=,; echo "${ADDONS[*]}")"

  info "\nminikube cluster status:"
  minikube status
  info "minikube cluster is ready!"
}

# main entry point
main() {
  if command -v minikube >/dev/null 2>&1; then
    info "minikube is already installed. Skipping installation."
  else
    detect_platform_arch
    download_minikube
  fi

  start_minikube

  # build images after minikube is started
  build_image invoice-app:latest ./invoice-app
  build_image payment-provider:latest ./payment-provider
}

main "$@"
