#!/usr/bin/env bash
# =============================================================================
# DEPLOY-WITH-CUSTOM-IMAGES.SH - Deploy with Pre-built Images
# =============================================================================
#
# Deploy OpenClaw + Moltbook using custom pre-built images
#
# Usage:
#   ./deploy-with-custom-images.sh <cluster-domain> \
#     --openclaw-image <image> \
#     --moltbook-image <image>
#
# Example:
#   ./deploy-with-custom-images.sh apps.mycluster.com \
#     --openclaw-image quay.io/myorg/openclaw:v1.0.0 \
#     --moltbook-image quay.io/myorg/moltbook-api:v1.0.0
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
CLUSTER_DOMAIN=""
OPENCLAW_IMAGE=""
MOLTBOOK_IMAGE=""
SKIP_BUILDS="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --openclaw-image)
      OPENCLAW_IMAGE="$2"
      shift 2
      ;;
    --moltbook-image)
      MOLTBOOK_IMAGE="$2"
      shift 2
      ;;
    --skip-builds)
      SKIP_BUILDS="true"
      shift
      ;;
    *)
      if [ -z "$CLUSTER_DOMAIN" ]; then
        CLUSTER_DOMAIN="$1"
        shift
      else
        echo "Unknown argument: $1"
        exit 1
      fi
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}❌ $1${NC}"
}

section() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Check prerequisites
check_prerequisites() {
  section "Checking Prerequisites"

  if ! command -v oc &> /dev/null; then
    log_error "oc CLI not found"
    exit 1
  fi

  if ! oc whoami &> /dev/null; then
    log_error "Not logged into OpenShift. Run 'oc login' first."
    exit 1
  fi

  if [ -z "$CLUSTER_DOMAIN" ]; then
    log_error "Usage: $0 <cluster-domain> --openclaw-image <image> --moltbook-image <image>"
    exit 1
  fi

  if [ -z "$OPENCLAW_IMAGE" ]; then
    log_error "Missing --openclaw-image parameter"
    exit 1
  fi

  if [ -z "$MOLTBOOK_IMAGE" ]; then
    log_error "Missing --moltbook-image parameter"
    exit 1
  fi

  log_success "oc CLI authenticated as: $(oc whoami)"
  log_info "Cluster domain: $CLUSTER_DOMAIN"
  log_info "OpenClaw image: $OPENCLAW_IMAGE"
  log_info "Moltbook image: $MOLTBOOK_IMAGE"
}

# Generate secure tokens
generate_tokens() {
  section "Generating Secure Tokens"

  OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
  MOLTBOOK_JWT_SECRET=$(openssl rand -hex 32)
  MOLTBOOK_ADMIN_KEY="moltbook_admin_$(openssl rand -hex 24)"

  # Generate OAuth secrets
  OPENCLAW_CLIENT_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  OPENCLAW_COOKIE_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  MOLTBOOK_CLIENT_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  MOLTBOOK_COOKIE_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

  log_success "Generated all tokens"
}

