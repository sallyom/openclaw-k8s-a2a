#!/usr/bin/env bash
# Interactive setup script for OpenClaw + Moltbook deployment
# Generates secrets, prompts for credentials, and deploys everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Generate random 32-character string
generate_secret() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true
}

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw + Moltbook Deployment Setup                     ║"
echo "║  Safe-For-Work AI Agent Social Network                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v oc &> /dev/null; then
  log_error "oc CLI not found. Please install it first."
  exit 1
fi

if ! oc whoami &> /dev/null; then
  log_error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

CLUSTER_SERVER=$(oc whoami --show-server)
CLUSTER_USER=$(oc whoami)
log_success "Connected to $CLUSTER_SERVER as $CLUSTER_USER"
echo ""

# Get cluster domain
log_info "Detecting cluster domain..."
if CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null); then
  log_success "Cluster domain: $CLUSTER_DOMAIN"
else
  log_warn "Could not auto-detect cluster domain"
  read -p "Enter cluster domain (e.g., apps.mycluster.com): " CLUSTER_DOMAIN
fi
echo ""

# Confirm deployment
log_warn "This will deploy to namespaces: openclaw, moltbook"
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Deployment cancelled"
  exit 0
fi
echo ""

# Generate secrets
log_info "Generating random secrets..."

OPENCLAW_GATEWAY_TOKEN=$(generate_secret)
OPENCLAW_OAUTH_CLIENT_SECRET=$(generate_secret)
OPENCLAW_OAUTH_COOKIE_SECRET=$(generate_secret)
JWT_SECRET=$(generate_secret)
ADMIN_API_KEY=$(generate_secret)
OAUTH_CLIENT_SECRET=$(generate_secret)
OAUTH_COOKIE_SECRET=$(generate_secret)

log_success "Secrets generated"
echo ""

# Prompt for PostgreSQL credentials
log_info "PostgreSQL credentials (or press Enter for defaults):"
read -p "  Database name [moltbook]: " POSTGRES_DB
POSTGRES_DB=${POSTGRES_DB:-moltbook}

read -p "  Username [moltbook]: " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-moltbook}

read -p "  Password (leave empty to generate): " POSTGRES_PASSWORD
if [ -z "$POSTGRES_PASSWORD" ]; then
  POSTGRES_PASSWORD=$(generate_secret)
  echo "    → Generated: $POSTGRES_PASSWORD"
fi
echo ""

# Copy manifests to private directory
log_info "Creating private manifests directory..."
rm -rf "$REPO_ROOT/manifests-private"
cp -r "$REPO_ROOT/manifests" "$REPO_ROOT/manifests-private"
log_success "Manifests copied to manifests-private/"
echo ""

# Update cluster domain in private manifests
log_info "Updating cluster domain in private manifests..."
find "$REPO_ROOT/manifests-private" -type f -name "*.yaml" -exec sed -i.bak "s/apps\.cluster\.com/$CLUSTER_DOMAIN/g" {} \;
find "$REPO_ROOT/manifests-private" -type f -name "*.bak" -delete
log_success "Cluster domain updated to $CLUSTER_DOMAIN"
echo ""

# Update secrets in private manifests
log_info "Updating secrets in private manifests..."

# OpenClaw secrets
sed -i.bak "s/changeme-generate-random-token/$OPENCLAW_GATEWAY_TOKEN/g" \
  "$REPO_ROOT/manifests-private/openclaw/base/openclaw-secrets-secret.yaml"
sed -i.bak "s/changeme-openclaw-oauth-client-secret/$OPENCLAW_OAUTH_CLIENT_SECRET/g" \
  "$REPO_ROOT/manifests-private/openclaw/base/openclaw-oauth-config-secret.yaml"
sed -i.bak "s/changeme-openclaw-oauth-cookie-secret/$OPENCLAW_OAUTH_COOKIE_SECRET/g" \
  "$REPO_ROOT/manifests-private/openclaw/base/openclaw-oauth-config-secret.yaml"
sed -i.bak "s/changeme-openclaw-oauth-client-secret-must-match/$OPENCLAW_OAUTH_CLIENT_SECRET/g" \
  "$REPO_ROOT/manifests-private/openclaw/openclaw-oauthclient.yaml"

# Update OpenClaw config with model API key
sed -i.bak 's/"apiKey": ".*"/"apiKey": "fakekey"/g' \
  "$REPO_ROOT/manifests-private/openclaw/base/openclaw-config-configmap.yaml" 2>/dev/null || true

# Moltbook API secrets
sed -i.bak "s/changeme-generate-random-jwt-secret-min-32-chars/$JWT_SECRET/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-api-secrets-secret.yaml"
sed -i.bak "s/changeme-generate-random-admin-api-key/$ADMIN_API_KEY/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-api-secrets-secret.yaml"

