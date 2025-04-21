#!/usr/bin/env bash
# deploy.sh: Deploy Kubernetes manifests
set -euo pipefail

declare -A APPS_DIR=(
  [invoice-app]="./invoice-app"
  [payment-provider]="./payment-provider"
)
declare -A APPS_IMAGES=(
  [invoice-app]="invoice-app:latest"
  [payment-provider]="payment-provider:latest"
)

# logging functions
info() { echo -e "\033[1;32mINFO:\033[0m $*"; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; }

# ensure minikube is running
check_minikube() {
  if ! minikube status --format "{{.Host}}" 2>/dev/null | grep -qw "Running"; then
    error "Minikube is not running. Starting via init.sh..."
    ./init.sh
  else
    info "Minikube is already running."
  fi
}

check_image() {
  local app="$1"
  local image="${APPS_IMAGES[$app]}"
  local dir="${APPS_DIR[$app]}"

  if minikube image ls | grep -qw "docker.io/library/$image"; then
    info "$image already exists; skipping build."
  else
    info "Building $image image..."
    minikube image build -t "$image" "$dir"
  fi
}

# deploy applications
deploy_manifests() {
  local app="$1"
  local app_dir="${APPS_DIR[$app]}"

  info "Applying manifests from directory '$app_dir'..."
  kubectl apply -f "$app_dir"
}

wait_rollout() {
  local app="$1"

  info "Waiting for deployment of $app to complete..."
  if ! kubectl rollout status deployment/"$app" --timeout=60s; then
    error "Deployment of $app failed."
    exit 1
  fi

  info "Deployment of $app was successful."
}

main() {
  check_minikube

  for app in "${!APPS_DIR[@]}"; do
    check_image "$app"
    deploy_manifests "$app"
    wait_rollout "$app"
  done
}

main "$@"
