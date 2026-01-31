# OpenClaw on OpenShift - Quick Start Guide

Deploy OpenClaw with your existing observability stack (otel-collector + Tempo in `observability-hub` namespace).

## Prerequisites

- OpenShift cluster access
- Existing `observability-hub` namespace with:
  - otel-collector (OTLP endpoint on port 4318)
  - Tempo for distributed tracing
- (Optional) MLFlow deployment
- (Optional) Langfuse deployment

## Deployment Steps

### 1. Create Project

```bash
oc new-project openclaw
```

### 2. Build OpenClaw Image

**Option A: BuildConfig (Recommended)**

```bash
oc process -f openshift/template.yaml \
  -p GATEWAY_HOSTNAME=openclaw.apps.your-cluster.com \
  -p OTEL_ENDPOINT=http://otel-collector.observability-hub.svc.cluster.local:4318 \
  -p MLFLOW_TRACKING_URI=http://mlflow.openclaw.svc:5000 \
  -p LANGFUSE_HOST=http://langfuse.openclaw.svc:3000 \
  -p LANGFUSE_PUBLIC_KEY=pk-xxx \
  -p LANGFUSE_SECRET_KEY=sk-xxx \
  | oc create -f -

# Start build
oc start-build openclaw -n openclaw

# Watch build
oc logs -f bc/openclaw
```

**Option B: Local Build + Push**

```bash
# Build locally
docker build -t openclaw:latest .

# Tag for OpenShift registry
docker tag openclaw:latest \
  default-route-openshift-image-registry.apps.your-cluster.com/openclaw/openclaw:latest

# Login to registry
oc registry login

# Push
docker push default-route-openshift-image-registry.apps.your-cluster.com/openclaw/openclaw:latest

# Deploy using existing observability
oc apply -f kubernetes/deployment-with-existing-observability.yaml
```

### 3. Configure Secrets

```bash
# Generate secure token
GATEWAY_TOKEN=$(openssl rand -hex 32)

# Update secrets
oc patch secret openclaw-secrets -n openclaw -p "{
  \"stringData\": {
    \"OPENCLAW_GATEWAY_TOKEN\": \"$GATEWAY_TOKEN\",
    \"LANGFUSE_PUBLIC_KEY\": \"pk-your-key\",
    \"LANGFUSE_SECRET_KEY\": \"sk-your-secret\"
  }
}"
```

### 4. Verify Deployment

```bash
# Check pods
oc get pods -n openclaw

# Check logs
oc logs -f deployment/openclaw-gateway -n openclaw

# Get route
oc get route openclaw -n openclaw -o jsonpath='{.spec.host}'
```

### 5. Access Control UI

```bash
# Get the URL
OPENCLAW_URL=$(oc get route openclaw -n openclaw -o jsonpath='{.spec.host}')

# Open in browser
open "https://$OPENCLAW_URL"

# Login with token
echo "Token: $GATEWAY_TOKEN"
```

## Verify Observability Integration

### OpenTelemetry → Tempo

```bash
# Check if traces are flowing
oc logs -n observability-hub deployment/otel-collector | grep openclaw

# Query Tempo for OpenClaw traces
# (Use your Grafana/Tempo UI)
```

### MLFlow Integration

```bash
# Check MLFlow runs
curl http://mlflow.openclaw.svc:5000/api/2.0/mlflow/experiments/search

# View in MLFlow UI
kubectl port-forward -n openclaw svc/mlflow 5000:5000
open http://localhost:5000
```

### Langfuse Integration

```bash
# View traces in Langfuse UI
kubectl port-forward -n openclaw svc/langfuse 3000:3000
open http://localhost:3000
```

## Connecting Channels

### Telegram Bot

```bash
# Get bot token from @BotFather
# Then run:
oc exec -it deployment/openclaw-gateway -n openclaw -- \
  node dist/index.js channels add \
  --channel telegram \
  --token "YOUR_BOT_TOKEN"
```

### Discord Bot

```bash
# Get bot token from Discord Developer Portal
oc exec -it deployment/openclaw-gateway -n openclaw -- \
  node dist/index.js channels add \
  --channel discord \
  --token "YOUR_DISCORD_TOKEN"
```

