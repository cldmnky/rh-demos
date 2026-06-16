#!/usr/bin/env bash
# EVPN Multi-Cluster Stretched L2 Presentation Script
#
# Starts from a pre-provisioned infrastructure baseline (clusters, edges, BGP peering).
# Resets any active EVPN resources, then walks through:
#   1. EVPN Fabric Config (VTEP, CUDN, RouteAdvertisements)
#   2. BGP EVPN Session Status (eBGP transit between sites)
#   3. Workload Deployment (vm-a / vm-b)
#   4. Cross-Cluster L2 Connectivity (ARP & Ping)
#   5. Web UI Live Visualization
#
# Run from repo root:
#   ./evpn/demo/demo-v2.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")
cd "${REPO_ROOT}"

# Include demo-magic
. "${REPO_ROOT}/scripts/demo-magic.sh"

# Configuration
TYPE_SPEED=${TYPE_SPEED:-40}
DEMO_PROMPT="${GREEN}\$ ${COLOR_RESET}"
EVPN_DIR="evpn"
export KUBECONFIG_C1="${EVPN_DIR}/kubeconfig.evpn-cluster1"
export KUBECONFIG_C2="${EVPN_DIR}/kubeconfig.evpn-cluster2"
MANIFESTS_DIR="${EVPN_DIR}/demo/manifests-v2"

# Feature detection
HAS_GUM=false && command -v gum &>/dev/null && HAS_GUM=true
HAS_BAT=false && command -v bat &>/dev/null && HAS_BAT=true
HAS_REDHATSAY=false && command -v redhatsay &>/dev/null && HAS_REDHATSAY=true

# Create temp kubectl wrappers so pe commands show short aliases instead of full kubeconfig paths
TMP_KUBE_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_KUBE_DIR}"' EXIT
cat >"${TMP_KUBE_DIR}/kubectl-c1" <<'WRAPPER'
#!/usr/bin/env bash
exec kubectl --kubeconfig="${KUBECONFIG_C1}" "$@"
WRAPPER
cat >"${TMP_KUBE_DIR}/kubectl-c2" <<'WRAPPER'
#!/usr/bin/env bash
exec kubectl --kubeconfig="${KUBECONFIG_C2}" "$@"
WRAPPER
chmod +x "${TMP_KUBE_DIR}/kubectl-c1" "${TMP_KUBE_DIR}/kubectl-c2"
export PATH="${TMP_KUBE_DIR}:${PATH}"

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

function show_manifest() {
    if [ "$HAS_GUM" = true ]; then
        cat "$1" | gum format -t code -l yaml
    else
        cat "$1"
    fi
}

function redhatsay() {
    if [ "$HAS_GUM" = true ] && [ "$HAS_REDHATSAY" = true ]; then
        printf '%s\n' "$1" | gum format -t markdown 2>/dev/null | command redhatsay 2>/dev/null || printf '\n\033[1;31m%s\033[0m\n\n' "$1"
    elif [ "$HAS_REDHATSAY" = true ]; then
        printf '%s\n' "$1" | command redhatsay 2>/dev/null || printf '\n\033[1;31m%s\033[0m\n\n' "$1"
    else
        printf '\n\033[1;31m%s\033[0m\n\n' "$1"
    fi
}

# Pre-flight Check: Ensure BGP infra is running
if [[ ! -f "${KUBECONFIG_C1}" || ! -f "${KUBECONFIG_C2}" ]]; then
    echo -e "${RED}Error: Kubeconfigs not found. Run './evpn/clusters-v2.sh create' first to stand up BGP infra.${COLOR_RESET}"
    exit 1
fi

# Pre-flight Reset (Silently reset active EVPN config to pristine starting state)
echo -e "${GREY}Pre-flight: Cleaning up existing EVPN resources...${COLOR_RESET}"
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete vtep,cudn,ra --all --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete vtep,cudn,ra --all --timeout=15s >/dev/null 2>&1 &

