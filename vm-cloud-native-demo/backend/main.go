package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

const defaultDSN = "orders:demo-only-password@tcp(orders-db:3306)/orders?parseTime=true&timeout=3s"

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// runtimeName is what the stack badge shows: does this tier run on a VM or in a container?
func runtimeName() string { return env("APP_RUNTIME", "VM") }

// Placement identifies the instance serving a request. A VM cannot discover
// its Kubernetes node from inside the guest, so Node stays empty there.
type Placement struct {
	Runtime    string `json:"runtime"`
	Name       string `json:"name"`
	Namespace  string `json:"namespace"`
	Node       string `json:"node"`
	Serial     string `json:"serial"`
	ReportedBy string `json:"reported_by"`
}

func placement() Placement {
	p := Placement{Runtime: runtimeName()}
	if p.Runtime == "container" {
		p.Name, p.Namespace, p.Node = os.Getenv("POD_NAME"), os.Getenv("POD_NAMESPACE"), os.Getenv("NODE_NAME")
		p.ReportedBy = "Downward API"
		return p
	}
	if data, err := os.ReadFile("/etc/rocket-ramen/placement.json"); err == nil {
		_ = json.Unmarshal(data, &p)
	}
	p.Runtime = "VM"
	p.ReportedBy = "Unavailable"
	if p.Name != "" || p.Namespace != "" || p.Serial != "" {
		p.ReportedBy = "Provisioning metadata"
	}
	if serial, err := os.ReadFile("/sys/class/dmi/id/product_serial"); err == nil && strings.TrimSpace(string(serial)) != "" {
		p.Serial = strings.TrimSpace(string(serial))
		p.ReportedBy = "KubeVirt SMBIOS + provisioning metadata"
	}
	p.Node = ""
	return p
}

type API struct {
	store *Store
	hub   *Hub
}

func main() {
	db, err := sql.Open("mysql", env("DB_DSN", defaultDSN))
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(4)
	db.SetConnMaxLifetime(3 * time.Minute)

	api := &API{store: NewStore(db), hub: NewHub()}

	// Keep serving if MariaDB is still booting; handlers answer 503 until it is up.
	go func() {
		for attempt := 1; attempt <= 30; attempt++ {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			_, err := api.store.Ping(ctx)
			cancel()
			if err == nil {
				log.Printf("MariaDB reachable, galley online (runtime=%s)", runtimeName())
				return
			}
			log.Printf("waiting for MariaDB (attempt %d): %v", attempt, err)
			time.Sleep(2 * time.Second)
		}
		log.Print("MariaDB still unreachable; /health will report 503")
	}()

	// One background ticker keeps every connected board's ops strip fresh.
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			stats, err := api.store.Stats(ctx)
			cancel()
			if err == nil {
				api.hub.Broadcast("stats", stats)
			}
		}
	}()

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           logRequests(api.routes()),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout: /api/stream is a long-lived SSE response.
		IdleTimeout: 120 * time.Second,
	}
	log.Printf("Rocket Ramen API listening on %s", srv.Addr)
	log.Fatal(srv.ListenAndServe())
}

func (a *API) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.health)
	mux.HandleFunc("/api/menu", a.menu)
	mux.HandleFunc("/api/orders", a.orders)
	mux.HandleFunc("/api/orders/", a.orderAction)
	mux.HandleFunc("/api/stats", a.stats)
	mux.HandleFunc("/api/stream", a.stream)
	mux.HandleFunc("/api/restock", a.restock)
	mux.HandleFunc("/api/reset", a.reset)
	return mux
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Flush keeps SSE streaming through the recorder and the Node proxy.
func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, code int, kind, message string) {
	writeJSON(w, code, map[string]string{"error": kind, "message": message})
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	latency, err := a.store.Ping(r.Context())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]interface{}{
			"status": "database unavailable", "runtime": runtimeName(), "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "ok", "runtime": runtimeName(), "db_latency_ms": float64(latency.Microseconds()) / 1000.0,
	})
}