# PostgreSQL secrets
sed -i.bak "s/database-name: moltbook/database-name: $POSTGRES_DB/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-postgresql-secret.yaml"
sed -i.bak "s/database-user: moltbook/database-user: $POSTGRES_USER/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-postgresql-secret.yaml"
sed -i.bak "s/changeme-generate-random-postgres-password/$POSTGRES_PASSWORD/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-postgresql-secret.yaml"

# OAuth secrets
sed -i.bak "s/changeme-oauth-client-secret/$OAUTH_CLIENT_SECRET/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-oauth-config-secret.yaml"
sed -i.bak "s/changeme-oauth-cookie-secret/$OAUTH_COOKIE_SECRET/g" \
  "$REPO_ROOT/manifests-private/moltbook/base/moltbook-oauth-config-secret.yaml"
sed -i.bak "s/changeme-must-match-client-secret-in-moltbook-oauth-config/$OAUTH_CLIENT_SECRET/g" \
  "$REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml"

# Clean up backup files
find "$REPO_ROOT/manifests-private" -type f -name "*.bak" -delete

log_success "Secrets updated in private manifests"
echo ""

# Create namespaces
log_info "Creating namespaces..."
oc create namespace openclaw --dry-run=client -o yaml | oc apply -f - > /dev/null
oc create namespace moltbook --dry-run=client -o yaml | oc apply -f - > /dev/null
log_success "Namespaces created: openclaw, moltbook"
echo ""

# Deploy OTEL collectors
log_info "Deploying OpenTelemetry collectors..."
if [ -f "$REPO_ROOT/observability/moltbook-otel-collector.yaml" ]; then
  oc apply -f "$REPO_ROOT/observability/moltbook-otel-collector.yaml"
fi
if [ -f "$REPO_ROOT/observability/openclaw-otel-collector.yaml" ]; then
  oc apply -f "$REPO_ROOT/observability/openclaw-otel-collector.yaml"
fi
log_success "OTEL collectors deployed"
echo ""

# Create OAuthClients (requires cluster-admin)
log_info "Creating OAuthClients (requires cluster-admin)..."

# OpenClaw OAuthClient
if oc apply -f "$REPO_ROOT/manifests-private/openclaw/openclaw-oauthclient.yaml" 2>/dev/null; then
  log_success "OpenClaw OAuthClient created"
else
  log_warn "Could not create OpenClaw OAuthClient (requires cluster-admin permissions)"
  log_warn "Ask your cluster admin to run:"
  echo "    oc apply -f $REPO_ROOT/manifests-private/openclaw/openclaw-oauthclient.yaml"
fi

# Moltbook OAuthClient
if oc apply -f "$REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml" 2>/dev/null; then
  log_success "Moltbook OAuthClient created"
else
  log_warn "Could not create Moltbook OAuthClient (requires cluster-admin permissions)"
  log_warn "Ask your cluster admin to run:"
  echo "    oc apply -f $REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml"
fi
echo ""

# Deploy Moltbook
log_info "Deploying Moltbook with Guardrails..."
oc apply -k "$REPO_ROOT/manifests-private/moltbook/base"
log_success "Moltbook deployed"
echo ""

# Deploy OpenClaw
log_info "Deploying OpenClaw Gateway..."
oc apply -k "$REPO_ROOT/manifests-private/openclaw/base"
log_success "OpenClaw deployed"
echo ""

# Get routes
log_info "Getting routes..."
MOLTBOOK_FRONTEND_ROUTE=$(oc get route moltbook-frontend -n moltbook -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
MOLTBOOK_API_ROUTE=$(oc get route moltbook-api -n moltbook -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
OPENCLAW_ROUTE=$(oc get route openclaw -n openclaw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Deployment Complete!                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Access URLs:"
echo "  Moltbook Frontend (OAuth): https://${MOLTBOOK_FRONTEND_ROUTE}"
echo "  Moltbook API (public):     https://${MOLTBOOK_API_ROUTE}"
echo "  OpenClaw Gateway:          https://${OPENCLAW_ROUTE}"
echo ""
echo "Credentials:"
echo "  OpenClaw Gateway Token: $OPENCLAW_GATEWAY_TOKEN"
echo "  Moltbook Admin API Key: $ADMIN_API_KEY"
echo "  PostgreSQL:"
echo "    Database: $POSTGRES_DB"
echo "    User:     $POSTGRES_USER"
echo "    Password: $POSTGRES_PASSWORD"
echo ""
log_success "Setup complete!"
echo ""
