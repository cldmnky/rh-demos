package collectors

import (
	"context"
	"encoding/json"
	"log"
	"strconv"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

// metallbCollector gathers MetalLB LoadBalancer services (VIPs) and how each
// VIP prefix is present in the provider edges' IPv4 unicast RIBs. MetalLB
// shares the frr-k8s instance with OVN-K, so the VIPs ride the same iBGP /
// eBGP transit sessions the EVPN fabric uses.
type metallbCollector struct {
	cfg Config
}

func newMetallbCollector(cfg Config) *metallbCollector {
	return &metallbCollector{cfg: cfg}
}

func (m *metallbCollector) clusterLabel(clusterName string) string {
	if clusterName == m.cfg.Cluster2Name {
		return "c2"
	}
	return "c1"
}

func (m *metallbCollector) cpNode(clusterName string) string {
	return clusterName + "-control-plane"
}

func (m *metallbCollector) collect(ctx context.Context) model.BGPServiceState {
	state := model.BGPServiceState{}

	// The pool listing doubles as the MetalLB presence probe: when the
	// IPAddressPool CRD is not served (MetalLB not installed) the exec fails.
	pools, installed := m.collectPools(ctx)
	state.Pools = pools
	state.Installed = installed

	vips := m.collectServices(ctx)
	if len(vips) > 0 {
		m.annotateAdvertisements(ctx, vips)
	}
	state.VIPs = vips

	return state
}

func (m *metallbCollector) collectPools(ctx context.Context) (pools []model.AddressPool, installed bool) {
	for _, clusterName := range []string{m.cfg.Cluster1Name, m.cfg.Cluster2Name} {
		out, err := ContainerExec(ctx, m.cpNode(clusterName), []string{
			"kubectl", "get", "ipaddresspool", "-n", "metallb-system", "-o", "json"})
		if err != nil {
			// MetalLB not installed (or API unreachable) on this cluster.
			continue
		}
		installed = true

		var list struct {
			Items []struct {
				Metadata struct {
					Name string `json:"name"`
				} `json:"metadata"`
				Spec struct {
					Addresses []string `json:"addresses"`
				} `json:"spec"`
			} `json:"items"`
		}
		if json.Unmarshal(out, &list) != nil {
			continue
		}

		cluster := m.clusterLabel(clusterName)
		for _, item := range list.Items {
			pools = append(pools, model.AddressPool{
				Cluster:   cluster,
				Name:      item.Metadata.Name,
				Addresses: item.Spec.Addresses,
			})
		}
	}
	return pools, installed
}

func (m *metallbCollector) collectServices(ctx context.Context) []model.VIP {
	var vips []model.VIP

	for _, clusterName := range []string{m.cfg.Cluster1Name, m.cfg.Cluster2Name} {
		out, err := ContainerExec(ctx, m.cpNode(clusterName), []string{
			"kubectl", "get", "svc", "-A",
			"--field-selector", "spec.type=LoadBalancer",
			"-o", "json"})
		if err != nil {
			continue
		}

		var list struct {
			Items []struct {
				Metadata struct {
					Name              string            `json:"name"`
					Namespace         string            `json:"namespace"`
					CreationTimestamp string            `json:"creationTimestamp"`
					Annotations       map[string]string `json:"annotations"`
				} `json:"metadata"`
				Spec struct {
					Ports []struct {
						Port     int    `json:"port"`
						Protocol string `json:"protocol"`
					} `json:"ports"`
				} `json:"spec"`
				Status struct {
					LoadBalancer struct {
						Ingress []struct {
							IP string `json:"ip"`
						} `json:"ingress"`
					} `json:"loadBalancer"`
				} `json:"status"`
			} `json:"items"`
		}
		if json.Unmarshal(out, &list) != nil {
			continue
		}

		cluster := m.clusterLabel(clusterName)
		for _, item := range list.Items {
			for _, ing := range item.Status.LoadBalancer.Ingress {
				if ing.IP == "" {
					continue // VIP not assigned yet
				}
				var ports []string
				for _, p := range item.Spec.Ports {
					ports = append(ports, strconv.Itoa(p.Port)+"/"+p.Protocol)
				}
				vips = append(vips, model.VIP{
					Cluster:   cluster,
					Namespace: item.Metadata.Namespace,
					Service:   item.Metadata.Name,
					IP:        ing.IP,
					Ports:     ports,
					Pool:      item.Metadata.Annotations["metallb.io/address-pool"],
					Age:       formatAge(time.Now(), item.Metadata.CreationTimestamp),
				})
			}
		}
	}
	return vips
}

// annotateAdvertisements looks every VIP prefix up in each edge's IPv4
// unicast RIB (one exec per edge per cycle) and records how it was learned.
func (m *metallbCollector) annotateAdvertisements(ctx context.Context, vips []model.VIP) {
	for _, edge := range []string{"evpn-edge1", "evpn-edge2"} {
		table := m.edgeIPv4Table(ctx, edge)
		if table == nil {
			continue
		}
		for i := range vips {
			paths, ok := table[vips[i].IP+"/32"]
			if !ok || len(paths) == 0 {
				vips[i].Advertisements = append(vips[i].Advertisements, model.VIPAdvert{
					Edge:    edge,
					Present: false,
				})
				continue
			}
			vips[i].Advertisements = append(vips[i].Advertisements, bestPathAdvert(edge, paths))
		}
	}
}

func (m *metallbCollector) edgeIPv4Table(ctx context.Context, edge string) map[string][]bgpPath {
	ctx2, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	out, err := ContainerExecJSON(ctx2, edge, []string{"vtysh", "-c", "show bgp ipv4 unicast json"})
	if err != nil {
		log.Printf("vtysh ipv4 unicast %s: %v", edge, err)
		return nil
	}

	var raw struct {
		Routes map[string]json.RawMessage `json:"routes"`
	}
	if err := json.Unmarshal(out, &raw); err != nil || raw.Routes == nil {
		log.Printf("vtysh ipv4 unicast %s: unexpected JSON: %v", edge, err)
		return nil
	}

	table := make(map[string][]bgpPath, len(raw.Routes))
	for prefix, msg := range raw.Routes {
		// Depending on the FRR version/output, routes[prefix] is either a
		// plain array of paths or an object wrapping them under "paths".
		var paths []bgpPath
		if err := json.Unmarshal(msg, &paths); err != nil {
			var wrapper struct {
				Paths []bgpPath `json:"paths"`
			}
			if err := json.Unmarshal(msg, &wrapper); err != nil {
				continue
			}
			paths = wrapper.Paths
		}
		table[prefix] = paths
	}
	return table
}

type bgpPath struct {
	BestPath bool   `json:"bestpath"`
	PathFrom string `json:"pathFrom"` // internal | external
	Path     string `json:"path"`     // AS path, empty for locally originated
	PeerID   string `json:"peerId"`
	NextHops []struct {
		IP       string `json:"ip"`
		Hostname string `json:"hostname"`
	} `json:"nexthops"`
}

func bestPathAdvert(edge string, paths []bgpPath) model.VIPAdvert {
	adv := model.VIPAdvert{Edge: edge, Present: true}

	path := paths[0]
	for _, p := range paths {
		if p.BestPath {
			path = p
			adv.Best = true
			break
		}
	}

	adv.PathFrom = path.PathFrom
	adv.ASPath = path.Path
	if len(path.NextHops) > 0 {
		adv.NextHop = path.NextHops[0].IP
		adv.Hostname = path.NextHops[0].Hostname
	}
	if adv.NextHop == "" {
		adv.NextHop = path.PeerID
	}
	return adv
}
