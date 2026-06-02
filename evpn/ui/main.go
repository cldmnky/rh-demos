package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/collectors"
)

func main() {
	port := flag.Int("port", 8080, "HTTP listen port")
	cluster1Name := flag.String("cluster1", "evpn-cluster1", "cluster1 name")
	cluster2Name := flag.String("cluster2", "evpn-cluster2", "cluster2 name")
	staticDir := flag.String("static", "static", "path to static files")
	flag.Parse()

	log.Printf("evpn-ui starting on :%d", *port)
	log.Printf("  cluster1=%s", *cluster1Name)
	log.Printf("  cluster2=%s", *cluster2Name)

	collector := collectors.New(collectors.Config{
		Cluster1Name: *cluster1Name,
		Cluster2Name: *cluster2Name,
	})

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	hub := newSSEHub()
	srv := newServer(collector, hub, *staticDir)

	go collector.Loop(ctx)

	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		var lastGenerated time.Time
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				topo := collector.Snapshot()
				if topo.GeneratedAt.Equal(lastGenerated) {
					continue
				}
				lastGenerated = topo.GeneratedAt
				hub.broadcast(topo)
				// Broadcast each route event as a separate SSE event
				for _, re := range topo.RouteEvents {
					hub.broadcastEvent("route_event", re)
				}
			}
		}
	}()

	httpServer := &http.Server{Addr: fmt.Sprintf(":%d", *port), Handler: srv}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("listening on :%d", *port)
	if err := httpServer.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}

func newServer(c *collectors.Collector, hub *sseHub, staticDir string) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	mux.HandleFunc("GET /api/topology", func(w http.ResponseWriter, r *http.Request) {
		topo := c.Snapshot()
		writeJSON(w, topo)
	})

	mux.HandleFunc("GET /api/events", func(w http.ResponseWriter, r *http.Request) {
		hub.subscribe(w, r)
	})

	mux.HandleFunc("GET /api/workloads", func(w http.ResponseWriter, r *http.Request) {
		topo := c.Snapshot()
		writeJSON(w, topo.Workloads)
	})

	mux.HandleFunc("POST /api/workloads", handleCreateWorkload)
	mux.HandleFunc("DELETE /api/workloads/{cluster}/{name}", handleDeleteWorkload)
	mux.HandleFunc("GET /api/ping", handlePingStream)
	mux.HandleFunc("GET /api/nodes/{name}/fdb", handleNodeFDB)
	mux.HandleFunc("GET /api/nodes/{name}/neigh", handleNodeNeigh)
	mux.HandleFunc("GET /api/nodes/{name}/devices", handleNodeDevices)
	mux.HandleFunc("GET /api/edges/{name}/routes", handleEdgeRoutes)
	mux.HandleFunc("GET /api/cluster-resources/{cluster}", handleClusterResources)

	fs := http.FileServer(http.Dir(staticDir))
	mux.Handle("GET /", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
		w.Header().Set("Pragma", "no-cache")
		w.Header().Set("Expires", "0")
		fs.ServeHTTP(w, r)
	}))

	return logMiddleware(mux)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	data, err := jsonMarshal(v)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Write(data)
}

func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}
