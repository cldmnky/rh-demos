#!/usr/bin/env bash
# Show image mode inside the running target VM without disabling SSH host checking.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
[[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
[[ -f "$SSH_KEY" && -f "$PRIVATE_DIR/db-bootc-known_hosts" ]] || { echo 'Missing target SSH identity.' >&2; exit 1; }
log=$(mktemp "${TMPDIR:-/tmp}/rocket-ramen-status.XXXXXXXX")
pf=''
cleanup() { [[ -z "$pf" ]] || kill "$pf" 2>/dev/null || true; rm -f "$log"; }
trap cleanup EXIT
for ((attempt=0;attempt<60;attempt++)); do
  : > "$log"
  oc -n "$NAMESPACE" port-forward svc/orders-db-bootc :22 >"$log" 2>&1 & pf=$!
  port=''
  for ((i=0;i<15;i++)); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 22.*/\1/p' "$log" | head -1)
    [[ -n "$port" ]] && break
    kill -0 "$pf" 2>/dev/null || break
    sleep 1
  done
  if [[ -n "$port" ]] && ssh -p "$port" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$PRIVATE_DIR/db-bootc-known_hosts" -o HostKeyAlias=orders-db-bootc demo-automation@127.0.0.1 true >/dev/null 2>&1; then
    ssh -p "$port" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$PRIVATE_DIR/db-bootc-known_hosts" -o HostKeyAlias=orders-db-bootc demo-automation@127.0.0.1 'sudo bootc status'
    exit $?
  fi
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  pf=''
  sleep 3
done
echo 'Bootc target SSH did not become ready.' >&2
exit 1