# Setup OAuth for a namespace
setup_oauth() {
  local NAMESPACE=$1
  local ROUTE_NAME=$2
  local CLIENT_ID=$3
  local CLIENT_SECRET=$4
  local COOKIE_SECRET=$5

  log_info "Configuring OpenShift OAuth for ${NAMESPACE}..."

  # Get Route host
  local ROUTE_HOST
  ROUTE_HOST=$(oc -n ${NAMESPACE} get route ${ROUTE_NAME} -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -z "$ROUTE_HOST" ]]; then
    log_warn "Route ${ROUTE_NAME} not found in ${NAMESPACE}, skipping OAuth setup"
    return 1
  fi

  log_info "Route host: https://${ROUTE_HOST}"

  # Create/Update cluster-scoped OAuthClient (requires cluster-admin)
  log_info "Creating/Updating OAuthClient '${CLIENT_ID}'..."
  cat > /tmp/${CLIENT_ID}-oauthclient.yaml <<EOF
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: ${CLIENT_ID}
secret: ${CLIENT_SECRET}
redirectURIs:
- https://${ROUTE_HOST}/oauth/callback
grantMethod: auto
EOF

  set +e
  oc apply -f /tmp/${CLIENT_ID}-oauthclient.yaml
  OAUTH_APPLY_RC=$?
  set -e
  rm -f /tmp/${CLIENT_ID}-oauthclient.yaml

  if [[ ${OAUTH_APPLY_RC} -ne 0 ]]; then
    log_warn "Could not create/update cluster-scoped OAuthClient. You likely need cluster-admin."
    log_warn "Ask an admin to run:"
    echo "oc apply -f - <<'EOF'"
    echo "apiVersion: oauth.openshift.io/v1"
    echo "kind: OAuthClient"
    echo "metadata:"
    echo "  name: ${CLIENT_ID}"
    echo "secret: ${CLIENT_SECRET}"
    echo "redirectURIs:"
    echo "- https://${ROUTE_HOST}/oauth/callback"
    echo "grantMethod: auto"
    echo "EOF"
  else
    log_success "OAuthClient configured"
  fi

  # Create/Update the OAuth secret in the namespace
  log_info "Creating/Updating Secret '${NAMESPACE}-oauth-config'..."
  oc -n ${NAMESPACE} create secret generic ${NAMESPACE}-oauth-config \
    --from-literal=client-secret="${CLIENT_SECRET}" \
    --from-literal=cookie_secret="${COOKIE_SECRET}" \
    --dry-run=client -o yaml | oc apply -f -
  log_success "Secret configured"
}

# Deploy OpenClaw with custom image
deploy_openclaw() {
  section "Deploying OpenClaw Gateway (Custom Image)"

  log_info "Creating openclaw namespace..."
  oc new-project openclaw 2>/dev/null || oc project openclaw

  log_info "Deploying OpenTelemetry Collector for openclaw namespace..."
  oc apply -f "$SCRIPT_DIR/../observability/openclaw-otel-collector.yaml"

  log_info "Creating deployment with custom image..."

  # Create modified deployment YAML with custom image
  cat "$SCRIPT_DIR/../manifests/kubernetes/deployment-with-existing-observability.yaml" | \
    sed "s|image: openclaw:latest|image: $OPENCLAW_IMAGE|g" | \
    sed "s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g" | \
    oc apply -f -

  log_info "Setting gateway token..."
  oc patch secret openclaw-secrets -n openclaw -p "{
    \"stringData\": {
      \"OPENCLAW_GATEWAY_TOKEN\": \"$OPENCLAW_GATEWAY_TOKEN\"
    }
  }" 2>/dev/null || {
    # Create secret if it doesn't exist
    oc create secret generic openclaw-secrets -n openclaw \
      --from-literal=OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"
  }

  log_info "Waiting for OpenClaw to be ready..."
  oc rollout status deployment/openclaw-gateway -n openclaw --timeout=10m || {
    log_warn "Rollout taking longer than expected, continuing..."
  }

  # Apply OAuth proxy patch
  log_info "Applying OAuth proxy configuration..."
  oc apply -f "$SCRIPT_DIR/../manifests/kubernetes/openclaw-oauth-patch.yaml"

  # Setup OAuth
  setup_oauth "openclaw" "openclaw-ingress" "openclaw-frontend" "$OPENCLAW_CLIENT_SECRET" "$OPENCLAW_COOKIE_SECRET" || {
    log_warn "OAuth setup completed with warnings. See messages above."
  }

  # Restart deployment to pick up OAuth proxy
  log_info "Restarting deployment to apply OAuth proxy..."
  oc rollout restart deployment/openclaw-gateway -n openclaw
  oc rollout status deployment/openclaw-gateway -n openclaw --timeout=10m || {
    log_warn "Rollout taking longer than expected, continuing..."
  }

  OPENCLAW_URL=$(oc get route openclaw-ingress -n openclaw -o jsonpath='{.spec.host}' 2>/dev/null || echo "openclaw.$CLUSTER_DOMAIN")

  log_success "OpenClaw deployed!"
  log_info "Control UI (OAuth protected): https://$OPENCLAW_URL"
  log_info "Gateway Token: $OPENCLAW_GATEWAY_TOKEN"
}

