package main

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"

	_ "github.com/go-sql-driver/mysql"
)

// TestStoreIntegration exercises the real SQL against a throwaway MariaDB:
//
//	podman run -d --name ramen-db -p 13306:3306 \
//	  -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=orders \
//	  -e MARIADB_USER=orders -e MARIADB_PASSWORD=demo-only-password mariadb:11.4
//	podman exec -i ramen-db mariadb --default-character-set=utf8mb4 -uorders -pdemo-only-password orders < db/schema.sql
//	ORDERS_TEST_DSN='orders:demo-only-password@tcp(127.0.0.1:13306)/orders?parseTime=true' go test -run Integration ./...
func TestStoreIntegration(t *testing.T) {
	dsn := os.Getenv("ORDERS_TEST_DSN")
	if dsn == "" {
		t.Skip("set ORDERS_TEST_DSN to run the MariaDB integration test")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	store := NewStore(db)
	ctx := context.Background()

	// Start from a clean galley.
	if _, err := db.ExecContext(ctx, `DELETE FROM order_events`); err != nil {
		t.Fatalf("clean events: %v", err)
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM order_items`); err != nil {
		t.Fatalf("clean items: %v", err)
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM orders`); err != nil {
		t.Fatalf("clean orders: %v", err)
	}
	if _, err := db.ExecContext(ctx, `ALTER TABLE orders AUTO_INCREMENT = 1`); err != nil {
		t.Fatalf("reset auto increment: %v", err)
	}
	if err := store.Restock(ctx); err != nil {
		t.Fatalf("restock: %v", err)
	}

	menu, err := store.Menu(ctx, "")
	if err != nil || len(menu) < 8 {
		t.Fatalf("menu: %v (%d items)", err, len(menu))
	}
	found, err := store.Menu(ctx, "spicy")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(found) == 0 || found[0].Name != "Solar Flare Tan Tan" {
		t.Fatalf("fulltext search returned %+v", found)
	}

	stockBefore := map[int]int{}
	for _, m := range menu {
		stockBefore[m.ID] = m.Stock
	}

	order, err := store.CreateOrder(ctx, NewOrder{Customer: "Cadet Vega", Items: []OrderLine{
		{MenuID: 1, Qty: 2}, {MenuID: 7, Qty: 1},
	}})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if order.Code != "M-0001" {
		t.Errorf("code = %q", order.Code)
	}
	if want := 1450*2 + 450; order.TotalCents != want {
		t.Errorf("total = %d want %d", order.TotalCents, want)
	}
	// 2 * 240s + 30s = 510s of prep, nothing queued ahead -> 3 + ceil(510/60) = 12
	if order.ETAMinutes != 12 {
		t.Errorf("eta = %d want 12", order.ETAMinutes)
	}

	after, _ := store.Menu(ctx, "")
	for _, m := range after {
		switch m.ID {
		case 1:
			if m.Stock != stockBefore[1]-2 {
				t.Errorf("stock for %s = %d want %d", m.Name, m.Stock, stockBefore[1]-2)
			}
		case 7:
			if m.Stock != stockBefore[7]-1 {
				t.Errorf("stock for %s = %d want %d", m.Name, m.Stock, stockBefore[7]-1)
			}
		}
	}

	// Draining stock must roll the whole basket back, not partially commit.
	if _, err := store.CreateOrder(ctx, NewOrder{Items: []OrderLine{{MenuID: 5, Qty: 9}}}); err != nil {
		t.Fatalf("first drain: %v", err)
	}
	if _, err := store.CreateOrder(ctx, NewOrder{Items: []OrderLine{{MenuID: 5, Qty: 9}}}); err != nil {
		t.Fatalf("second drain: %v", err)
	}
	var sold *SoldOutError
	if _, err := store.CreateOrder(ctx, NewOrder{Items: []OrderLine{{MenuID: 5, Qty: 9}}}); !errors.As(err, &sold) {
		t.Fatalf("expected sold out, got %v", err)
	}
	if sold.Item != "Supernova Shio" {
		t.Errorf("sold out item = %q", sold.Item)
	}
	if _, err := store.CreateOrder(ctx, NewOrder{Items: []OrderLine{{MenuID: 99, Qty: 1}}}); !errors.Is(err, ErrUnknownItem) {
		t.Fatalf("expected unknown item, got %v", err)
	}

	// Status flow, and the queue-derived ETA on the second order.
	queued, err := store.Orders(ctx, 10, 0)
	if err != nil {
		t.Fatalf("orders: %v", err)
	}
	if len(queued) != 3 {
		t.Fatalf("orders = %d want 3", len(queued))
	}
	if queued[0].ETAMinutes <= order.ETAMinutes {
		t.Errorf("second order eta %d should follow the first (%d)", queued[0].ETAMinutes, order.ETAMinutes)
	}

	updated, err := store.AdvanceOrder(ctx, order.ID)
	if err != nil {
		t.Fatalf("advance: %v", err)
	}
	if updated.Status != StatusCooking {
		t.Errorf("status = %q", updated.Status)
	}
	for _, want := range []string{StatusPlating, StatusServed} {
		if updated, err = store.AdvanceOrder(ctx, order.ID); err != nil || updated.Status != want {
			t.Fatalf("advance to %s: %v (%v)", want, err, updated)
		}
	}
	if _, err := store.AdvanceOrder(ctx, order.ID); !errors.Is(err, ErrDone) {
		t.Errorf("expected ErrDone, got %v", err)
	}
	if _, err := store.AdvanceOrder(ctx, 99999); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}

	stats, err := store.Stats(ctx)
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if stats.OrdersToday != 3 || stats.RevenueCents == 0 || len(stats.TopSellers) == 0 {
		t.Errorf("stats = %+v", stats)
	}
	if stats.QueueDepth != 2 {
		t.Errorf("queue depth = %d want 2", stats.QueueDepth)
	}
	if len(stats.Hourly) != 12 {
		t.Errorf("hourly buckets = %d", len(stats.Hourly))
	}
	if stats.DB.Version == "" || stats.DB.UptimeSeconds == 0 {
		t.Errorf("db info = %+v", stats.DB)
	}
}
