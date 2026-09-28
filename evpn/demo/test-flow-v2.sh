#!/usr/bin/env bash
# Headless logical verification for EVPN Stretched L2 demo (v2 — Separate Networks).
#
# Fails closed on: tracked runtime kubeconfigs, transit eBGP + L2VPN-EVPN
# session state, Type-2 route propagation to both edges, workload readiness,
# cross-cluster ping, and ARP resolution.
#
# Run from repo root:
#   ./evpn/demo/test-flow-v2.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")
cd "${REPO_ROOT}"

EVPN_DIR="evpn"
export KUBECONFIG_C1="${EVPN_DIR}/kubeconfig.evpn-cluster1"
export KUBECONFIG_C2="${EVPN_DIR}/kubeconfig.evpn-cluster2"
export MANIFESTS_DIR="${EVPN_DIR}/demo/manifests-v2"

# Create temp kubectl wrappers so commands show short aliases instead of full kubeconfig paths
TMP_KUBE_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_KUBE_DIR}"' EXIT
cat > "${TMP_KUBE_DIR}/kubectl-c1" <<'WRAPPER'
#!/usr/bin/env bash
exec kubectl --kubeconfig="${KUBECONFIG_C1}" "$@"
WRAPPER
cat > "${TMP_KUBE_DIR}/kubectl-c2" <<'WRAPPER'
#!/usr/bin/env bash
exec kubectl --kubeconfig="${KUBECONFIG_C2}" "$@"
WRAPPER
chmod +x "${TMP_KUBE_DIR}/kubectl-c1" "${TMP_KUBE_DIR}/kubectl-c2"
export PATH="${TMP_KUBE_DIR}:${PATH}"

log() {
  printf '\n==> %s\n' "$*"
}

# 0. Safety: runtime kubeconfigs may contain credentials and must never be
# tracked in Git. This inspects the Git index only — never file contents.
log "0. Verifying runtime kubeconfigs are not tracked in Git..."
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
  if git ls-files --error-unmatch "${kc}" >/dev/null 2>&1; then
    echo "Error: ${kc} is tracked in Git. Remove it from the index; kubeconfigs may contain credentials."
    exit 1
  fi
done
echo "Runtime kubeconfigs are untracked."

# 1. Reset
log "1. Resetting previous resources..."
kubectl-c1 delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=30s >/dev/null 2>&1 &
kubectl-c1 delete vtep,cudn,ra --all --timeout=30s >/dev/null 2>&1 &
kubectl-c2 delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=30s >/dev/null 2>&1 &
kubectl-c2 delete vtep,cudn,ra --all --timeout=30s >/dev/null 2>&1 &
wait

# Wait for namespaces to be fully gone from both clusters (Kubernetes deletes them asynchronously)
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
  while kubectl --kubeconfig="${kc}" get ns vm-workloads >/dev/null 2>&1; do
    echo "Waiting for namespace vm-workloads to be completely deleted on cluster..."
    sleep 2
  done
done

# 2. Namespace and Labels
log "2. Creating namespaces with primary UDN label from manifest..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/namespace.yaml"
kubectl-c2 apply -f "${MANIFESTS_DIR}/namespace.yaml"

# 3. Apply Fabric Configuration (same subnet on both clusters; IP overlap retried later)
log "3. Applying EVPN Fabric Manifest (v2 — same subnet, IP overlap handled via retry)..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
kubectl-c2 apply -f "${MANIFESTS_DIR}/evpn-fabric-c2.yaml"

# 4. Wait for acceptance
log "4. Waiting for EVPN resources to be accepted..."
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
  deadline=$(( $(date +%s) + 120 ))
  while true; do
    v_ok=$(kubectl --kubeconfig="${kc}" get vtep evpn-vtep -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "False")
    c_ok=$(kubectl --kubeconfig="${kc}" get clusteruserdefinednetwork stretched-l2 -o jsonpath='{.status.conditions[?(@.type=="NetworkCreated")].status}' 2>/dev/null || echo "False")
    r_ok=$(kubectl --kubeconfig="${kc}" get routeadvertisements evpn-ra -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "False")
    if [[ "${v_ok}" == "True" && "${c_ok}" == "True" && "${r_ok}" == "True" ]]; then
      break
    fi
    [[ $(date +%s) -gt "${deadline}" ]] && { echo "EVPN acceptance timeout"; exit 1; }
    sleep 2
  done
done
echo "Fabric configuration ACCEPTED."

