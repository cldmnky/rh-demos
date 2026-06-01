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
the stretched L2 CUDN as their primary network. They can be assigned IPs
from `192.170.1.0/24` and communicate directly across clusters.

```yaml
# Example pod on Cluster1
apiVersion: v1
kind: Pod
metadata:
  name: vm-1
  namespace: vm-workloads
  annotations:
    k8s.ovn.org/pod-networks: |
      {"default":{"ip_addresses":["192.170.1.10/24"],"role":"primary"}}
spec:
  containers:
  - name: test
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["sleep", "infinity"]
```

```yaml
# Example pod on Cluster2
apiVersion: v1
kind: Pod
metadata:
  name: vm-2
  namespace: vm-workloads
  annotations:
    k8s.ovn.org/pod-networks: |
      {"default":{"ip_addresses":["192.170.1.20/24"],"role":"primary"}}
spec:
  containers:
  - name: test
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["sleep", "infinity"]
```

Verify cross-cluster connectivity:
```bash
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl exec -n vm-workloads vm-1 -- ping 192.170.1.20
```

## Debugging

### Check EVPN resources
```bash
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get vtep,cudn,routeadvertisements,frrconfiguration -A
```

All resources should show `ACCEPTED: True`.

### Check BGP sessions
```bash
podman exec evpn-edge1 vtysh -c "show bgp summary"
podman exec evpn-edge1 vtysh -c "show bgp l2vpn evpn"
podman exec evpn-edge1 vtysh -c "show evpn vni"
```

### Check data plane devices on a node
```bash
podman exec evpn-cluster1-control-plane bash -c "
  ip link show type bridge | grep evbr
  ip link show type vxlan | grep evx4
  bridge vni show
"
```

### Check OVN-K pods
```bash
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get pods -n ovn-kubernetes -o wide
KUBECONFIG=kubeconfig.evpn-cluster1 kubectl get pods -n frr-k8s-system -o wide
```

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
