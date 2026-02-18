# CLAUDE.md - Complete Guide for AI Assistants

> **Context and instructions for AI assistants working with this repository**

## What This Repo Is

- **OpenClaw**: AI agent runtime environment (gateway, workspaces, cron jobs)
- **Deployment**: Pre-built container images, deployed via kustomize overlays on K8s/OpenShift
- **Security**: OpenShift `restricted` SCC compliant, exec allowlist, tool deny lists, OAuth proxy

## Deployment Flow (Two Steps)

### Step 1: `./scripts/setup.sh` (or `./scripts/setup.sh --k8s`)

Interactive script that:
1. Prompts for a **namespace prefix** (e.g., `sally`) — creates `sally-openclaw` namespace
2. Auto-detects cluster domain (OpenShift) or skips routes (K8s)
3. Generates secrets into `.env` (git-ignored)
4. Runs `envsubst` on all `.envsubst` templates to produce deployment YAML
5. Deploys OpenClaw gateway to `<prefix>-openclaw` namespace

### Step 2: `./scripts/setup-agents.sh` (or `./scripts/setup-agents.sh --k8s`)

Requires Step 1 complete and OpenClaw running. Interactive script that:
1. Prompts to **customize the default agent name** (default: "Shadowman", e.g., rename to "Lynx")
2. Runs `envsubst` on agent templates
3. Deploys agent ConfigMaps and RBAC
4. Installs agent identity files (AGENTS.md, agent.json) into workspaces
5. Sets up cron jobs for scheduled agent tasks

### Other Scripts

- `./scripts/export-config.sh` — Export live `openclaw.json` from the running pod (captures UI changes)
- `./scripts/update-jobs.sh` — Update cron jobs and resource-report script without full re-deploy
- `./scripts/teardown.sh` — Remove namespace, OAuthClients, PVCs
- `./scripts/build-and-push.sh` — Build images with podman (only needed if modifying source)

## Repository Structure

```
openclaw-k8s/
├── scripts/
│   ├── setup.sh                 # Step 1: Deploy platform
│   ├── setup-agents.sh          # Step 2: Deploy agents, RBAC, cron jobs
│   ├── update-jobs.sh           # Update cron jobs + resource-report script
│   ├── export-config.sh         # Export live config from running pod
│   ├── teardown.sh              # Remove everything
│   └── build-and-push.sh       # Build images with podman (optional)
│
├── .env                         # Generated secrets (GIT-IGNORED)
│
├── manifests/
│   └── openclaw/
│       ├── base/                # Core: deployment, service, PVCs, quotas
│       ├── base-k8s/            # K8s-specific base (no Routes/OAuth)
│       ├── overlays/
│       │   ├── openshift/       # OpenShift overlay (secrets, config, OAuth, routes)
│       │   │   └── config-patch.yaml.envsubst   # Main gateway config template
│       │   └── k8s/             # Vanilla Kubernetes overlay
│       ├── llm/                 # vLLM reference deployment (GPU model server)
│       ├── skills/              # Reusable agent skills
│       │   └── nps/SKILL.md     # NPS Agent query skill
│       └── agents/              # Agent configs, RBAC, cron jobs
│           ├── shadowman/       # Default agent (customizable name)
│           │   └── shadowman-agent.yaml.envsubst
│           ├── resource-optimizer/  # Resource Optimizer agent
│           │   ├── resource-optimizer-agent.yaml.envsubst
│           │   ├── resource-optimizer-rbac.yaml.envsubst
│           │   └── resource-report-cronjob.yaml.envsubst
│           ├── mlops-monitor/   # MLOps Monitor agent
│           │   ├── mlops-monitor-agent.yaml.envsubst
│           │   ├── mlops-monitor-rbac.yaml.envsubst
│           │   └── mlops-monitor-cronjob.yaml.envsubst
│           ├── audit-reporter/  # Compliance monitoring (future)
│           ├── agents-config-patch.yaml.envsubst  # Agent list config overlay
│           └── remove-custom-agents.sh            # Cleanup script
│
├── manifests/
│   └── nps-agent/               # NPS Agent (separate namespace, own SPIFFE identity)
│       ├── nps-agent-deployment.yaml.envsubst  # Deployment with A2A + AuthBridge sidecars
│       ├── nps-agent-a2a-bridge.yaml           # A2A bridge for /invocations API
│       ├── nps-agent-eval.yaml                 # Eval script ConfigMap (6 test cases)
│       ├── nps-agent-eval-job.yaml.envsubst    # CronJob: weekly eval + on-demand trigger
│       ├── nps-agent-buildconfig.yaml          # S2I build from GitHub repo
│       ├── npsagent-patch.yaml                 # vLLM compatibility patch (ChatCompletions)
│       ├── nps-agent-service.yaml              # Service (A2A on 8080, invocations on 8090)
│       ├── nps-agent-route.yaml                # OpenShift Route
│       └── nps-agent-rbac.yaml                 # SA + SCC RBAC
│
├── observability/               # OTEL sidecar and collector templates
│   ├── openclaw-otel-sidecar.yaml.envsubst
│   └── vllm-otel-sidecar.yaml.envsubst
│
└── docs/                        # Architecture, observability, deployment docs
```

