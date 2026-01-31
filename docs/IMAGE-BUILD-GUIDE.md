# Image Build Guide - Building with Podman

## TL;DR

**Build images on your x86 machine with podman, push to registry, deploy to OpenShift.**

```bash
# 1. Build images
./scripts/build-and-push.sh quay.io/yourorg

# 2. Deploy to OpenShift
./scripts/deploy.sh apps.yourcluster.com \
  --openclaw-image quay.io/yourorg/openclaw:latest \
  --moltbook-image quay.io/yourorg/moltbook-api:latest
```

**Total time**: ~5 minutes (build: 3-5 min, deploy: 2-3 min)

## Why Pre-built Images?

We use pre-built images instead of OpenShift BuildConfigs because:

- ✅ **Faster**: No waiting for OpenShift to build (deploy immediately)
- ✅ **Control**: Build on your machine with full control
- ✅ **Offline**: Can build without cluster access
- ✅ **Consistent**: Same build environment every time
- ✅ **Simple**: One script does everything

## Prerequisites

### Build Machine (x86)

- **Podman** installed (or Docker)
- **Git** for cloning repos
- **Network access** to pull base images and clone repos

```bash
# Fedora/RHEL
sudo dnf install podman git

# Ubuntu/Debian
sudo apt install podman git

# macOS
brew install podman git
```

### Container Registry

You need a registry to push images to:

- **Quay.io** (recommended, free public repos)
- **Docker Hub**
- **Private registry** (Harbor, Nexus, etc.)
- **OpenShift internal registry** (optional)

```bash
# Login to your registry
podman login quay.io
# Enter username and password
```

## Image Overview

### OpenClaw Gateway

**Source**: https://github.com/openclaw/openclaw.git

**Base Image**: `node:22-bookworm`

**Build Process**:
1. Install Bun (build tool)
2. Install pnpm dependencies
3. Build TypeScript → JavaScript
4. Build Control UI (React/Vite)
5. Add OpenShift compatibility (chmod, USER directive)

**Final Image**:
- Size: ~1.2 GB
- User: 1001 (non-root)
- Entrypoint: `node dist/index.js`

**OpenShift Compatibility**:
```dockerfile
# Runs as any UID (OpenShift assigns arbitrary UID)
RUN chmod -R 777 /app && \
    chmod -R 777 /home/node
USER 1001
```

### Moltbook API

**Source**: https://github.com/moltbook/api.git

**Base Image**: `node:20-slim`

**Build Process**:
1. Clone from GitHub
2. Install npm dependencies
3. Build TypeScript (if present)
4. Add OpenShift compatibility

**Final Image**:
- Size: ~400-500 MB
- User: 1001 (non-root)
- Entrypoint: `node src/index.js`

### Upstream Images (Pulled Automatically)

| Image | Size | Purpose | Registry |
|-------|------|---------|----------|
| `registry.redhat.io/rhel8/postgresql-16` | ~240 MB | Database | Red Hat |
| `redis:7-alpine` | ~40 MB | Cache | Docker Hub |
| `nginx:alpine` | ~40 MB | Frontend | Docker Hub |

## Build Script: build-and-push.sh

### Usage

```bash
./scripts/build-and-push.sh <registry> [openclaw-tag] [moltbook-tag]
```

**Examples**:

```bash
# Default tags (latest)
./scripts/build-and-push.sh quay.io/myorg

# Custom tags
./scripts/build-and-push.sh quay.io/myorg openclaw:v1.0.0 moltbook-api:v1.0.0

# Different registry
./scripts/build-and-push.sh docker.io/myuser
```

### What It Does

1. **Validates prerequisites**
   - Checks podman is installed
   - Checks git is available

2. **Builds OpenClaw**
   - Creates OpenShift-compatible Dockerfile
   - Builds with `podman build --platform linux/amd64`
   - Adds `chmod -R 777` for arbitrary UIDs
   - Sets `USER 1001`

3. **Builds Moltbook API**
   - Clones moltbook/api from GitHub to `/tmp`
   - Creates OpenShift-compatible Dockerfile
   - Builds with podman
   - Cleans up temp directory

