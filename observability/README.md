# Observability Architecture

This directory contains OpenTelemetry Collector configurations for the OCM Platform deployment.

## Architecture Overview

The observability stack uses a **three-tier architecture**:

```
┌─────────────────────────────────────────────────────────────────┐
│ Application Layer                                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  OpenClaw Gateway (openclaw namespace)                         │
│  └─ Built-in OTLP instrumentation                             │
│     └─ Traces, metrics, logs                                   │
│                                                                 │
│  Moltbook API (moltbook namespace)                             │
│  └─ OTLP instrumentation (if enabled)                          │
│     └─ Traces, metrics, logs                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼ OTLP/HTTP (4318)
┌─────────────────────────────────────────────────────────────────┐
│ Namespace-Local Collectors (OpenTelemetry Operator)            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  otel-collector.openclaw.svc:4318                              │
│  └─ Receives from OpenClaw                                     │
│  └─ Enriches with namespace labels                             │
│  └─ Batches and forwards                                       │
│                                                                 │
│  otel-collector.moltbook.svc:4318                              │
│  └─ Receives from Moltbook API                                 │
│  └─ Enriches with namespace labels                             │
│  └─ Batches and forwards                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼ OTLP/HTTP (4318)
┌─────────────────────────────────────────────────────────────────┐
│ Central Collector (observability-hub namespace)                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  otel-collector.observability-hub.svc:4318                     │
│  └─ Receives from all namespace collectors                     │
│  └─ Routes to backends:                                        │
│     ├─ Tempo (traces)                                          │
│     ├─ Prometheus (metrics)                                    │
│     ├─ Loki (logs, optional)                                   │
│     └─ Other exporters as needed                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Why Namespace-Local Collectors?

### Benefits

1. **Isolation**: Each namespace has its own collector, preventing cross-namespace telemetry pollution
2. **Namespace Enrichment**: Automatically add `k8s.namespace.name` and `service.namespace` attributes
3. **Resource Management**: Isolate resource usage per namespace
4. **Security**: Enforce network policies at namespace boundaries
5. **Scalability**: Scale collectors independently per namespace workload
6. **Troubleshooting**: Debug telemetry issues without affecting other namespaces

### How It Works

Each namespace collector:
- Receives OTLP from apps in its namespace (port 4317/4318)
- Adds namespace-specific resource attributes
- Batches telemetry for efficiency
- Forwards to central collector in `observability-hub`

The central collector:
- Receives from all namespace collectors
- Routes to backend systems (Tempo, Prometheus, Loki)
- Handles authentication/authorization with backends
- Applies global sampling/filtering rules

## Files

### OpenTelemetryCollector CRs (Operator-based)

- **`openclaw-otel-collector.yaml`**: Collector for openclaw namespace
- **`moltbook-otel-collector.yaml`**: Collector for moltbook namespace

These use the **OpenTelemetry Operator** to manage collector deployments. The operator handles:
- Deployment lifecycle
- Service creation
- ConfigMap management
- Auto-instrumentation (if enabled)

### Reference Configuration

- **`otel-collector-config.yaml`**: Legacy standalone collector example (not used in current deployment)

## Prerequisites

1. **OpenTelemetry Operator** installed in cluster:
   ```bash
   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   ```

2. **Central collector** running in `observability-hub` namespace:
   - Service: `otel-collector.observability-hub.svc`
   - Listening on ports: 4317 (gRPC), 4318 (HTTP)

3. **Backend systems** configured in central collector:
   - Tempo for traces
   - Prometheus for metrics
   - Loki for logs (optional)

## Deployment

The collectors are deployed automatically by `scripts/deploy.sh`:

```bash
# Deploy both OpenClaw and Moltbook with observability
./scripts/deploy.sh apps.yourcluster.com \
  --openclaw-image quay.io/yourorg/openclaw:latest \
  --moltbook-image quay.io/yourorg/moltbook-api:latest
```

This script:
1. Creates `openclaw` and `moltbook` namespaces
2. Deploys OpenTelemetryCollector CRs in each namespace
3. Configures apps to send telemetry to local collectors
4. Sets up NetworkPolicies to allow forwarding to `observability-hub`

## Configuration

### OpenClaw Configuration

OpenClaw has built-in OpenTelemetry support via `extensions/diagnostics-otel`. The deployment configures:

```json
{
  "diagnostics": {
    "otel": {
      "enabled": true,
      "protocol": "http/protobuf",
      "endpoint": "http://otel-collector.openclaw.svc.cluster.local:4318",
      "serviceName": "openclaw",
      "traces": true,
      "metrics": true,
      "logs": true
    }
  }
}
```

Environment variables:
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.openclaw.svc.cluster.local:4318`
- `OTEL_SERVICE_NAME=openclaw`

### Moltbook Configuration

Moltbook API uses standard Node.js OpenTelemetry auto-instrumentation:

```yaml
env:
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector.moltbook.svc.cluster.local:4318"
- name: OTEL_SERVICE_NAME
  value: "moltbook-api"
- name: OTEL_TRACES_SAMPLER
  value: "always_on"
```

The Moltbook API image should include OpenTelemetry instrumentation. If not already included, add to the Dockerfile:

