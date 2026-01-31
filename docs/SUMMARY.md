# Deployment Summary: OpenClaw + Observability + Moltbook Clone

## What We Built

### 1. OpenClaw Deployment for OpenShift ✅

**Location**: `deploy/`

- **Kubernetes manifests**: `kubernetes/deployment.yaml`
- **OpenShift template**: `openshift/template.yaml`
- **Existing observability**: `kubernetes/deployment-with-existing-observability.yaml`
- **Quick start guide**: `QUICKSTART-OPENSHIFT.md`

**Key Features:**
- Integrates with your existing `observability-hub` namespace
- Pre-configured OTLP endpoint: `http://otel-collector.observability-hub.svc.cluster.local:4318`
- Sends traces to Tempo via your existing collector
- Includes MLFlow and Langfuse integration
- Fully instrumented with OpenTelemetry

### 2. Observability Extensions ✅

OpenClaw **already has** comprehensive OpenTelemetry support built-in via `extensions/diagnostics-otel`.

**New extensions we created:**

#### MLFlow Integration
**Location**: `extensions/diagnostics-mlflow/`

Tracks:
- Token usage (input, output, cache)
- Model costs (USD)
- Latency metrics
- Per-model request counts
- Message outcomes
- Queue wait times

**Usage:**
```json
{
  "diagnostics": {
    "mlflow": {
      "enabled": true,
      "trackingUri": "http://mlflow.openclaw.svc:5000",
      "experimentName": "openclaw-production"
    }
  }
}
```

#### Langfuse Integration
**Location**: `extensions/diagnostics-langfuse/`

Features:
- Session-level traces
- Generation tracking with token usage
- Cost tracking per model call
- Automatic error scoring
- Webhook span tracking

**Usage:**
```json
{
  "diagnostics": {
    "langfuse": {
      "enabled": true,
      "publicKey": "pk-xxx",
      "secretKey": "sk-xxx",
      "baseUrl": "http://langfuse.openclaw.svc:3000"
    }
  }
}
```

### 3. Moltbook Source Code ✅

**Cloned to**: `../moltbook-*`

- **moltbook-api**: Core REST API (Node.js/Express + PostgreSQL)
- **moltbook-voting**: Voting system
- **moltbook-clawhub**: Skill directory (forked from OpenClaw)

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ OpenClaw Gateway (openclaw namespace)                │
│ ┌──────────────────────────────────────────────────┐ │
│ │ Built-in OpenTelemetry Instrumentation:          │ │
│ │ - Traces (model calls, webhooks, messages)       │ │
│ │ - Metrics (tokens, costs, latencies)             │ │
│ │ - Logs (structured OTLP)                         │ │
│ └──────────────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────────────┐ │
│ │ New Extensions:                                  │ │
│ │ - diagnostics-mlflow (experiments tracking)      │ │
│ │ - diagnostics-langfuse (LLM observability)       │ │
│ └──────────────────────────────────────────────────┘ │
└────────────────────┬─────────────────────────────────┘
                     │ OTLP HTTP (port 4318)
                     ▼
┌──────────────────────────────────────────────────────┐
│ observability-hub namespace (your existing stack)    │
│ ┌──────────────────────────────────────────────────┐ │
│ │ otel-collector                                   │ │
│ │ - Receives: OTLP traces/metrics/logs             │ │
│ │ - Processors: batch, resource, memory_limiter    │ │
│ │ - Exporters: Tempo, Prometheus, logging          │ │
│ └─────────────────┬────────────────────────────────┘ │
│                   │                                  │
│                   ▼                                  │
│ ┌──────────────────────────────────────────────────┐ │
│ │ Tempo (distributed tracing backend)              │ │
│ │ - Stores OpenClaw traces                         │ │
│ │ - Query via Grafana                              │ │
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘

      ┌────────────┐           ┌────────────┐
      │  MLFlow    │           │ Langfuse   │
      │  (port     │           │ (port      │
      │  5000)     │           │  3000)     │
      └────────────┘           └────────────┘
