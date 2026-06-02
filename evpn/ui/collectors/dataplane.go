package collectors

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

type dataplaneCollector struct {
	cfg     Config
	mu      sync.Mutex
	devices map[string][]model.Device
}

func newDataplaneCollector(cfg Config) *dataplaneCollector {
	return &dataplaneCollector{
		cfg:     cfg,
		devices: make(map[string][]model.Device),
	}
}

func (d *dataplaneCollector) HasData() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.devices) > 0
}

func (d *dataplaneCollector) collect(ctx context.Context) {
	for _, clusterName := range []string{d.cfg.Cluster1Name, d.cfg.Cluster2Name} {
		for _, role := range []string{"control-plane", "worker"} {
			nodeName := clusterName + "-" + role
			devices := d.discoverDevices(ctx, nodeName)
			d.mu.Lock()
			d.devices[nodeName] = devices
			d.mu.Unlock()
		}
	}
}

func (d *dataplaneCollector) mergeDevices(topo *model.Topology) *model.Topology {
	d.mu.Lock()
	defer d.mu.Unlock()

	for ci := range topo.Clusters {
		for ni := range topo.Clusters[ci].Nodes {
			name := topo.Clusters[ci].Nodes[ni].Name
			if devs, ok := d.devices[name]; ok {
				topo.Clusters[ci].Nodes[ni].Devices = devs
			}
		}
	}

	return topo
}

func (d *dataplaneCollector) discoverDevices(ctx context.Context, nodeName string) []model.Device {
	ctx2, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	out, err := ContainerExec(ctx2, nodeName, []string{"bash", "-c",
		"ip -j link show type bridge 2>/dev/null; echo '---'; ip -j link show type vxlan 2>/dev/null"})
	if err != nil {
		log.Printf("dataplane %s: %v", nodeName, err)
		return nil
	}

	var devices []model.Device
	parts := splitOutput(string(out))
	for _, part := range parts {
		devices = append(devices, parseLinkDevices(part)...)
	}

	return devices
}

func splitOutput(out string) []string {
	var parts []string
	chunks := splitStr(out, "---")
	for _, chunk := range chunks {
		chunk = trimSpace(chunk)
		if chunk != "" && chunk != "null" {
			parts = append(parts, chunk)
		}
	}
	return parts
}

type ipLink struct {
	IfName   string `json:"ifname"`
	LinkType string `json:"link_type"`
	LinkInfo struct {
		InfoKind string `json:"info_kind"`
		InfoData struct {
			ID int `json:"id"`
		} `json:"info_data"`
	} `json:"linkinfo"`
}

func parseLinkDevices(raw string) []model.Device {
	var links []ipLink
	if json.Unmarshal([]byte(raw), &links) != nil {
		return nil
	}

	var devices []model.Device
	for _, l := range links {
		dev := model.Device{
			Name: l.IfName,
			Kind: l.LinkInfo.InfoKind,
			VNI:  l.LinkInfo.InfoData.ID,
		}
		devices = append(devices, dev)
	}
	return devices
}
