# EVPN Multi-Cluster Stretched L2 Demo (v2 — Isolated Sites + eBGP Transit)

End-to-end demo that stretches a Layer-2 network across two independent
kind clusters using **OVN-Kubernetes BGP EVPN**. Each cluster lives on its
own podman site network with a local FRR provider edge; the two edges peer
over a dedicated eBGP transit network. **MetalLB** runs against the same
frr-k8s instance and announces Kubernetes `LoadBalancer` service VIPs across
the same eBGP fabric — one BGP session per node, two consumers.

```
   Site 1 — AS 65001                            Site 2 — AS 65002
   evpn-site1 10.100.0.0/24                     evpn-site2 10.200.0.0/24
   ┌──────────────────────┐                     ┌──────────────────────┐
   │ Cluster1             │                     │ Cluster2             │
   │ CUDN: stretched-l2   │                     │ CUDN: stretched-l2   │
   │  L2, VNI 110         │                     │  L2, VNI 110         │
   │  subnet: 192.170.1.0 │                     │  subnet: 192.170.1.0 │
   │  ns: vm-workloads    │                     │  ns: vm-workloads    │
   │  transport: EVPN     │                     │  transport: EVPN     │
   ├──────────────────────┤                     ├──────────────────────┤
   │ frr-k8s (BGP+EVPN)   │                     │ frr-k8s (BGP+EVPN)   │
   │ rawConfig: VNI 110   │                     │ rawConfig: VNI 110   │
   │ + MetalLB VIPs       │                     │ + MetalLB VIPs       │
   │   192.170.2.100-149  │                     │   192.170.2.150-199  │
   └──────────┬───────────┘                     └──────────┬───────────┘
              │ iBGP (AS 65001)                           │ iBGP (AS 65002)
              ▼                                           ▼
   ┌───────────────────┐     eBGP 65001 ↔ 65002  ┌───────────────────┐
   │  evpn-edge1       │◄───────────────────────►│  evpn-edge2       │
   │  10.100.0.100     │                         │  10.200.0.100     │
   │  10.250.0.1       │   evpn-transit          │  10.250.0.2       │
   │                   │   10.250.0.0/24         │                   │
   └───────────────────┘                         └───────────────────┘
```

## Architecture

| Component | Description |
|-----------|-------------|
| **2 kind clusters** | Kubernetes v1.34.3, each with 1 control-plane + 1 worker |
| **3 podman networks** | `evpn-site1` (10.100.0.0/24), `evpn-site2` (10.200.0.0/24) and `evpn-transit` (10.250.0.0/24); the shared `kind` network stays for management (API server, image pull) |
| **OVN-Kubernetes** | Helm-installed from source, EVPN + RouteAdvertisements enabled |
| **frr-k8s** | Metallb FRR-K8s v0.0.25, per-node BGP/EVPN daemon |
| **MetalLB** | v0.16.1 in FRR-K8s mode (`frrk8s.external`), sharing the frr-k8s instance with OVN-K for BGP `LoadBalancer` VIP announcements |
| **2 FRR edge containers** | quay.io/frrouting/frr:10.4.3; iBGP route reflector for their own site (AS 65001 / AS 65002) and eBGP transit speaker between sites |
| **Stretched L2 CUDN** | VNI 110, subnet 192.170.1.0/24, EVPN transport |
| **SVD data plane** | Single VXLAN Device per cluster — Linux bridge + VXLAN + VLAN |

### Peering model (v2)

```
cluster1 nodes ──iBGP (AS 65001)── evpn-edge1 ──eBGP (65001 ↔ 65002)── evpn-edge2 ──iBGP (AS 65002)── cluster2 nodes
```

- Each edge is the iBGP route reflector for its site's OVN-K/frr-k8s nodes
  and uses the site AS (edge1 = 65001, edge2 = 65002).
- The two edges peer with each other over `evpn-transit` using **eBGP** and
  exchange EVPN routes in both the IPv4 unicast and L2VPN-EVPN address
  families.
- EVPN route propagation path: cluster1 node → edge1 (iBGP) → edge2 (eBGP,
  transit) → cluster2 node, and symmetrically in the other direction.
- **BGP services path** (MetalLB): backend service VIP (e.g. 192.170.2.100)
  → local node frr-k8s (iBGP) → edge1 → edge2 (eBGP transit, AS path
  65001) → cluster2 nodes. Nodes install the VIP route because the MetalLB
  setup adds a `toReceive` prefix filter for the VIP supernet; edges rewrite
  the next hop to their site IP (`next-hop-self` on the iBGP client group)
  so the routes are resolvable inside each isolated site network.