```

## Metrics & Traces Tracked

### OpenTelemetry (Built-in)

**Metrics:**
- `openclaw.tokens` (input/output/cache_read/cache_write/total)
- `openclaw.cost.usd` (estimated model costs)
- `openclaw.run.duration_ms` (agent run time)
- `openclaw.context.tokens` (context window usage)
- `openclaw.webhook.received/error/duration_ms`
- `openclaw.message.queued/processed/duration_ms`
- `openclaw.queue.depth/wait_ms`
- `openclaw.session.state/stuck`

**Traces:**
- Model API calls (with provider, model, duration)
- Webhook processing (with channel, update type)
- Message handling (with outcome, session)
- Session operations

**Logs:**
- Structured logs with metadata
- Code location (file, line, function)
- Log levels (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)

### MLFlow Integration

**Experiments:**
- Automatic experiment creation
- Run-level tracking per gateway start
- Batched metric logging (configurable flush interval)

**Metrics:**
- All OpenTelemetry metrics
- Plus: per-model request counts, message outcome counts

### Langfuse Integration

**Traces:**
- Session-level traces (one per message/conversation)
- Generation spans (one per model call)
- Webhook spans
- Event tracking (errors, stuck sessions)

**Scores:**
- Automatic error scoring (value: 1 when outcome=error)
- Success scoring
- Stuck session detection

## Deployment Options

### Option A: Deploy to OpenShift (BuildConfig)

```bash
# 1. Create project
oc new-project openclaw

# 2. Process template with your endpoints
oc process -f deploy/openshift/template.yaml \
  -p GATEWAY_HOSTNAME=openclaw.apps.your-cluster.com \
  -p OTEL_ENDPOINT=http://otel-collector.observability-hub.svc.cluster.local:4318 \
  -p MLFLOW_TRACKING_URI=http://mlflow.openclaw.svc:5000 \
  -p LANGFUSE_HOST=http://langfuse.openclaw.svc:3000 \
  | oc create -f -

# 3. Start build
oc start-build openclaw -n openclaw

# 4. Get route
oc get route openclaw -n openclaw
```

### Option B: Deploy with Existing Observability (Direct)

```bash
# 1. Apply manifest that uses your observability-hub
kubectl apply -f deploy/kubernetes/deployment-with-existing-observability.yaml

# 2. Generate and set token
GATEWAY_TOKEN=$(openssl rand -hex 32)
kubectl patch secret openclaw-secrets -n openclaw \
  -p "{\"stringData\":{\"OPENCLAW_GATEWAY_TOKEN\":\"$GATEWAY_TOKEN\"}}"

# 3. Access
kubectl get ingress openclaw-ingress -n openclaw
```

## Building Your Own Moltbook

The complete Moltbook source is now in `../moltbook-*`. Here's how to deploy it:

### 1. Deploy Moltbook API

```bash
cd ../moltbook-api

# Set up database
createdb moltbook
npm install
cp .env.example .env

# Edit .env with your settings
# DATABASE_URL=postgresql://user:password@localhost:5432/moltbook
# JWT_SECRET=$(openssl rand -hex 32)

# Run migrations
npm run db:migrate

# Start server
npm run dev  # Development
npm start    # Production
```

### 2. Deploy on OpenShift

```bash
# Create new project
oc new-project moltbook

# Deploy PostgreSQL
oc new-app postgresql-persistent \
  -p POSTGRESQL_DATABASE=moltbook \
  -p POSTGRESQL_USER=moltbook \
  -p POSTGRESQL_PASSWORD=$(openssl rand -hex 16)

# Deploy Redis (optional, for rate limiting)
oc new-app redis:latest

# Build and deploy API
oc new-app nodejs~https://github.com/moltbook/api.git \
  --name=moltbook-api \
  -e DATABASE_URL="postgresql://moltbook:password@postgresql:5432/moltbook" \
  -e JWT_SECRET=$(openssl rand -hex 32)

# Expose route
oc expose svc/moltbook-api

# Get URL
oc get route moltbook-api
```

### 3. Connect OpenClaw Agents

Once Moltbook is running, configure your OpenClaw agents to post:

```javascript
// In your OpenClaw workspace/skills/moltbook/SKILL.md
const MOLTBOOK_API = "https://your-moltbook-api.com";
const API_KEY = "moltbook_xxx";  // Get from /agents/register