# Wait for namespaces to be fully gone from both clusters (Kubernetes deletes them asynchronously)
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
    while KUBECONFIG="${kc}" kubectl get ns vm-workloads >/dev/null 2>&1; do
        echo "Waiting for namespace vm-workloads to be completely deleted on cluster..."
        sleep 2
    done
done

# Ensure Web UI is running
./evpn/clusters-v2.sh ui start >/dev/null 2>&1 || true

# ==============================================================
# INTRO
# ==============================================================
clear
redhatsay '**EVPN Multi-Cluster Stretched L2 Demo**

Two Kubernetes clusters
on isolated podman networks
connected via BGP EVPN and eBGP transit'
wait
clear
p ""
pei "ls -al"
p ""

say "Baseline Infrastructure:
  - 2 Kind clusters on ISOLATED podman networks:
      Cluster 1 (East)  → evpn-site1   (10.100.0.0/24, AS 65001)
      Cluster 2 (West)  → evpn-site2   (10.200.0.0/24, AS 65002)
  - 2 FRR Edge routers connected via evpn-transit (10.250.0.0/24)
  - eBGP peering between sites: edge1 (AS 65001) ↔ edge2 (AS 65002)
  - iBGP within each site: cluster nodes ↔ local edge router

But there is NO stretched network and NO EVPN routes exchanged yet."
wait
clear

# ==============================================================
# TERMINOLOGY — BGP EVPN Concepts
# ==============================================================

say "Before we dive in, let's establish a shared vocabulary.
Understanding these terms makes everything clearer." 226
wait
clear

redhatsay '**Primer — BGP EVPN Terminology**

BGP  EVPN  VNI  VTEP  CUDN  VXLAN
AS  iBGP  eBGP  Transit  Site-Networks'
wait
clear

say "BGP (Border Gateway Protocol)
──────────────────────────────────
The routing protocol that carries EVPN route information
between edge routers and cluster nodes. Think of BGP as
the postal service of the network — it delivers route
announcements. Two flavors:
  • iBGP  — Internal BGP (same AS number)
  • eBGP  — External BGP (different ASes)
    Here: eBGP between edge1 (AS 65001) ↔ edge2 (AS 65002)" 117
wait
clear

say "EVPN (Ethernet VPN)
──────────────────────
An extension of BGP for L2/L3 VPN services. Distributes
MAC addresses and IP bindings via BGP instead of legacy
flooding-based protocols. Key route types:
  • Type-2 — MAC/IP Advertisement (workload location)
  • Type-3 — IMET (BUM traffic flooding trees)" 117
wait
clear

say "VNI (VXLAN Network Identifier)
──────────────────────────────────
A 24-bit tag (like a VLAN ID) for a virtual L2 segment.
Our demo: VNI 110. Traffic between clusters is encapsulated
in VXLAN tunnels tagged with this VNI, keeping each network
isolated from others."
wait
clear

say "VTEP (VXLAN Tunnel Endpoint)
────────────────────────────────
The source/destination IP of VXLAN tunnels. Each OVN-K
worker node is a VTEP — it encapsulates outgoing traffic
and decapsulates incoming VXLAN. EVPN Type-3 routes tell
every VTEP which other VTEPs are in the same broadcast domain.
VTEPs use their site network IPs (10.100.x.x or 10.200.x.x)."
wait
clear

say "CUDN (Cluster User Defined Network)
──────────────────────────────────────
OVN-K CR that defines a network segment: subnet, topology
(Layer2), VNI, MTU, IP allocation. The CUDN is the blueprint
for the stretched network — the 'what.'"
wait
clear

say "RouteAdvertisement (RA) & VTEP CRs
──────────────────────────────────────
  • RouteAdvertisement — OVN-K CR that tells frr-k8s to
    advertise the CUDN's routes into BGP EVPN
  • VTEP — OVN-K CR that configures the local VXLAN tunnel
    endpoint CIDR, picking the correct source IP"
wait
clear

