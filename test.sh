#!/usr/bin/env bash
# test.sh: Test the deployed applications
set -euo pipefail

INVOICE_HOST="invoice-app.pleo"
INVOICE_URL="http://$INVOICE_HOST/invoices"
PAY_URL="http://$INVOICE_HOST/invoices/pay"
MAX_RETRIES=10

# logging functions
info() { echo -e "\033[1;32mINFO:\033[0m $*"; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; }

# ensure required dependencies are installed
require_dependency() {
  local cmd="$1"

  command -v "$cmd" >/dev/null 2>&1 || {
    error "Required command '$cmd' not found. Please install it and try again."
    exit 1
  }
}

# wait for invoice-app to become available
wait_invoice() {
  local url="$1"
  local attempt=1

  until curl --silent --show-error --fail "$url" >/dev/null; do
    if [ $attempt -gt $MAX_RETRIES ]; then
      error "invoice-app did not become available after $MAX_RETRIES attempts."
      exit 1
    fi
    info "Waiting for invoice-app (attempt $attempt/$MAX_RETRIES)..."
    sleep 2
    ((attempt++))
  done

  info "invoice-app is available."
}

# verify initial state: expect at least one unpaid invoice
verify_unpaid_invoices() {
  local url="$1"

  if curl --silent "$url" | jq '.[].IsPaid' | grep -q 'false'; then
    info "Initial verification passed: found unpaid invoices."
  else
    error "Initial verification failed: no unpaid invoices found."
    exit 1
  fi
}

# trigger payment process
trigger_payment() {
  local url="$1"

  curl --silent --fail -X POST "$url" || {
    error "Failed to trigger payment process at $url."
    exit 1
  }
  info "Triggered payment process."
}

# verify all invoices are paid
verify_paid_invoices() {
  local url="$1"

  if curl --silent "$url" | jq '.[].IsPaid' | grep -q 'false'; then
    error "Error: some invoices remain unpaid."
    exit 1
  else
    info "Success: All invoices have been paid."
  fi
}

# main entry point
main() {
  require_dependency curl
  require_dependency jq

  wait_invoice "$INVOICE_URL"
  verify_unpaid_invoices "$INVOICE_URL"
  trigger_payment "$PAY_URL"

  verify_paid_invoices "$INVOICE_URL"
}

main "$@"