```dockerfile
# Install OpenTelemetry dependencies
RUN npm install --save \
    @opentelemetry/api \
    @opentelemetry/sdk-node \
    @opentelemetry/auto-instrumentations-node \
    @opentelemetry/exporter-trace-otlp-http \
    @opentelemetry/exporter-metrics-otlp-http

# Enable auto-instrumentation at startup
ENV NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"
```

## Telemetry Pipelines

### Traces Pipeline

```
App → Local Collector → Central Collector → Tempo
```

Processors:
- `memory_limiter`: Prevent OOM
- `resource`: Add namespace labels
- `attributes`: Add environment labels
- `batch`: Batch for efficiency

### Metrics Pipeline

```
App → Local Collector → Central Collector → Prometheus
```

Processors: Same as traces

### Logs Pipeline

```
App → Local Collector → Central Collector → Loki (optional)
```

Processors: Same as traces

## Querying Telemetry

### In Grafana (Tempo for traces)

```promql
# All traces from openclaw
{service.namespace="openclaw"}

# All traces from moltbook
{service.namespace="moltbook"}

# Traces from specific service
{service.name="openclaw"}

# Filter by operation
{service.name="openclaw" span.name="agent.send"}
```

### In Prometheus (metrics)

```promql
# OpenClaw token usage rate
rate(openclaw_tokens_total{service_namespace="openclaw"}[5m])

# OpenClaw costs
sum(openclaw_cost_usd{service_namespace="openclaw"})

# Moltbook API request rate
rate(http_requests_total{service_namespace="moltbook"}[5m])
```

## Network Policies

The deployment creates NetworkPolicies to allow:

1. **OpenClaw pods → openclaw collector**:
   - Ports 4317/4318 (OTLP)

2. **Moltbook pods → moltbook collector**:
   - Ports 4317/4318 (OTLP)

3. **Both collectors → observability-hub collector**:
   - Ports 4317/4318 (OTLP)

All other cross-namespace traffic is blocked by default (if using default-deny policies).

## Troubleshooting

### Collector not receiving telemetry

```bash
# Check collector pods
oc get pods -n openclaw -l app.kubernetes.io/component=opentelemetry-collector
oc get pods -n moltbook -l app.kubernetes.io/component=opentelemetry-collector

# Check collector logs
oc logs -n openclaw -l app.kubernetes.io/component=opentelemetry-collector
oc logs -n moltbook -l app.kubernetes.io/component=opentelemetry-collector

# Verify services
oc get svc -n openclaw otel-collector
oc get svc -n moltbook otel-collector
```

### Apps not sending to collector

```bash
# Check app logs for OTLP errors
oc logs -n openclaw deployment/openclaw-gateway | grep -i otel
oc logs -n moltbook deployment/moltbook-api | grep -i otel

# Test connectivity from app pod
oc exec -n openclaw deployment/openclaw-gateway -- \
  curl -v http://otel-collector.openclaw.svc.cluster.local:4318/v1/traces

oc exec -n moltbook deployment/moltbook-api -- \
  curl -v http://otel-collector.moltbook.svc.cluster.local:4318/v1/traces
```

### Collector not forwarding to central collector

```bash
# Check NetworkPolicy allows egress
oc get networkpolicy -n openclaw
oc get networkpolicy -n moltbook

# Test connectivity to observability-hub
oc exec -n openclaw -l app.kubernetes.io/component=opentelemetry-collector -- \
  curl -v http://otel-collector.observability-hub.svc.cluster.local:4318/v1/traces
```

### Central collector not receiving

```bash
# Check central collector logs
oc logs -n observability-hub -l app=otel-collector

# Verify central collector service
oc get svc -n observability-hub otel-collector
```

## Resource Tuning

### Memory Limits

Default: 512Mi limit, 256Mi request

Increase if experiencing OOM:

```yaml
resources:
  requests:
    memory: 512Mi
  limits:
    memory: 1Gi
```

### CPU Limits

Default: 500m limit, 200m request

Increase for high-throughput:

```yaml
resources:
  requests:
    cpu: 500m
  limits:
    cpu: 1000m
```

### Batch Size

Default: 1024 spans/batch

Increase for higher throughput:

```yaml
processors:
  batch:
    send_batch_size: 2048
    timeout: 5s
```

## Scaling

Namespace collectors can be scaled horizontally:

```bash
# Scale openclaw collector
oc patch opentelemetrycollector otel-collector -n openclaw -p '{"spec":{"replicas":2}}'

# Scale moltbook collector
oc patch opentelemetrycollector otel-collector -n moltbook -p '{"spec":{"replicas":2}}'
```

Note: Apps will load-balance across collector replicas via the Service.

## Advanced: Auto-Instrumentation

The OpenTelemetry Operator can auto-instrument apps without code changes:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: auto-instrumentation
  namespace: moltbook
spec:
  exporter:
    endpoint: http://otel-collector.moltbook.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: always_on
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:latest
```

Then annotate the deployment:

```yaml
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-nodejs: "true"
```

## References

- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [OpenClaw Observability Docs](https://docs.openclaw.ai/observability)
- [Tempo Query Language](https://grafana.com/docs/tempo/latest/traceql/)
