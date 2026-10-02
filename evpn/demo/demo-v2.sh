#!/usr/bin/env bash
# OVN-Kubernetes Multi-Tenant Networking — Presentation Script
#
# Showcases what OVN-Kubernetes makes possible across isolated sites, for
# both pods and virtual machines:
#   0. Enterprise topology baseline (two sites, eBGP transit, provider edges)
#   1. Tenant isolation with User Defined Networks (UDN, Layer3, primary)
#   2. Publish a UDN into the existing BGP fabric — plain Layer2, NO EVPN
#   3. Stretch L2 across sites with BGP EVPN (VNI 110)
#   4. Cross-site connectivity (workloads, routes, ping)
#   5. Cross-site LoadBalancer services with MetalLB over the same BGP fabric
#   6. Live visualization dashboard
#
# Starts from a pre-provisioned infrastructure baseline (clusters, edges, BGP
# peering, MetalLB). Run from repo root:
#   ./evpn/demo/demo-v2.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")
cd "${REPO_ROOT}"

# Include demo-magic and the shared presentation helpers (act, say, comment,
# show_manifest, redhatsay, and a NO_WAIT-aware wait).
. "${REPO_ROOT}/scripts/demo-magic.sh"
. "${REPO_ROOT}/scripts/helpers.sh"

# Configuration
TYPE_SPEED=${TYPE_SPEED:-40}
DEMO_PROMPT="${GREEN}\$ ${COLOR_RESET}"
EVPN_DIR="evpn"
export KUBECONFIG_C1="${EVPN_DIR}/kubeconfig.evpn-cluster1"
export KUBECONFIG_C2="${EVPN_DIR}/kubeconfig.evpn-cluster2"
MANIFESTS_DIR="${EVPN_DIR}/demo/manifests-v2"
OPEN_BROWSER="${OPEN_BROWSER:-true}"
_DEMO_START=$(date +%s)

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

# Pre-flight Check: Ensure BGP infra is running
if [[ ! -f "${KUBECONFIG_C1}" || ! -f "${KUBECONFIG_C2}" ]]; then
    echo -e "${RED}Error: Kubeconfigs not found. Run './evpn/clusters-v2.sh create' first to stand up the infra.${COLOR_RESET}"
    exit 1
fi

# Pre-flight Reset (silently reset demo state to a pristine starting point)
echo -e "${GREY}Pre-flight: Cleaning up existing demo resources...${COLOR_RESET}"
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete ns vm-workloads tenant-a udn-bgp --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete ns l3-services --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C1}" kubectl delete vtep,cudn,ra --all --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete ns vm-workloads --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete ns l3-services --ignore-not-found --grace-period=0 --force --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete vtep,cudn,ra --all --timeout=15s >/dev/null 2>&1 &
KUBECONFIG="${KUBECONFIG_C2}" kubectl delete frrconfiguration udn-subnets -n frr-k8s-system --ignore-not-found >/dev/null 2>&1 &

# Wait for namespaces to be fully gone from both clusters (Kubernetes deletes them asynchronously)
for kc in "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"; do
    for ns in vm-workloads l3-services tenant-a udn-bgp; do
        while KUBECONFIG="${kc}" kubectl get ns "${ns}" >/dev/null 2>&1; do
            echo "Waiting for namespace ${ns} to be completely deleted on cluster..."
            sleep 2
        done
    done
done

# Ensure Web UI is running
./evpn/clusters-v2.sh ui start >/dev/null 2>&1 || true

# ==============================================================
# INTRO
# ==============================================================
clear
echo '**OVN-Kubernetes Multi-Tenant Networking**

Isolation for tenants  •  BGP integration
Stretched L2 for VMs and pods  •  BGP services' | gum format | redhatsay
wait
clear

say "Using OVN-Kubernetes for network multi-tenancy — for virtual machines AND pods.

Demo:
  1. Carve out an isolated tenant network (UDN) — segmentation in minutes
  2. Publish a pod network straight into BGP — no overlay, no EVPN
  3. Stretch one L2 segment across sites with BGP EVPN — VMs keep their IPs
  4. Announce LoadBalancer services across sites with MetalLB

Yes, this is a live demo"
wait
clear

# ==============================================================
# ACT 0 — Enterprise topology baseline
# ==============================================================
act "Baseline" "Two Sites, One BGP Fabric"

