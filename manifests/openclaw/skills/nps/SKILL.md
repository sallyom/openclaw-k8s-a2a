---
name: nps
description: Query the National Park Service agent for park information
metadata: { "openclaw": { "emoji": "\ud83c\udfde\ufe0f", "requires": { "bins": ["curl"] } } }
---

# NPS Skill -- National Park Service Queries

You can query the **NPS Agent** for information about U.S. national parks. The NPS Agent is an AI assistant running in the `nps-agent` namespace that has access to the National Park Service API. It can answer questions about parks, alerts, campgrounds, events, and visitor centers.

## How It Works

The NPS Agent runs as a standalone service with its own model and MCP tools. You send questions via HTTP and receive natural language answers. Authentication is handled transparently by the AuthBridge -- you just make the call.

## Query the NPS Agent

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": [{"role": "user", "content": "Your question about national parks here"}]}')

echo "$RESPONSE" | python3 -c "import sys,json; o=json.load(sys.stdin)['output']; print(next(c['text'] for m in reversed(o) for c in m.get('content',[]) if 'text' in c))"
```

**Important:** The NPS Agent may take up to 60 seconds on the first request (cold start). Use `--max-time 300` to allow for this.

## Input Format

The `/invocations` endpoint accepts JSON with an `input` array of messages:

```json
{"input": [{"role": "user", "content": "What national parks are in California?"}]}
```

## Output Format

The response follows the MLflow ResponsesAgent format:

```json
{
  "output": [
    {
      "type": "message",
      "role": "assistant",
      "content": [
        {
          "type": "output_text",
          "text": "California has nine national parks..."
        }
      ]
    }
  ]
}
```

Extract the answer:

```bash
echo "$RESPONSE" | python3 -c "import sys,json; o=json.load(sys.stdin)['output']; print(next(c['text'] for m in reversed(o) for c in m.get('content',[]) if 'text' in c))"
```

## What the NPS Agent Can Answer

The agent has 5 MCP tools connected to the NPS API:

| Tool | What It Does | Example Question |
|------|-------------|-----------------|
| `search_parks` | Find parks by state, code, or keyword | "What parks are in Utah?" |
| `get_park_alerts` | Current alerts and hazards | "Are there any alerts for Yellowstone?" |
| `get_park_campgrounds` | Campground info and amenities | "What campgrounds are at Grand Canyon?" |
| `get_park_events` | Upcoming events and activities | "What events are happening at Acadia?" |
| `get_visitor_centers` | Visitor center locations and hours | "Where are the visitor centers at Zion?" |

## Examples

### Find parks in a state

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": [{"role": "user", "content": "What national parks are in Colorado?"}]}')
echo "$RESPONSE" | python3 -c "import sys,json; o=json.load(sys.stdin)['output']; print(next(c['text'] for m in reversed(o) for c in m.get('content',[]) if 'text' in c))"
```

### Check park alerts

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": [{"role": "user", "content": "Are there any current alerts or closures at Yellowstone National Park?"}]}')
echo "$RESPONSE" | python3 -c "import sys,json; o=json.load(sys.stdin)['output']; print(next(c['text'] for m in reversed(o) for c in m.get('content',[]) if 'text' in c))"
```

### Get campground info

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": [{"role": "user", "content": "What campgrounds are available at the Grand Canyon and what amenities do they have?"}]}')
echo "$RESPONSE" | python3 -c "import sys,json; o=json.load(sys.stdin)['output']; print(next(c['text'] for m in reversed(o) for c in m.get('content',[]) if 'text' in c))"
```

## Health Check

Verify the NPS Agent is running:

```bash
curl -s http://nps-agent.nps-agent.svc.cluster.local:8080/ping
```

Returns `200 OK` if healthy.

## Run Agent Evaluation

You can trigger an evaluation of the NPS Agent. This runs 6 test cases (parks by state, park codes, campgrounds, alerts, visitor centers) and checks that expected facts appear in the responses.

### Trigger an eval run

```bash
oc create job nps-eval-$(date +%s) --from=cronjob/nps-eval -n nps-agent
```

### Check eval status

```bash
oc get jobs -n nps-agent -l component=eval --sort-by='{.metadata.creationTimestamp}'
```

### Read eval results

```bash
JOB_NAME=$(oc get jobs -n nps-agent -l component=eval --sort-by='{.metadata.creationTimestamp}' -o jsonpath='{.items[-1].metadata.name}')
oc logs -l job-name=$JOB_NAME -n nps-agent
```

The eval output shows pass/fail for each test case, expected facts found, latency per query, and an overall summary. Results are also logged to the NPSAgent experiment in MLflow.

### Quick eval (3 test cases only)

To run a faster eval, create the job manually:

```bash
oc create job nps-eval-quick -n nps-agent --image=image-registry.openshift-image-registry.svc:5000/nps-agent/nps-agent:latest -- python3 /eval/run_eval.py --quick --standalone
```

## Error Handling

| Error | Meaning | Action |
|-------|---------|--------|
| Connection refused | NPS Agent pod is down or not deployed | Check `oc get pods -n nps-agent` |
| Timeout (>300s) | Agent is processing a complex query or cold starting | Retry with a simpler question |
| Empty response | Agent couldn't find relevant data | Try a more specific query (include park name or state code) |
| 500 error | Agent encountered an internal error | Check NPS Agent logs: `oc logs deployment/nps-agent -n nps-agent` |
