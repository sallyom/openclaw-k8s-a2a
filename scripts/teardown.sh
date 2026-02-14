#!/usr/bin/env bash
# ============================================================================
# TEARDOWN SCRIPT
# ============================================================================
# Removes OpenClaw + Moltbook deployments and namespaces.
#
# Usage:
#   ./teardown.sh                    # Teardown OpenShift (default)
#   ./teardown.sh --k8s              # Teardown vanilla Kubernetes
#   ./teardown.sh --openclaw-only    # Only teardown OpenClaw namespace
#   ./teardown.sh --moltbook-only    # Only teardown Moltbook namespace
#   ./teardown.sh --delete-env       # Also delete .env file
#
# This script:
#   - Reads .env for namespace and prefix configuration
#   - Deletes all resources in namespaces before deleting namespaces
#     (avoids finalizer hang during namespace deletion)
#   - Removes cluster-scoped OAuthClients (OpenShift only)
#   - Strips finalizers from stuck namespaces
#   - Optionally deletes .env
#
# If .env doesn't exist, you can set OPENCLAW_NAMESPACE manually:
#   OPENCLAW_NAMESPACE=my-openclaw ./teardown.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
OPENCLAW_ONLY=false
MOLTBOOK_ONLY=false
DELETE_ENV=false
for arg in "$@"; do
  case "$arg" in
    --k8s) K8S_MODE=true ;;
    --openclaw-only) OPENCLAW_ONLY=true ;;
    --moltbook-only) MOLTBOOK_ONLY=true ;;
    --delete-env) DELETE_ENV=true ;;
  esac
done

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="oc"
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw + Moltbook Teardown                              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load .env if available
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

# Determine namespace — env var takes precedence, then .env, then prompt
if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  log_warn "No .env file and OPENCLAW_NAMESPACE not set."
  read -p "  Enter OpenClaw namespace to teardown (e.g., sallyom-openclaw): " OPENCLAW_NAMESPACE
  if [ -z "$OPENCLAW_NAMESPACE" ]; then
    log_error "Namespace is required."
    exit 1
  fi
fi

# Build list of namespaces to delete
TEARDOWN_OPENCLAW=true
TEARDOWN_MOLTBOOK=true
if $OPENCLAW_ONLY; then
  TEARDOWN_MOLTBOOK=false
fi
if $MOLTBOOK_ONLY; then
  TEARDOWN_OPENCLAW=false
fi

echo "Namespaces to teardown:"
if $TEARDOWN_OPENCLAW; then echo "  - $OPENCLAW_NAMESPACE"; fi
if $TEARDOWN_MOLTBOOK; then echo "  - moltbook"; fi
echo ""

read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Teardown cancelled"
  exit 0
fi
echo ""

# Delete all resources in a namespace before deleting the namespace itself.
# This avoids the common issue where namespace deletion hangs on finalizers.
teardown_namespace() {
  local ns="$1"

  if ! $KUBECTL get namespace "$ns" &>/dev/null; then
    log_warn "Namespace $ns does not exist — skipping"
    return 0
  fi

  log_info "Deleting resources in $ns..."

  # Workloads and services (oc delete all covers deployments, replicasets,
  # pods, services, daemonsets, statefulsets, replicationcontrollers, buildconfigs, builds, imagestreams)
  $KUBECTL delete all --all -n "$ns" --timeout=60s 2>/dev/null || true

  # Jobs (not included in 'all')
  $KUBECTL delete jobs --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete cronjobs --all -n "$ns" --timeout=30s 2>/dev/null || true

  # Config and secrets
  $KUBECTL delete configmaps --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete secrets --all -n "$ns" --timeout=30s 2>/dev/null || true

  # RBAC
  $KUBECTL delete serviceaccounts --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete roles --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete rolebindings --all -n "$ns" --timeout=30s 2>/dev/null || true

  # Storage
  $KUBECTL delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

  # Security / availability
  $KUBECTL delete networkpolicies --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete poddisruptionbudgets --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete resourcequotas --all -n "$ns" --timeout=30s 2>/dev/null || true

  # OpenShift-specific
  if ! $K8S_MODE; then
    $KUBECTL delete routes --all -n "$ns" --timeout=30s 2>/dev/null || true
  fi

  log_success "Resources deleted from $ns"

  # Delete the namespace
  log_info "Deleting namespace $ns..."
  if $KUBECTL delete namespace "$ns" --timeout=60s 2>/dev/null; then
    log_success "Namespace $ns deleted"
  else
    log_warn "Namespace deletion timed out — removing finalizers..."
    $KUBECTL get namespace "$ns" -o json | \
      jq '.spec.finalizers = []' | \
      $KUBECTL replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
    # Wait briefly for it to disappear
    sleep 3
    if $KUBECTL get namespace "$ns" &>/dev/null; then
      log_error "Namespace $ns still exists. May need manual cleanup."
    else
      log_success "Namespace $ns deleted (finalizers stripped)"
    fi
  fi
  echo ""
}

# Teardown OpenClaw
if $TEARDOWN_OPENCLAW; then
  # Remove cluster-scoped OAuthClient (OpenShift only)
  if ! $K8S_MODE; then
    log_info "Removing OpenClaw OAuthClient..."
    $KUBECTL delete oauthclient "$OPENCLAW_NAMESPACE" 2>/dev/null && \
      log_success "OAuthClient $OPENCLAW_NAMESPACE deleted" || \
      log_warn "OAuthClient $OPENCLAW_NAMESPACE not found (already removed)"
    echo ""
  fi

  teardown_namespace "$OPENCLAW_NAMESPACE"
fi

# Teardown Moltbook
if $TEARDOWN_MOLTBOOK; then
  if ! $K8S_MODE; then
    log_info "Removing Moltbook OAuthClient..."
    $KUBECTL delete oauthclient moltbook-frontend 2>/dev/null && \
      log_success "OAuthClient moltbook-frontend deleted" || \
      log_warn "OAuthClient moltbook-frontend not found (already removed)"
    echo ""
  fi

  teardown_namespace "moltbook"
fi

# Optionally delete .env
if $DELETE_ENV && [ -f "$REPO_ROOT/.env" ]; then
  rm "$REPO_ROOT/.env"
  log_success "Deleted .env"
  echo ""
elif [ -f "$REPO_ROOT/.env" ]; then
  log_info ".env kept (use --delete-env to remove)"
  echo ""
fi

# Clean up generated YAML files (from envsubst)
log_info "Cleaning up generated YAML files..."
generated=0
for tpl in $(find "$REPO_ROOT/manifests" "$REPO_ROOT/observability" -name '*.envsubst' 2>/dev/null); do
  yaml="${tpl%.envsubst}"
  if [ -f "$yaml" ]; then
    rm "$yaml"
    generated=$((generated + 1))
  fi
done
if [ $generated -gt 0 ]; then
  log_success "Removed $generated generated YAML files"
else
  log_info "No generated YAML files to clean up"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Teardown Complete                                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "To redeploy, run: ./scripts/setup.sh$(if $K8S_MODE; then echo ' --k8s'; fi)"
echo ""