## Key Design Decisions

### 1. Per-User Namespaces with Prefixed Agents

Each team member gets their own OpenClaw namespace (`<prefix>-openclaw`).

The `${OPENCLAW_PREFIX}` variable is used throughout templates. The default agent name uses `${SHADOWMAN_CUSTOM_NAME}` (ID) and `${SHADOWMAN_DISPLAY_NAME}` (display name), set interactively during `setup-agents.sh` and saved to `.env`.

### 2. envsubst Template System

- `.envsubst` files contain `${VAR}` placeholders and are committed to Git
- `.env` file contains real secrets and is git-ignored
- `setup.sh` runs `envsubst` with an explicit variable list to protect non-env placeholders like `{agentId}`
- Generated `.yaml` files are git-ignored

**Variable list** (from setup.sh):
```
${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE}
${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET}
${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${MODEL_ENDPOINT} ${DEFAULT_AGENT_MODEL}
${ANTHROPIC_API_KEY} ${GOOGLE_CLOUD_PROJECT} ${GOOGLE_CLOUD_LOCATION}
```

### 3. Config Lifecycle (Important)

```
.envsubst template    -->    ConfigMap    -->    PVC (live config)
(source of truth)          (K8s object)        /home/node/.openclaw/openclaw.json
                         setup.sh runs         init container copies
                         envsubst + deploy     on EVERY pod restart
```

- The init container copies `openclaw.json` from ConfigMap to PVC **on every restart** (no guard)
- UI changes write to PVC only — they are lost on next pod restart
- Use `./scripts/export-config.sh` to capture live config before it gets overwritten
- Update the `.envsubst` template with exported changes, replacing concrete values with `${VAR}` placeholders

### 4. Agent Registration Ordering

In `setup-agents.sh`, ConfigMaps are applied AFTER the kustomize config patch. The base kustomization includes a default `shadowman-agent` ConfigMap that would overwrite custom agent ConfigMaps if applied later.

### 5. Init Container Idempotency

The init container in `base/openclaw-deployment.yaml`:
- Always overwrites `openclaw.json` from ConfigMap (no guard)
- Only copies default workspace files (AGENTS.md, agent.json) if they don't already exist (`if [ ! -f ... ]` guard)
- Creates agent session directories dynamically from config

### 6. OpenShift Security Compliance

All manifests comply with `restricted` SCC:
- No root containers (arbitrary UIDs)
- No privileged mode, drop all capabilities
- Non-privileged ports only (8080 for nginx, not 80)
- ReadOnlyRootFilesystem support
- ResourceQuota (4 CPU, 8Gi RAM per namespace)
- PodDisruptionBudget, NetworkPolicy

### 7. OpenShift OAuth Integration

**Known issue**: `oc apply` on an existing OAuthClient can corrupt its internal secret state, causing 500 "unauthorized_client" errors after login. Fix: delete and recreate the OAuthClient.

## Pre-Built Agents

| Agent | ID Pattern | Description | Model | Schedule |
|-------|-----------|-------------|-------|----------|
| Default | `<prefix>_<custom_name>` | Interactive agent (customizable name) | Anthropic Claude | On-demand |
| Resource Optimizer | `<prefix>_resource_optimizer` | K8s resource analysis | In-cluster | Every 8 hours |
| MLOps Monitor | `<prefix>_mlops_monitor` | NPS Agent performance monitoring via MLflow | In-cluster | Every 6 hours |

### NPS Agent (Separate Namespace)

The NPS Agent is a standalone AI agent that answers questions about U.S. national parks. It deploys to its own namespace (`nps-agent`) with its own SPIFFE identity, A2A bridge, and AuthBridge sidecars.

| Component | Details |
|-----------|---------|
| Source | https://github.com/Nehanth/nps_agent (S2I build) |
| API | `/invocations` on port 8090, A2A bridge on port 8080 |
| Model | In-cluster vLLM (`openai/gpt-oss-20b`) via `OpenAIChatCompletionsModel` |
| MCP Tools | `search_parks`, `get_park_alerts`, `get_park_campgrounds`, `get_park_events`, `get_visitor_centers` |
| Eval | CronJob weekly Monday 8 AM UTC, or on-demand: `oc create job nps-eval-$(date +%s) --from=cronjob/nps-eval -n nps-agent` |
| Deploy script | `./scripts/setup-nps-agent.sh` |
| Tracing | MLflow experiment "NPSAgent" |

The default agent has an **nps** skill that queries the NPS Agent via curl. The MLOps Monitor agent watches the NPS Agent's MLflow traces and eval results.

Agent workspaces follow the pattern `~/.openclaw/workspace-<agent_id>`. Each workspace contains:
- `AGENTS.md` — Agent identity and instructions
- `agent.json` — Agent registration data (name, description)

## Directory Structure Inside Pod

