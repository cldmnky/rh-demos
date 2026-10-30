#!/usr/bin/env bash
# Read-only verification of the pre-presentation application.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
for tier in db app web; do oc wait -n "$NAMESPACE" --for=condition=Ready "vm/orders-$tier" --timeout=5m; done
host=$(oc get route orders -n "$NAMESPACE" -o jsonpath='{.spec.host}')
[[ -n "$host" ]] || { echo 'Route has no host' >&2; exit 1; }
BASE="http://$host"
for ((attempt=1; attempt<=60; attempt++)); do
  if curl -fsS --max-time 5 "$BASE/api/menu" >/dev/null 2>&1; then break; fi
  [[ $attempt -lt 60 ]] || { echo 'Application did not become ready.' >&2; exit 1; }
  sleep 5
done
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
base = sys.argv[1]
def get(path):
    with urllib.request.urlopen(base + path, timeout=15) as response:
        return json.load(response)
menu, web, stats = get('/api/menu'), get('/api/webinfo'), get('/api/stats')
assert len(menu['items']) >= 8, 'Menu is incomplete'
assert web['runtime'] == 'VM', 'Frontend is not running on a VM'
assert stats['runtime'] == 'VM', 'API is not running on a VM'
assert 'MariaDB' in stats['db']['version'], 'Database is not MariaDB'
print(f"Application ready: {base} ({len(menu['items'])} dishes; web VM, API VM, {stats['db']['version']})")
PY
