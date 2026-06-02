#!/usr/bin/env bash
# EVPN Multi-Cluster Stretched L2 Presentation Script
#
# Starts from a pre-provisioned infrastructure baseline (clusters, edges, BGP peering).
# Resets any active EVPN resources, then walks through:
#   1. EVPN Fabric Config (VTEP, CUDN, RouteAdvertisements)
#   2. BGP EVPN Session Status
#   3. Workload Deployment (vm-a / vm-b)
#   4. Cross-Cluster L2 Connectivity (ARP & Ping)
#   5. Web UI Live Visualization
#
# Run from repo root:
#   ./evpn/demo/demo.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")
cd "${REPO_ROOT}"

# Include demo-magic
. "${REPO_ROOT}/scripts/demo-magic.sh"

# Configuration
TYPE_SPEED=${TYPE_SPEED:-40}
DEMO_PROMPT="${GREEN}❯ ${COLOR_RESET}"
EVPN_DIR="evpn"
KUBECONFIG_C1="${REPO_ROOT}/${EVPN_DIR}/kubeconfig.evpn-cluster1"
KUBECONFIG_C2="${REPO_ROOT}/${EVPN_DIR}/kubeconfig.evpn-cluster2"
MANIFESTS_DIR="${REPO_ROOT}/${EVPN_DIR}/demo/manifests"

# Feature detection
HAS_GUM=false && command -v gum &>/dev/null && HAS_GUM=true
HAS_BAT=false && command -v bat &>/dev/null && HAS_BAT=true

# Helper formatting
function act() {
  clear
  if [ "$HAS_GUM" = true ]; then
    gum style --bold --foreground=226 --border=double --padding="1 2" --margin="1 1" "Act $1 — $2"
  else
    printf '\n\033[1;33mAct %s — %s\033[0m\n\n' "$1" "$2"
  fi
  wait
  clear
}

function say() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --bold --padding="1 2" --margin="1 0" --foreground="${2:-117}"
  else
    printf '\n\033[1;36m%s\033[0m\n\n' "$1"
  fi
}

function comment() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --italic --foreground=245 --padding="0 2"
  else
    printf '\033[3m%s\033[0m\n' "$1"
  fi
}

# Pre-flight Check: Ensure BGP infra is running
if [[ ! -f "${KUBECONFIG_C1}" || ! -f "${KUBECONFIG_C2}" ]]; then
  echo -e "${RED}Error: Kubeconfigs not found. Run './evpn/clusters.sh create' first to stand up BGP infra.${COLOR_RESET}"
  exit 1
fi

# Pre-flight Reset (Silently reset active EVPN config to pristine starting state)
echo -e "${GREY}Pre-flight: Cleaning up existing EVPN resources...${COLOR_RESET}"
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete vtep,cudn,ra --all --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete vtep,cudn,ra --all --timeout=15s >/dev/null 2>&1 &
wait

# Wait for namespaces to be fully gone from both clusters (Kubernetes deletes them asynchronously)
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
  while KUBECONFIG="${kc}" kubectl get ns vm-workloads >/dev/null 2>&1; do
    echo "Waiting for namespace vm-workloads to be completely deleted on cluster..."
    sleep 2
  done
done

# Ensure Web UI is running
./evpn/clusters.sh ui start >/dev/null 2>&1 || true

# ==============================================================
# INTRO
# ==============================================================
clear
say "EVPN Multi-Cluster Stretched L2 Demo 🎩
Connecting clusters over a single stretched segment using OVN-Kubernetes" 226
wait
clear

say "Baseline Infrastructure:
  - 2 Kind clusters (Cluster 1: East, Cluster 2: West)
  - 2 FRR Edge routers (BGP Route Reflectors)
  - Base IPv4 BGP sessions established between clusters and worker nodes

But there is NO stretched network and NO EVPN routes exchanged yet."
wait
clear

# ==============================================================
# ACT 1 — Creating the EVPN Fabric
# ==============================================================
act "1" "Configuring the Stretched L2 Segment"

say "We begin by creating a standard Namespace with the primary UDN label on both clusters."
wait

if [ "$HAS_BAT" = true ]; then
  pe "bat --style=plain --color=always --language=yaml ${MANIFESTS_DIR}/namespace.yaml"
else
  pe "cat ${MANIFESTS_DIR}/namespace.yaml"
fi
wait

comment "Creating and labeling the namespaces simultaneously..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl apply -f ${MANIFESTS_DIR}/namespace.yaml"
pe "KUBECONFIG=${KUBECONFIG_C2} kubectl apply -f ${MANIFESTS_DIR}/namespace.yaml"
wait
clear

say "Now we define the Stretched Fabric. We apply the config to Cluster 1 and Cluster 2.
We use non-overlapping 'reservedSubnets' on each cluster's CUDN to prevent IP allocation conflicts:
  - Cluster 1 (East): Reserves upper half '192.170.1.128/25' (allocates from lower half)
  - Cluster 2 (West): Reserves lower half '192.170.1.0/25' (allocates from upper half)

This gives us beautiful, coordinated, non-overlapping IP address pools on the exact same Layer-2 stretched network!"
wait

if [ "$HAS_BAT" = true ]; then
  pe "bat --style=plain --color=always --language=yaml ${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