# Deploy Moltbook with custom image
deploy_moltbook() {
  section "Deploying Moltbook Platform (Custom Image)"

  log_info "Creating moltbook namespace..."
  oc new-project moltbook 2>/dev/null || oc project moltbook

  log_info "Deploying OpenTelemetry Collector for moltbook namespace..."
  oc apply -f "$SCRIPT_DIR/../observability/moltbook-otel-collector.yaml"

  log_info "Deploying with custom image..."

  # Deploy PostgreSQL (OpenShift-compatible)
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: moltbook-postgresql
  namespace: moltbook
type: Opaque
stringData:
  database-name: moltbook
  database-user: moltbook
  database-password: $(openssl rand -hex 16)
---
apiVersion: v1
kind: Service
metadata:
  name: moltbook-postgresql
  namespace: moltbook
spec:
  ports:
  - port: 5432
  selector:
    app: moltbook
    component: postgresql
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: moltbook-postgresql-data
  namespace: moltbook
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moltbook-postgresql
  namespace: moltbook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: moltbook
      component: postgresql
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: moltbook
        component: postgresql
    spec:
      containers:
      - name: postgresql
        image: registry.redhat.io/rhel8/postgresql-16:latest
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRESQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: moltbook-postgresql
              key: database-name
        - name: POSTGRESQL_USER
          valueFrom:
            secretKeyRef:
              name: moltbook-postgresql
              key: database-user
        - name: POSTGRESQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: moltbook-postgresql
              key: database-password
        volumeMounts:
        - name: data
          mountPath: /var/lib/pgsql/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: moltbook-postgresql-data
EOF

  log_info "Waiting for PostgreSQL..."
  oc rollout status deployment/moltbook-postgresql -n moltbook --timeout=5m

  # Deploy Redis
  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: moltbook-redis
  namespace: moltbook
spec:
  ports:
  - port: 6379
  selector:
    app: moltbook
    component: redis
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moltbook-redis
  namespace: moltbook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: moltbook
      component: redis
  template:
    metadata:
      labels:
        app: moltbook
        component: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        command: ["redis-server", "--appendonly", "yes", "--dir", "/tmp"]
        ports:
        - containerPort: 6379
EOF

  # Deploy Moltbook API with custom image
  DB_PASS=$(oc get secret moltbook-postgresql -n moltbook -o jsonpath='{.data.database-password}' | base64 -d)

  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: moltbook-api-secrets
  namespace: moltbook
type: Opaque
stringData:
  JWT_SECRET: $MOLTBOOK_JWT_SECRET
  ADMIN_API_KEY: $MOLTBOOK_ADMIN_KEY
  DATABASE_URL: "postgresql://moltbook:$DB_PASS@moltbook-postgresql:5432/moltbook"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moltbook-api
  namespace: moltbook
spec:
  replicas: 2
  selector:
    matchLabels:
      app: moltbook
      component: api
  template:
    metadata:
      labels:
        app: moltbook
        component: api
    spec:
      containers:
      - name: api
        image: $MOLTBOOK_IMAGE
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        env:
        - name: NODE_ENV
          value: production
        - name: PORT
          value: "3000"
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: moltbook-api-secrets
              key: DATABASE_URL
        - name: REDIS_URL
          value: "redis://moltbook-redis:6379"
        - name: JWT_SECRET
          valueFrom:
            secretKeyRef:
              name: moltbook-api-secrets
              key: JWT_SECRET
        # OpenTelemetry configuration
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector.moltbook.svc.cluster.local:4318"
        - name: OTEL_SERVICE_NAME
          value: "moltbook-api"
        - name: OTEL_TRACES_SAMPLER
          value: "always_on"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
---
apiVersion: v1
kind: Service
metadata:
  name: moltbook-api
  namespace: moltbook
spec:
  ports:
  - port: 3000
  selector:
    app: moltbook
    component: api
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: moltbook-api
  namespace: moltbook
spec:
  host: moltbook-api.$CLUSTER_DOMAIN
  to:
    kind: Service
    name: moltbook-api
  port:
    targetPort: 3000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

  log_info "Waiting for Moltbook API..."
  oc rollout status deployment/moltbook-api -n moltbook --timeout=10m

  # Note: OAuth proxy for Moltbook is configured for frontend deployment
  # The API route remains unprotected for agent access
  # Frontend deployment would be added separately if needed

  MOLTBOOK_API_URL="https://moltbook-api.$CLUSTER_DOMAIN"
  MOLTBOOK_URL="https://moltbook.$CLUSTER_DOMAIN"

  log_success "Moltbook deployed!"
  log_info "API (unprotected, for agents): $MOLTBOOK_API_URL"
  log_info "Admin Key: $MOLTBOOK_ADMIN_KEY"
}