func (a *API) menu(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET only")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	items, err := a.store.Menu(ctx, r.URL.Query().Get("q"))
	if err != nil {
		log.Printf("menu: %v", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": items})
}

func (a *API) orders(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		orders, err := a.store.Orders(ctx, limit, 0)
		if err != nil {
			log.Printf("orders: %v", err)
			writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"orders": orders})
	case http.MethodPost:
		var in NewOrder
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&in); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		order, err := a.store.CreateOrder(ctx, in)
		var sold *SoldOutError
		switch {
		case err == nil:
			a.hub.Broadcast("order.created", order)
			if stats, statErr := a.store.Stats(ctx); statErr == nil {
				a.hub.Broadcast("stats", stats)
			}
			writeJSON(w, http.StatusCreated, order)
		case errors.As(err, &sold):
			writeJSON(w, http.StatusConflict, map[string]string{
				"error": "sold_out", "message": sold.Item + " is sold out", "item": sold.Item,
			})
		case errors.Is(err, ErrUnknownItem):
			writeError(w, http.StatusConflict, "unknown_item", "that dish is not on the menu")
		default:
			log.Printf("create order: %v", err)
			writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET or POST")
	}
}

// orderAction handles POST /api/orders/{id}/advance.
func (a *API) orderAction(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/orders/")
	parts := strings.Split(strings.Trim(rest, "/"), "/")
	if len(parts) != 2 || parts[1] != "advance" {
		writeError(w, http.StatusNotFound, "not_found", "unknown order action")
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST only")
		return
	}
	id, err := strconv.Atoi(parts[0])
	if err != nil || id <= 0 {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid order id")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	order, err := a.store.AdvanceOrder(ctx, id)
	switch {
	case err == nil:
		a.hub.Broadcast("order.updated", order)
		if stats, statErr := a.store.Stats(ctx); statErr == nil {
			a.hub.Broadcast("stats", stats)
		}
		writeJSON(w, http.StatusOK, order)
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "no such order")
	case errors.Is(err, ErrDone):
		writeError(w, http.StatusConflict, "already_served", "order is already served")
	default:
		log.Printf("advance order: %v", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
	}
}

func (a *API) stats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET only")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	stats, err := a.store.Stats(ctx)
	if err != nil {
		log.Printf("stats: %v", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, stats)
}

func (a *API) restock(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST only")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	if err := a.store.Restock(ctx); err != nil {
		log.Printf("restock: %v", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
		return
	}
	if items, err := a.store.Menu(ctx, ""); err == nil {
		a.hub.Broadcast("menu.updated", map[string]interface{}{"items": items})
	}
	if stats, err := a.store.Stats(ctx); err == nil {
		a.hub.Broadcast("stats", stats)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "restocked"})
}

// reset clears the order board so the demo can be rehearsed repeatedly.
func (a *API) reset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST only")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	if err := a.store.ResetOrders(ctx); err != nil {
		log.Printf("reset: %v", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable", "galley database unavailable")
		return
	}
	a.hub.Broadcast("orders.cleared", map[string]string{"status": "cleared"})
	if stats, err := a.store.Stats(ctx); err == nil {
		a.hub.Broadcast("stats", stats)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cleared"})
}

// stream is the SSE endpoint behind the live Mission Control board.
func (a *API) stream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "no_flush", "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	events, unsubscribe := a.hub.Subscribe()
	defer unsubscribe()

	// Tell the client it is live, then keep a heartbeat under the proxy idle timeout.
	if _, err := w.Write([]byte("event: hello\ndata: {\"status\":\"live\"}\n\n")); err != nil {
		return
	}
	flusher.Flush()

	ping := time.NewTicker(10 * time.Second)
	defer ping.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ping.C:
			if _, err := w.Write([]byte(": ping\n\n")); err != nil {
				return
			}
			flusher.Flush()
		case frame, open := <-events:
			if !open {
				return
			}
			if _, err := w.Write(frame); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}