## 4 OVN-K Resources Wired Together

```
FRRConfiguration ──(label selector)──▶ RouteAdvertisements
                                            │
                                     (networkSelector)
                                            │
VTEP  ◀────────────────────────────  CUDN (transport: EVPN)
```

- **VTEP** (`k8s.ovn.org/v1`): Defines VXLAN Tunnel Endpoint IP range
- **CUDN** (`k8s.ovn.org/v1`): Layer-2 ClusterUserDefinedNetwork with `transport: EVPN`
- **RouteAdvertisements** (`k8s.ovn.org/v1`): Links FRR config to CUDN labels
- **FRRConfiguration** (`frrk8s.metallb.io/v1beta1`): BGP peering toward edges

The `RouteAdvertisements` controller auto-generates per-node `FRRConfiguration`
objects with `rawConfig` containing `address-family l2vpn evpn`, VNI route-targets,
and `advertise-all-vni`.

## Prerequisites

- macOS or Linux with:
  - `kind` v0.31+ (with podman provider; v0.31.0 ships the v1.34.3 node image)
  - `podman` (machine running, `podman machine start`)
  - `kubectl`, `helm`, `git`, `curl`, `python3` (test/demo scripts parse JSON)
  - GNU `timeout` (Linux has it; on macOS `brew install coreutils`) — optional,
    the OVN-K image pull skips the timeout guard when it is missing
  - `gum` (interactive presentation), plus optional `bat` / `redhatsay`
- Free disk space: ~15 GB for OVN-K image + kind cluster images

## Quick Start

```bash
# Create everything (site/transit networks, clusters, OVN-K, edges, EVPN fabric,
# MetalLB BGP services)
./evpn/clusters-v2.sh create

# Check status
./evpn/clusters-v2.sh status

# Stop (preserves state)
./evpn/clusters-v2.sh stop

# Restart
./evpn/clusters-v2.sh start

# Destroy
./evpn/clusters-v2.sh destroy

# Build and run the web UI
./evpn/clusters-v2.sh ui build
./evpn/clusters-v2.sh ui start      # → http://localhost:8080
```

`create` also accepts `--skip-evpn` (skip the stretched L2 fabric) and
`--skip-metallb` (skip MetalLB), or set `INSTALL_METALLB=0`.

### Headless verification and demo

```bash
# Full end-to-end check against running clusters; fails closed on tracked
# kubeconfigs, transit BGP/EVPN session state, Type-2 route propagation,
# cross-cluster ping/ARP, and MetalLB VIP announcement + reachability
./evpn/demo/test-flow-v2.sh

# Interactive presentation
./evpn/demo/demo-v2.sh
```

### Legacy v1 (single shared network, iBGP)