# 5. Verify eBGP transit connectivity (fail-closed)
# bgp_peer_established <edge> <peer-ip> <vtysh-command>
# Returns 0 only when the peer is present in the given BGP summary with an
# up state. Both "Up" (text style) and "Established" are accepted.
bgp_peer_established() {
  local edge="$1" peer="$2" cmd="$3"
  local out state
  out=$(podman exec "${edge}" vtysh -c "${cmd}" 2>/dev/null || true)
  [[ -n "${out}" ]] || return 1
  state=$(printf '%s' "${out}" | python3 -c '
import json
import sys

peer = sys.argv[1]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

def find_peer(node):
    if isinstance(node, dict):
        peers = node.get("peers")
        if isinstance(peers, dict) and peer in peers:
            return peers[peer].get("state", "")
        for value in node.values():
            found = find_peer(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_peer(value)
            if found:
                return found
    return ""

print(find_peer(data))
' "${peer}")
  [[ "${state}" == "Up" || "${state}" == "Established" ]]
}

# assert_transit_peer <edge> <peer-ip>
# Waits (bounded) for both the general BGP and L2VPN-EVPN summaries to show
# the directed transit peer as established, then fails closed.
assert_transit_peer() {
  local edge="$1" peer="$2"
  local deadline=$(( $(date +%s) + 90 ))
  while true; do
    if bgp_peer_established "${edge}" "${peer}" "show bgp summary json" \
       && bgp_peer_established "${edge}" "${peer}" "show bgp l2vpn evpn summary json"; then
      break
    fi
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      echo "Error: transit peer ${edge} -> ${peer} is not established in IPv4 unicast and L2VPN-EVPN within 90s"
      exit 1
    fi
    sleep 3
  done
  echo "  ${edge} -> ${peer}: established (IPv4 unicast + L2VPN-EVPN)"
}

log "5. Verifying eBGP transit sessions (edge1 AS 65001 ↔ edge2 AS 65002)..."
assert_transit_peer evpn-edge1 10.250.0.2
assert_transit_peer evpn-edge2 10.250.0.1
echo "eBGP transit sessions verified."

# 6. Deploy Workloads
log "6. Deploying workload pods..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/pod-vm-a.yaml"
kubectl-c2 apply -f "${MANIFESTS_DIR}/pod-vm-b.yaml"

# 7. Wait for Workloads
log "7. Waiting for workloads to be ready..."
kubectl-c1 wait --for=condition=Ready pod vm-a -n vm-workloads --timeout=60s
kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=60s

# 8. Extract IPs and strip CIDR mask
log "8. Extracting CUDN IPs..."
VM_A_IP_FULL=$(kubectl-c1 get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")
VM_B_IP_FULL=$(kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")

VM_A_IP=$(echo "${VM_A_IP_FULL}" | cut -d'/' -f1)
VM_B_IP=$(echo "${VM_B_IP_FULL}" | cut -d'/' -f1)

echo "vm-a (C1) IP: ${VM_A_IP_FULL} -> ${VM_A_IP}"
echo "vm-b (C2) IP: ${VM_B_IP_FULL} -> ${VM_B_IP}"

if [[ "${VM_A_IP}" == "${VM_B_IP}" ]]; then
  echo "vm-a and vm-b received the same IP (${VM_A_IP}). Recreating vm-b to get a different allocation..."
  for attempt in 1 2 3 4 5; do
    kubectl-c2 delete pod vm-b -n vm-workloads --force --grace-period=0 --wait=false >/dev/null 2>&1
    sleep 3
    kubectl-c2 apply -f "${MANIFESTS_DIR}/pod-vm-b.yaml" >/dev/null
    kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=60s >/dev/null 2>&1
    VM_B_IP_FULL=$(kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])" 2>/dev/null || echo "")
    VM_B_IP=$(echo "${VM_B_IP_FULL}" | cut -d'/' -f1)
    if [[ -n "${VM_B_IP}" && "${VM_A_IP}" != "${VM_B_IP}" ]]; then
      break
    fi
  done
  if [[ "${VM_A_IP}" == "${VM_B_IP}" ]]; then
    echo "Error: vm-a and vm-b still share the same IP (${VM_A_IP}) after multiple retries."
    exit 1
  fi
  echo "vm-b recreated with IP ${VM_B_IP}."
fi

# 9. Verify EVPN Type-2 routes propagated via eBGP (fail-closed)
# contains_ip <ip> <text>: byte-boundary match so 192.170.1.5 does not match 192.170.1.50.
contains_ip() {
  local ip_re
  ip_re="$(printf '%s' "$1" | sed 's/\./\\./g')"
  grep -Eq "(^|[^0-9.])${ip_re}([^0-9.]|$)" <<<"$2"
}

# Both edges must carry Type-2 routes for both workload CUDN IPs.
assert_type2_routes() {
  local deadline=$(( $(date +%s) + 90 ))
  local edge1_routes edge2_routes missing ip
  while true; do
    edge1_routes=$(podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route type macip' 2>/dev/null || true)
    edge2_routes=$(podman exec evpn-edge2 vtysh -c 'show bgp l2vpn evpn route type macip' 2>/dev/null || true)
    missing=""
    for ip in "${VM_A_IP}" "${VM_B_IP}"; do
      contains_ip "${ip}" "${edge1_routes}" || missing="${missing} evpn-edge1:${ip}"
      contains_ip "${ip}" "${edge2_routes}" || missing="${missing} evpn-edge2:${ip}"
    done
    if [[ -z "${missing}" ]]; then
      break
    fi
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      echo "Error: missing EVPN Type-2 routes on both-edge check:${missing}"
      exit 1
    fi
    sleep 3
  done
  echo "EVPN Type-2 routes for ${VM_A_IP} and ${VM_B_IP} present on both edges."
}

log "9. Verifying EVPN Type-2 routes on both edges..."
assert_type2_routes

# 10. Ping Cross-Cluster
log "10. Performing cross-cluster ping VM-A ↔ VM-B (across isolated networks)..."
kubectl-c1 exec vm-a -n vm-workloads -- ping -c 4 "${VM_B_IP}"
kubectl-c2 exec vm-b -n vm-workloads -- ping -c 4 "${VM_A_IP}"

# 11. Verify ARP Resolution
log "11. Verifying local ARP resolution..."
kubectl-c1 exec vm-a -n vm-workloads -- arp -a | grep -q "${VM_B_IP}"
echo "ARP checks passed. ${VM_B_IP} resolved successfully on vm-a."

log "✅ All tests PASSED. Stretched EVPN L2 connectivity verified across isolated networks with eBGP transit."
