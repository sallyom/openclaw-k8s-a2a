# OpenClaw Deployment Guide

## Quick Deploy

### Setup Script (Recommended for Fresh Install)

```bash
cd /path/to/ocm-guardrails
./scripts/setup.sh           # OpenShift (default)
./scripts/setup.sh --k8s     # Vanilla Kubernetes (minikube, KinD, etc.)
```

This handles everything:
- Generates secrets into `.env` (git-ignored)
- Runs `envsubst` on `.envsubst` templates to produce deployment YAML
- Deploys OAuthClient (cluster-scoped, OpenShift only)
- Deploys OpenClaw via kustomize overlay (namespace-scoped)
- Optionally deploys agents

**OAuthClient is cluster-scoped** (no namespace), while everything else is namespace-scoped (`openclaw`).

## Update Existing Deployment

If you already have OpenClaw running and just want to apply updates:

```bash
# Ensure .env exists and templates have been processed (envsubst)
source .env && set -a
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET}'
for tpl in manifests/openclaw/overlays/openshift/*.envsubst; do
  envsubst "$ENVSUBST_VARS" < "$tpl" > "${tpl%.envsubst}"
done

# OAuthClient already exists, no need to redeploy it
# Just update namespace resources
oc apply -k manifests/openclaw/overlays/openshift/
```

## What Gets Deployed

### Cluster-scoped (deployed separately)
- `OAuthClient/openclaw` - OAuth integration with OpenShift

### Namespace-scoped (deployed via kustomize)
- `Deployment/openclaw` - Main gateway with OAuth proxy
- `Service/openclaw` - ClusterIP service
- `Route/openclaw` - External access with TLS
- `ConfigMap/openclaw-config` - Application configuration
- `Secret/openclaw-secrets` - API tokens
- `Secret/openclaw-oauth-config` - OAuth proxy secrets
- `ServiceAccount/openclaw-oauth-proxy` - OAuth RBAC
- `PersistentVolumeClaim` x2 - Storage for home and workspace
- `ResourceQuota/openclaw-quota` - Resource limits
- `PodDisruptionBudget/openclaw-pdb` - High availability
