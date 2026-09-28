#!/usr/bin/env bash
# Headless logical verification for the OVN-K Multi-Tenant Networking demo
# (v2 — Separate Networks).
#
# Fails closed on: tracked runtime kubeconfigs, tenant UDN isolation,
# BGP export of a plain Layer2 UDN (no EVPN), transit eBGP + L2VPN-EVPN
# session state, Type-2 route propagation to both edges, workload readiness,
# cross-cluster ping, ARP resolution, and (MetalLB) cross-site LoadBalancer
# VIP announcement + reachability.
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
kubectl-c1 delete ns vm-workloads tenant-a udn-bgp --ignore-not-found --grace-period=0 --force --timeout=30s >/dev/null 2>&1 &
kubectl-c1 delete ns l3-services --ignore-not-found --grace-period=0 --force --timeout=30s >/dev/null 2>&1 &
kubectl-c1 delete vtep,cudn,ra --all --timeout=30s >/dev/null 2>&1 &
kubectl-c2 delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=30s >/dev/null 2>&1 &
kubectl-c2 delete ns l3-services --ignore-not-found --grace-period=0 --force --timeout=30s >/dev/null 2>&1 &
kubectl-c2 delete vtep,cudn,ra --all --timeout=30s >/dev/null 2>&1 &
kubectl-c2 delete frrconfiguration udn-subnets -n frr-k8s-system --ignore-not-found >/dev/null 2>&1 &
wait

# Wait for namespaces to be fully gone from both clusters (Kubernetes deletes them asynchronously)
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
  for ns in vm-workloads l3-services tenant-a udn-bgp; do
    while kubectl --kubeconfig="${kc}" get ns "${ns}" >/dev/null 2>&1; do
      echo "Waiting for namespace ${ns} to be completely deleted on cluster..."
      sleep 2
    done
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

