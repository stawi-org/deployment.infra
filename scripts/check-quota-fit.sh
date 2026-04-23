#!/usr/bin/env bash
# check-quota-fit.sh — Quota-fit verification for a namespace's Kustomize output.
#
# Sums container resource requests/limits across all workload kinds
# (Deployment, StatefulSet, Pod, Job, CronJob, CNPG Cluster, CNPG Pooler,
# and HelmRelease with spec.values.resources) and compares against the
# namespace's ResourceQuota.
#
# Usage:
#   ./scripts/check-quota-fit.sh <namespace>
#
# Exit codes:
#   0  all dimensions ≥ 10% headroom (or no ResourceQuota found)
#   1  any dimension > 100% of cap (over quota)
#   2  any dimension 90–100% of cap (warning: near cap)
#
# Intended to run from the deployments repo root.

set -euo pipefail

NS="${1:?Usage: $0 <namespace>}"

# ── Locate manifest root ────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -d "${REPO_ROOT}/manifests/namespaces/${NS}" ]; then
  BASE="${REPO_ROOT}/manifests/namespaces/${NS}"
elif [ -d "${REPO_ROOT}/manifests/providers/${NS}" ]; then
  BASE="${REPO_ROOT}/manifests/providers/${NS}"
else
  echo "ERROR: no manifests found for namespace '${NS}'" \
       "(checked manifests/namespaces/ and manifests/providers/)" >&2
  exit 1
fi

# ── Render manifests ────────────────────────────────────────────────────────
if command -v kustomize &>/dev/null; then
  RENDERED=$(kustomize build "${BASE}" 2>/dev/null || true)
else
  # Fallback: concatenate all YAML files reachable from the kustomization
  # (best-effort; does not evaluate patches/overlays).
  echo "WARNING: kustomize not found — concatenating raw YAML files (patches not applied)" >&2
  RENDERED=$(find "${BASE}" \( -name "*.yaml" -o -name "*.yml" \) | sort | while IFS= read -r f; do
    printf -- '---\n'
    cat "$f"
    printf '\n'
  done 2>/dev/null || true)
fi

if [ -z "${RENDERED}" ]; then
  echo "ERROR: no manifest content produced for ${BASE}" >&2
  exit 1
fi

# ── Hand off arithmetic to inline Python ───────────────────────────────────
# Write rendered YAML to a temp file so we can feed it via stdin to the
# Python heredoc without bash's <</'PY' and <<< fighting over stdin.
_TMPFILE=$(mktemp /tmp/check-quota-fit-XXXXXX.yaml)
trap 'rm -f "${_TMPFILE}"' EXIT
printf '%s' "${RENDERED}" > "${_TMPFILE}"

python3 - "${NS}" "${REPO_ROOT}" "${_TMPFILE}" <<'PY'
import sys
import os
import re
import yaml

ns        = sys.argv[1]
root      = sys.argv[2]
yaml_path = sys.argv[3]

# ── Resource quantity parser ────────────────────────────────────────────────
# CPU → millicores (int); Memory → mebibytes (float)

_SI = {'k': 1e3, 'M': 1e6, 'G': 1e9, 'T': 1e12, 'P': 1e15, 'E': 1e18}
_BI = {'Ki': 1024, 'Mi': 1024**2, 'Gi': 1024**3, 'Ti': 1024**4,
       'Pi': 1024**5, 'Ei': 1024**6}

def parse_cpu(v):
    """Return millicores as float."""
    if v is None:
        return 0.0
    s = str(v).strip()
    if s.endswith('m'):
        return float(s[:-1])
    return float(s) * 1000.0

def parse_mem(v):
    """Return mebibytes as float."""
    if v is None:
        return 0.0
    s = str(v).strip()
    for suffix, mult in _BI.items():
        if s.endswith(suffix):
            return float(s[:-len(suffix)]) * mult / (1024**2)
    for suffix, mult in _SI.items():
        if s.endswith(suffix):
            return float(s[:-1]) * mult / (1024**2)
    return float(s) / (1024**2)

def fmt_cpu(m):
    """Format millicores for display."""
    if m >= 1000:
        return f"{m/1000:.3g}"
    return f"{m:.0f}m"

def fmt_mem(mib):
    """Format mebibytes for display."""
    if mib >= 1024:
        return f"{mib/1024:.3g}Gi"
    return f"{mib:.0f}Mi"

# ── Totals ──────────────────────────────────────────────────────────────────
totals = {
    'requests.cpu':    0.0,
    'requests.memory': 0.0,
    'limits.cpu':      0.0,
    'limits.memory':   0.0,
}
quota_hard = {}
quota_name = None
workloads_seen = []

