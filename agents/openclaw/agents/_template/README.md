# Adding a New Agent

## Quick Start

The fastest way to add an agent:

```bash
./scripts/add-agent.sh
```

This scaffolds the files and prints the registration snippet. Or do it manually:

## Manual Setup

### 1. Copy the template

```bash
cp -r agents/openclaw/agents/_template agents/openclaw/agents/myagent
cd agents/openclaw/agents/myagent
mv agent.yaml.template myagent-agent.yaml.envsubst
```

### 2. Edit the agent files

Open `myagent-agent.yaml.envsubst` and replace all `REPLACE_` placeholders:

| Placeholder | Example | Description |
|-------------|---------|-------------|
| `REPLACE_AGENT_ID` | `myagent` | Lowercase ID (used in filenames and K8s names) |
| `REPLACE_DISPLAY_NAME` | `My Agent` | Human-readable name shown in UI |
| `REPLACE_DESCRIPTION` | `Monitors API health` | What the agent does |
| `REPLACE_EMOJI` | `🔍` | Emoji shown in UI |
| `REPLACE_COLOR` | `#FF6B6B` | Hex color for UI |

Write your agent's instructions in the `AGENTS.md` section. This is the markdown
that tells the agent who it is and what to do.

### 3. Register the agent

Add this to `agents/openclaw/agents/agents-config-patch.yaml.envsubst` in the
`agents.list` array:

```json
{
  "id": "${OPENCLAW_PREFIX}_myagent",
  "name": "My Agent",
  "workspace": "~/.openclaw/workspace-${OPENCLAW_PREFIX}_myagent",
  "subagents": {"allowAgents": ["*"]}
}
```

### 4. Deploy

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

## Adding a Scheduled Job

To give your agent a scheduled task, create a `JOB.md` in your agent's directory:

```bash
cp agents/openclaw/agents/_template/JOB.md.template \
   agents/openclaw/agents/myagent/JOB.md
```

Edit the frontmatter:

```yaml
---
id: myagent-job              # Unique job ID
schedule: "0 9 * * *"        # Cron expression (this = daily 9 AM UTC)
tz: UTC                      # Timezone
---
```

Write the job instructions in the body — this is the message your agent receives
when the job fires. Then update the running jobs:

```bash
./scripts/update-jobs.sh           # OpenShift
./scripts/update-jobs.sh --k8s     # Kubernetes
```

### Cron Schedule Examples

| Schedule | Expression |
|----------|-----------|
| Every day at 9 AM UTC | `0 9 * * *` |
| Every 8 hours | `0 */8 * * *` |
| Weekdays at 9 AM and 5 PM | `0 9,17 * * 1-5` |
| Every Monday at 8 AM | `0 8 * * 1` |