The original v1 lab is still available but is no longer the default. See
[Legacy v1](#legacy-v1-single-shared-network-ibgp) for the full comparison.

```bash
./evpn/clusters.sh create     # v1 cluster manager
./evpn/demo/test-flow.sh      # v1 headless test
./evpn/demo/demo.sh           # v1 presentation
```

## Workloads on the Stretched Network

Pods created in the `vm-workloads` namespace are automatically attached to
the stretched L2 CUDN as their primary network. OVN-K auto-assigns IPs from
the CUDN subnet and FRR generates Type-2 EVPN routes, making the pod
reachable across both clusters.

### Deploy pods

```bash
# Cluster1 — pod lands on cluster1-worker
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: vm-a
  namespace: vm-workloads
spec:
  containers:
  - name: netexec
    image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
    command: ["sleep", "infinity"]
  nodeSelector:
    kubernetes.io/hostname: evpn-cluster1-worker
EOF

# Cluster2 — pod lands on cluster2-worker
KUBECONFIG=evpn/kubeconfig.evpn-cluster2 kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: vm-b
  namespace: vm-workloads
spec:
  containers:
  - name: netexec
    image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
    command: ["sleep", "infinity"]
  nodeSelector:
    kubernetes.io/hostname: evpn-cluster2-worker
EOF
```

The v2 manifests used by the test/demo are in
[`demo/manifests-v2/`](demo/manifests-v2/); v1 manifests stay in
[`demo/manifests/`](demo/manifests/).

### Get CUDN IPs

`kubectl get pods -o wide` shows the management IP only. The CUDN IP is in
the pod annotation:

```bash
# vm-a CUDN IP
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get pod vm-a -n vm-workloads \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])"

# vm-b CUDN IP
KUBECONFIG=evpn/kubeconfig.evpn-cluster2 kubectl get pod vm-b -n vm-workloads \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])"
```

### Cross-cluster ping

```bash
# From vm-a (Cluster1) to vm-b (Cluster2) — travels over VXLAN via EVPN
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl exec vm-a -n vm-workloads -- \
  ping 192.170.1.<vm-b-ip>

# Verified: <2ms latency, 0% packet loss, ARP resolved via EVPN Type-2 routes
```

### Cross-cluster ARP

```bash
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl exec vm-a -n vm-workloads -- arp -a
# 192.170.1.<vm-b-ip> at 0a:58:c0:aa:01:xx [ether] on ovn-udn1
```

The remote pod's MAC is learned via EVPN Type-2 routes and the L2 SVI's
neighbor table, appearing as a local ARP entry on the `ovn-udn1` interface.

### IPAM across clusters

OVN-K allocates CUDN IPs independently on each cluster. There is **no
cross-cluster IPAM coordination** — two pods may receive the same IP if
the allocation counters happen to align. This is an inherent characteristic
of stretched L2 fabrics; the EVPN underlay provides connectivity but does
not coordinate address assignment.

**Production approaches** for unique IPs across clusters:

- **`reservedSubnets`** — Carve out a range from auto-allocation on each
  cluster's CUDN, leaving non-overlapping pools per cluster:
  ```yaml
  # Cluster1 CUDN — auto-allocate from 192.170.1.0/25
  reservedSubnets: ["192.170.1.128/25"]
  # Cluster2 CUDN — auto-allocate from 192.170.1.128/25
  reservedSubnets: ["192.170.1.0/25"]
  ```
- **External DHCP** — Run a DHCP server on the stretched L2 segment (e.g.,
  a pod or external container attached to the CUDN). Omit or reserve
  subnets so OVN-K doesn't auto-allocate, and let DHCP handle all IPs.
- **Static assignment** — Use OVN-K preconfigured UDN addresses
  (`enablePreconfiguredUDNAddresses=true` + `v1.multus-cni.io/default-network`
  annotation) to assign specific IPs per pod (requires feature gate).

The v2 headless test recreates `vm-b` if both workloads land on the same
IP, and fails if a unique allocation cannot be reached.

## BGP Services with MetalLB

`clusters-v2.sh create` installs **MetalLB v0.16.1** into both clusters in
FRR-K8s mode, deliberately **reusing the existing frr-k8s daemonset**
(`frr-k8s-system`) rather than deploying its own copy:

```
OVN-K RouteAdvertisements ─┐
                           ├─ FRRConfiguration objects ─ frr-k8s (one per node) ─ iBGP ─ provider edge
MetalLB BGPPeer/BGPAdv    ─┘
```

Why this works: frr-k8s merges all `FRRConfiguration` objects that select a
node. OVN-K advertises pod/EVPN networks, MetalLB advertises service VIPs,
and both share one FRR instance, one BGP router and one session per node
toward the provider edge. Nothing about the EVPN fabric changes.

What `create` applies per cluster:

| Resource | Cluster 1 | Cluster 2 |
|----------|-----------|-----------|
| `IPAddressPool` (`evpn-pool`) | `192.170.2.100-192.170.2.149` | `192.170.2.150-192.170.2.199` |
| `BGPPeer` (`evpn-edge`) | `10.100.0.100`, AS 65001 (iBGP) | `10.200.0.100`, AS 65002 (iBGP) |
| `BGPAdvertisement` | `evpn-bgp-adv` (all peers) | `evpn-bgp-adv` (all peers) |
| `FRRConfiguration` (`metallb-vips`) | accepts `192.170.2.0/24 le 32` from edge1 | accepts `192.170.2.0/24 le 32` from edge2 |

The `metallb-vips` configuration is what lets the **nodes** install VIP
routes announced by the remote site. The edges additionally rewrite the
next hop of reflected routes to their own site IP (`neighbor ovn
next-hop-self` for IPv4 unicast), so the routes resolve inside each site
network even though the eBGP transit is not reachable from the nodes.

Two kind-lab specifics worth knowing:

- The MetalLB **controller is pinned to the control-plane node** (chart
  `controller.nodeSelector` + toleration): in this kind + OVN-K lab, pods on
  worker nodes cannot reach the Kubernetes API (neither ClusterIP nor the
  management network), while control-plane pods can. The speaker is
  `hostNetwork` and reaches the API via `KUBERNETES_SERVICE_HOST/PORT`
  patched to the node IP — the same pattern used for frr-k8s.
- The MetalLB **validating webhook** is only reachable through the ClusterIP
  (broken for the API server host), so the chart is installed with
  `crds.validationFailurePolicy=Ignore`. The webhook objects must stay in
  place: the controller's certificate rotator reconciles their `caBundle`
  and blocks startup if they are deleted.

### Try it

```bash
# Deploy a web service and request a LoadBalancer on cluster1
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 \
  kubectl apply -f evpn/demo/manifests-v2/l3-service.yaml
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 \
  kubectl get svc -n l3-services -w      # wait for EXTERNAL-IP

# Announcement on the local edge (iBGP from a cluster1 node)
podman exec evpn-edge1 vtysh -c "show bgp ipv4 unicast 192.170.2.100/32"

# Learned over the eBGP transit on edge2 (AS path 65001)
podman exec evpn-edge2 vtysh -c "show bgp ipv4 unicast 192.170.2.100/32"

# Reach the VIP from the other site with a host-network client
sed 's|__VIP__|192.170.2.100|' evpn/demo/manifests-v2/l3-client.yaml | \
  KUBECONFIG=evpn/kubeconfig.evpn-cluster2 kubectl apply -f -
KUBECONFIG=evpn/kubeconfig.evpn-cluster2 \
  kubectl logs vip-client -n l3-services     # → VIP-OK
```

The client **must run with `hostNetwork: true`** (or otherwise off the
stretched CUDN). Pods attached to a `transport: EVPN` ClusterUserDefinedNetwork
cannot reach default-network ClusterIP/LoadBalancer services — the EVPN
transport is an isolated L2 VPN, and off-VPN destinations are dropped by the
UDN's logical router with ICMP unreachable. This is also why `vm-b` is not
used as the VIP client: the L2 stretch and the BGP service path are two
independent data planes. The host-network client also gives the BGP path a
source IP the remote site can route back to (the node's advertised VTEP /32).

OVN-Kubernetes programs `status.loadBalancer.ingress` VIPs as OVN load
balancers on every node, so incoming VIP traffic is DNATed to the service
backends cluster-wide; MetalLB only owns the address assignment and the BGP
announcement. With the default `externalTrafficPolicy: Cluster` the VIP is
announced from every eligible node (ECMP).

MetalLB resources live in `metallb-system`; the address pool annotation
(`metallb.io/address-pool`) is not needed while a single pool exists per
cluster.

## Debugging

### Pod level — find CUDN IP and verify ARP

```bash
# Get CUDN IP (not the kubectl get pods -o wide IP)
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get pod vm-a -n vm-workloads \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}'

# ARP table — shows remote pod MAC learned via EVPN
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl exec vm-a -n vm-workloads -- arp -a

# Routes — verify CUDN interface is default
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl exec vm-a -n vm-workloads -- ip route
```

### Cluster level — EVPN resources

```bash
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get vtep,cudn,routeadvertisements,frrconfiguration -A
```

All resources should show `ACCEPTED: True`.

### Edge level — BGP and EVPN state

Each edge has 3 sessions: iBGP to its cluster's 2 nodes plus the eBGP
session to the peer edge (edge1 ↔ 10.250.0.2, edge2 ↔ 10.250.0.1).

> **Data-plane check:** the edges route the VXLAN underlay between sites, so
> `net.ipv4.ip_forward` must be `1` inside both edge containers
> (`podman exec evpn-edge1 cat /proc/sys/net/ipv4/ip_forward`). Every
> subcommand that (re)starts the edges enforces this, and new containers get
> it via `--sysctl net.ipv4.ip_forward=1`. If EVPN sessions and Type-2 routes
> all look healthy but pings blackhole, this is the first thing to check.

```bash
# BGP session summary (iBGP site sessions + eBGP transit session)
podman exec evpn-edge1 vtysh -c "show bgp summary"

# L2VPN EVPN sessions and routes (Type-2 MAC/IP, Type-3 IMET)
podman exec evpn-edge1 vtysh -c "show bgp l2vpn evpn summary"
podman exec evpn-edge1 vtysh -c "show bgp l2vpn evpn"

# EVPN VNI status (local + remote VTEPs)
podman exec evpn-edge1 vtysh -c "show evpn vni"
```

### Edge level — MetalLB service VIPs

```bash
# VIP route on the local edge (originated by a site node over iBGP)
podman exec evpn-edge1 vtysh -c "show bgp ipv4 unicast 192.170.2.100/32"

# On the remote edge it must show AS path 65001 (learned via eBGP transit)
podman exec evpn-edge2 vtysh -c "show bgp ipv4 unicast 192.170.2.100/32"

# MetalLB resources and the merged FRRConfiguration view
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get ipaddresspool,bgppeer,bgpadvertisement -n metallb-system
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get frrconfiguration -n frr-k8s-system
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl logs -n metallb-system daemonset/metallb-speaker --tail=50
```

### Node level — data plane devices

```bash
podman exec evpn-cluster1-control-plane bash -c "
  # SVD bridge
  ip link show type bridge | grep evbr
  # VXLAN device (VNI 110)
  ip link show type vxlan | grep evx4
  # VLAN-to-VNI mapping
  bridge vni show
  # FDB entries (static per-pod + remote via EVPN)
  bridge fdb show dev evbr-evpn-vtep
  # L2 SVI with neighbor entries from EVPN Type-2 routes
  ip neigh show dev svl2.1
"
```

### OVN-K pods

```bash
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get pods -n ovn-kubernetes -o wide
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get pods -n frr-k8s-system -o wide
KUBECONFIG=evpn/kubeconfig.evpn-cluster1 kubectl get pods -n metallb-system -o wide
```

## Web UI

A real-time visualization dashboard runs alongside the clusters.

```bash
# Build and start
./evpn/clusters-v2.sh ui build
./evpn/clusters-v2.sh ui start      # → http://localhost:8080

# Manage
./evpn/clusters-v2.sh ui stop
./evpn/clusters-v2.sh ui status
./evpn/clusters-v2.sh ui logs
```

The UI shows:
- **Topology graph** — kind nodes, edge containers, and live BGP session state
- **Workload inventory** — all pods in `vm-workloads`, their CUDN IPs and MACs
- **BGP sessions** — per-edge session summary with state and prefix counts
- **EVPN state** — VNI details, route-targets, remote VTEP count

The UI container is attached to `evpn-site1`, `evpn-site2`, `evpn-transit`
and `kind`, so it can inspect both edges (site + transit addresses) and both
clusters. Edge drawers show the v2 site IP, the edge AS (65001 / 65002), and
the provider-edge role.

All panels update in real time via Server-Sent Events (3-second collector poll).

For development details, see [`ui/README.md`](ui/README.md) and the
full implementation plan at [`ui/plan.md`](ui/plan.md).

## Configuration Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `SITE1_NETWORK` | `evpn-site1` | Podman bridge for cluster1 nodes + edge1 |
| `SITE1_SUBNET` | `10.100.0.0/24` | Site1 network subnet |
| `SITE2_NETWORK` | `evpn-site2` | Podman bridge for cluster2 nodes + edge2 |
| `SITE2_SUBNET` | `10.200.0.0/24` | Site2 network subnet |
| `TRANSIT_NETWORK` | `evpn-transit` | Podman bridge between the two edges |
| `TRANSIT_SUBNET` | `10.250.0.0/24` | eBGP transit subnet |
| `SITE1_AS` | `65001` | BGP AS for cluster1 + edge1 (iBGP) |
| `SITE2_AS` | `65002` | BGP AS for cluster2 + edge2 (iBGP) |
| `EDGE1_SITE_IP` | `10.100.0.100` | edge1 IP on `evpn-site1` |
| `EDGE2_SITE_IP` | `10.200.0.100` | edge2 IP on `evpn-site2` |
| `EDGE1_TRANSIT_IP` | `10.250.0.1` | edge1 IP on `evpn-transit` |
| `EDGE2_TRANSIT_IP` | `10.250.0.2` | edge2 IP on `evpn-transit` |
| `CUDN_VNI` | `110` | VXLAN VNI for the stretched L2 |
| `CUDN_SUBNETS` | `192.170.1.0/24` | Subnet for the stretched CUDN |
| `ROUTE_TARGET` | `64512:110` | Shared EVPN route-target imported/exported by both sites (independent of the BGP ASNs) |
| `VTEP_CIDRS` | `10.100.0.0/16,10.200.0.0/16` | VTEP IP discovery ranges (both site networks) |
| `EVPN_NAMESPACE` | `vm-workloads` | Namespace for stretched workloads |
| `OVN_K_IMAGE` | `ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-fedora:release-1.4` | OVN-K container image (ghcr publishes branch tags only; keep paired with `OVN_K_REF`) |
| `OVN_K_REF` | `v1.4.0` | OVN-K git ref for Helm chart; keep it compatible with `OVN_K_IMAGE` |
| `K8S_VERSION` | `v1.34.3` | Kubernetes version for kind (image published with kind v0.31.0) |
| `FRR_IMAGE` | `quay.io/frrouting/frr:10.4.3` | Provider edge FRR image (matches frr-k8s v0.0.25) |
| `FRR_K8S_MANIFEST_URL` | `.../frr-k8s/v0.0.25/config/all-in-one/frr-k8s.yaml` | frr-k8s manifest |
| `INSTALL_METALLB` | `1` | Install MetalLB and BGP service advertisements |
| `METALLB_VERSION` | `0.16.1` | MetalLB Helm chart version |
| `METALLB_POOL_C1` | `192.170.2.100-192.170.2.149` | Cluster1 LoadBalancer VIP pool |
| `METALLB_POOL_C2` | `192.170.2.150-192.170.2.199` | Cluster2 LoadBalancer VIP pool |
| `METALLB_VIP_SUPERNET` | `192.170.2.0/24` | VIP supernet accepted by the nodes via BGP |

## EVPN Route Types

After creating workloads in the `vm-workloads` namespace, the FRR edge
containers will show:

- **Type-2 (MAC/IP)**: Per-pod MAC+IP advertisements
- **Type-3 (IMET)**: Multicast group membership for BUM traffic replication
- **Type-5 (IP-Prefix)**: If an IP-VRF is configured on the CUDN

## Legacy v1 (single shared network, iBGP)

The original v1 lab keeps both clusters and both edges on a single shared
`kind` bridge network, with the edges acting as iBGP route reflectors in one
AS (64512). It is preserved for comparison but is not the default.

| Concern | v2 (default) | v1 (legacy) |
|---------|--------------|-------------|
| Cluster manager | `evpn/clusters-v2.sh` | `evpn/clusters.sh` |
| Network layout | `evpn-site1` + `evpn-site2` + `evpn-transit` | single `kind` network |
| Edge peering | iBGP per site + eBGP transit (AS 65001 ↔ 65002) | iBGP route reflectors (AS 64512) |
| Edge addresses | 10.100.0.100 / 10.200.0.100 (site), 10.250.0.1 / 10.250.0.2 (transit) | 10.89.0.100 / 10.89.0.101 |
| Manifests | `evpn/demo/manifests-v2/` | `evpn/demo/manifests/` |
| Headless test | `evpn/demo/test-flow-v2.sh` | `evpn/demo/test-flow.sh` |
| Presentation | `evpn/demo/demo-v2.sh` | `evpn/demo/demo.sh` |

## References

- [OVN-Kubernetes EVPN OKEP](https://ovn-kubernetes.io/okeps/okep-5088-evpn/)
- [EVPN in OpenShift — Status and Roadmap (internal wiki)](https://github.com/cldmnky/openshift-llm-wiki/wiki/queries/evpn-roadmap)
- [Home Lab Guide (internal wiki)](https://github.com/cldmnky/openshift-llm-wiki/wiki/home-lab/evpn-multicluster-l2-vm)
- [Upstream OVN-K kind-helm.sh](https://github.com/ovn-kubernetes/ovn-kubernetes/blob/master/contrib/kind-helm.sh)
- [MetalLB — BGP mode / FRR-K8s backend](https://metallb.io/concepts/bgp/)
- [frr-k8s — merging multiple FRRConfiguration objects](https://github.com/metallb/frr-k8s)
- [OVN-Kubernetes EVPN feature docs](https://github.com/ovn-kubernetes/ovn-kubernetes/blob/master/docs/features/bgp-integration/evpn.md)
- [OVN-Kubernetes — External IP and LoadBalancer Ingress VIPs](https://github.com/openshift/ovn-kubernetes/blob/master/docs/external-ip-and-loadbalancer-ingress.md)
