#!/usr/bin/env bash
# ============================================================================
# EXPORT LIVE CONFIG
# ============================================================================
# Exports the running OpenClaw config from the gateway pod to a local file.
# Use this to capture UI changes before updating manifests for redeployment.
#
# Usage:
#   ./scripts/export-config.sh                     # OpenShift (default)
#   ./scripts/export-config.sh --k8s               # Vanilla Kubernetes
#   ./scripts/export-config.sh -o myconfig.json    # Custom output file
#
# Output: openclaw-config-export.json (or specified file)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
K8S_MODE=false
OUTPUT_FILE=""

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --k8s) K8S_MODE=true ;;
    -o) shift_next=true ;;
    *)
      if [ "${shift_next:-}" = "true" ]; then
        OUTPUT_FILE="$arg"
        shift_next=false
      fi
      ;;
  esac
done

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="oc"
fi

# Load .env
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  echo "ERROR: OPENCLAW_NAMESPACE not set. Run setup.sh first or set it manually."
  exit 1
fi

OUTPUT_FILE="${OUTPUT_FILE:-$REPO_ROOT/openclaw-config-export.json}"

echo "Exporting live config from $OPENCLAW_NAMESPACE..."

$KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  cat /home/node/.openclaw/openclaw.json > "$OUTPUT_FILE"

echo "Exported to: $OUTPUT_FILE"
echo ""
echo "To diff against current manifest:"
echo "  diff <(python3 -m json.tool $OUTPUT_FILE) <(python3 -m json.tool manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst 2>/dev/null || echo 'n/a')"
echo ""
echo "To update the overlay config-patch, copy the relevant sections"
echo "from the export into the .envsubst template, replacing concrete"
echo "values with \${VAR} placeholders where needed."
