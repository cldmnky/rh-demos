# EVPN UI — Implementation Plan & Roadmap

This document serves as the implementation plan and status tracker for the EVPN Multi-Cluster Stretched L2 Web UI.

---

## Goals & Non-Goals

### Goals
- **Real-Time Visualization**: A single lightweight container (`evpn-ui`) running on the same network that auto-discovers and visualizes the state of BGP peering, kind nodes, SVD dataplane devices, and cross-cluster workloads.
- **Visual Impact**: Demo-friendly design (dark theme by default, high-contrast, large readable typography) tailored for projectors and conference presentations.
- **Interactive Control Surface**: Shift the demo narrative from a dry terminal-only CLI loop to a real-time web dashboard where users can interactively deploy pods, trigger cross-cluster pings, and inspect routing tables.
- **Clean Architecture**: Minimal external dependencies. Go backend (serving a vanilla JS Single Page Application over SSE) communicating with the podman/docker REST socket.

### Non-Goals
- Multi-user authentication, SSO, RBAC, or persistent databases.
- Multi-tenant security or network namespace isolation.
- Long-term timeseries storage, metrics monitoring, or alerting.
- Production-ready OpenShift dynamic console plugin packaging (deferred to Phase 4).

---

## Current Status: Phase 1 (MVP) — ✅ Complete

We have fully implemented, built, and end-to-end verified the MVP.

### What was achieved and shipped (Commit `0f4e8b5`):
- **Lightweight Go Web Server (`main.go`, `sse.go`)**: Serves static frontend files and hosts a REST API coupled with an SSE (Server-Sent Events) broadcaster. Updates the UI at a 1Hz frequency.
- **Docker Socket REST Client (`collectors/exec.go`)**: Communicates with the VM's podman socket at `/run/podman/podman.sock` via `net.Dial("unix")`. This bypasses the need for the heavy Docker Go SDK, keeping the final binary footprint incredibly small.
- **Docker Stream Protocol Demuxer**: Built a stream demultiplexer to parse Docker's 8-byte framing headers (`[stream_type:1][padding:3][payload_length:4]`) from non-TTY exec terminals, extracting clean stdout streams and stripping out interleaved binary control bytes (such as `0xed`).
- **Robust VTysh JSON Stripper (`stripToJSON`)**: Cleans up FRR vtysh outputs. VTysh often writes configuration/vtysh.conf loading errors to standard streams before dumping the actual JSON. The stripper locates the first `{` or `[` and slices the buffer cleanly.
- **UBI 10 Minimal Base Image (`Dockerfile`)**: Switched from distroless to Red Hat Universal Base Image 10 Minimal (with `ca-certificates` installed), satisfying enterprise compliance and alignment with Red Hat's product catalog.
- **4 Active Collectors (`collectors/`)**:
  - `podmanCollector`: Discovers kind cluster nodes and edge route reflectors directly from the socket.
  - `k8sCollector`: Execs `kubectl get pods -n vm-workloads -o json` inside the cluster control-plane nodes to grab active workloads.
  - `frrCollector`: Execs `vtysh -c "show bgp summary json"` and `"show bgp l2vpn evpn json"` on the edges to parse session states, remote VTEPs, and route counts.
  - `dataplaneCollector`: Discovers local SVD devices (`evbr-vtep`, `evx4-vtep`) on nodes.
- **Interactive Topology Canvas (`static/topology.js`)**: Leverages `vis-network` to draw real-time nodes (kind nodes, edge diamonds) and edges (BGP sessions colored green when Up/Established and dashed/orange when connecting).
- **Responsive Panels**: Live inventory of Workloads (names, CUDN IPs, MACs, node hostname, state), BGP peers, and EVPN active routes.

---

## Extensive Plan: Phase 2 — Interactive Control Surface

**Goal**: Transform the UI from a read-only observability console into an interactive control surface where users can manipulate the stretched L2 fabric.

### Task 2.1: Workload Creation Modal
We will add support for deploying workloads directly onto the stretched L2 network via a Web UI form.

- **Backend API (`POST /api/workloads`)**:
  - Accepts a JSON payload:
    ```json
    {
      "cluster": "c1", 
      "name": "vm-c",
      "cudn_ip": "192.170.1.30",
      "node": "evpn-cluster1-worker"
    }
    ```
  - Formulates a Kubernetes Pod manifest dynamically.
  - Passes the manifest to the respective control-plane container (`evpn-cluster1-control-plane` or `evpn-cluster2-control-plane`) and applies it via a podman-socket exec call: `kubectl apply -f -`.
  - For static IP assignments, handles Multus `v1.multus-cni.io/default-network` annotations if the preconfigured addresses feature gate is enabled, or falls back to standard OVN-K CUDN auto-allocation.
- **Frontend UI Form**:
  - Unlocks the `+ Create Pod` button in `index.html`.
  - Displays a clean overlay modal with fields: Pod Name, Target Cluster, Target Node (worker vs control-plane), and optional Static IP.
  - Includes client-side validations (RFC-1123 DNS subdomains, correct subnet validation in `192.170.1.0/24`).
  - Animates the submission flow with a spinner ("Deploying...") and adds an optimistic temporary row in the Workloads table.

### Task 2.2: Workload Teardown
- **Backend API (`DELETE /api/workloads/{cluster}/{namespace}/{name}`)**:
  - Maps the cluster name to the corresponding control-plane container.
  - Execs `kubectl delete pod <name> -n <namespace> --grace-period=0 --force` to quickly clear the pod.
- **Frontend Button**:
  - Enables the red `×` button next to each workload.
  - Warns the user with a subtle confirmation modal before firing the API request.