say "The starting point mirrors an enterprise DC: two sites on isolated
networks, provider edges in between, external BGP peering on a transit link.

  Cluster 1 (site 1)  → evpn-site1   (10.100.0.0/24, AS 65001)
  Cluster 2 (site 2)  → evpn-site2   (10.200.0.0/24, AS 65002)
  Edges peer eBGP: edge1 (10.250.0.1) ↔ edge2 (10.250.0.2)

No tenant networks, no stretched segments yet — just the underlay."
wait
clear
viu evpn/demo/bgp.png -w 120
wait
clear

comment "Separate site networks plus the shared transit..."
pei "podman network ls --format 'table {{.Name}}\t{{.Driver}}' | grep -E 'NAME|evpn|kind'"

comment "The edges are the only bridge between sites (site + transit addresses)..."
pei "podman inspect evpn-edge1 --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{printf \"%s=%s \" \$k \$v.IPAddress}}{{end}}'"
pei "podman inspect evpn-edge2 --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{printf \"%s=%s \" \$k \$v.IPAddress}}{{end}}'"
wait
clear

# ==============================================================
# ACT 1 — Tenant isolation with a plain UDN
# ==============================================================
act "Plain UDN´s" "Tenant Networks in Minutes"

say "Use case one: a tenant team needs its own isolated network — for pods
today, for VMs tomorrow. A namespace-scoped UserDefinedNetwork gives them
exactly that: their own subnet, their own default route, unreachable from
every other network in the cluster.

One rule to know: the namespace must carry the primary-UDN label at creation
time — admission policy rejects adding it later."
wait
clear

show_manifest "${MANIFESTS_DIR}/udn-tenant.yaml"

wait
clear

comment "One manifest: namespace + tenant network + first workload..."
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/udn-tenant.yaml"
kubectl-c1 wait --for=condition=Ready pod app-a -n tenant-a --timeout=30s
wait
clear

say "The pod now has TWO interfaces: eth0 on the cluster network (kubelet
healthchecks only) and ovn-udn1 on the tenant network with its own default
route. For a VM the attachment point is the same: request the network by
name and the address can even persist across live migration."
wait

comment "Tenant address on ovn-udn1, cluster address on eth0..."
pei "kubectl-c1 exec app-a -n tenant-a -- ip -o addr | grep -v '127.0.0.1\|::1'"
wait

comment "Egress still works — SNATed through the node gateway..."
pei "kubectl-c1 exec app-a -n tenant-a -- ping -c 2 10.100.0.100"
wait

comment "But pods on the cluster network are unreachable — native isolation, no policies needed..."
pei "DNS_IP=\$(kubectl-c1 get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}'); kubectl-c1 exec app-a -n tenant-a -- ping -c 2 -W 1 \${DNS_IP} || true"
wait
clear

redhatsay '**Tenant network: isolated, egressing, in one manifest**

Same mechanism serves VMs — and IPs can persist
across VM live migration'
wait
clear

# ==============================================================
# ACT 2 — Publish a UDN with BGP: Layer2, no EVPN
# ==============================================================
act "UDN´s with BGP" "Pods Directly on the provider network — No EVPN Required"

say "Use case two: integrate Kubernetes with the infrastructure you already
have. A plain Layer2 ClusterUserDefinedNetwork — no EVPN transport, no VNI —
whose pod subnet is exported into BGP by a RouteAdvertisements object.

External clients then reach pod IPs directly, unSNATed. This is what
third-party load balancers and existing DC fabrics need: real routes to
real pods."
wait

comment "A flat L2 segment plus an export rule into the default VRF..."
show_manifest "${MANIFESTS_DIR}/udn-bgp-net.yaml"

comment "Network and export on cluster 1, receiver rule on cluster 2..."
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/udn-bgp-net.yaml"
pei "kubectl-c2 apply -f ${MANIFESTS_DIR}/udn-bgp-receive.yaml"
wait

comment "Wait for the export to be accepted before deploying the consumer..."
kubectl-c1 wait --for=jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}'=True routeadvertisements/udn-bgp-ra --timeout=60s
show_manifest "${MANIFESTS_DIR}/udn-bgp-pod.yaml"
pe "kubectl-c1 apply -f ${MANIFESTS_DIR}/udn-bgp-pod.yaml"
kubectl-c1 wait --for=condition=Ready pod udn-web -n udn-bgp --timeout=30s
wait
clear