else
  pe "cat ${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
fi
wait

comment "Applying the fabric configurations to both clusters..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl apply -f ${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
pe "KUBECONFIG=${KUBECONFIG_C2} kubectl apply -f ${MANIFESTS_DIR}/evpn-fabric-c2.yaml"
wait

comment "Verifying acceptance of EVPN configurations on Cluster 1..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl get vtep,cudn,ra"
wait
clear

# ==============================================================
# ACT 2 — BGP EVPN Convergence
# ==============================================================
act "2" "BGP EVPN Peerings and Routes"

say "The RouteAdvertisements controller auto-generated per-node BGP configuration!
Let's inspect the FRR edge routers to verify that L2VPN EVPN routing has converged."
wait

comment "Checking BGP L2VPN EVPN session states on evpn-edge1..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn summary'"
wait

comment "Inspecting EVPN Type-3 (IMET) routes for multicast flooding..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route-type imet'"
wait
clear

# ==============================================================
# ACT 3 — Deploying Workloads
# ==============================================================
act "3" "Deploying Stretched Workloads"

say "Let's deploy two workloads. They are placed in different clusters but attach to the same primary network segment."
wait

if [ "$HAS_BAT" = true ]; then
  pe "bat --style=plain --color=always --language=yaml ${MANIFESTS_DIR}/pod-vm-a.yaml"
  pe "bat --style=plain --color=always --language=yaml ${MANIFESTS_DIR}/pod-vm-b.yaml"
else
  pe "cat ${MANIFESTS_DIR}/pod-vm-a.yaml"
  pe "cat ${MANIFESTS_DIR}/pod-vm-b.yaml"
fi
wait

comment "Spawning VM-A (Cluster 1) and VM-B (Cluster 2)..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl apply -f ${MANIFESTS_DIR}/pod-vm-a.yaml"
pe "KUBECONFIG=${KUBECONFIG_C2} kubectl apply -f ${MANIFESTS_DIR}/pod-vm-b.yaml"
wait

comment "Waiting for pods to reach Ready state..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl wait --for=condition=Ready pod vm-a -n vm-workloads --timeout=30s"
pe "KUBECONFIG=${KUBECONFIG_C2} kubectl wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=30s"
wait
clear

say "Let's extract their assigned CUDN IP addresses. Notice how the IP pools are split perfectly by the reservedSubnets we configured!"
wait

comment "Fetching VM-A CUDN IP (Cluster 1)..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""

comment "Fetching VM-B CUDN IP (Cluster 2)..."
pe "KUBECONFIG=${KUBECONFIG_C2} kubectl get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""
wait
clear

# ==============================================================
# ACT 4 — Control Plane Verification
# ==============================================================
act "4" "Under the Hood: EVPN Type-2 Routes and Data Plane"

say "As soon as the workloads spun up, OVN-K advertised their MAC + IP combinations.
Let's verify that the edges and node kernel tables have learned the remote locations."
wait

comment "Checking EVPN Type-2 (MAC/IP) routes on evpn-edge1..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route-type macip'"
wait

comment "Checking Linux Bridge FDB entries on the Cluster 1 worker node (where vm-b MAC maps to Cluster 2 worker IP)..."
pe "podman exec evpn-cluster1-worker bridge fdb show dev evbr-evpn-vtep"
wait

comment "Checking local IP neighbor (ARP) table on Cluster 1 SVI interface..."
pe "podman exec evpn-cluster1-worker ip neigh show dev svl2.1"
wait
clear

# ==============================================================
# ACT 5 — Connectivity and Ping
# ==============================================================
act "5" "Cross-Cluster Ping over the Stretched Segment"

say "Now, the moment of truth. Let's ping directly from VM-A (Cluster 1) to VM-B (Cluster 2) CUDN IP."
wait

# Extract VM-B IP and strip the mask for the command
VM_B_IP_FULL=$(KUBECONFIG=${KUBECONFIG_C2} kubectl get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")
VM_B_IP=$(echo "${VM_B_IP_FULL}" | cut -d'/' -f1)

comment "Pinging VM-B (${VM_B_IP}) from inside VM-A..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl exec vm-a -n vm-workloads -- ping -c 4 ${VM_B_IP}"
wait

comment "Checking the pod ARP table inside VM-A..."
pe "KUBECONFIG=${KUBECONFIG_C1} kubectl exec vm-a -n vm-workloads -- arp -a"
wait
clear

# ==============================================================
# ACT 6 — Web UI Visualization
# ==============================================================
act "6" "Live Real-Time Web Visualization"

say "Let's open our live visualization dashboard at http://localhost:8080.
We will see:
  - Real-time topology with custom backdrops separating East, West, and Core
  - Circular Pod nodes hovering above their hosting worker nodes
  - Live BGP sessions and prefix counts
  - Direct UI action: Launching a continuous ping and animating route propagation!"
wait

comment "Opening the Web UI in your browser..."
if command -v open &>/dev/null; then
  open "http://localhost:8080"
elif command -v xdg-open &>/dev/null; then
  xdg-open "http://localhost:8080" >/dev/null 2>&1 || true
fi
wait

say "Demo complete! You have successfully demonstrated OVN-K Stretched L2 EVPN."
