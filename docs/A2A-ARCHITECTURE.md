# A2A Cross-Namespace Agent Communication

## Overview

OpenClaw instances communicate across Kubernetes namespaces using Google's [Agent-to-Agent (A2A)](https://github.com/google/A2A) protocol. Each instance runs an A2A bridge sidecar that translates between A2A JSON-RPC and OpenClaw's internal API. Authentication is handled transparently by an Envoy-based AuthBridge that exchanges SPIFFE workload identities for OAuth tokens via Keycloak.

This architecture demonstrates zero-trust agent communication where:
- Each OpenClaw instance has a cryptographic workload identity (SPIFFE)
- No shared secrets or API keys between instances
- All cross-namespace traffic is authenticated and auditable
- The gateway container remains fully hardened (read-only FS, dropped capabilities, no privilege escalation)

## Architecture

```
 Sally's Namespace (sallyom-openclaw)              Bob's Namespace (bob-openclaw)
 ┌────────────────────────────────────┐            ┌────────────────────────────────────┐
 │  OpenClaw Pod                      │            │  OpenClaw Pod                      │
 │                                    │            │                                    │
 │  ┌──────────┐    ┌──────────────┐  │            │  ┌──────────────┐    ┌──────────┐  │
 │  │  Lynx    │    │   A2A Bridge │  │            │  │  A2A Bridge  │    │ Shadowman│  │
 │  │  Agent   │    │   :8080      │  │            │  │  :8080       │    │  Agent   │  │
 │  └────┬─────┘    └──────┬───────┘  │            │  └──────┬───────┘    └────┬─────┘  │
 │       │                 │          │            │         │                 │        │
 │  ┌────┴─────────────────┴───────┐  │            │  ┌──────┴─────────────────┴─────┐  │
 │  │     OpenClaw Gateway         │  │            │  │     OpenClaw Gateway         │  │
 │  │     :18789                   │  │            │  │     :18789                   │  │
 │  └──────────────────────────────┘  │            │  └──────────────────────────────┘  │
 │                                    │            │                                    │
 │  ┌──────────────────────────────┐  │            │  ┌──────────────────────────────┐  │
 │  │     AuthBridge (Envoy)       │  │  A2A/HTTP  │  │     AuthBridge (Envoy)       │  │
 │  │  ┌─────────┐ ┌────────────┐  │  │◄──────────►│  │ ┌────────────┐ ┌─────────┐   │  │
 │  │  │ SPIFFE  │ │  Token     │  │  │            │  │ │   Token    │ │ SPIFFE  │   │  │
 │  │  │ Helper  │ │  Exchange  │  │  │            │  │ │  Exchange  │ │ Helper  │   │  │
 │  │  └─────────┘ └────────────┘  │  │            │  │ └────────────┘ └─────────┘   │  │
 │  └──────────────────────────────┘  │            │  └──────────────────────────────┘  │
 └────────────────────────────────────┘            └────────────────────────────────────┘
          │                                                    │
          ▼                                                    ▼
 ┌─────────────────┐                                ┌─────────────────┐
 │  SPIRE Agent    │         Trust Domain:          │  SPIRE Agent    │
 │  (DaemonSet)    │    demo.example.com            │  (DaemonSet)    │
 └────────┬────────┘                                └────────┬────────┘
          │                                                  │
          ▼                                                  ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │                      Keycloak (spiffe-demo)                        │
 │   Realm: spiffe-demo                                               │
 │   Clients auto-registered per SPIFFE ID                            │
 └────────────────────────────────────────────────────────────────────┘
```

## Message Flow

When Lynx (Sally's agent) sends a message to Shadowman (Bob's agent):

```
1. Lynx executes:  curl -X POST http://openclaw.bob-openclaw.svc.cluster.local:8080/

2. proxy-init iptables rules redirect outbound traffic to Envoy (:15123)

3. Envoy outbound listener:
   a. ext_proc filter calls token processor (:9090)
   b. Processor reads SPIFFE JWT from /opt/jwt_svid.token
   c. Processor exchanges SPIFFE JWT for Keycloak OAuth token
   d. OAuth token injected as Authorization header

4. Request arrives at Bob's pod → Envoy inbound listener (:15124)
   a. Validates OAuth token against Keycloak
   b. Strips auth header, forwards to A2A bridge (:8080)

5. A2A bridge:
   a. Parses JSON-RPC message/send request
   b. Extracts text from A2A message parts
   c. Translates to OpenAI chat completions format
   d. Calls gateway at 127.0.0.1:18789 with bearer token
   e. Wraps response in A2A JSON-RPC format

6. Response travels back through Envoy to Lynx
```