def add_resources(res, replicas):
    """Add a single container's resources × replicas to totals."""
    if not res:
        return
    req = res.get('requests', {}) or {}
    lim = res.get('limits', {})  or {}
    totals['requests.cpu']    += parse_cpu(req.get('cpu'))    * replicas
    totals['requests.memory'] += parse_mem(req.get('memory')) * replicas
    totals['limits.cpu']      += parse_cpu(lim.get('cpu'))    * replicas
    totals['limits.memory']   += parse_mem(lim.get('memory')) * replicas

def containers_from_pod_spec(pod_spec):
    """Yield (name, resources) from a pod spec."""
    if not pod_spec:
        return
    for c in (pod_spec.get('containers') or []):
        yield c.get('name', '?'), c.get('resources') or {}
    for c in (pod_spec.get('initContainers') or []):
        yield c.get('name', '?'), c.get('resources') or {}

def replicas_from_spec(spec, hpa_max=None):
    """Conservative replica count: prefer HPA maxReplicas when present."""
    if hpa_max is not None:
        return hpa_max
    r = spec.get('replicas') if spec else None
    if r is None:
        return 1
    return int(r)

# ── Load all YAML documents from stdin ─────────────────────────────────────
with open(yaml_path, 'r') as _f:
    raw = _f.read()
try:
    docs = list(yaml.safe_load_all(raw))
except yaml.YAMLError as e:
    print(f"ERROR: YAML parse failure: {e}", file=sys.stderr)
    sys.exit(1)

docs = [d for d in docs if d and isinstance(d, dict)]

# Build an HPA index: {workload-name → maxReplicas}
hpa_index = {}
for doc in docs:
    kind = doc.get('kind', '')
    if kind == 'HorizontalPodAutoscaler':
        ref = (doc.get('spec') or {}).get('scaleTargetRef') or {}
        name = ref.get('name')
        max_r = (doc.get('spec') or {}).get('maxReplicas')
        if name and max_r is not None:
            hpa_index[name] = int(max_r)

for doc in docs:
    kind = doc.get('kind', '')
    meta = doc.get('metadata') or {}
    name = meta.get('name', '?')
    spec = doc.get('spec') or {}

    # ── ResourceQuota ────────────────────────────────────────────────────
    if kind == 'ResourceQuota':
        quota_name = name
        quota_hard = spec.get('hard') or {}
        continue

    # ── Standard workloads ───────────────────────────────────────────────
    if kind in ('Deployment', 'StatefulSet', 'ReplicaSet', 'DaemonSet'):
        hpa_max = hpa_index.get(name)
        replicas = replicas_from_spec(spec, hpa_max)
        pod_spec = ((spec.get('template') or {}).get('spec') or {})
        for cname, res in containers_from_pod_spec(pod_spec):
            add_resources(res, replicas)
        workloads_seen.append(f"{kind}/{name} ×{replicas}")
        continue

    if kind == 'Pod':
        for cname, res in containers_from_pod_spec(spec):
            add_resources(res, 1)
        workloads_seen.append(f"Pod/{name}")
        continue

    if kind == 'Job':
        pod_spec = ((spec.get('template') or {}).get('spec') or {})
        for cname, res in containers_from_pod_spec(pod_spec):
            add_resources(res, 1)
        workloads_seen.append(f"Job/{name}")
        continue

    if kind == 'CronJob':
        job_spec  = spec.get('jobTemplate') or {}
        pod_spec  = ((job_spec.get('spec') or {}).get('template') or {}).get('spec') or {}
        for cname, res in containers_from_pod_spec(pod_spec):
            add_resources(res, 1)
        workloads_seen.append(f"CronJob/{name}")
        continue

    # ── CNPG Cluster ─────────────────────────────────────────────────────
    # Each instance runs one container with spec.resources
    if kind == 'Cluster' and 'postgresql.cnpg.io' in (doc.get('apiVersion') or ''):
        instances = int(spec.get('instances', 1))
        res = spec.get('resources') or {}
        add_resources(res, instances)
        workloads_seen.append(f"CNPG-Cluster/{name} ×{instances}")
        continue

    # ── CNPG Pooler ──────────────────────────────────────────────────────
    # Pooler creates a Deployment with spec.instances pods, each running
    # one pgbouncer container described in spec.template.spec.containers
    if kind == 'Pooler':
        instances = int(spec.get('instances', 1))
        containers = ((spec.get('template') or {}).get('spec') or {}).get('containers') or []
        for c in containers:
            add_resources(c.get('resources') or {}, instances)
        workloads_seen.append(f"CNPG-Pooler/{name} ×{instances}")
        continue

    # ── HelmRelease (Flux) ────────────────────────────────────────────────
    # kustomize build won't expand HelmRelease into Deployments.
    # Parse spec.values directly using the colony chart convention.
    if kind == 'HelmRelease':
        values = spec.get('values') or {}

        # Resource spec: top-level values.resources (colony chart pattern)
        res = values.get('resources') or {}

        # Replica count: conservative = autoscaling.maxReplicas if autoscaling
        # is enabled, else values.replicaCount, else 1.
        autoscaling = values.get('autoscaling') or {}
        as_enabled  = autoscaling.get('enabled', False)
        if as_enabled and autoscaling.get('maxReplicas') is not None:
            replicas = int(autoscaling['maxReplicas'])
        elif values.get('replicaCount') is not None:
            replicas = int(values['replicaCount'])
        else:
            replicas = 1

        if res:
            add_resources(res, replicas)
            workloads_seen.append(f"HelmRelease/{name} ×{replicas} (maxReplicas)")

        # Some charts nest resources under values.<component>.resources
        # (e.g. hydra chart uses values.hydra.resources). Walk one level deep.
        for vkey, vval in values.items():
            if not isinstance(vval, dict):
                continue
            sub_res = vval.get('resources')
            if not sub_res or not isinstance(sub_res, dict):
                continue
            if vkey in ('autoscaling', 'resources', 'affinity',
                        'podDisruptionBudget', 'topologySpreadConstraints'):
                continue
            # Sub-component autoscaling
            sub_as   = vval.get('autoscaling') or {}
            sub_asen = sub_as.get('enabled', False)
            if sub_asen and sub_as.get('maxReplicas') is not None:
                sub_replicas = int(sub_as['maxReplicas'])
            elif vval.get('replicaCount') is not None:
                sub_replicas = int(vval['replicaCount'])
            else:
                sub_replicas = 1
            add_resources(sub_res, sub_replicas)
            workloads_seen.append(f"HelmRelease/{name}.{vkey} ×{sub_replicas}")

        continue

