#!/usr/bin/env bash
# Headless logical verification for EVPN Stretched L2 demo.
#
# Run from repo root:
#   ./evpn/demo/test-flow.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")
cd "${REPO_ROOT}"

EVPN_DIR="evpn"
export KUBECONFIG_C1="${EVPN_DIR}/kubeconfig.evpn-cluster1"
export KUBECONFIG_C2="${EVPN_DIR}/kubeconfig.evpn-cluster2"
export MANIFESTS_DIR="${EVPN_DIR}/demo/manifests"

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

# 3. Apply Fabric Configuration (Split manifests for non-overlapping IP pools)
log "3. Applying EVPN Fabric Manifest..."
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

# 5. Deploy Workloads
log "5. Deploying workload pods..."
kubectl-c1 apply -f "${MANIFESTS_DIR}/pod-vm-a.yaml"
kubectl-c2 apply -f "${MANIFESTS_DIR}/pod-vm-b.yaml"

# 6. Wait for Workloads
log "6. Waiting for workloads to be ready..."
kubectl-c1 wait --for=condition=Ready pod vm-a -n vm-workloads --timeout=60s
kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=60s

# 7. Extract IPs and strip CIDR mask
log "7. Extracting CUDN IPs..."
VM_A_IP_FULL=$(kubectl-c1 get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")
VM_B_IP_FULL=$(kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")

VM_A_IP=$(echo "${VM_A_IP_FULL}" | cut -d'/' -f1)
VM_B_IP=$(echo "${VM_B_IP_FULL}" | cut -d'/' -f1)

echo "vm-a (C1) IP: ${VM_A_IP_FULL} -> ${VM_A_IP}"
echo "vm-b (C2) IP: ${VM_B_IP_FULL} -> ${VM_B_IP}"

if [[ "${VM_A_IP}" == "${VM_B_IP}" ]]; then
  echo "Error: vm-a and vm-b were assigned the same IP address (${VM_A_IP}). Check reservedSubnets routing pools."
  exit 1
fi

# 8. Ping Cross-Cluster
log "8. Performing cross-cluster ping VM-A ↔ VM-B..."
kubectl-c1 exec vm-a -n vm-workloads -- ping -c 4 "${VM_B_IP}"
kubectl-c2 exec vm-b -n vm-workloads -- ping -c 4 "${VM_A_IP}"

# 9. Verify ARP Resolution
log "9. Verifying local ARP resolution..."
kubectl-c1 exec vm-a -n vm-workloads -- arp -a | grep -q "${VM_B_IP}"
echo "ARP checks passed. ${VM_B_IP} resolved successfully on vm-a."

log "✅ All tests PASSED. Stretched EVPN L2 connectivity verified successfully."
