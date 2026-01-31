# OpenShift Security Compliance Fixes

## OpenShift Security Constraints

OpenShift runs with the `restricted` SCC (Security Context Constraint) by default:

1. ❌ **No root user** - Containers must run as non-root
2. ⚠️ **Arbitrary UIDs** - OpenShift assigns random UIDs (not the Dockerfile USER)
3. ❌ **No privileged** - Can't use privileged mode
4. ❌ **Drop all capabilities** - Must drop all Linux capabilities
5. ⚠️ **fsGroup** - May be assigned by OpenShift
6. ❌ **No hostPath volumes** - Can only use PVCs, ConfigMaps, Secrets
7. ❌ **No hostNetwork/hostPort** - Must use Services

## Issues in Our Manifests & Fixes

### Issue 1: PostgreSQL Running as Root ❌

**Problem**:
```yaml
# postgres:16-alpine runs as postgres user (UID 70)
# But OpenShift assigns arbitrary UID (e.g., 1000680000)
# Postgres fails: "initdb: could not change permissions"
```

**Fix**: Use OpenShift-compatible PostgreSQL image

```yaml
# OLD (won't work on OpenShift)
image: postgres:16-alpine

# NEW (OpenShift-compatible)
image: registry.redhat.io/rhel8/postgresql-16:latest
# OR
image: centos/postgresql-13-centos7  # Community option
```

### Issue 2: Init Containers with BusyBox ❌

**Problem**:
```yaml
initContainers:
- name: init-config
  image: busybox:latest  # Runs as root!
```

**Fix**: Use ubi-minimal (runs as any UID)

```yaml
initContainers:
- name: init-config
  image: registry.access.redhat.com/ubi8/ubi-minimal:latest
  command:
  - sh
  - -c
  - |
    if [ ! -f /home/node/.openclaw/openclaw.json ]; then
      cp /config/openclaw.json /home/node/.openclaw/openclaw.json
      chmod 644 /home/node/.openclaw/openclaw.json
    fi
```

### Issue 3: Hardcoded securityContext ❌

**Problem**:
```yaml
securityContext:
  runAsUser: 1000  # OpenShift will override this!
  fsGroup: 1000
```

**Fix**: Let OpenShift assign UIDs

```yaml
# Remove runAsUser, fsGroup - OpenShift handles this
securityContext:
  # OpenShift will inject:
  # - runAsUser: <random-uid>
  # - fsGroup: <random-gid>
  # - seLinuxOptions: ...
```

### Issue 4: File Permissions on Volumes ❌

**Problem**:
```bash
# Volumes may not be writable by arbitrary UID
mkdir: cannot create directory: Permission denied
```

**Fix**: Use initContainer to fix permissions

```yaml
initContainers:
- name: fix-permissions
  image: registry.access.redhat.com/ubi8/ubi-minimal:latest
  command:
  - sh
  - -c
  - |
    chmod -R 777 /home/node/.openclaw
    chmod -R 777 /home/node/.openclaw/workspace
  volumeMounts:
  - name: config-volume
    mountPath: /home/node/.openclaw
  - name: workspace-volume
    mountPath: /home/node/.openclaw/workspace
  securityContext:
    runAsNonRoot: true
```

### Issue 5: Nginx Port 80 ❌

**Problem**:
```yaml
# Nginx default listens on port 80 (privileged port)
# Non-root users can't bind to ports < 1024
```

**Fix**: Listen on port 8080

```nginx
server {
  listen 8080;  # Non-privileged port
  server_name _;
  # ...
}
```

### Issue 6: Redis Persistence ❌

**Problem**:
```yaml
# Redis tries to write to /data
# May not have permissions with arbitrary UID
```

**Fix**: Configure Redis for arbitrary UID

```yaml
command:
- redis-server
- --appendonly
- "yes"
- --dir
- /tmp  # Writable by any UID
```

## Complete Fixed Manifests

### Fixed OpenClaw Deployment

See the updated manifest with:
- ✅ No hardcoded UIDs
- ✅ UBI-based init containers
- ✅ Proper volume permissions
- ✅ Drop all capabilities
- ✅ Non-root enforcement

### Fixed Moltbook PostgreSQL

Uses OpenShift-compatible PostgreSQL image:
- ✅ Runs as arbitrary UID
- ✅ Handles fsGroup assignment
- ✅ Persistent volume works with any UID

### Fixed Moltbook Frontend (Nginx)

- ✅ Listens on port 8080 (non-privileged)
- ✅ Runs as nginx user (or arbitrary UID)
- ✅ No root required

## Testing OpenShift Compliance

### Check SCC

```bash
# See which SCC is being used
oc get pod <pod-name> -n openclaw -o yaml | grep scc

# Should show: openshift.io/scc: restricted
```

### Verify No Root

```bash
# Check actual UID
oc exec -it deployment/openclaw-gateway -n openclaw -- id

# Should show: uid=1000680000(random) NOT uid=0(root)
```

### Test Volume Permissions

```bash
# Try to write to volumes
oc exec -it deployment/openclaw-gateway -n openclaw -- \
  touch /home/node/.openclaw/test.txt

# Should succeed (not "Permission denied")
```

## Common OpenShift Errors & Fixes

### Error: "container has runAsNonRoot and image will run as root"

**Fix**: Dockerfile must have `USER` directive
```dockerfile
# Add to Dockerfile
USER 1001  # Any non-root UID
```

### Error: "unable to validate against any security context constraint"

**Cause**: Trying to use privileged features

**Fix**: Remove privileged settings:
```yaml
# Remove these:
privileged: true
hostNetwork: true
hostPID: true
hostIPC: true
```

### Error: "mkdir: cannot create directory: Permission denied"

**Cause**: Volume not writable by arbitrary UID

**Fix**: Use initContainer to chmod:
```yaml
initContainers:
- name: fix-perms
  image: registry.access.redhat.com/ubi8/ubi-minimal
  command: ["sh", "-c", "chmod 777 /data"]
  volumeMounts:
  - name: data
    mountPath: /data
```

### Error: "Error: EACCES: permission denied, open '/home/node/.openclaw/config'"

**Cause**: App directory not writable

**Fix**: In Dockerfile, chmod application directories:
```dockerfile
RUN chmod -R 777 /app
USER 1001
```

## Updated Deployment Script

The `deploy-all.sh` script now includes OpenShift compliance checks:

```bash
# Verify no root containers
check_security() {
  for pod in $(oc get pods -n openclaw -o name); do
    uid=$(oc exec $pod -n openclaw -- id -u)
    if [ "$uid" == "0" ]; then
      echo "❌ $pod running as root!"
      exit 1
    fi
  done
  echo "✅ All containers running as non-root"
}
```

## Summary of Changes

| Component | Issue | Fix |
|-----------|-------|-----|
| OpenClaw | Dockerfile USER=node | ✅ Works (OpenShift overrides anyway) |
| Init containers | busybox (root) | ✅ Changed to ubi-minimal |
| PostgreSQL | postgres:alpine (UID 70) | ✅ Use registry.redhat.io/postgresql |
| Redis | Port binding issues | ✅ Use /tmp for appendonly |
| Nginx | Port 80 (privileged) | ✅ Changed to port 8080 |
| securityContext | Hardcoded UIDs | ✅ Let OpenShift assign |
| Volumes | Permission errors | ✅ Init container chmod |

All manifests are now **OpenShift restricted SCC compliant**! ✅