## Pod Components

Each OpenClaw pod contains 7 containers (2 init + 5 runtime):

### Init Containers

| Container | Image | Purpose |
|-----------|-------|---------|
| `proxy-init` | `kagenti-extensions/proxy-init` | iptables rules for transparent Envoy interception |
| `init-config` | `ubi9-minimal` | Copies openclaw.json and agent configs to PVC |

### Runtime Containers

| Container | Port | Purpose | Security |
|-----------|------|---------|----------|
| `gateway` | 18789 | OpenClaw agent runtime | Read-only FS, all caps dropped, no escalation |
| `a2a-bridge` | 8080 | A2A JSON-RPC ↔ OpenAI translation | Read-only FS, non-root, all caps dropped |
| `oauth-proxy` | 8443 | OpenShift OAuth for UI access | Read-only FS, all caps dropped |
| `spiffe-helper` | - | Fetches X.509 + JWT SVIDs from SPIRE | `spc_t` SELinux for CSI access |
| `client-registration` | - | Registers OAuth client in Keycloak | `spc_t` SELinux |
| `envoy-proxy` | 15123, 15124 | Transparent token exchange proxy | Runs as UID 1337 |

## A2A Bridge

The A2A bridge (`manifests/openclaw/base/a2a-bridge-configmap.yaml`) is a lightweight Node.js HTTP server that implements two roles:

### Agent Discovery

Serves an agent card at `/.well-known/agent.json` (and `/.well-known/agent-card.json` for backward compatibility). The card is built dynamically from `openclaw.json` — each agent in `agents.list[]` becomes a skill:

```json
{
  "name": "openclaw",
  "url": "http://openclaw.<namespace>.svc.cluster.local:8080",
  "capabilities": { "streaming": false },
  "skills": [
    { "id": "sallyom_lynx", "name": "Lynx", "description": "Chat with Lynx" }
  ]
}
```

### Protocol Translation

Translates A2A `message/send` JSON-RPC requests into OpenAI `/v1/chat/completions` calls against the local gateway:

```
A2A request:                              OpenAI request:
{                                         {
  "method": "message/send",        →        "model": "nerc/openai/gpt-oss-20b",
  "params": {                               "messages": [{
    "message": {                              "role": "user",
      "parts": [{"text": "Hi"}]               "content": "Hi"
    }                                       }]
  }                                       }
}
```

## AuthBridge (Zero-Trust Identity)

The AuthBridge pattern provides transparent mutual authentication between OpenClaw instances without application code changes. It consists of four sidecar containers working together:

### 1. SPIFFE Helper

Fetches workload identity credentials from the SPIRE agent via CSI volume:
- X.509 SVID certificate + key (for mTLS)
- JWT SVID token (for Keycloak exchange)
- Output: `/opt/svid.pem`, `/opt/svid_key.pem`, `/opt/jwt_svid.token`

Identity format: `spiffe://demo.example.com/ns/<namespace>/sa/openclaw-oauth-proxy`

### 2. Client Registration

Waits for SPIFFE credentials, then registers the OpenClaw instance as an OAuth client in Keycloak:
- Client ID = SPIFFE ID (unique per namespace)
- Enables token exchange for outbound calls
- Writes credentials to `/shared/client-id.txt` and `/shared/client-secret.txt`

### 3. Envoy Proxy

Transparent proxy that intercepts all pod network traffic via iptables rules set by `proxy-init`:

- **Outbound** (port 15123): Calls `ext_proc` to exchange SPIFFE JWT for Keycloak OAuth token, injects `Authorization` header
- **Inbound** (port 15124): Validates incoming OAuth tokens against Keycloak before forwarding to the A2A bridge

### 4. Proxy Init (init container)

Configures iptables to redirect traffic through Envoy. Excluded ports prevent interception of:
- Internal traffic: 18789 (gateway), 18790 (bridge WS)
- Health probes: 8080 (A2A bridge), 8443 (OAuth proxy)
- OTEL: 4317, 4318 (collector)
- External HTTPS: 443 (model API calls)