say "VXLAN (Virtual eXtensible LAN)
──────────────────────────────────
L2-over-IP encapsulation. Wraps the original Ethernet frame
in an outer IP/UDP envelope, addressed from source VTEP
to destination VTEP. VNI in the VXLAN header identifies
which L2 segment the frame belongs to."
wait
clear

say "Transit & Site Networks
────────────────────────────────────────
  • Site Network — One podman bridge per cluster.
    evpn-site1 (10.100.0.0/24) for C1, evpn-site2
    (10.200.0.0/24) for C2. No direct routing between them.
  • Transit Network — The podman bridge connecting the two
    edge routers (evpn-transit, 10.250.0.0/24). This is
    where eBGP peering happens between sites.
  • Edges are dual-homed: site network + transit network.
    They are the ONLY devices bridging the two sites." 117
wait
clear

say "AS (Autonomous System)
───────────────────────
A collection of IP prefixes under one administrative domain,
identified by a unique AS number. Here:
  • AS 65001 — Cluster 1 + edge1 (iBGP domain)
  • AS 65002 — Cluster 2 + edge2 (iBGP domain)
  • eBGP between AS 65001 and AS 65002 on the transit
This mirrors a real WAN: independent sites, external peering."
wait
clear

say "That covers the essentials. Let's put them to work."
wait
clear

# ==============================================================
# ACT 0 — Network Topology
# ==============================================================
act "0" "Network Topology Overview"

say "Before we configure EVPN, let's inspect the network layout.
Each cluster lives on its own podman bridge network — completely isolated.
The edge routers are the only containers that bridge the gap."
wait

comment "Showing podman networks (note the separate site + transit networks)..."
pe "podman network ls --format 'table {{.Name}}\t{{.Driver}}' | grep -E 'NAME|evpn|kind'"
wait

comment "Edge1 is dual-homed: site1 (10.100.0.100) + transit (10.250.0.1)..."
pe "podman inspect evpn-edge1 --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{printf \"%s=%s \" \$k \$v.IPAddress}}{{end}}'"
wait

comment "Edge2 is dual-homed: site2 (10.200.0.100) + transit (10.250.0.2)..."
pe "podman inspect evpn-edge2 --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{printf \"%s=%s \" \$k \$v.IPAddress}}{{end}}'"
wait
clear

# ==============================================================
# ACT 1 — Creating the EVPN Fabric
# ==============================================================
act "1" "Configuring the Stretched L2 Segment"

say "We begin by creating a standard Namespace with the primary UDN label on both clusters."
wait

show_manifest "${MANIFESTS_DIR}/namespace.yaml"

comment "Creating and labeling the namespaces simultaneously..."
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/namespace.yaml"
pei "kubectl-c2 apply -f ${MANIFESTS_DIR}/namespace.yaml"
wait
clear

say "Now we define the Stretched Fabric. The VTEP CIDRs cover BOTH site networks
(10.100.0.0/16 and 10.200.0.0/16) so OVN-K can pick the right source IP on each node.

Both clusters share the same CUDN subnet (192.170.1.0/24). Since 'reservedSubnets'
is Layer3-only (not supported for Layer2 topology in this OVN-K build), each
cluster allocates independently. If both pods happen to get the same IP, we
simply delete and recreate one — the next allocation will differ."
wait

show_manifest "${MANIFESTS_DIR}/evpn-fabric-c1.yaml"

comment "Applying the fabric configurations to both clusters..."
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
pei "kubectl-c2 apply -f ${MANIFESTS_DIR}/evpn-fabric-c2.yaml"
p ""

comment "Verifying acceptance of EVPN configurations on Cluster 1..."
pe "kubectl-c1 get vtep,cudn,ra"
wait
clear

# ==============================================================
# ACT 2 — BGP EVPN Convergence
# ==============================================================
act "2" "BGP EVPN Peerings and Routes (eBGP Transit)"

