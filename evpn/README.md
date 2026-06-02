# EVPN Multi-Cluster Stretched L2 Demo

End-to-end demo that stretches a Layer-2 network across two independent
kind clusters using **OVN-Kubernetes BGP EVPN**, with FRR provider-edge
containers acting as BGP route reflectors.

```
   Cluster1                              Cluster2
   ┌──────────────────────┐              ┌──────────────────────┐
   │ CUDN: stretched-l2   │              │ CUDN: stretched-l2   │
   │  L2, VNI 110          │              │  L2, VNI 110          │
   │  subnet: 192.170.1.0  │              │  subnet: 192.170.1.0 │
   │  ns: vm-workloads     │              │  ns: vm-workloads    │
   │   transport: EVPN      │              │   transport: EVPN    │
   ├──────────────────────┤              ├──────────────────────┤
   │ evbr-evpn-vtep (SVD)  │              │ evbr-evpn-vtep (SVD) │
   │ evx4-evpn-vtep (VXLAN)│              │ evx4-evpn-vtep (VXLAN)│
   │ svl2.1 (L2 SVI)       │              │ svl2.1 (L2 SVI)      │
   │ ovl2.1 (OVS→bridge)   │              │ ovl2.1 (OVS→bridge)  │
   ├──────────────────────┤              ├──────────────────────┤
   │ frr-k8s (BGP+EVPN)   │              │ frr-k8s (BGP+EVPN)   │
   │ rawConfig: VNI 110     │              │ rawConfig: VNI 110    │
   └──────────┬───────────┘              └──────────┬───────────┘
              │ BGP EVPN                             │ BGP EVPN
              ▼                                     ▼
   ┌───────────────────┐              ┌───────────────────┐
   │  evpn-edge1       │◄──BGP EVPN──│  evpn-edge2       │
   │  10.89.0.100      │   (iBGP)    │  10.89.0.101      │
   │  route-reflector  │              │  route-reflector  │
   └───────────────────┘              └───────────────────┘
```

## Architecture

| Component | Description |
|-----------|-------------|
| **2 kind clusters** | Kubernetes v1.32.0, each with 1 control-plane + 1 worker |
| **OVN-Kubernetes** | Helm-installed from source, EVPN + RouteAdvertisements enabled |
| **frr-k8s** | Metallb FRR-K8s v0.0.21, per-node BGP/EVPN daemon |
| **2 FRR edge containers** | quay.io/frrouting/frr:10.1.0, iBGP route reflectors |
| **Stretched L2 CUDN** | VNI 110, subnet 192.170.1.0/24, EVPN transport |
| **SVD data plane** | Single VXLAN Device per cluster — Linux bridge + VXLAN + VLAN |

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
# Create everything (clusters, OVN-K, edges, EVPN fabric)
./evpn/clusters.sh create

# Check status
./evpn/clusters.sh status

# Stop (preserves state)
./evpn/clusters.sh stop

# Restart
./evpn/clusters.sh start

# Destroy
./evpn/clusters.sh destroy
```

## Workloads on the Stretched Network

Pods created in the `vm-workloads` namespace are automatically attached to
the stretched L2 CUDN as their primary network. OVN-K auto-assigns IPs from
the CUDN subnet and FRR generates Type-2 EVPN routes, making the pod
reachable across both clusters.

### Deploy pods

```bash
# Cluster1 — pod lands on cluster1-worker
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl apply -f - <<'EOF'
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
KUBECONFIG=kubeconfig.evpn-cluster2 kubectl apply -f - <<'EOF'
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

### Get CUDN IPs

`kubectl get pods -o wide` shows the management IP only. The CUDN IP is in
the pod annotation:

```bash
# vm-a CUDN IP
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get pod vm-a -n vm-workloads \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])"

# vm-b CUDN IP
KUBECONFIG=kubeconfig.evpn-cluster2 kubectl get pod vm-b -n vm-workloads \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['vm-workloads/stretched-l2']['ip_address'])"
```

### Cross-cluster ping