say "Two things to notice in that manifest. First, the CUDN has NO transport
field — this is ordinary OVN networking, announced as plain IPv4 unicast.
Second, the RouteAdvertisements object omits targetVRF, so it exports over
the default VRF using the SAME peering template as everything else in this
demo — one BGP session per node, many consumers."
wait

comment "The export is accepted; the pod sits on the segment..."
pe "kubectl-c1 get ra udn-bgp-ra -o wide"
pe "kubectl-c1 exec udn-web -n udn-bgp -- ip -o addr | grep 192.170"
wait

comment "Edge1 learned the /24 from a cluster1 node over iBGP..."
pei "podman exec evpn-edge1 vtysh -c 'show bgp ipv4 unicast 192.170.10.0/24'"
wait

comment "Edge2 learned it over the eBGP transit (AS path 65001)..."
pei "podman exec evpn-edge2 vtysh -c 'show bgp ipv4 unicast 192.170.10.0/24'"
wait
clear

say "Final proof, in both directions. The cluster2 nodes installed the pod
subnet via edge2 — and the pod itself reaches across the transit. Pod IPs
as first-class citizens of your existing routing domain."
wait

comment "Cluster2 worker installed the pod subnet (via edge2)..."
pei "UDN_IP=\$(kubectl-c1 exec udn-web -n udn-bgp -- ip -o addr | grep -o '192\\.170\\.10\\.[0-9]*' | head -1); kubectl-c2 exec -n frr-k8s-system \$(kubectl-c2 get pods -n frr-k8s-system -l app.kubernetes.io/component=frr-k8s --field-selector spec.nodeName=evpn-cluster2-worker -o name | head -1) -c frr -- ip route get \${UDN_IP}"
wait

comment "And the pod reaches the remote site — its identity is routable..."
pei "kubectl-c1 exec udn-web -n udn-bgp -- ping -c 3 10.200.0.3"
wait

redhatsay '**Pod IPs as BGP routes — consumable anywhere**

No EVPN, no overlay. Just routes your DC already understands.'
wait
clear

# ==============================================================
# ACT 3 — Stretched L2 with BGP EVPN
# ==============================================================
act "3" "One L2 Segment Across Sites (BGP EVPN)"

say "Use case three: seamless mobility. A virtual machine — or a pod — that
keeps its MAC and IP while moving between sites needs one broadcast domain
spanning both. BGP EVPN carries exactly that: MAC+IP bindings as Type-2
routes, broadcast trees as Type-3, inside VXLAN tunnels between VTEPs.

Four resources wire it up; the RouteAdvertisements controller generates the
per-node FRR config from the template:"
wait

comment "Standard namespace, stretched fabric on both clusters..."
show_manifest "${MANIFESTS_DIR}/namespace.yaml"
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/namespace.yaml"
pei "kubectl-c2 apply -f ${MANIFESTS_DIR}/namespace.yaml"
wait

comment "VTEP + CUDN (VNI 110) + RouteAdvertisements on both sites..."
show_manifest "${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/evpn-fabric-c1.yaml"
pei "kubectl-c2 apply -f ${MANIFESTS_DIR}/evpn-fabric-c2.yaml"
p ""

comment "Acceptance on both clusters..."
pe "kubectl-c1 get vtep,cudn,ra"
wait
clear

say "The RouteAdvertisements controller auto-generated per-node BGP config.
The two edges exchange EVPN over the eBGP transit — Type-3 (IMET) routes
build the broadcast tree first, before any workload exists."
wait

comment "Sessions converged over the transit (note the eBGP peer)..."
pei "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn summary'"
wait

comment "Type-3 routes on edge1 — every worker announced as a VTEP..."
pei "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route type multicast'"
wait

comment "Same routes relayed to edge2 via eBGP..."
pei "podman exec evpn-edge2 vtysh -c 'show bgp l2vpn evpn route type multicast'"
wait
clear

# ==============================================================
# ACT 4 — Workloads, Type-2 routes, ping
# ==============================================================
act "4" "Workloads on the Stretched Segment"

