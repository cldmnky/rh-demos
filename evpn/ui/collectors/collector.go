package collectors

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

type Config struct {
	Cluster1Name string
	Cluster2Name string
}

type Collector struct {
	cfg      Config
	tick     *time.Ticker
	mu       sync.RWMutex
	snapshot *model.Topology

	seenWorkloads map[string]bool
	ready         bool // becomes true after first collect cycle

	podmanCollector    *podmanCollector
	k8sCollector       *k8sCollector
	frrCollector       *frrCollector
	dataplaneCollector *dataplaneCollector
}

func New(cfg Config) *Collector {
	k8s := newK8sCollector(cfg)
	k8s.setExec(func(ctx context.Context, cluster, node string, cmd ...string) ([]byte, error) {
		return ContainerExec(ctx, node, cmd)
	})

	return &Collector{
		cfg:                cfg,
		seenWorkloads:      make(map[string]bool),
		podmanCollector:    newPodmanCollector(cfg),
		k8sCollector:       k8s,
		frrCollector:       newFrrCollector(cfg),
		dataplaneCollector: newDataplaneCollector(cfg),
	}
}

func (c *Collector) Loop(ctx context.Context) {
	c.collect(ctx)
	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()

	devTick := time.NewTicker(30 * time.Second)
	defer devTick.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			c.collect(ctx)
		case <-devTick.C:
			c.dataplaneCollector.collect(ctx)
		}
	}
}

func (c *Collector) Snapshot() *model.Topology {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.snapshot == nil {
		return &model.Topology{}
	}
	s := *c.snapshot
	return &s
}

func (c *Collector) collect(ctx context.Context) {
	topo := &model.Topology{GeneratedAt: time.Now()}

	topo.Clusters = c.podmanCollector.collectClusters(ctx)
	topo.Edges = c.podmanCollector.collectEdges(ctx)
	topo.BGP = c.frrCollector.collectBGP(ctx)
	topo.EVPN = c.frrCollector.collectEVPN(ctx)
	topo.Workloads = c.k8sCollector.collectWorkloads(ctx)

	// Detect new workloads → generate route propagation events (skip first cycle)
	currentWorkloads := make(map[string]bool)
	var newestWorkload *model.Workload

	for _, w := range topo.Workloads {
		currentWorkloads[w.Name] = true
		if c.ready && !c.seenWorkloads[w.Name] {
			wCopy := w
			newestWorkload = &wCopy
		}
	}

	if newestWorkload != nil {
		log.Printf("Route event: new workload %s on %s (cluster=%s)", newestWorkload.Name, newestWorkload.Node, newestWorkload.Cluster)
		routeEvent := model.RouteEvent{
			Type:    "type2",
			VNI:     110,
			Cluster: newestWorkload.Cluster,
			Source:  newestWorkload.Node,
		}
		if newestWorkload.Cluster == "c1" {
			routeEvent.Path = []string{newestWorkload.Node, "evpn-edge1", "evpn-edge2", "evpn-cluster2-worker"}
		} else {
			routeEvent.Path = []string{newestWorkload.Node, "evpn-edge2", "evpn-edge1", "evpn-cluster1-worker"}
		}
		topo.RouteEvents = append(topo.RouteEvents, routeEvent)
	}

	c.seenWorkloads = currentWorkloads
	c.ready = true

	if c.dataplaneCollector.HasData() {
		topo = c.dataplaneCollector.mergeDevices(topo)
	}

	c.mu.Lock()
	c.snapshot = topo
	c.mu.Unlock()
}
