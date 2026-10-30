#!/usr/bin/env bash
# Offline, data-preserving migration to the prepared bootc VM. Takes the API down briefly.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
[[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
SNAPSHOT_CLASS=$("$DEMO_DIR/bootc/snapshot-class.sh")
export NAMESPACE PRIVATE_DIR SSH_KEY
for cmd in oc virtctl ssh ruby python3; do command -v "$cmd" >/dev/null; done
[[ -f "$PRIVATE_DIR/known_hosts" && -f "$PRIVATE_DIR/db-bootc-known_hosts" && -f "$SSH_KEY" ]] || { echo 'Private SSH setup files are missing.' >&2; exit 1; }
[[ $(oc -n "$NAMESPACE" get vm orders-db -o jsonpath='{.status.printableStatus}') == Running ]] || { echo 'Legacy database VM must be running.' >&2; exit 1; }
[[ $(oc -n "$NAMESPACE" get svc orders-db -o jsonpath='{.spec.selector.vm\.kubevirt\.io/name}') == orders-db ]] || { echo 'Database Service does not target the legacy database.' >&2; exit 1; }
oc -n "$NAMESPACE" get vm orders-db-bootc >/dev/null
oc -n "$NAMESPACE" get volumesnapshotclass "$SNAPSHOT_CLASS" >/dev/null
run_id=$(date -u +%Y%m%d%H%M%S)
SNAPSHOT="orders-db-migration-$run_id"
TARGET_PVC="orders-db-bootc-$run_id"
export SNAPSHOT TARGET_PVC SNAPSHOT_CLASS
log=$(mktemp "${TMPDIR:-/tmp}/rocket-ramen-forward.XXXXXXXX")
pf=''
cleanup() { [[ -z "$pf" ]] || kill "$pf" 2>/dev/null || true; rm -f "$log"; }
trap cleanup EXIT
forward() {
  local service=$1 alias=$2 known=$3
  [[ -z "$pf" ]] || { kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true; }
  for ((attempt=0;attempt<60;attempt++)); do
    : > "$log"
    oc -n "$NAMESPACE" port-forward "svc/$service" :22 >"$log" 2>&1 & pf=$!
    port=''
    for ((i=0;i<15;i++)); do
      port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 22.*/\1/p' "$log" | head -1)
      [[ -n "$port" ]] && break
      kill -0 "$pf" 2>/dev/null || break
      sleep 1
    done
    if [[ -n "$port" ]]; then
      SSH=(ssh -p "$port" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known" -o "HostKeyAlias=$alias" demo-automation@127.0.0.1)
      if "${SSH[@]}" true >/dev/null 2>&1; then return 0; fi
    fi
    kill "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
    pf=''
    sleep 3
  done
  echo "SSH to $service did not become ready." >&2; return 1
}
printf 'Quiescing the API and legacy database; the application will be briefly unavailable.\n'
oc -n "$NAMESPACE" scale deployment/orders-api-container --replicas=0
oc -n "$NAMESPACE" rollout status deployment/orders-api-container --timeout=5m
if [[ -n $(oc -n "$NAMESPACE" get vmi orders-app --ignore-not-found -o name) ]]; then
  virtctl -n "$NAMESPACE" stop orders-app
  oc -n "$NAMESPACE" wait --for=delete vmi/orders-app --timeout=5m
fi
forward orders-db orders-db "$PRIVATE_DIR/known_hosts"
counts=$("${SSH[@]}" 'sudo mariadb -Nse "SELECT (SELECT COUNT(*) FROM orders.menu_items), (SELECT COUNT(*) FROM orders.orders)"')
[[ "$counts" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]] || { echo 'Could not read legacy database counts.' >&2; exit 1; }
"${SSH[@]}" 'sudo systemctl stop mariadb'
virtctl -n "$NAMESPACE" stop orders-db
oc -n "$NAMESPACE" wait --for=delete vmi/orders-db --timeout=5m
"$DEMO_DIR/bootc/snapshot-data.sh"
"$DEMO_DIR/bootc/clone-snapshot.sh"
"$DEMO_DIR/bootc/attach-data.sh"
forward orders-db-bootc orders-db-bootc "$PRIVATE_DIR/db-bootc-known_hosts"
"${SSH[@]}" 'sudo bash -s' < "$DEMO_DIR/bootc/configure-target-guest.sh"
new_counts=$("${SSH[@]}" 'sudo mariadb -Nse "SELECT (SELECT COUNT(*) FROM orders.menu_items), (SELECT COUNT(*) FROM orders.orders)"')
[[ "$counts" == "$new_counts" ]] || { echo 'Database counts differ; leaving the original disk and service untouched.' >&2; exit 1; }
oc -n "$NAMESPACE" patch svc orders-db --type=merge -p '{"spec":{"selector":{"vm.kubevirt.io/name":"orders-db-bootc"}}}'
oc -n "$NAMESPACE" scale deployment/orders-api-container --replicas=1
oc -n "$NAMESPACE" rollout status deployment/orders-api-container --timeout=5m
"$DEMO_DIR/modernization/traffic.sh" api container
"$DEMO_DIR/modernization/traffic.sh" web 100
host=$(oc -n "$NAMESPACE" get route orders -o jsonpath='{.spec.host}')
HOST="$host" python3 - <<'PY'
import json, os, urllib.request
base='http://'+os.environ['HOST']
def get(path):
    with urllib.request.urlopen(base+path,timeout=15) as r: return json.load(r)
web, api, menu = get('/api/webinfo'), get('/api/stats'), get('/api/menu')
assert web['runtime']=='container' and api['runtime']=='container' and menu['items']
print('Container frontend and API are serving data through the bootc database:', base)
PY
printf 'Snapshot %s and original database PVC are retained. After new writes, the original is stale.\n' "$SNAPSHOT"