## Custom SCC (OpenShift)

The `openclaw-authbridge` SCC (`manifests/openclaw/base/openclaw-scc.yaml`) grants only the capabilities the AuthBridge sidecars require:

| Capability | Container | Reason |
|-----------|-----------|--------|
| `NET_ADMIN`, `NET_RAW` | proxy-init | iptables rules for transparent interception |
| `spc_t` SELinux | spiffe-helper, client-registration | Access SPIRE CSI volume |
| `RunAsAny` user | proxy-init (UID 0), envoy (UID 1337) | Sidecar runtime requirements |
| CSI volumes | spiffe-helper | SPIRE agent socket mount |

The SCC preserves `fsGroup: MustRunAs`, so the gateway container runs with the namespace-assigned GID in supplemental groups. This means the gateway's hardened security posture is unchanged:

```yaml
# Gateway container security (unchanged from restricted SCC)
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
    - ALL
```

Grant the SCC to the service account:
```bash
oc adm policy add-scc-to-user openclaw-authbridge -z openclaw-oauth-proxy -n <namespace>
```

## A2A Skill

The A2A skill (`manifests/openclaw/skills/a2a/SKILL.md`) teaches agents how to communicate with other OpenClaw instances. It is deployed as a ConfigMap and copied into the agent's skill directory at `/home/node/.openclaw/skills/a2a/SKILL.md`.

The skill instructs agents to:

1. **Discover** remote agents via `curl ... /.well-known/agent.json | jq .`
2. **Send messages** via A2A `message/send` JSON-RPC
3. **Relay information** to local agents via `sessions_send`

