#!/usr/bin/env bash
# Preserve the current bootc database in a new PVC for the original three-VM baseline.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
[[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
SNAPSHOT_CLASS=$("$DEMO_DIR/bootc/snapshot-class.sh")
export NAMESPACE PRIVATE_DIR SSH_KEY SNAPSHOT_CLASS
[[ $(oc -n "$NAMESPACE" get svc orders-db -o jsonpath='{.spec.selector.vm\.kubevirt\.io/name}') == orders-db-bootc ]] || { echo 'Database Service does not target the bootc VM.' >&2; exit 1; }
legacy_vm=$(oc -n "$NAMESPACE" get vm orders-db --ignore-not-found -o name)
if [[ -n "$legacy_vm" ]]; then
  [[ $(oc -n "$NAMESPACE" get vm orders-db -o jsonpath='{.spec.runStrategy}') == Halted ]] || { echo 'Original database VM must be halted.' >&2; exit 1; }
fi
[[ -f "$PRIVATE_DIR/values.yaml" && -f "$PRIVATE_DIR/db-bootc-known_hosts" && -f "$SSH_KEY" ]] || { echo 'Private setup files are missing.' >&2; exit 1; }
run_id=$(date -u +%Y%m%d%H%M%S)
SNAPSHOT="orders-db-reset-$run_id" TARGET_PVC="orders-db-legacy-$run_id" SOURCE_VM=orders-db-bootc
export SNAPSHOT TARGET_PVC SOURCE_VM
log=$(mktemp "${TMPDIR:-/tmp}/rocket-ramen-reset.XXXXXXXX")
oc -n "$NAMESPACE" port-forward svc/orders-db-bootc :22 >"$log" 2>&1 & pf=$!
trap 'kill "$pf" 2>/dev/null || true; rm -f "$log"' EXIT
port=''
for ((i=0;i<60;i++)); do
  port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 22.*/\1/p' "$log" | head -1)
  [[ -n "$port" ]] && break
  kill -0 "$pf" 2>/dev/null || { cat "$log" >&2; exit 1; }
  sleep 1
done
[[ -n "$port" ]] || { echo 'Could not forward bootc SSH.' >&2; exit 1; }
SSH=(ssh -p "$port" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$PRIVATE_DIR/db-bootc-known_hosts" -o HostKeyAlias=orders-db-bootc demo-automation@127.0.0.1)
"${SSH[@]}" true
printf 'Quiescing API and bootc MariaDB before returning data to the VM baseline.\n'
oc -n "$NAMESPACE" scale deploy/orders-api-container --replicas=0
oc -n "$NAMESPACE" rollout status deploy/orders-api-container --timeout=5m
"${SSH[@]}" 'sudo systemctl stop mariadb'
virtctl -n "$NAMESPACE" stop orders-db-bootc
oc -n "$NAMESPACE" wait --for=delete vmi/orders-db-bootc --timeout=5m
"$DEMO_DIR/bootc/snapshot-data.sh"
"$DEMO_DIR/bootc/clone-snapshot.sh"
export TARGET_PVC
if [[ -n "$legacy_vm" ]]; then
  patch=$(oc -n "$NAMESPACE" get vm orders-db -o json | ruby -rjson -e 'j=JSON.parse(STDIN.read); a=j.dig("spec","template","spec","volumes"); i=a.index{|x|x["name"]=="datadisk"}; abort "disk not found" unless i; puts JSON.generate([{op:"replace",path:"/spec/template/spec/volumes/#{i}/persistentVolumeClaim/claimName",value:ENV.fetch("TARGET_PVC")}])')
  oc -n "$NAMESPACE" patch vm orders-db --type=json -p "$patch"
fi
ruby -ryaml -e 'p=ENV.fetch("PRIVATE_DIR")+"/values.yaml"; v=YAML.load_file(p); v.fetch("vm")["dataClaim"]=ENV.fetch("TARGET_PVC"); File.write(p,YAML.dump(v),mode:"w",perm:0600)'
oc -n "$NAMESPACE" patch svc orders-db --type=merge -p '{"spec":{"selector":{"vm.kubevirt.io/name":"orders-db"}}}'
oc -n "$NAMESPACE" patch svc orders-app --type=merge -p '{"spec":{"selector":{"app":null,"vm.kubevirt.io/name":"orders-app"}}}'
"$DEMO_DIR/automation/scripts/install.sh" -f "$PRIVATE_DIR/values.yaml"
"$DEMO_DIR/modernization/traffic.sh" web 0
if [[ -z "$legacy_vm" ]]; then
  # Wait for garbage collection of VM-owned root DataVolumes before recreating.
  for dv in orders-db-root orders-app-root orders-web-root; do
    for ((attempt=0; attempt<120; attempt++)); do
      [[ -z $(oc -n "$NAMESPACE" get dv "$dv" --ignore-not-found -o name) ]] && break
      [[ $attempt -lt 119 ]] || { echo "Timed out waiting for $dv deletion." >&2; exit 1; }
      sleep 5
    done
  done
  "$DEMO_DIR/automation/scripts/run.sh" provision
  "$DEMO_DIR/automation/scripts/run.sh" configure
fi
for vm in orders-db orders-app orders-web; do
  if [[ $(oc -n "$NAMESPACE" get vm "$vm" -o jsonpath='{.spec.runStrategy}') == Halted ]]; then virtctl -n "$NAMESPACE" start "$vm"; fi
  oc -n "$NAMESPACE" wait --for=condition=Ready "vm/$vm" --timeout=10m
done
"$DEMO_DIR/scripts/verify.sh"
printf 'VM baseline restored with data in %s; previous PVCs and snapshot %s remain available.\n' "$TARGET_PVC" "$SNAPSHOT"
