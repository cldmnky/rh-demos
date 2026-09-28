# EVPN Multi-Cluster Stretched L2 Demo (v2 — Isolated Sites + eBGP Transit)

End-to-end demo that stretches a Layer-2 network across two independent
kind clusters using **OVN-Kubernetes BGP EVPN**. Each cluster lives on its
own podman site network with a local FRR provider edge; the two edges peer
over a dedicated eBGP transit network.

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
| **2 kind clusters** | Kubernetes v1.32.0, each with 1 control-plane + 1 worker |
| **3 podman networks** | `evpn-site1` (10.100.0.0/24), `evpn-site2` (10.200.0.0/24) and `evpn-transit` (10.250.0.0/24); the shared `kind` network stays for management (API server, image pull) |
| **OVN-Kubernetes** | Helm-installed from source, EVPN + RouteAdvertisements enabled |
| **frr-k8s** | Metallb FRR-K8s v0.0.21, per-node BGP/EVPN daemon |
| **2 FRR edge containers** | quay.io/frrouting/frr:10.1.0; iBGP route reflector for their own site (AS 65001 / AS 65002) and eBGP transit speaker between sites |
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
  - `kind` v0.27+ (with podman provider)
  - `podman` (machine running, `podman machine start`)
  - `kubectl`, `helm`, `git`, `curl`
- Free disk space: ~15 GB for OVN-K image + kind cluster images

## Quick Start

```bash
# Create everything (site/transit networks, clusters, OVN-K, edges, EVPN fabric)
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

### Headless verification and demo

```bash
# Full end-to-end check against running clusters; fails closed on tracked
# kubeconfigs, transit BGP/EVPN session state, and Type-2 route propagation
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
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
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
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
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

```bash
# BGP session summary (iBGP site sessions + eBGP transit session)
podman exec evpn-edge1 vtysh -c "show bgp summary"

# L2VPN EVPN sessions and routes (Type-2 MAC/IP, Type-3 IMET)
podman exec evpn-edge1 vtysh -c "show bgp l2vpn evpn summary"
podman exec evpn-edge1 vtysh -c "show bgp l2vpn evpn"

# EVPN VNI status (local + remote VTEPs)
podman exec evpn-edge1 vtysh -c "show evpn vni"
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
| `ROUTE_TARGET` | `64512:110` | EVPN route-target (auto-derived) |
| `VTEP_CIDRS` | `10.100.0.0/16,10.200.0.0/16` | VTEP IP discovery ranges (both site networks) |
| `EVPN_NAMESPACE` | `vm-workloads` | Namespace for stretched workloads |
| `OVN_K_IMAGE` | `ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-fedora:release-1.4` | OVN-K container image |
| `OVN_K_REF` | `v1.4.0` | OVN-K git ref for Helm chart; keep it compatible with `OVN_K_IMAGE` |
| `K8S_VERSION` | `v1.32.0` | Kubernetes version for kind |

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