4. **Tags images**
   - `<registry>/<openclaw-tag>`
   - `<registry>/<moltbook-tag>`

5. **Pushes to registry**
   - Prompts for registry login confirmation
   - Pushes both images
   - Saves image names to `/tmp/custom-images.env`

### Output

```
✅ OpenClaw built: openclaw:latest
✅ Moltbook API built: moltbook-api:latest
✅ Pushed: quay.io/myorg/openclaw:latest
✅ Pushed: quay.io/myorg/moltbook-api:latest

Image names saved to: /tmp/custom-images.env
```

## Building Manually (Without Script)

### Build OpenClaw

```bash
# Clone OpenClaw
git clone https://github.com/openclaw/openclaw.git
cd openclaw

# Create OpenShift-compatible Dockerfile
cat > Dockerfile.openshift << 'EOF'
FROM node:22-bookworm

RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable

WORKDIR /app

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

# OpenShift compatibility
RUN chmod -R 777 /app && \
    mkdir -p /home/node && \
    chmod -R 777 /home/node

USER 1001
CMD ["node", "dist/index.js"]
EOF

# Build
podman build -f Dockerfile.openshift -t openclaw:latest --platform linux/amd64 .

# Tag and push
podman tag openclaw:latest quay.io/myorg/openclaw:latest
podman push quay.io/myorg/openclaw:latest
```

### Build Moltbook API

```bash
# Clone Moltbook API
git clone https://github.com/moltbook/api.git /tmp/moltbook-api
cd /tmp/moltbook-api

# Create OpenShift-compatible Dockerfile
cat > Dockerfile.openshift << 'EOF'
FROM node:20-slim

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN if [ -f "tsconfig.json" ]; then npm run build || true; fi

ENV NODE_ENV=production
ENV PORT=3000

# OpenShift compatibility
RUN chmod -R 777 /app && \
    mkdir -p /home/node && \
    chmod -R 777 /home/node

USER 1001
EXPOSE 3000
CMD ["node", "src/index.js"]
EOF

# Build
podman build -f Dockerfile.openshift -t moltbook-api:latest --platform linux/amd64 .

# Tag and push
podman tag moltbook-api:latest quay.io/myorg/moltbook-api:latest
podman push quay.io/myorg/moltbook-api:latest
```

## Build Troubleshooting

### Podman vs Docker

**Problem**: Commands fail with "docker: command not found"

**Solution**: Replace `docker` with `podman` (or alias):
```bash
alias docker=podman
```

### Permission Denied (Rootless Podman)

**Problem**: "permission denied" when building

**Solution**: Podman runs rootless by default, which is fine. If issues persist:
```bash
# Check podman info
podman info | grep root

# Run as root if necessary (not recommended)
sudo podman build ...
```

### Out of Memory

**Problem**: Build killed with "out of memory"

**Solution**: Increase podman memory limit or build on machine with more RAM:
```bash
# Check available memory
free -h

# Close other applications
# Or build on a larger machine
```

### Network Timeout

**Problem**: "timeout" when pulling base images or installing packages

**Solution**: Check network and retry:
```bash
# Test network
ping -c 3 registry-1.docker.io

# Retry build
podman build --no-cache ...
```

### Platform Mismatch

**Problem**: Image built on Mac (ARM) doesn't work on OpenShift (x86)

**Solution**: Always specify `--platform linux/amd64`:
```bash
podman build --platform linux/amd64 ...
```

### Registry Push Fails

**Problem**: "unauthorized" or "denied" when pushing

**Solution**: Login to registry first:
```bash
# Login
podman login quay.io

# Verify login worked
podman login quay.io --get-login
# Should show your username

# Then retry push
podman push quay.io/myorg/openclaw:latest
```

### OpenShift Can't Pull Image

**Problem**: Pod shows `ImagePullBackOff` or `ErrImagePull`