say "The RouteAdvertisements controller auto-generated per-node BGP configuration!
Let's inspect the FRR edge routers to verify that L2VPN EVPN routing has converged.

The two edges peer via eBGP (different ASes) over the dedicated transit
network — just like a real inter-site WAN deployment."
wait

comment "Checking BGP summary on evpn-edge1 (AS 65001) — note the eBGP peer to edge2..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp summary'"
wait

comment "Checking BGP L2VPN EVPN session states on evpn-edge1..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn summary'"
wait

say "Now let's look at EVPN Type-3 (IMET — Inclusive Multicast Ethernet Tag) routes.
These advertise which VTEPs belong to the same broadcast domain (VNI 110).
Each worker node announces itself as an originator IP, forming the flooding list
for BUM traffic (broadcast, unknown unicast, multicast) on the stretched segment.

These routes flow: cluster1 nodes → edge1 (iBGP) → edge2 (eBGP) → cluster2 nodes."
wait

comment "Inspecting EVPN Type-3 (IMET) routes on evpn-edge1..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route type multicast'"
wait

comment "Verifying the same routes propagated to evpn-edge2 via eBGP transit..."
pe "podman exec evpn-edge2 vtysh -c 'show bgp l2vpn evpn route type multicast'"
wait
clear

# ==============================================================
# ACT 3 — Deploying Workloads
# ==============================================================
act "3" "Deploying Stretched Workloads"

say "Let's deploy two workloads. They are placed in different clusters but attach to the same primary network segment."
wait

show_manifest "${MANIFESTS_DIR}/pod-vm-a.yaml"
show_manifest "${MANIFESTS_DIR}/pod-vm-b.yaml"

comment "Spawning VM-A (Cluster 1) and VM-B (Cluster 2)..."
pe "kubectl-c1 apply -f ${MANIFESTS_DIR}/pod-vm-a.yaml"
pe "kubectl-c2 apply -f ${MANIFESTS_DIR}/pod-vm-b.yaml"
wait

comment "Waiting for pods to reach Ready state..."
pe "kubectl-c1 wait --for=condition=Ready pod vm-a -n vm-workloads --timeout=30s"
pe "kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=30s"
wait
clear

say "Let's extract their assigned CUDN IP addresses. Since 'reservedSubnets' is not supported for
Layer2 topology, IPAM runs independently on each cluster. If both pods get the same IP, delete
and recreate one pod until they differ (typically takes 1 retry)."

comment "Fetching VM-A CUDN IP (Cluster 1)..."
pe "kubectl-c1 get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""

comment "Fetching VM-B CUDN IP (Cluster 2)..."
pe "kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""

# If both pods received the same IP, recreate one and retry
VM_A_IP=$(KUBECONFIG="${KUBECONFIG_C1}" kubectl get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])" 2>/dev/null | cut -d/ -f1)
VM_B_IP=$(KUBECONFIG="${KUBECONFIG_C2}" kubectl get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])" 2>/dev/null | cut -d/ -f1)
if [[ -n "${VM_A_IP}" && "${VM_A_IP}" == "${VM_B_IP}" ]]; then
    comment "Same IP detected! Recreating vm-b to get a different allocation..."
    pe "kubectl-c2 delete pod vm-b -n vm-workloads --force --grace-period=0 --wait=false"
    sleep 5
    pe "kubectl-c2 apply -f ${MANIFESTS_DIR}/pod-vm-b.yaml"
    pe "kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=30s"
    comment "Checking VM-B's new IP..."
    pe "kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""
fi
wait
clear

# ==============================================================
# ACT 4 — Control Plane Verification
# ==============================================================
act "4" "Under the Hood: EVPN Type-2 Routes and Data Plane"

say "As soon as the workloads spun up, OVN-K advertised their MAC + IP combinations
into BGP EVPN as Type-2 (MAC/IP Advertisement) routes. Each entry shows:

  [2]:[EthTag]:[MAClen]:[MAC]:[IPlen]:[IP]

