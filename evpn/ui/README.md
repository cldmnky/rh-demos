# EVPN UI — Development

The EVPN UI is a standalone web application that visualizes the multi-cluster
EVPN fabric in real time. It runs as a single podman container attached to the
four v2 networks (`evpn-site1`, `evpn-site2`, `evpn-transit` and `kind`),
using the Docker/podman REST API to inspect and exec into sibling containers.

## Quick Start

```bash
# Build the image
podman build -t evpn-ui:latest -f Dockerfile .

# Run (after evpn clusters are up). The v2 layout attaches the UI to both
# site networks, the eBGP transit network, and the shared kind network:
podman run -d --name evpn-ui \
  --network evpn-site1 \
  --network evpn-site2 \
  --network evpn-transit \
  --network kind \
  --privileged \
  -p 8080:8080 \
  -v /var/run/docker.sock:/run/podman/podman.sock:rw \
  evpn-ui:latest \
  --cluster1 evpn-cluster1 \
  --cluster2 evpn-cluster2
```

The UI talks to the clusters through the podman socket (container inspect/exec)
and does not need kubeconfig mounts.

Or use `./evpn/clusters-v2.sh ui build` and `./evpn/clusters-v2.sh ui start`.

## Architecture

```
Go HTTP server (main.go)
  ├── SSE hub (sse.go) — fan-out topology updates to browsers
  ├── Collectors
  │   ├── podman.go   — list/inspect/exec containers via podman CLI
  │   ├── kubernetes.go — kubectl exec inside kind nodes
  │   ├── frr.go      — vtysh exec on edge containers
  │   └── dataplane.go — ip/bridge device discovery on kind nodes
  ├── Model (model/types.go)
  └── Static (static/) — vanila JS SPA + vis-network
```

## Development Loop

```bash
# Run locally (Mac host, need podman CLI)
go run . \
  --cluster1 evpn-cluster1 \
  --cluster2 evpn-cluster2

# Or build and test in container
podman build -t evpn-ui:latest -f Dockerfile . && \
  ../clusters-v2.sh ui start
```

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Static SPA |
| GET | `/api/topology` | Full topology snapshot |
| GET | `/api/events` | SSE stream of model updates |
| GET | `/api/workloads` | List workloads |
| GET | `/api/healthz` | Liveness check |
