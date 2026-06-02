# EVPN UI — Implementation Plan

## Goals & Non-Goals

**Goals**
- A single podman container (`evpn-ui`) that visualizes the EVPN lab in real time.
- The primary deliverable for this engagement is the kind lab, with a forward path to OpenShift.
- Demo-friendly: dark theme, large fonts, three columns, no auth (it's a local demo).

**Non-Goals**
- Multi-user / RBAC / SSO.
- Long-term history, metrics storage, alerting.
- OpenShift Console plugin packaging.
- Recording / replay.

## Architecture

```
macOS host (podman machine, AppleHV)
  evpn-ui container
    --network kind  --privileged
    -v /var/run/docker.sock:/var/run/docker.sock
    -p 8080:8080

    ┌──────────┐  ┌──────────────┐  ┌────────────────────┐
    │ static   │  │  Go HTTP API │  │  collector workers  │
    │ SPA      │◄─┤  (SSE + REST)├─►│  docker-api exec    │
    │ +vis-net │  │              │  │  kubectl (k8s)      │
    └──────────┘  └──────────────┘  │  vtysh (FRR)        │
                                    └────────────────────┘

    Reaches by name on the `kind` network:
    evpn-edge1, evpn-edge2, evpn-cluster{1,2}-{control-plane,worker}
```

**Docker/Podman SDK** connects to the mounted podman socket. The Go binary uses it to list containers and exec commands into kind nodes and edge containers. Kubernetes state is fetched by exec'ing `kubectl` inside the kind control-plane nodes (which bundle kubectl).

## File Layout

```
evpn/ui/
├── Dockerfile
├── go.mod
├── go.sum
├── main.go
├── model/
│   └── types.go
├── collectors/
│   ├── podman.go
│   ├── kubernetes.go
│   ├── frr.go
│   └── dataplane.go
├── api/
│   ├── topology.go
│   ├── events.go
│   ├── workloads.go
│   ├── ping.go
│   └── static.go
├── static/
│   ├── index.html
│   ├── app.js
│   ├── topology.js
│   └── style.css
├── plan.md
└── README.md
```

## Data Model

See `model/types.go` for the canonical struct definitions.

Key types:
- `Topology` — root snapshot: clusters, edges, workloads, bgp, evpn
- `Cluster` — name, kubeconfig path, list of Node
- `Node` — name, role, IP, SVD devices
- `Device` — SVD data plane: evbr-evpn-vtep (bridge), evx4-evpn-vtep (VXLAN), svl2.1 (SVI), ovl2.1 (OVS port)
- `Edge` — FRR edge container: name, IP, BGP AS, state
- `Workload` — pod in vm-workloads: name, cluster, CUDN IP, MAC, state
- `BGPSession` — per-peer BGP session from vtysh
- `EVPNState` — VNI list, Type-2/Type-3 route counts

## API Surface

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Static SPA |
| GET | `/api/topology` | Full snapshot |
| GET | `/api/events` | SSE stream (model diff every refresh) |
| GET | `/api/workloads` | List workloads across clusters |
| POST | `/api/workloads` | Create a pod |
| DELETE | `/api/workloads/{cluster}/{namespace}/{name}` | Delete a pod |
| GET | `/api/ping?from={cluster}/{pod}&to={ip}` | SSE ping output |
| GET | `/api/healthz` | Liveness |

## Collector Strategy

| Source | Command | Cadence |
|--------|---------|---------|
| Edge containers | Docker SDK container list | 5s |
| Kind nodes | Docker SDK container list + inspect | 5s |
| Node IPs | Docker SDK inspect | 10s |
| SVD devices | kubectl exec into node: ip -j link show | 30s |
| BGP sessions | podman exec evpn-edge1 vtysh show bgp summary json | 3s |
| EVPN VNI/routes | podman exec evpn-edge1 vtysh show bgp l2vpn evpn json | 5s |
| Workloads (pods) | kubectl get pods -n vm-workloads -o json | 3s |
| CUDN/VTEP/RA status | kubectl get cudn,vtep,routeadvertisements -o json | 5s |

## Phases

### Phase 1 — MVP
- Go backend with collectors for podman containers, kind nodes, vtysh BGP/EVPN, kubectl pods/resources
- Static SPA: topology graph (vis-network), workload list, BGP sessions panel
- `clusters.sh ui` subcommand for build/start/stop/status/logs
- Live SSE updates

### Phase 2 — Interactive
- POST /api/workloads to create pods from the UI
- Cross-cluster ping with live SSE output
- Node details on click in topology

### Phase 3 — Polish
- Animated route propagation visualization
- Health indicator colors
- Keyboard shortcuts

### Phase 4 — OpenShift Forward Path
- --platform openshift flag
- OCP UDN/NAD equivalents
- Console plugin packaging