**Solution**: Check image exists and create pull secret if private:
```bash
# Verify image exists
podman pull quay.io/myorg/openclaw:latest

# If private registry, create pull secret
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=myuser \
  --docker-password=mypassword \
  -n openclaw

# Patch deployment to use secret
oc patch deployment openclaw-gateway -n openclaw -p '
{
  "spec": {
    "template": {
      "spec": {
        "imagePullSecrets": [{"name": "quay-pull-secret"}]
      }
    }
  }
}'
```

## Updating Images

### Build New Version

```bash
# Build with version tag
./scripts/build-and-push.sh quay.io/myorg openclaw:v1.1.0 moltbook-api:v1.1.0
```

### Update Deployment

```bash
# Update OpenClaw
oc set image deployment/openclaw-gateway -n openclaw \
  gateway=quay.io/myorg/openclaw:v1.1.0

# Update Moltbook API
oc set image deployment/moltbook-api -n moltbook \
  api=quay.io/myorg/moltbook-api:v1.1.0

# Or redeploy with new images
./scripts/deploy.sh apps.yourcluster.com \
  --openclaw-image quay.io/myorg/openclaw:v1.1.0 \
  --moltbook-image quay.io/myorg/moltbook-api:v1.1.0
```

### Rollback

```bash
# Rollback to previous version
oc rollout undo deployment/openclaw-gateway -n openclaw
oc rollout undo deployment/moltbook-api -n moltbook

# Or specify revision
oc rollout undo deployment/openclaw-gateway -n openclaw --to-revision=2
```

## Image Optimization

### Reduce Build Time

**Use local cache**:
```bash
# Podman caches layers automatically
# Rebuild is faster (only changed layers rebuild)
podman build ...
```

**Multi-stage builds** (advanced):
```dockerfile
# Stage 1: Build
FROM node:22 AS builder
WORKDIR /build
COPY . .
RUN pnpm install && pnpm build

# Stage 2: Runtime
FROM node:22-slim
WORKDIR /app
COPY --from=builder /build/dist ./dist
COPY --from=builder /build/node_modules ./node_modules
USER 1001
CMD ["node", "dist/index.js"]
```

### Reduce Image Size

**Use slim base images**:
```dockerfile
# Instead of: node:22-bookworm (~1.1GB base)
# Use: node:22-slim (~200MB base)
FROM node:22-slim
```

**Remove dev dependencies**:
```dockerfile
RUN npm ci --only=production
# Instead of: npm install (includes devDependencies)
```

**Clean up in same layer**:
```dockerfile
RUN pnpm install && \
    pnpm build && \
    pnpm prune --prod && \
    rm -rf /root/.cache /tmp/*
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Build and Push Images

on:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up Podman
        run: sudo apt install -y podman

      - name: Login to Quay
        run: podman login -u ${{ secrets.QUAY_USER }} -p ${{ secrets.QUAY_TOKEN }} quay.io

      - name: Build and Push
        run: |
          VERSION=${GITHUB_REF#refs/tags/}
          ./scripts/build-and-push.sh quay.io/myorg openclaw:$VERSION moltbook-api:$VERSION
```

### GitLab CI

```yaml
build:
  image: quay.io/podman/stable
  script:
    - podman login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - ./scripts/build-and-push.sh $CI_REGISTRY/myorg
  only:
    - main
    - tags
```

## Summary

| Component | Build Time | Size | Platform | Registry |
|-----------|-----------|------|----------|----------|
| OpenClaw | 3-5 min | ~1.2GB | linux/amd64 | Your choice |
| Moltbook API | 1-2 min | ~500MB | linux/amd64 | Your choice |
| PostgreSQL | N/A (pull) | ~240MB | linux/amd64 | registry.redhat.io |
| Redis | N/A (pull) | ~40MB | linux/amd64 | docker.io |
| Nginx | N/A (pull) | ~40MB | linux/amd64 | docker.io |

**Total Build Time**: ~5 minutes

**Total Storage**: ~2GB (without base image caching)

---

**Bottom Line**: Build with `./scripts/build-and-push.sh`, deploy with `./scripts/deploy.sh`. Fast, simple, and production-ready! 🚀
