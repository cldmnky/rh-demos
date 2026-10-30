#!/usr/bin/env bash
# Pre-stage a bootc target without touching the live VM application.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
if [[ -z ${SSH_KEY+x} ]]; then
  SSH_KEY="$HOME/.ssh/rh-demos"
  [[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
fi
export NAMESPACE PRIVATE_DIR SSH_KEY
# Do not replace existing OS disks or VMs, which may contain migrated data.
if [[ -n $(oc -n "$NAMESPACE" get vm orders-db-bootc --ignore-not-found -o name) ]]; then
  [[ -f "$PRIVATE_DIR/db-bootc-known_hosts" ]] || { echo 'Existing bootc target requires its original private host keys.' >&2; exit 1; }
  echo 'Existing bootc target retained.'
  exit 0
fi
"$DEMO_DIR/bootc/prepare-builder.sh"
if [[ -n $(oc -n "$NAMESPACE" get dv orders-bootc-root --ignore-not-found -o name) ]]; then
  phase=$(oc -n "$NAMESPACE" get dv orders-bootc-root -o jsonpath='{.status.phase}')
  [[ "$phase" == Succeeded ]] || { echo "Existing bootc DataVolume is $phase; inspect before retrying." >&2; exit 1; }
  "$DEMO_DIR/bootc/prepare-target.sh"
  exit 0
fi
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid namespace.' >&2; exit 1; }
if [[ -z $(oc -n "$NAMESPACE" get imagestream orders-bootc --ignore-not-found -o name) ]]; then oc -n "$NAMESPACE" create imagestream orders-bootc; fi
log=$(mktemp "${TMPDIR:-/tmp}/rocket-ramen-builder-forward.XXXXXXXX")
pf=''
SSH=()
cleanup() {
  if [[ ${#SSH[@]} -gt 0 ]]; then "${SSH[@]}" 'sudo rm -f /run/rocket-ramen/auth.json' >/dev/null 2>&1 || true; fi
  [[ -z "$pf" ]] || kill "$pf" 2>/dev/null || true
  rm -f "$log"
}
trap cleanup EXIT
for ((attempt=0;attempt<60;attempt++)); do
  : > "$log"
  oc -n "$NAMESPACE" port-forward svc/orders-builder :22 >"$log" 2>&1 & pf=$!
  port=''
  for ((i=0;i<15;i++)); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 22.*/\1/p' "$log" | head -1)
    [[ -n "$port" ]] && break
    kill -0 "$pf" 2>/dev/null || break
    sleep 1
  done
  if [[ -n "$port" ]]; then
    SSH=(ssh -p "$port" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$PRIVATE_DIR/builder-known_hosts" -o HostKeyAlias=orders-builder demo-automation@127.0.0.1)
    if "${SSH[@]}" true >/dev/null 2>&1; then break; fi
  fi
  kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true; pf=''
  [[ $attempt -lt 59 ]] || { echo 'Builder SSH did not become ready.' >&2; exit 1; }
  sleep 3
done
# Registry credentials stay in root-only /run, are never printed, and are removed on exit.
"${SSH[@]}" 'sudo install -d -m 700 /run/rocket-ramen /var/lib/rocket-ramen-builder/context /etc/containers/certs.d/image-registry.openshift-image-registry.svc:5000'
oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | ruby -rbase64 -e 'STDOUT.write(Base64.strict_decode64(STDIN.read))' | "${SSH[@]}" 'sudo install -m 600 /dev/stdin /run/rocket-ramen/auth.json'
oc -n "$NAMESPACE" get configmap openshift-service-ca.crt -o jsonpath='{.data.service-ca\.crt}' | "${SSH[@]}" 'sudo install -m 644 /dev/stdin /etc/containers/certs.d/image-registry.openshift-image-registry.svc:5000/ca.crt'
oc -n "$NAMESPACE" create token builder --duration=6h | "${SSH[@]}" 'sudo podman login --authfile /run/rocket-ramen/auth.json --username serviceaccount --password-stdin image-registry.openshift-image-registry.svc:5000'
"${SSH[@]}" 'sudo install -m 644 /dev/stdin /var/lib/rocket-ramen-builder/context/Containerfile' < "$DEMO_DIR/bootc/Containerfile"
"${SSH[@]}" 'sudo install -m 755 /dev/stdin /var/lib/rocket-ramen-builder/context/build-on-builder.sh' < "$DEMO_DIR/bootc/build-on-builder.sh"
output="/var/lib/rocket-ramen-builder/image-$(date -u +%Y%m%d%H%M%S)"
image="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/orders-bootc:demo"
"${SSH[@]}" "sudo env BOOTC_IMAGE='$image' OUTPUT_DIR='$output' REGISTRY_AUTH_FILE=/run/rocket-ramen/auth.json /var/lib/rocket-ramen-builder/context/build-on-builder.sh"
BUILDER_SSH_PORT="$port" BUILDER_DISK_DIR="$output/qcow2" "$DEMO_DIR/bootc/stage-disk.sh"
BOOTC_DISK_URL="http://orders-bootc-artifacts.$NAMESPACE.svc:8081/disk.qcow2" "$DEMO_DIR/bootc/import-disk.sh"
"$DEMO_DIR/bootc/prepare-target.sh"