```bash
# From vm-a (Cluster1) to vm-b (Cluster2) — travels over VXLAN via EVPN
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl exec vm-a -n vm-workloads -- \
  ping 192.170.1.<vm-b-ip>

# Verified: <2ms latency, 0% packet loss, ARP resolved via EVPN Type-2 routes
```

### Cross-cluster ARP

```bash
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl exec vm-a -n vm-workloads -- arp -a
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

## Debugging

### Pod level — find CUDN IP and verify ARP

```bash
# Get CUDN IP (not the kubectl get pods -o wide IP)
kubectl get pod vm-a -n vm-workloads \
  -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}'

# ARP table — shows remote pod MAC learned via EVPN
kubectl exec vm-a -n vm-workloads -- arp -a

# Routes — verify CUDN interface is default
kubectl exec vm-a -n vm-workloads -- ip route
```

### Cluster level — EVPN resources

```bash
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get vtep,cudn,routeadvertisements,frrconfiguration -A
```

All resources should show `ACCEPTED: True`.

### Edge level — BGP and EVPN state

```bash
# BGP session summary (all 6 sessions: 2 cluster nodes + peer edge)
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
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get pods -n ovn-kubernetes -o wide
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get pods -n frr-k8s-system -o wide
```

## Web UI

A real-time visualization dashboard runs alongside the clusters.

```bash
# Build and start
./evpn/clusters.sh ui build
./evpn/clusters.sh ui start      # → http://localhost:8080

# Manage
./evpn/clusters.sh ui stop
./evpn/clusters.sh ui status
./evpn/clusters.sh ui logs
```

The UI shows:
- **Topology graph** — kind nodes, edge containers, and live BGP session state
- **Workload inventory** — all pods in `vm-workloads`, their CUDN IPs and MACs
- **BGP sessions** — per-edge session summary with state and prefix counts
- **EVPN state** — VNI details, route-targets, remote VTEP count

All panels update in real time via Server-Sent Events (1 second refresh).

For development details, see [`ui/README.md`](ui/README.md) and the
full implementation plan at [`ui/plan.md`](ui/plan.md).

## Configuration Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `BGP_AS` | `64512` | BGP AS number for all peers |
| `CUDN_VNI` | `110` | VXLAN VNI for the stretched L2 |
| `CUDN_SUBNETS` | `192.170.1.0/24` | Subnet for the stretched CUDN |
| `ROUTE_TARGET` | `64512:110` | EVPN route-target (auto-derived) |
| `VTEP_CIDRS` | `10.89.0.0/16` | VTEP IP discovery range |
| `EVPN_NAMESPACE` | `vm-workloads` | Namespace for stretched workloads |
| `EDGE1_IP` | `10.89.0.100` | Static IP for edge1 FRR container |
| `EDGE2_IP` | `10.89.0.101` | Static IP for edge2 FRR container |
| `OVN_K_IMAGE` | `ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-fedora:master` | OVN-K container image |
| `OVN_K_REF` | `master` | OVN-K git ref for helm chart |
| `K8S_VERSION` | `v1.32.0` | Kubernetes version for kind |

## EVPN Route Types

After creating workloads in the `vm-workloads` namespace, the FRR edge
containers will show:

- **Type-2 (MAC/IP)**: Per-pod MAC+IP advertisements
- **Type-3 (IMET)**: Multicast group membership for BUM traffic replication
- **Type-5 (IP-Prefix)**: If an IP-VRF is configured on the CUDN

## References

- [OVN-Kubernetes EVPN OKEP](https://ovn-kubernetes.io/okeps/okep-5088-evpn/)
- [EVPN in OpenShift — Status and Roadmap (internal wiki)](https://github.com/cldmnky/openshift-llm-wiki/wiki/queries/evpn-roadmap)
- [Home Lab Guide (internal wiki)](https://github.com/cldmnky/openshift-llm-wiki/wiki/home-lab/evpn-multicluster-l2-vm)
- [Upstream OVN-K kind-helm.sh](https://github.com/ovn-kubernetes/ovn-kubernetes/blob/master/contrib/kind-helm.sh)