Agents never handle authentication — the AuthBridge does it transparently. The skill uses only `curl` and `jq` (both in the gateway's `safeBins` allowlist).

## Cluster Prerequisites

The A2A/AuthBridge feature depends on three external components that must be running in the cluster before deploying OpenClaw. These provide the identity infrastructure that makes zero-trust cross-namespace communication possible.

### 1. SPIRE (SPIFFE Runtime Environment)

SPIRE provides cryptographic workload identity via the SPIFFE standard. Each OpenClaw pod gets an X.509 certificate and JWT token that uniquely identify it by namespace and service account.

**What must be deployed:**

| Component | Purpose |
|-----------|---------|
| SPIRE Server | Issues and manages workload identities (SVIDs) |
| SPIRE Agent (DaemonSet) | Runs on each node, attests workloads, serves SVIDs to pods |
| SPIFFE CSI Driver (`csi.spiffe.io`) | Exposes the SPIRE agent socket as a CSI volume so pods can request identities without hostPath mounts |

**Namespace:** Typically `spiffe-system`

**Trust domain:** `demo.example.com` (configurable — must match Keycloak realm federation)

**Registration entries:** Each OpenClaw namespace needs a SPIRE registration entry that maps the pod's service account to a SPIFFE ID:

```
spiffe://demo.example.com/ns/<namespace>/sa/openclaw-oauth-proxy
```

Example registration (via SPIRE Server CLI or CRD):
```bash
spire-server entry create \
  -spiffeID spiffe://demo.example.com/ns/sallyom-openclaw/sa/openclaw-oauth-proxy \
  -parentID spiffe://demo.example.com/agent/<node-id> \
  -selector k8s:ns:sallyom-openclaw \
  -selector k8s:sa:openclaw-oauth-proxy
```

**How OpenClaw uses it:**
- `spiffe-helper` sidecar connects to the agent socket at `/run/spire/agent-sockets/spire-agent.sock` (mounted via CSI volume)
- Fetches X.509 SVID → `/opt/svid.pem`, `/opt/svid_key.pem`
- Fetches JWT SVID (audience: `kagenti`) → `/opt/jwt_svid.token`
- JWT is passed to client-registration and used by the token processor for Keycloak exchange

**Configuration:** `manifests/openclaw/base/authbridge-configmaps.yaml` (spiffe-helper-config section)

### 2. Keycloak

Keycloak acts as the OAuth authorization server. It validates SPIFFE JWTs and issues OAuth tokens that remote instances can verify. This is what makes cross-namespace calls authenticated — Envoy exchanges the local SPIFFE JWT for a Keycloak OAuth token before each outbound call.

**What must be deployed:**

| Component | Purpose |
|-----------|---------|
| Keycloak Server | OIDC provider with token exchange support |
| Realm: `spiffe-demo` | Pre-configured realm that trusts the SPIRE trust domain |

**Namespace:** `spiffe-demo` (current deployment)

**Required Keycloak configuration:**
- Token exchange enabled (RFC 8693 `urn:ietf:params:oauth:grant-type:token-exchange`)
- Dynamic client registration enabled (OpenClaw pods self-register on startup)
- SPIFFE JWT issuer trusted as an identity provider in the realm
- Admin API accessible for client registration (used by `client-registration` sidecar)

**How OpenClaw uses it:**
- `client-registration` sidecar registers the pod as an OAuth client using the SPIFFE ID as the client ID
- `envoy-with-processor` exchanges SPIFFE JWTs for Keycloak OAuth tokens on outbound requests
- On inbound requests, Envoy validates the caller's OAuth token against Keycloak

**Configuration:**
- `manifests/openclaw/base/authbridge-configmaps.yaml` — Keycloak URL, realm, admin credentials
- `manifests/openclaw/base/authbridge-secret.yaml` — Token endpoint, issuer, target audience

**Current values (cluster-specific, update for your environment):**
```
KEYCLOAK_URL:  https://keycloak-spiffe-demo.apps.ocp-demo.com
KEYCLOAK_REALM: spiffe-demo
TOKEN_URL:     https://keycloak-spiffe-demo.apps.ocp-demo.com/realms/spiffe-demo/protocol/openid-connect/token
```

### 3. Kagenti Extension Images

The AuthBridge sidecars use container images from the [Kagenti](https://github.com/kagenti) project. These are pulled from `ghcr.io/kagenti/` at pod startup — no operator or CRD installation is required.

| Image | Container | Purpose |
|-------|-----------|---------|
| `ghcr.io/kagenti/kagenti-extensions/proxy-init` | `proxy-init` (init) | iptables rules for transparent Envoy interception |
| `ghcr.io/kagenti/kagenti-extensions/client-registration` | `client-registration` | Registers OAuth client in Keycloak using SPIFFE identity |
| `ghcr.io/kagenti/kagenti-extensions/envoy-with-processor` | `envoy-proxy` | Envoy proxy + ext_proc token exchange processor |
| `ghcr.io/spiffe/spiffe-helper` | `spiffe-helper` | Fetches SVIDs from SPIRE agent |

The Kagenti operator itself (`kagenti-system` namespace) is **not required**. OpenClaw uses Kagenti labels (`kagenti.io/type: agent`, etc.) for future discovery but does not depend on the operator for any runtime functionality. See the note in `manifests/openclaw/base/kustomization.yaml`.

### Dependency Diagram

```
┌────────────────────────────────────────────────────────── ┐
│  Your Cluster                                             │
│                                                           │
│  ┌─────────────────┐    ┌───────────────────────────── ┐  │
│  │  spiffe-system   │    │  spiffe-demo                │  │
│  │                  │    │                             │  │
│  │  SPIRE Server    │    │  Keycloak                   │  │
│  │  SPIRE Agent     │◄───│  Realm: spiffe-demo         │  │
│  │  CSI Driver      │    │  Token exchange enabled     │  │
│  │                  │    │  Client registration enabled│  │
│  └────────┬─────────┘    └──────────┬──────────────────┘  │
│           │ SVIDs                    │ OAuth tokens       │
│           ▼                         ▼                     │
│  ┌────────────────────────────────────────────────────┐   │
│  │  <prefix>-openclaw                                 │   │
│  │                                                    │   │
│  │  spiffe-helper ──► client-registration ──► envoy   │   │
│  │  (gets SVIDs)      (registers client)     (token   │   │
│  │                                           exchange)│   │
│  │                    gateway ◄── a2a-bridge          │   │
│  └────────────────────────────────────────────────────┘   │
│                                                           │
│  ┌────────────────────────────────────────────────────┐   │
│  │  <other-prefix>-openclaw (same pattern)            │   │
│  └────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────── ┘
```

## Deployment

### Setup

```bash
# 1. Deploy OpenClaw (creates namespace, deploys pod, installs A2A skill)
./scripts/setup.sh          # OpenShift
./scripts/setup.sh --k8s    # Vanilla K8s (no AuthBridge)

# 2. Grant SCC (OpenShift only)
oc adm policy add-scc-to-user openclaw-authbridge \
  -z openclaw-oauth-proxy -n <namespace>

# 3. Deploy agents (optional — adds resource-optimizer, cron jobs)
./scripts/setup-agents.sh
```

### Verification

```bash
# Check agent card
curl -s http://openclaw.<namespace>.svc.cluster.local:8080/.well-known/agent.json | jq .

# Check SPIFFE identity
oc exec deployment/openclaw -c spiffe-helper -- cat /opt/jwt_svid.token | \
  cut -d. -f2 | base64 -d 2>/dev/null | jq .sub

# Test cross-namespace A2A call
oc exec deployment/openclaw -c gateway -- \
  curl -s -X POST http://openclaw.<remote-namespace>.svc.cluster.local:8080/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Hello from my namespace"}]}}}'
```

## Network Flow Diagram

```
                    ┌─────────────────────┐
                    │   K8s Service       │
                    │   openclaw:8080     │
                    │   (A2A endpoint)    │
                    └──────────┬──────────┘
                               │
 Inbound ──────────────────────┼──────────────────────── Outbound
                               │
  ┌────────────────────────────┼────────────────────────────────┐
  │  Pod                       │                                │
  │                            ▼                                │
  │  ┌───────────────────────────────────────────────────────┐  │
  │  │  iptables (proxy-init)                                │  │
  │  │                                                       │  │
  │  │  Inbound:  → port 15124 (Envoy)                       │  │
  │  │  Outbound: → port 15123 (Envoy)                       │  │
  │  │                                                       │  │
  │  │  Excluded inbound:  8080, 8443, 18789, 18790          │  │
  │  │  Excluded outbound: 443, 4317, 4318, 18789            │  │
  │  └───────────────────────────────────────────────────────┘  │
  │                                                             │
  │  ┌─────────────┐  ┌────────────┐  ┌──────────────────────┐  │
  │  │ Envoy       │  │ Token      │  │ SPIFFE Helper        │  │
  │  │ :15123 out  │──│ Processor  │──│ → /opt/jwt_svid.token│  │
  │  │ :15124 in   │  │ :9090      │  │ → /opt/svid.pem      │  │
  │  └──────┬──────┘  └────────────┘  └──────────────────────┘  │
  │         │                                                   │
  │         ▼                                                   │
  │  ┌─────────────┐  ┌──────────────────────────────────────┐  │
  │  │ A2A Bridge  │  │ Gateway                              │  │
  │  │ :8080       │──│ :18789                               │  │
  │  │ JSON-RPC    │  │ OpenAI-compatible API                │  │
  │  └─────────────┘  └──────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `manifests/openclaw/base/a2a-bridge-configmap.yaml` | A2A bridge Node.js server |
| `manifests/openclaw/base/openclaw-deployment.yaml` | Pod spec with all 7 containers |
| `manifests/openclaw/base/openclaw-scc.yaml` | Custom SCC for AuthBridge |
| `manifests/openclaw/base/authbridge-configmaps.yaml` | SPIFFE/Keycloak/Envoy config |
| `manifests/openclaw/base/authbridge-secret.yaml` | Token exchange parameters |
| `manifests/openclaw/skills/a2a/SKILL.md` | A2A skill for agents |
| `manifests/openclaw/skills/kustomization.yaml` | Skill ConfigMap generator |
| `manifests/openclaw/skills/install-a2a-skill.sh` | Install skill into running pod |

## Limitations

- **No streaming**: A2A bridge handles `message/stream` as non-streaming (full response returned at once)
- **Single-turn**: Each `message/send` creates a new session — no multi-turn conversation context across calls
- **Kagenti operator gap**: The Kagenti Agent CR takes over Deployment lifecycle, overwriting env vars, volumes, and sidecars. Until the operator supports "unmanaged" agents, we use the A2A bridge for protocol compatibility but skip operator-level discovery. See comments in `manifests/openclaw/base/kustomization.yaml`.
- **K8s mode**: When deployed with `--k8s` (no OpenShift), the AuthBridge sidecars are not present. Cross-namespace calls work but are unauthenticated.