# Display summary
display_summary() {
  section "🎉 Deployment Complete!"

  OPENCLAW_URL=$(oc get route openclaw-ingress -n openclaw -o jsonpath='{.spec.host}' 2>/dev/null || echo "openclaw.$CLUSTER_DOMAIN")
  MOLTBOOK_API_URL=$(oc get route moltbook-api -n moltbook -o jsonpath='{.spec.host}' 2>/dev/null || echo "moltbook-api.$CLUSTER_DOMAIN")
  MOLTBOOK_URL="moltbook.$CLUSTER_DOMAIN"

  echo ""
  echo -e "${GREEN}Your AI Agent Social Network is deployed!${NC}"
  echo ""
  echo -e "${BLUE}OpenClaw Gateway (OAuth Protected):${NC}"
  echo "  • Control UI: https://$OPENCLAW_URL"
  echo "  • Authentication: OpenShift OAuth (automatic)"
  echo "  • Gateway Token: $OPENCLAW_GATEWAY_TOKEN"
  echo "  • Image: $OPENCLAW_IMAGE"
  echo ""
  echo -e "${BLUE}Moltbook Platform:${NC}"
  echo "  • API (unprotected, for agents): https://$MOLTBOOK_API_URL"
  echo "  • Admin Key: $MOLTBOOK_ADMIN_KEY"
  echo "  • API Image: $MOLTBOOK_IMAGE"
  echo ""
  echo -e "${BLUE}Authentication:${NC}"
  echo "  • OpenClaw Control UI uses OpenShift OAuth"
  echo "  • You will be redirected to OpenShift login when accessing"
  echo "  • Moltbook API remains unprotected for agent access"
  echo ""
  echo -e "${YELLOW}Next Steps:${NC}"
  echo "  1. Access OpenClaw: open https://$OPENCLAW_URL"
  echo "     (You'll be prompted to log in with OpenShift credentials)"
  echo "  2. Create agents in OpenClaw"
  echo "  3. Agents can register on Moltbook API: https://$MOLTBOOK_API_URL"
  echo ""

  # Save credentials
  cat > /tmp/deployment-credentials.txt << EOF
=== Deployment Credentials ===
Generated: $(date)

OpenClaw:
- URL: https://$OPENCLAW_URL
- Token: $OPENCLAW_GATEWAY_TOKEN
- Image: $OPENCLAW_IMAGE

Moltbook:
- API: https://$MOLTBOOK_API_URL
- Frontend: https://$MOLTBOOK_URL
- Admin Key: $MOLTBOOK_ADMIN_KEY
- API Image: $MOLTBOOK_IMAGE

PostgreSQL Password: (see secret moltbook-postgresql)
EOF

  log_success "Credentials saved to: /tmp/deployment-credentials.txt"
}

# Main
main() {
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   🦞 Deploy with Custom Images 🦞                         ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  check_prerequisites
  generate_tokens
  deploy_openclaw
  deploy_moltbook
  display_summary

  echo -e "${GREEN}All done! 🚀${NC}"
}

main "$@"
