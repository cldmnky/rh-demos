package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
)

func jsonMarshal(v interface{}) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	return b, nil
}

type sseMessage struct {
	event string
	data  []byte
}

type sseClient struct {
	ch   chan sseMessage
	done <-chan struct{}
}

type sseHub struct {
	mu      sync.RWMutex
	clients map[*sseClient]struct{}
}

func newSSEHub() *sseHub {
	return &sseHub{clients: make(map[*sseClient]struct{})}
}

func (h *sseHub) subscribe(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	flusher.Flush()

	client := &sseClient{
		ch:   make(chan sseMessage, 16),
		done: r.Context().Done(),
	}

	h.mu.Lock()
	h.clients[client] = struct{}{}
	h.mu.Unlock()

	log.Printf("SSE client connected (%d total)", len(h.clients))

	defer func() {
		h.mu.Lock()
		delete(h.clients, client)
		h.mu.Unlock()
		log.Printf("SSE client disconnected (%d remaining)", len(h.clients))
	}()

	for {
		select {
		case <-client.done:
			return
		case msg := <-client.ch:
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", msg.event, msg.data)
			flusher.Flush()
		}
	}
}

func (h *sseHub) broadcast(topo interface{}) {
	payload, err := jsonMarshal(topo)
	if err != nil {
		log.Printf("SSE marshal error: %v", err)
		return
	}
	msg := sseMessage{event: "topology", data: payload}

	h.mu.RLock()
	defer h.mu.RUnlock()

	for client := range h.clients {
		select {
		case client.ch <- msg:
		default:
		}
	}
}

func (h *sseHub) broadcastEvent(eventType string, data interface{}) {
	payload, err := jsonMarshal(data)
	if err != nil {
		log.Printf("SSE marshal error: %v", err)
		return
	}
	msg := sseMessage{event: eventType, data: payload}

	h.mu.RLock()
	defer h.mu.RUnlock()

	for client := range h.clients {
		select {
		case client.ch <- msg:
		default:
		}
	}
}