### Task 2.3: Cross-Cluster Ping Runner (Live SSE Stream)
The marquee feature of the demo. Users see ping packets travelling over the EVPN-stretched VXLAN fabric.

- **Backend API (`GET /api/ping?from={cluster}/{name}&to={ip_or_name}`)**:
  - Upgrades the HTTP request to a Server-Sent Events (SSE) stream.
  - Launches a background goroutine to execute a persistent ping inside the source pod: `kubectl exec -n vm-workloads <name> -- ping -c 10 -i 0.5 <target_ip>`.
  - Parses each line of ping output and streams it back to the client immediately using `http.Flusher`.
  - Safely tears down the ping process if the client aborts or closes the SSE connection.
- **Frontend Visual Runner**:
  - Adds a "Ping Runner" panel at the bottom of the screen.
  - Includes a "Source Pod" dropdown (filtered to running workloads in cluster 1) and a "Target Pod" dropdown (filtered to running workloads in cluster 2).
  - Displays a terminal-like log screen showing live stdout lines (`64 bytes from 192.170.1.11...`) as they arrive.
  - Generates a summary upon completion (Packet Loss %, Avg Latency).

### Task 2.4: Node Drill-Down (FDB & Neighbors)
- **Backend APIs**:
  - `GET /api/nodes/{cluster}/{name}/fdb`: Execs `bridge fdb show dev evbr-evpn-vtep` on the node.
  - `GET /api/nodes/{cluster}/{name}/neigh`: Execs `ip neigh show dev svl2.1`.
- **Frontend side-drawer**:
  - Clicking a Node in the vis-network graph opens a details side panel.
  - Lists the SVD interface stack, active FDB MAC entries, and learned neighbors. This shows the exact MAC address of remote pods being mapped to VXLAN tunnel destinations.

### Task 2.5: Edge Route Drill-Down
- **Backend API (`GET /api/edges/{name}/routes`)**:
  - Execs `vtysh -c "show bgp l2vpn evpn route-type macip"` and outputs detailed prefix paths.
- **Frontend side-drawer**:
  - Clicking an Edge container in the graph displays its full BGP L2VPN EVPN routing table, allowing the presenter to explain the difference between Type-2 (MAC/IP) and Type-3 (IMET) routes live.

---

## Extensive Plan: Phase 3 — Visual Polish & Route Animations

**Goal**: Elevate the visual fidelity of the demo to a professional grade.

### Task 3.1: Animated Route Propagation
- **Concept**: When a new pod is deployed on Cluster 1, the EVPN Type-2 route propagates through the BGP fabric. We want to show this route's journey visually in the topology.
- **Implementation**:
  - The Go backend will calculate the diff of EVPN route tables between sequential poll cycles.
  - If a new route is discovered, the SSE payload sends a `route_event` specifying the route's path (e.g. `evpn-cluster1-worker -> evpn-edge1 -> evpn-edge2 -> evpn-cluster2-worker`).
  - The frontend `topology.js` temporarily overrides the edge styles for the affected BGP connections, turning them into pulsing, animated orange dashed lines representing the route propagation.
  - After 3 seconds, the lines fade back to stable green.

### Task 3.2: Color-Coded Health Indicators
- **Node/Edge Health**: Color nodes red if their container status changes to stopped/failed.
- **Resource Health**: Collect status of key EVPN CRs on the control planes (`VTEP`, `ClusterUserDefinedNetwork`, `RouteAdvertisements`, `FRRConfiguration`).
- Display a small dashboard header showing a health summary (e.g., "Fabric Status: HEALTHY" or "Degraded (Edge 2 BGP Offline)").

### Task 3.3: Cluster Resources Page
- Adds a tab to switch from the "Topology" view to a "CRD Diagnostics" view.
- Runs `kubectl get vtep,cudn,routeadvertisements -A -o json` on-demand and renders structured key-value panels, showing the OVN-K controllers accepting the EVPN configs.

### Task 3.4: Keyboard Shortcuts & Theme Toggles
- Renders a small floating shortcut legend:
  - `r`: Force instant topology poll
  - `c`: Launch pod creation wizard
  - `p`: Toggle continuous ping
  - `t`: Toggle light/dark UI themes (crucial for high-contrast projectors at events)

---

## Implementation Task Breakdown & Estimates

| Task | Subcomponents | Complexity | Estimated Effort |
|------|---------------|------------|------------------|
| **Phase 2** | | | **12-16 hours** |
| **2.1: Create Pod** | POST API, dynamically built Pod spec, Form modal, client validation | Medium | 4h |
| **2.2: Delete Pod** | DELETE API, shell out kubectl delete, delete button animations | Low | 2h |
| **2.3: Ping Runner** | SSE stream handler, ping subprocess wrapper, Terminal logs component | High | 5h |
| **2.4 & 2.5: Drill-down** | Side-drawer UI, FDB/Neigh APIs, vis-network click handlers | Medium | 4h |
| **2.6: UI Modularization**| Split JS into app/workloads/bgp/evpn, clean up CSS variables | Low | 2h |
| **Phase 3** | | | **10-14 hours** |
| **3.1: Route Animation** | State diffing, vis-network edge styling animations | High | 5h |
| **3.2: Health System** | CR status collector, CSS color states, global header badge | Medium | 3h |
| **3.3: CRD Diagnostics** | Diagnostics tab view, JSON formatter for k8s resources | Medium | 3h |
| **3.4 & 3.5: Polish** | Light/dark theme toggle, keyboard listener, last-updated timestamp | Low | 2h |
