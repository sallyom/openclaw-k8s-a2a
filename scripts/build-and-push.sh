#!/usr/bin/env bash
# =============================================================================
# BUILD-AND-PUSH.SH - Build OpenClaw + Moltbook with Podman
# =============================================================================
#
# Builds images on x86 machine using podman, then pushes to registry
#
# Usage:
#   ./build-and-push.sh <registry-url> [openclaw-tag] [moltbook-tag]
#
# Examples:
#   ./build-and-push.sh quay.io/myorg
#   ./build-and-push.sh registry.example.com:5000/myproject
#   ./build-and-push.sh quay.io/myorg openclaw:v1.0.0 moltbook-api:v1.0.0
#
# =============================================================================

set -euo pipefail

REGISTRY="${1:-}"
OPENCLAW_TAG="${2:-openclaw:latest}"
MOLTBOOK_TAG="${3:-moltbook-api:latest}"

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

  if [ -z "$REGISTRY" ]; then
    log_error "Usage: $0 <registry-url> [openclaw-tag] [moltbook-tag]"
    log_info "Example: $0 quay.io/myorg"
    exit 1
  fi

  if ! command -v podman &> /dev/null; then
    log_error "podman not found. Install with: sudo dnf install podman"
    exit 1
  fi

  if ! command -v git &> /dev/null; then
    log_error "git not found. Install with: sudo dnf install git"
    exit 1
  fi

  log_success "podman found: $(podman --version)"
  log_success "git found: $(git --version)"
  log_info "Registry: $REGISTRY"
  log_info "OpenClaw tag: $OPENCLAW_TAG"
  log_info "Moltbook tag: $MOLTBOOK_TAG"
}

# Build OpenClaw
build_openclaw() {
  section "Building OpenClaw"

  OPENCLAW_DIR="$(pwd)"

  if [ ! -f "$OPENCLAW_DIR/package.json" ]; then
    log_error "Not in openclaw directory. package.json not found."
    exit 1
  fi

  log_info "Building OpenClaw image..."

  # Fix Dockerfile for OpenShift (no root, arbitrary UID)
  cat > Dockerfile.openshift << 'EOF'
FROM node:22-bookworm

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# OpenShift compatibility: chmod for arbitrary UID
RUN chmod -R 777 /app && \
    mkdir -p /home/node && \
    chmod -R 777 /home/node

# Non-root user (OpenShift will override UID)
USER 1001

CMD ["node", "dist/index.js"]
EOF

  podman build \
    -f Dockerfile.openshift \
    -t "$OPENCLAW_TAG" \
    --platform linux/amd64 \
    .

  log_success "OpenClaw built: $OPENCLAW_TAG"
}

# Build Moltbook API
build_moltbook() {
  section "Building Moltbook API"

  MOLTBOOK_DIR="/tmp/moltbook-api-build"

  log_info "Cloning Moltbook API..."
  rm -rf "$MOLTBOOK_DIR"
  git clone https://github.com/moltbook/api.git "$MOLTBOOK_DIR"

  cd "$MOLTBOOK_DIR"

  # Create OpenShift-compatible Dockerfile
  cat > Dockerfile.openshift << 'EOF'
FROM node:20-slim

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy source
COPY . .

# Build if needed
RUN if [ -f "tsconfig.json" ]; then npm run build || true; fi

ENV NODE_ENV=production
ENV PORT=3000

# OpenShift compatibility
RUN chmod -R 777 /app && \
    mkdir -p /home/node && \
    chmod -R 777 /home/node

# Non-root user
USER 1001

EXPOSE 3000

CMD ["node", "src/index.js"]
EOF

  log_info "Building Moltbook API image..."

  podman build \
    -f Dockerfile.openshift \
    -t "$MOLTBOOK_TAG" \
    --platform linux/amd64 \
    .

  cd -

  log_success "Moltbook API built: $MOLTBOOK_TAG"
}

# Tag images for registry
tag_images() {
  section "Tagging Images for Registry"

  OPENCLAW_FULL="$REGISTRY/$OPENCLAW_TAG"
  MOLTBOOK_FULL="$REGISTRY/$MOLTBOOK_TAG"

  log_info "Tagging OpenClaw: $OPENCLAW_FULL"
  podman tag "$OPENCLAW_TAG" "$OPENCLAW_FULL"

  log_info "Tagging Moltbook: $MOLTBOOK_FULL"
  podman tag "$MOLTBOOK_TAG" "$MOLTBOOK_FULL"

  log_success "Images tagged"

  export OPENCLAW_IMAGE="$OPENCLAW_FULL"
  export MOLTBOOK_IMAGE="$MOLTBOOK_FULL"
}

# Push images to registry
push_images() {
  section "Pushing Images to Registry"

  OPENCLAW_FULL="$REGISTRY/$OPENCLAW_TAG"
  MOLTBOOK_FULL="$REGISTRY/$MOLTBOOK_TAG"

  log_warn "Make sure you're logged into the registry:"
  log_info "  podman login $REGISTRY"
  echo ""
  read -p "Press Enter to continue (or Ctrl+C to cancel)..."

  log_info "Pushing OpenClaw..."
  podman push "$OPENCLAW_FULL"
  log_success "Pushed: $OPENCLAW_FULL"

  log_info "Pushing Moltbook API..."
  podman push "$MOLTBOOK_FULL"
  log_success "Pushed: $MOLTBOOK_FULL"
}

# Display summary
display_summary() {
  section "🎉 Build Complete!"

  echo ""
  echo -e "${GREEN}Images built and pushed successfully!${NC}"
  echo ""
  echo -e "${BLUE}OpenClaw Image:${NC}"
  echo "  $REGISTRY/$OPENCLAW_TAG"
  echo ""
  echo -e "${BLUE}Moltbook API Image:${NC}"
  echo "  $REGISTRY/$MOLTBOOK_TAG"
  echo ""
  echo -e "${YELLOW}Next Steps:${NC}"
  echo ""
  echo "1. Deploy with custom images:"
  echo "   ./deploy-all.sh apps.yourcluster.com \\"
  echo "     --openclaw-image $REGISTRY/$OPENCLAW_TAG \\"
  echo "     --moltbook-image $REGISTRY/$MOLTBOOK_TAG"
  echo ""
  echo "2. Or update manifests manually:"
  echo "   # In deployment YAML:"
  echo "   image: $REGISTRY/$OPENCLAW_TAG"
  echo ""
  echo -e "${GREEN}Ready to deploy! 🚀${NC}"
  echo ""

  # Save to file for easy copy-paste
  cat > /tmp/custom-images.env << EOF
export OPENCLAW_IMAGE="$REGISTRY/$OPENCLAW_TAG"
export MOLTBOOK_IMAGE="$REGISTRY/$MOLTBOOK_TAG"
EOF

  log_success "Image names saved to: /tmp/custom-images.env"
  log_info "Source it: source /tmp/custom-images.env"
}

# Main execution
main() {
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║                                                            ║${NC}"
  echo -e "${BLUE}║   🏗️  Podman Build Script for OpenShift 🏗️               ║${NC}"
  echo -e "${BLUE}║   OpenClaw + Moltbook                                      ║${NC}"
  echo -e "${BLUE}║                                                            ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  check_prerequisites
  build_openclaw
  build_moltbook
  tag_images
  push_images
  display_summary

  echo ""
  log_success "All done! Ready to deploy 🎉"
  echo ""
}

# Run main
main "$@"