# Both edges must carry Type-2 routes for both workload CUDN IPs. The window
# is generous because a cold start (or a freshly recreated pod) can coincide
# with the edges' BGP session re-establishing and re-advertising all routes.
assert_type2_routes() {
  local deadline=$(( $(date +%s) + 240 ))
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

# 11. Verify ARP Resolution. Ping first to force (re-)resolution, then poll
# both arp and ip neigh: right after a fabric recreate the neighbor entry
# can flap for a while even though traffic flows.
log "11. Verifying local ARP resolution..."
deadline=$(( $(date +%s) + 90 ))
while true; do
  kubectl-c1 exec vm-a -n vm-workloads -- ping -c 1 -W 2 "${VM_B_IP}" >/dev/null 2>&1 || true
  if kubectl-c1 exec vm-a -n vm-workloads -- arp -a 2>/dev/null | grep -q "${VM_B_IP}" \
    || kubectl-c1 exec vm-a -n vm-workloads -- ip neigh show "${VM_B_IP}" 2>/dev/null | grep -qE 'lladdr|STALE|REACHABLE|DELAY|PROBE'; then
    break
  fi
  if [[ $(date +%s) -gt "${deadline}" ]]; then
    echo "Error: ${VM_B_IP} not present in vm-a ARP table within 90s"
    kubectl-c1 exec vm-a -n vm-workloads -- arp -a 2>&1 || true
    kubectl-c1 exec vm-a -n vm-workloads -- ip neigh 2>&1 || true
    exit 1
  fi
  sleep 3
done
echo "ARP checks passed. ${VM_B_IP} resolved successfully on vm-a."

# 12. Tenant UDN: isolated network for pods (and VMs).
log "12. Creating the tenant UDN (${MANIFESTS_DIR}/udn-tenant.yaml)..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/udn-tenant.yaml" >/dev/null
kubectl-c1 wait --for=condition=Ready pod app-a -n tenant-a --timeout=60s
# Tenant address on ovn-udn1, cluster address on eth0.
kubectl-c1 exec app-a -n tenant-a -- ip -o addr 2>/dev/null | grep -q 'ovn-udn1.*103.103.0' \
  || { echo "Error: tenant pod has no UDN interface"; exit 1; }
echo "Tenant pod carries its own subnet (103.103.0.0/16) on ovn-udn1."
# Egress works (SNAT via the node gateway) ...
kubectl-c1 exec app-a -n tenant-a -- ping -c 2 -W 2 10.100.0.100 >/dev/null 2>&1 \
  || { echo "Error: tenant pod cannot egress"; exit 1; }
# ... but the cluster network is unreachable (native isolation, fail-closed).
DNS_IP=$(kubectl-c1 get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
if kubectl-c1 exec app-a -n tenant-a -- ping -c 2 -W 2 "${DNS_IP}" >/dev/null 2>&1; then
  echo "Error: tenant pod unexpectedly reached the cluster network (${DNS_IP})"
  exit 1
fi
echo "Tenant isolation verified: cluster network unreachable, egress works."

# 13. BGP export of a plain Layer2 UDN — no EVPN transport.
# Network first, pod after acceptance (the pod's OVN port only binds once
# the logical switch exists).
log "13. Advertising the Layer2 UDN into BGP (no EVPN)..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/udn-bgp-net.yaml" >/dev/null
kubectl-c2 apply -f "${MANIFESTS_DIR}/udn-bgp-receive.yaml" >/dev/null

# Wait for the export RA to be accepted.
deadline=$(( $(date +%s) + 120 ))
while true; do
  ra_ok=$(kubectl-c1 get routeadvertisements udn-bgp-ra -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "False")
  [[ "${ra_ok}" == "True" ]] && break
  if [[ $(date +%s) -gt "${deadline}" ]]; then
    echo "Error: udn-bgp-ra not accepted within 120s"
    kubectl-c1 get ra udn-bgp-ra -o jsonpath='{.status}' 2>/dev/null
    exit 1
  fi
  sleep 2
done
echo "UDN export RA accepted."

# Deploy the consumer only after the network is accepted, then wait for Ready.
kubectl-c1 apply -f "${MANIFESTS_DIR}/udn-bgp-pod.yaml" >/dev/null
kubectl-c1 wait --for=condition=Ready pod udn-web -n udn-bgp --timeout=60s

# The pod /24 must be in both edges' IPv4 unicast RIBs (edge2 via eBGP).
assert_subnet_on_edge() {
  local edge="$1" subnet="$2" require_as="$3"
  local deadline=$(( $(date +%s) + 120 )) out
  while true; do
    out=$(podman exec "${edge}" vtysh -c "show bgp ipv4 unicast ${subnet}" 2>/dev/null || true)
    if contains_ip "${subnet%%/*}" "${out}" \
       && { [[ -z "${require_as}" ]] || grep -Eq '(^|[^0-9])'"${require_as}"'([^0-9]|$)' <<<"${out}"; }; then
      break
    fi
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      echo "Error: subnet ${subnet} not present on ${edge} (require_as=${require_as:-none}) within 120s"
      exit 1
    fi
    sleep 3
  done
  echo "  ${edge}: ${subnet} present${require_as:+ (AS path contains ${require_as})}"
}
assert_subnet_on_edge evpn-edge1 "192.170.10.0/24" ""
assert_subnet_on_edge evpn-edge2 "192.170.10.0/24" "65001"

# Consume the pod subnet cross-site: the cluster2 worker must have the route
# (via edge2), and the pod itself must reach the remote site. The pod runs on
# the control-plane (see udn-bgp-pod.yaml for why).
UDN_POD_IP=$(kubectl-c1 exec udn-web -n udn-bgp -- ip -o addr 2>/dev/null | grep -o '192\.170\.10\.[0-9]*' | head -1)
[[ -n "${UDN_POD_IP}" ]] || { echo "Error: could not determine udn-web pod IP"; exit 1; }
echo "udn-web pod IP: ${UDN_POD_IP}"
C2_WORKER_FRR=$(kubectl-c2 get pods -n frr-k8s-system -l app.kubernetes.io/component=frr-k8s --field-selector spec.nodeName=evpn-cluster2-worker -o name | head -1)
kubectl-c2 exec -n frr-k8s-system "${C2_WORKER_FRR}" -c frr -- ip route get "${UDN_POD_IP}" 2>/dev/null | grep -q 'via 10.200.0.100' \
  || { echo "Error: cluster2 worker has no BGP route to ${UDN_POD_IP}"; exit 1; }
echo "Cluster2 worker routes ${UDN_POD_IP} via edge2 (10.200.0.100)."
kubectl-c1 exec udn-web -n udn-bgp -- ping -c 3 -W 2 10.200.0.3 >/dev/null 2>&1 \
  || { echo "Error: udn-web cannot reach the remote site (10.200.0.3)"; exit 1; }
echo "BGP-routed pod identity verified: ${UDN_POD_IP} reaches cluster2 without EVPN."

# 14. Deploy the MetalLB BGP service and wait for its VIP
log "14. Deploying the MetalLB BGP service (${MANIFESTS_DIR}/l3-service.yaml)..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/l3-service.yaml" >/dev/null
kubectl-c1 wait --for=condition=Available deployment/web -n l3-services --timeout=90s

VIP=""
deadline=$(( $(date +%s) + 90 ))
while true; do
  VIP=$(kubectl-c1 get svc web -n l3-services -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -n "${VIP}" ]] && break
  if [[ $(date +%s) -gt "${deadline}" ]]; then
    echo "Error: service web did not receive a LoadBalancer IP within 90s"
    exit 1
  fi
  sleep 3
done
echo "MetalLB assigned VIP: ${VIP}"

# 15. Verify the VIP in both edges' IPv4 unicast RIBs. On edge2 the route must
# have arrived over the eBGP transit (AS 65001).
log "15. Verifying VIP ${VIP}/32 in the edges' IPv4 unicast RIBs..."
assert_vip_on_edge() {
  local edge="$1" vip="$2" require_as="$3"
  local deadline=$(( $(date +%s) + 90 )) out
  while true; do
    out=$(podman exec "${edge}" vtysh -c "show bgp ipv4 unicast ${vip}/32" 2>/dev/null || true)
    if contains_ip "${vip}" "${out}" \
       && { [[ -z "${require_as}" ]] || grep -Eq '(^|[^0-9])'"${require_as}"'([^0-9]|$)' <<<"${out}"; }; then
      break
    fi
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      echo "Error: VIP ${vip}/32 not present on ${edge} (require_as=${require_as:-none}) within 90s"
      exit 1
    fi
    sleep 3
  done
  echo "  ${edge}: ${vip}/32 present${require_as:+ (AS path contains ${require_as})}"
}
assert_vip_on_edge evpn-edge1 "${VIP}" ""
assert_vip_on_edge evpn-edge2 "${VIP}" "65001"

# 16. Reach the VIP cross-site from a host-network client on cluster2.
# The client runs with hostNetwork so the request is routed purely by BGP
# (node FIB -> edge2 -> eBGP transit -> edge1 -> cluster1 node); pods on the
# EVPN CUDN cannot reach default-network service VIPs (network isolation).
log "16. Curling the remote site VIP from a host-network client on cluster2..."
kubectl-c2 delete pod vip-client -n l3-services --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
sed "s/__VIP__/${VIP}/" "${MANIFESTS_DIR}/l3-client.yaml" | kubectl-c2 apply -f - >/dev/null
deadline=$(( $(date +%s) + 90 ))
while true; do
  if kubectl-c2 logs vip-client -n l3-services 2>/dev/null | grep -q 'VIP-OK'; then
    break
  fi
  if [[ $(date +%s) -gt "${deadline}" ]]; then
    echo "Error: cluster2 host-network client could not reach http://${VIP}:8080/hostname within 90s"
    kubectl-c2 logs vip-client -n l3-services 2>/dev/null || true
    exit 1
  fi
  sleep 3
done
echo "BGP service reachability verified: ${VIP} reachable from cluster2 over eBGP transit."

log "✅ All tests PASSED. Tenant UDNs, BGP pod-network export, stretched EVPN L2 and MetalLB BGP services verified across isolated networks."