say "Deploy one workload per site on the same L2 segment — name them VMs,
they behave like it. Watch their MAC+IP appear as Type-2 routes, then ping
across the isolated networks."
wait

show_manifest "${MANIFESTS_DIR}/pod-vm-a.yaml"
show_manifest "${MANIFESTS_DIR}/pod-vm-b.yaml"

comment "Spawning VM-A (site 1) and VM-B (site 2)..."
pe "kubectl-c1 apply -f ${MANIFESTS_DIR}/pod-vm-a.yaml"
pe "kubectl-c2 apply -f ${MANIFESTS_DIR}/pod-vm-b.yaml"
wait

say "For real virtual machines the attachment is identical: a KubeVirt VM
requests the CUDN by name through the same NAD/IPAM mechanism, and the
address can persist across live migration — so a VM keeps its identity
while moving between these sites."
wait

comment "Waiting for Ready..."
kubectl-c1 wait --for=condition=Ready pod vm-a -n vm-workloads --timeout=30s
kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=30s
wait
clear

say "Each cluster allocates CUDN IPs independently — there is no cross-site
IPAM, which is inherent to stretched L2. If both land on the same address,
recreate one."
wait

comment "Fetching CUDN IPs from the pod annotations..."
pei "kubectl-c1 get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""
pei "kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""

VM_A_IP=$(KUBECONFIG="${KUBECONFIG_C1}" kubectl get pod vm-a -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])" 2>/dev/null | cut -d/ -f1)
VM_B_IP=$(KUBECONFIG="${KUBECONFIG_C2}" kubectl get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])" 2>/dev/null | cut -d/ -f1)
if [[ -n "${VM_A_IP}" && "${VM_A_IP}" == "${VM_B_IP}" ]]; then
    comment "Same IP detected! Recreating vm-b for a different allocation..."
    pe "kubectl-c2 delete pod vm-b -n vm-workloads --force --grace-period=0 --wait=false"
    sleep 5
    pe "kubectl-c2 apply -f ${MANIFESTS_DIR}/pod-vm-b.yaml"
    kubectl-c2 wait --for=condition=Ready pod vm-b -n vm-workloads --timeout=30s
    pe "kubectl-c2 get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])\""
fi
wait
clear

say "Type-2 (MAC/IP) routes now carry each workload's location through the
transit — visible on both edges. Then the kernel does the rest: remote MACs
land in the bridge FDB behind the remote VTEP."
wait

comment "Type-2 routes on both edges..."
pe "podman exec evpn-edge1 vtysh -c 'show bgp l2vpn evpn route type macip'"
pe "podman exec evpn-edge2 vtysh -c 'show bgp l2vpn evpn route type macip'"
wait

comment "Remote MAC in the kernel FDB behind the site-2 VTEP..."
pe "podman exec evpn-cluster1-worker bridge fdb show dev evbr-evpn-vtep | grep -v permanent"
wait
clear

say "Moment of truth — traffic must traverse the VXLAN underlay between two
completely separate podman networks, yet the overlay makes it one segment."
wait

VM_B_IP_FULL=$(KUBECONFIG=${KUBECONFIG_C2} kubectl get pod vm-b -n vm-workloads -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])")
VM_B_IP=$(echo "${VM_B_IP_FULL}" | cut -d'/' -f1)

comment "Pinging VM-B (${VM_B_IP}) from inside VM-A..."
pei "kubectl-c1 exec vm-a -n vm-workloads -- ping -c 4 ${VM_B_IP}"
wait

comment "Remote MAC learned via EVPN, right in the pod ARP table..."
pei "kubectl-c1 exec vm-a -n vm-workloads -- arp -a"
wait
clear

redhatsay '**Ping works across isolated networks!**

VM-A ↔ VM-B over the EVPN overlay'
wait
clear

# ==============================================================
# ACT 5 — MetalLB BGP Services
# ==============================================================
act "5" "Cross-Site Services with MetalLB (BGP)"

say "Use case four: expose services, not just pods. MetalLB announces a
Kubernetes LoadBalancer VIP into the SAME BGP fabric — it shares the
existing frr-k8s daemon with OVN-Kubernetes, so one session per node serves
both consumers.

VIP pools:
  Cluster 1 → 192.170.2.100-149
  Cluster 2 → 192.170.2.150-199"
wait