These routes travel across the eBGP transit:
  Cluster 1 worker → edge1 (iBGP, AS 65001) → edge2 (eBGP, AS 65002) → Cluster 2 worker

Let's verify the edge router has learned these routes."
wait

comment "Checking EVPN Type-2 (MAC/IP) routes on evpn-edge1..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route type macip'"
wait

comment "Verifying Type-2 routes propagated to evpn-edge2 via eBGP..."
pe "podman exec evpn-edge2 vtysh -c 'show bgp l2vpn evpn route type macip'"
wait

say "Those Type-2 routes are installed as forwarding entries in the kernel.
The Linux Bridge FDB on the Cluster 1 worker node tells us which MAC address
lives behind which remote VTEP IP. A remote MAC learned via EVPN will show up
here with the destination tunnel endpoint.

Let's check — we're looking for VM-B's MAC mapped to the Cluster 2 worker IP
(on the evpn-site2 network, 10.200.0.x)."
wait

comment "Checking Linux Bridge FDB entries on the Cluster 1 worker node..."
pe "podman exec evpn-cluster1-worker bridge fdb show dev evbr-evpn-vtep"
wait

say "And finally, the local ARP (neighbor) table on Cluster 1's SVI interface shows
which IP addresses the local node has resolved on the stretched segment."
wait

# Resolve the SVI vlan interface name (svl2.<vni>) — it varies per deployment
SVI_DEV=$(podman exec evpn-cluster1-worker sh -c "ip -br link | awk -F'[@ ]' '/svl2\./{print \$1; exit}'")

comment "Checking local IP neighbor (ARP) table on Cluster 1 SVI interface (${SVI_DEV})..."
pe "podman exec evpn-cluster1-worker ip neigh show dev ${SVI_DEV}"
wait
clear

# ==============================================================
# ACT 5 — Connectivity and Ping
# ==============================================================
act "5" "Cross-Cluster Ping over Isolated Networks"

say "Now, the moment of truth. Traffic must traverse:
  VM-A → Cluster 1 worker (evpn-site1) → VXLAN tunnel →
  Cluster 2 worker (evpn-site2) → VM-B

The two clusters are on completely separate podman bridge networks,
yet the EVPN overlay makes them appear as one Layer-2 segment."
wait

# Extract VM-B IP and strip the mask for the command
VM_B_IP_FULL=$(KUBECONFIG=${KUBECONFIG_C2} kubectl get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")
VM_B_IP=$(echo "${VM_B_IP_FULL}" | cut -d'/' -f1)

comment "Pinging VM-B (${VM_B_IP}) from inside VM-A..."
pe "kubectl-c1 exec vm-a -n vm-workloads -- ping -c 4 ${VM_B_IP}"
wait

comment "Checking the pod ARP table inside VM-A..."
pe "kubectl-c1 exec vm-a -n vm-workloads -- arp -a"
wait
clear

redhatsay '**Ping works across isolated networks!**

VM-A ↔ VM-B over the EVPN overlay'

# ==============================================================
# ACT 6 — Web UI Visualization
# ==============================================================
act "6" "Live Real-Time Web Visualization"

say "Let's open our live visualization dashboard at http://localhost:8080.
We will see:
  - Real-time topology with the separate site networks and transit link
  - Circular Pod nodes hovering above their hosting worker nodes
  - Live BGP sessions (iBGP within sites, eBGP on transit)
  - Direct UI action: Launching a continuous ping and animating route propagation!"
wait

comment "Opening the Web UI in your browser..."
if command -v open &>/dev/null; then
    open "http://localhost:8080"
elif command -v xdg-open &>/dev/null; then
    xdg-open "http://localhost:8080" >/dev/null 2>&1 || true
fi
wait

say "Demo complete! You have successfully demonstrated OVN-K Stretched L2 EVPN
across isolated networks with eBGP transit."

redhatsay '**EVPN Stretched L2 — that'\''s how it works!**

OVN-Kubernetes  BGP EVPN  eBGP transit'