### WhatsApp (QR Code)

```bash
# Start WhatsApp pairing
oc exec -it deployment/openclaw-gateway -n openclaw -- \
  node dist/index.js channels login

# Scan QR code with WhatsApp
```

## Observability Dashboard Queries

### Grafana/Tempo Queries

```promql
# Request rate
rate(openclaw_tokens{openclaw_token="total"}[5m])

# Cost per hour
sum(rate(openclaw_cost_usd[1h])) * 3600

# P95 latency
histogram_quantile(0.95,
  rate(openclaw_run_duration_ms_bucket[5m])
)

# Queue depth
openclaw_queue_depth
```

### Langfuse

- Navigate to Projects → openclaw-production
- View traces by session
- Check generation costs
- Review error scores

### MLFlow

- Experiments → openclaw-production
- View token usage metrics
- Track cost trends
- Compare model performance

## Troubleshooting

### Observability Not Working

```bash
# 1. Test OTLP endpoint from OpenClaw pod
oc exec -it deployment/openclaw-gateway -n openclaw -- \
  curl -v http://otel-collector.observability-hub.svc.cluster.local:4318/v1/traces

# 2. Check NetworkPolicy allows egress
oc get networkpolicy -n openclaw

# 3. Verify service endpoint
oc get endpoints -n observability-hub otel-collector
```

### Build Failures

```bash
# Check build logs
oc logs -f bc/openclaw

# Retry build
oc start-build openclaw --follow
```

### Pod Not Starting

```bash
# Check events
oc describe pod -n openclaw <pod-name>

# Check PVC binding
oc get pvc -n openclaw

# Check secrets
oc get secret openclaw-secrets -n openclaw -o yaml
```

## Next Steps

### 1. Build a Moltbook-Style Social Network

The Moltbook repos are now cloned in `../moltbook-*`:

```bash
cd ../moltbook-api
npm install
npm start
```

Key components:
- `moltbook-api`: Core API for posts, voting, agents
- `moltbook-voting`: Voting system
- `moltbook-clawhub`: Skill directory

### 2. Connect Multiple Agents

```bash
# Run multiple OpenClaw instances with different tokens
oc scale deployment openclaw-gateway --replicas=3 -n openclaw

# Configure session affinity
oc patch service openclaw-gateway -n openclaw -p '
{
  "spec": {
    "sessionAffinity": "ClientIP"
  }
}'
```

### 3. Monitor in Real-Time

- **Grafana**: `http://grafana.observability-hub.svc:3000`
- **Tempo**: Query traces via Grafana
- **MLFlow**: `http://mlflow.openclaw.svc:5000`
- **Langfuse**: `http://langfuse.openclaw.svc:3000`

## Architecture Summary

```
┌─────────────────────────────────────────────┐
│  OpenClaw Gateway (openclaw namespace)      │
│  - Control UI + WebChat                     │
│  - Built-in OpenTelemetry instrumentation   │
│  - MLFlow extension                         │
│  - Langfuse extension                       │
└────────────────┬────────────────────────────┘
                 │
                 │ OTLP HTTP (4318)
                 ▼
┌─────────────────────────────────────────────┐
│  observability-hub namespace                │
│  ┌─────────────────────────────────────┐    │
│  │  otel-collector                     │    │
│  │  - Receives OTLP traces/metrics     │    │
│  │  - Forwards to Tempo                │    │
│  └───────────────┬─────────────────────┘    │
│                  │                          │
│                  ▼                          │
│  ┌─────────────────────────────────────┐    │
│  │  Tempo                              │    │
│  │  - Stores distributed traces        │    │
│  │  - Queried via Grafana              │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘

    ┌──────────┐         ┌───────────┐
    │ MLFlow   │         │ Langfuse  │
    │ (5000)   │         │  (3000)   │
    └──────────┘         └───────────┘
```

## Support

- [OpenClaw Docs](https://docs.openclaw.ai)
- [GitHub Issues](https://github.com/openclaw/openclaw/issues)
- [Discord Community](https://discord.gg/clawd)
- [Moltbook](https://moltbook.com)