comment "MetalLB peering at the local provider edge (iBGP, site AS)..."
pei "kubectl-c1 get bgppeer,ipaddresspool,bgpadvertisement -n metallb-system"
wait

comment "Deploying a web service and requesting a LoadBalancer..."
show_manifest "${MANIFESTS_DIR}/l3-service.yaml"
pei "kubectl-c1 apply -f ${MANIFESTS_DIR}/l3-service.yaml"
kubectl-c1 wait --for=condition=Available deployment/web -n l3-services --timeout=60s
pei "kubectl-c1 get svc -n l3-services"
wait

say "The node's FRR announced the VIP to edge1 over iBGP; edge1 redistributed
it over the eBGP transit; edge2 reflected it to the site-2 nodes."
wait

# Extract the assigned VIP
VIP=""
for _ in $(seq 1 30); do
    VIP=$(KUBECONFIG="${KUBECONFIG_C1}" kubectl get svc web -n l3-services -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [[ -n "${VIP}" ]] && break
    sleep 2
done

if [[ -z "${VIP}" ]]; then
    echo -e "${RED}Error: no LoadBalancer VIP was assigned. Is MetalLB running? (./evpn/clusters-v2.sh create)${COLOR_RESET}"
    exit 1
fi

comment "Edge1 (AS 65001): VIP learned from the cluster1 node via iBGP..."
pei "podman exec evpn-edge1 vtysh -c 'show bgp ipv4 unicast ${VIP}/32'"
wait

comment "Edge2 (AS 65002): the same VIP arrived over the eBGP transit from AS 65001..."
pei "podman exec evpn-edge2 vtysh -c 'show bgp ipv4 unicast ${VIP}/32'"
wait

say "Request it from the other site with a host-network client — routed
purely by BGP (node FIB → edge2 → transit → edge1 → node), DNATed to the
backend by OVN-K. Stretched-L2 pods can't reach service VIPs; two separate
data paths, one shared control plane."
wait

comment "Deploying the client on cluster2 (host network — no L2 stretch)..."
show_manifest "${MANIFESTS_DIR}/l3-client.yaml"
pei "sed 's|__VIP__|${VIP}|' ${MANIFESTS_DIR}/l3-client.yaml | kubectl-c2 apply -f -"
wait

# Wait (silently) for the client to report a result
CLIENT_OK=0
for _ in $(seq 1 30); do
    if KUBECONFIG="${KUBECONFIG_C2}" kubectl logs vip-client -n l3-services 2>/dev/null | grep -q 'VIP-OK'; then
        CLIENT_OK=1
        break
    fi
    sleep 2
done
if [[ "${CLIENT_OK}" -eq 0 ]]; then
    echo -e "${RED}Error: cluster2 client could not reach the VIP${COLOR_RESET}"
    exit 1
fi

comment "Reading the client result..."
pei "kubectl-c2 logs vip-client -n l3-services"
wait

redhatsay '**One BGP fabric, two consumers**

OVN-K pod routes  +  MetalLB service VIPs
sharing one FRR instance and one session per node'
wait
clear

# ==============================================================
# ACT 6 — Web UI Visualization
# ==============================================================
act "6" "Live Real-Time Web Visualization"

say "All of this state is visible live at http://localhost:8080:
  - Topology with site networks and transit link
  - Workloads with CUDN IPs and MACs
  - BGP sessions (iBGP in sites, eBGP on transit)
  - BGP Services panel — VIPs and where each edge learned them
  - Try it: launch a ping and watch the route animation!"
wait

comment "Opening the Web UI in your browser..."
if [ "${OPEN_BROWSER}" = "true" ]; then
    if command -v open &>/dev/null; then
        open "http://localhost:8080"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "http://localhost:8080" >/dev/null 2>&1 || true
    fi
fi
wait

say "Takeaways for growing, complex enterprise environments:
  • Tenant isolation is a manifest away — UDNs segment pods AND VMs
  • Pod networks plug straight into existing BGP — less operational complexity
  • Stretched L2 over EVPN keeps VM/pod IPs stable across sites
  • Services ride the same fabric with MetalLB
  • One control plane, strict separation, standard protocols"

redhatsay '**OVN-Kubernetes networking — that'\''s how it works!**

UDN  BGP  BGP EVPN  eBGP transit  MetalLB'
