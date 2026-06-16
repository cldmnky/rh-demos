package collectors

import (
	"context"
	"strings"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

type podmanCollector struct {
	cfg       Config
	nodeRoles map[string]string
}

func newPodmanCollector(cfg Config) *podmanCollector {
	return &podmanCollector{
		cfg: cfg,
		nodeRoles: map[string]string{
			cfg.Cluster1Name + "-control-plane": "control-plane",
			cfg.Cluster1Name + "-worker":        "worker",
			cfg.Cluster2Name + "-control-plane": "control-plane",
			cfg.Cluster2Name + "-worker":        "worker",
		},
	}
}

func (p *podmanCollector) collectClusters(ctx context.Context) []model.Cluster {
	cluster1 := model.Cluster{Name: p.cfg.Cluster1Name}
	cluster2 := model.Cluster{Name: p.cfg.Cluster2Name}

	containers, err := listContainersAPI(ctx)
	if err != nil {
		return []model.Cluster{cluster1, cluster2}
	}

	for _, c := range containers {
		name := ""
		if len(c.Names) > 0 {
			name = strings.TrimPrefix(c.Names[0], "/")
		}
		role, ok := p.nodeRoles[name]
		if !ok {
			continue
		}
		kindIP := p.inspectIP(ctx, name)
		siteIP := p.inspectSiteIP(ctx, name)
		node := model.Node{
			Name:   name,
			Role:   role,
			IP:     siteIP,
			KindIP: kindIP,
		}
		if strings.HasPrefix(name, p.cfg.Cluster1Name) {
			cluster1.Nodes = append(cluster1.Nodes, node)
		} else {
			cluster2.Nodes = append(cluster2.Nodes, node)
		}
	}

	return []model.Cluster{cluster1, cluster2}
}

func (p *podmanCollector) collectEdges(ctx context.Context) []model.Edge {
	var edges []model.Edge
	for _, name := range []string{"evpn-edge1", "evpn-edge2"} {
		ip := p.inspectSiteIP(ctx, name)
		if ip == "" {
			ip = p.inspectIP(ctx, name)
		}
		transitIP := p.inspectNetworkIP(ctx, name, "evpn-transit")
		state := p.inspectState(ctx, name)
		edges = append(edges, model.Edge{
			Name:      name,
			IP:        ip,
			TransitIP: transitIP,
			Role:      "route-reflector",
			State:     state,
			AS:        64512,
		})
	}
	return edges
}

func (p *podmanCollector) inspectIP(ctx context.Context, name string) string {
	insp, err := inspectContainerAPI(ctx, name)
	if err != nil || insp == nil {
		return ""
	}
	for netName, net := range insp.NetworkSettings.Networks {
		if netName == "kind" {
			return net.IPAddress
		}
	}
	return ""
}

// inspectSiteIP returns the IP from a non-kind network (site or transit).
// Falls back to empty string if only kind network exists.
func (p *podmanCollector) inspectSiteIP(ctx context.Context, name string) string {
	insp, err := inspectContainerAPI(ctx, name)
	if err != nil || insp == nil {
		return ""
	}
	for netName, net := range insp.NetworkSettings.Networks {
		if netName != "kind" && net.IPAddress != "" {
			return net.IPAddress
		}
	}
	return ""
}

// inspectNetworkIP returns the IP for a specific named network.
func (p *podmanCollector) inspectNetworkIP(ctx context.Context, name, networkName string) string {
	insp, err := inspectContainerAPI(ctx, name)
	if err != nil || insp == nil {
		return ""
	}
	if net, ok := insp.NetworkSettings.Networks[networkName]; ok {
		return net.IPAddress
	}
	return ""
}

func (p *podmanCollector) inspectState(ctx context.Context, name string) string {
	insp, err := inspectContainerAPI(ctx, name)
	if err != nil || insp == nil {
		return "unknown"
	}
	return insp.State.Status
}

func (p *podmanCollector) Exec(ctx context.Context, container string, cmd ...string) ([]byte, error) {
	return ContainerExec(ctx, container, cmd)
}
