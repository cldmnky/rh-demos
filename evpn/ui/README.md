# EVPN UI — Development

The EVPN UI is a standalone web application that visualizes the multi-cluster
EVPN fabric in real time. It runs as a single podman container on the `kind`
network, using the Docker/podman REST API to inspect and exec into sibling
containers.

## Quick Start

```bash
# Build the image
podman build -t evpn-ui:latest -f Dockerfile .

# Run (after evpn clusters are up)
podman run -d --name evpn-ui \
  --network kind --privileged \
  -p 8080:8080 \
  -v /path/to/kubeconfig.evpn-cluster1:/etc/kubeconfig/c1:ro \
  -v /path/to/kubeconfig.evpn-cluster2:/etc/kubeconfig/c2:ro \
  evpn-ui:latest \
  --kubeconfig-c1 /etc/kubeconfig/c1 \
  --kubeconfig-c2 /etc/kubeconfig/c2
```

Or use `./clusters.sh ui start`.

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
  --kubeconfig-c1 ../kubeconfig.evpn-cluster1 \
  --kubeconfig-c2 ../kubeconfig.evpn-cluster2

# Or build and test in container
podman build -t evpn-ui:latest -f Dockerfile . && \
  ../clusters.sh ui start
```

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Static SPA |
| GET | `/api/topology` | Full topology snapshot |
| GET | `/api/events` | SSE stream of model updates |
| GET | `/api/workloads` | List workloads |
| GET | `/api/healthz` | Liveness check |