```
~/.openclaw/
├── openclaw.json                                    # Gateway config (from ConfigMap)
├── agents/                                          # Agent metadata and sessions
│   ├── <prefix>_<custom_name>/sessions/             # Session transcripts
│   ├── <prefix>_resource_optimizer/sessions/
│   └── <prefix>_mlops_monitor/sessions/
├── workspace/                                       # Default workspace
├── workspace-<prefix>_<custom_name>/                # Custom agent workspace
│   ├── AGENTS.md
│   └── agent.json
├── workspace-<prefix>_resource_optimizer/
│   ├── AGENTS.md
│   ├── agent.json
│   └── .env                                         # OC_TOKEN (K8s SA token)
├── workspace-<prefix>_mlops_monitor/
│   ├── AGENTS.md
│   └── agent.json
├── skills/
│   └── nps/SKILL.md                                 # NPS Agent query skill
├── cron/jobs.json                                   # Cron job definitions
└── scripts/resource-report.sh                       # Resource analysis script
```

## Critical Files to Know

| File | Purpose |
|------|---------|
| `manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst` | Main OpenClaw gateway config (models, agents, tools, gateway settings) |
| `manifests/openclaw/agents/agents-config-patch.yaml.envsubst` | Agent list overlay (applied by setup-agents.sh) |
| `manifests/openclaw/agents/shadowman/shadowman-agent.yaml.envsubst` | Default agent ConfigMap (AGENTS.md + agent.json, customizable name) |
| `manifests/openclaw/base/openclaw-deployment.yaml` | Gateway deployment with init container |
| `scripts/setup.sh` | Platform deployment (Step 1) |
| `scripts/setup-agents.sh` | Agent deployment (Step 2) |
| `scripts/export-config.sh` | Export live config from pod |
| `scripts/teardown.sh` | Full teardown |

## Environment Variables (.env)

| Variable | Source | Used By |
|----------|--------|---------|
| `CLUSTER_DOMAIN` | Auto-detected (OpenShift) or empty (K8s) | Routes, OAuthClient redirects |
| `OPENCLAW_PREFIX` | User prompt | Namespace name, agent ID prefix |
| `OPENCLAW_NAMESPACE` | Derived: `<prefix>-openclaw` | All K8s resources |
| `OPENCLAW_GATEWAY_TOKEN` | Auto-generated | Gateway auth |
| `OPENCLAW_OAUTH_CLIENT_SECRET` | Auto-generated | OAuth proxy |
| `OPENCLAW_OAUTH_COOKIE_SECRET` | Auto-generated (32 bytes) | OAuth proxy cookie |
| `ANTHROPIC_API_KEY` | User prompt (optional) | Agents using Claude |
| `MODEL_ENDPOINT` | User prompt (default: `http://vllm.openclaw-llms.svc.cluster.local/v1`) | In-cluster model provider URL (`nerc` provider baseUrl) |
| `VERTEX_ENABLED` | User prompt (default: `false`) | Whether Google Vertex AI is configured |
| `GOOGLE_CLOUD_PROJECT` | User prompt (if Vertex enabled) | GCP project ID for Vertex AI |
| `GOOGLE_CLOUD_LOCATION` | User prompt (default: `us-central1`) | GCP region for Vertex AI |
| `VERTEX_SA_JSON_PATH` | User prompt (if Vertex enabled) | Local path to GCP service account JSON (used to create K8s secret) |
| `SHADOWMAN_CUSTOM_NAME` | User prompt in setup-agents.sh | Default agent ID component |
| `SHADOWMAN_DISPLAY_NAME` | User prompt in setup-agents.sh | Default agent display name |
| `DEFAULT_AGENT_MODEL` | Derived from API key availability | Model ID for the default agent |
| `MLFLOW_TRACKING_URI` | User prompt in setup-agents.sh (saved to .env) | MLOps monitor MLflow endpoint |

## Common Tasks

### Redeploy after manifest changes
```bash
./scripts/setup.sh          # Re-runs envsubst + deploys everything
```

### Re-deploy agents only
```bash
./scripts/setup-agents.sh   # Idempotent: re-registers and configures
```

### Export and persist UI config changes
```bash
./scripts/export-config.sh
# Compare, then update the .envsubst template with changes
# Replace concrete values with ${VAR} placeholders where needed
```

### Restart OpenClaw to pick up config changes
```bash
oc rollout restart deployment/openclaw -n <prefix>-openclaw
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=120s
```

### Full teardown and redeploy
```bash
./scripts/teardown.sh
./scripts/setup.sh
# Wait for OpenClaw to be ready, then:
./scripts/setup-agents.sh
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| OAuthClient 500 "unauthorized_client" | `oc apply` corrupted OAuthClient secret state | `oc delete oauthclient <name> && oc apply -f oauthclient.yaml` |
| Workspace directory doesn't exist | First deploy, directory not yet created | setup-agents.sh runs `mkdir -p` before copying files |
| Agent shows wrong name in UI | Init container overwrote workspace files, or browser cache | Re-run setup-agents.sh; clear browser localStorage |
| Config changes lost after restart | Init container overwrites PVC config from ConfigMap | Export with export-config.sh, update .envsubst template |
| Kustomize overwrites agent ConfigMap | Base kustomization includes default shadowman-agent | setup-agents.sh applies agent ConfigMaps AFTER kustomize |