# ── Also search sibling kustomization paths for ResourceQuota ────────────────
# The datastore namespace stores its quota inline in namespace.yaml; others
# inherit from common-setup/resource-quotas.yaml. If we found no quota in the
# rendered stream, scan the common-setup file for a matching namespace field.
if not quota_hard:
    common_rq_path = os.path.join(root, 'manifests', 'common-setup', 'resource-quotas.yaml')
    if os.path.exists(common_rq_path):
        with open(common_rq_path) as f:
            try:
                for d in yaml.safe_load_all(f):
                    if not d or d.get('kind') != 'ResourceQuota':
                        continue
                    m = d.get('metadata') or {}
                    if m.get('namespace') == ns:
                        quota_name = m.get('name', '?')
                        quota_hard = (d.get('spec') or {}).get('hard') or {}
                        break
            except yaml.YAMLError:
                pass

# ── Report ───────────────────────────────────────────────────────────────────
print(f"\nNamespace: {ns}")
print(f"Workloads parsed ({len(workloads_seen)}):")
for w in workloads_seen:
    print(f"  {w}")
print()

if not quota_hard:
    print("WARNING: no ResourceQuota found for this namespace — skipping cap check.")
    print("         (unquotaed namespaces can exhaust cluster resources silently)")
    sys.exit(0)

print(f"ResourceQuota: {quota_name}")

# Dimensions we care about: only those present in the quota
dim_map = {
    'requests.cpu':    ('requests.cpu',    fmt_cpu, parse_cpu, totals['requests.cpu']),
    'requests.memory': ('requests.memory', fmt_mem, parse_mem, totals['requests.memory']),
    'limits.cpu':      ('limits.cpu',      fmt_cpu, parse_cpu, totals['limits.cpu']),
    'limits.memory':   ('limits.memory',   fmt_mem, parse_mem, totals['limits.memory']),
}

header = f"{'':20s}  {'used':>10}  {'cap':>10}  {'headroom':>9}  {'status':>4}"
print(header)
print('-' * len(header))

worst = 0   # 0=ok, 1=over, 2=warning

for dim_key, (qkey, fmt_fn, parse_fn, used_raw) in dim_map.items():
    cap_raw = quota_hard.get(qkey)
    if cap_raw is None:
        continue   # quota does not constrain this dimension

    cap  = parse_fn(str(cap_raw))
    used = used_raw

    if cap == 0:
        pct_used = 100.0 if used > 0 else 0.0
    else:
        pct_used = used / cap * 100.0

    headroom = 100.0 - pct_used

    if pct_used > 100.0:
        status = '❌'
        worst = max(worst, 1)
    elif pct_used >= 90.0:
        status = '⚠️ '
        worst = max(worst, 2)
    else:
        status = '✅'

    used_s = fmt_fn(used)
    cap_s  = fmt_fn(cap)
    hw_s   = f"{headroom:.0f}%"
    print(f"{dim_key+':':<20}  {used_s:>10}  {cap_s:>10}  {hw_s:>8}  {status}")

print()
if worst == 0:
    print("Result: ✅ All dimensions have ≥10% headroom.")
elif worst == 2:
    print("Result: ⚠️  One or more dimensions are 90–100% of cap (near limit).")
else:
    print("Result: ❌ One or more dimensions EXCEED the quota cap.")

sys.exit(worst if worst != 2 else 2)
PY