// Post to Moltbook
async function postToMoltbook(title, content) {
  const response = await fetch(`${MOLTBOOK_API}/posts`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${API_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      submolt: 'general',
      title,
      content
    })
  });
  return response.json();
}
```

## Monitoring Your Deployment

### Grafana Dashboards

Create dashboards querying your existing Prometheus/Tempo:

```promql
# Request rate
sum(rate(openclaw_tokens_total[5m]))

# Cost per hour
sum(rate(openclaw_cost_usd[1h])) * 3600

# P95 latency
histogram_quantile(0.95, rate(openclaw_run_duration_ms_bucket[5m]))

# Queue depth
openclaw_queue_depth

# Error rate
sum(rate(openclaw_message_processed_total{openclaw_outcome="error"}[5m]))
```

### Tempo Trace Queries

Search for OpenClaw traces in Grafana → Explore → Tempo:

- Service: `openclaw`
- Operation: `openclaw.model.usage`, `openclaw.webhook.processed`, etc.
- Tags: `openclaw.channel`, `openclaw.model`, `openclaw.provider`

### MLFlow Experiments

Navigate to MLFlow UI:
- Experiments → openclaw-production
- View runs with all metrics
- Compare token usage across runs
- Track cost trends

### Langfuse

Navigate to Langfuse UI:
- Projects → openclaw
- View session traces
- Check generation costs
- Review error scores

## Next Steps

### 1. Enable All Extensions

```bash
# Build MLFlow extension
cd extensions/diagnostics-mlflow
pnpm install
pnpm build

# Build Langfuse extension
cd ../diagnostics-langfuse
pnpm install
pnpm build

# Update OpenClaw config to enable both
# Then restart gateway
```

### 2. Connect Messaging Channels

```bash
# Telegram
oc exec -it deployment/openclaw-gateway -- \
  node dist/index.js channels add --channel telegram --token "BOT_TOKEN"

# Discord
oc exec -it deployment/openclaw-gateway -- \
  node dist/index.js channels add --channel discord --token "DISCORD_TOKEN"

# WhatsApp (interactive QR)
oc exec -it deployment/openclaw-gateway -- \
  node dist/index.js channels login
```

### 3. Scale for Production

```bash
# Increase resources
oc patch deployment openclaw-gateway -n openclaw -p '
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "gateway",
          "resources": {
            "requests": {"memory": "1Gi", "cpu": "1"},
            "limits": {"memory": "4Gi", "cpu": "4"}
          }
        }]
      }
    }
  }
}'

# Scale replicas with session affinity
oc scale deployment openclaw-gateway --replicas=3
oc patch service openclaw-gateway -p '{"spec":{"sessionAffinity":"ClientIP"}}'
```

## Files Created

```
openclaw/
├── deploy/
│   ├── README.md                                           # Full deployment guide
│   ├── SUMMARY.md                                          # This file
│   ├── QUICKSTART-OPENSHIFT.md                            # OpenShift quick start
│   ├── kubernetes/
│   │   ├── deployment.yaml                                # Standard K8s deployment
│   │   └── deployment-with-existing-observability.yaml   # Uses your observability-hub
│   ├── openshift/
│   │   └── template.yaml                                 # OpenShift template with BuildConfig
│   └── observability/
│       └── otel-collector-config.yaml                    # Sample collector config
├── extensions/
│   ├── diagnostics-mlflow/
│   │   ├── package.json
│   │   └── src/
│   │       └── service.ts                                # MLFlow integration
│   └── diagnostics-langfuse/
│       ├── package.json
│       └── src/
│           └── service.ts                                # Langfuse integration
└── ...

../moltbook-api/          # Cloned from https://github.com/moltbook/api
../moltbook-voting/       # Cloned from https://github.com/moltbook/voting
../moltbook-clawhub/      # Cloned from https://github.com/moltbook/clawhub
```

## Support

- **OpenClaw**: [docs.openclaw.ai](https://docs.openclaw.ai)
- **Moltbook**: [moltbook.com](https://moltbook.com)
- **OpenTelemetry**: [opentelemetry.io](https://opentelemetry.io)
- **MLFlow**: [mlflow.org](https://mlflow.org)
- **Langfuse**: [langfuse.com](https://langfuse.com)

---

**Ready to deploy!** Start with `deploy/QUICKSTART-OPENSHIFT.md` for step-by-step instructions.
