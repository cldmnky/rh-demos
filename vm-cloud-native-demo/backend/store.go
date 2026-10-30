// Rocket Ramen API: the galley service behind the Mission Control board.
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Order status flow. The board advances an order with one click per station.
const (
	StatusQueued  = "queued"
	StatusCooking = "cooking"
	StatusPlating = "plating"
	StatusServed  = "served"
)

var statusFlow = []string{StatusQueued, StatusCooking, StatusPlating, StatusServed}

// Ambiguous column names are avoided: every statement below names its columns.
type MenuItem struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Emoji       string `json:"emoji"`
	Description string `json:"description"`
	PriceCents  int    `json:"price_cents"`
	PrepSeconds int    `json:"prep_seconds"`
	Stock       int    `json:"stock"`
	Spice       int    `json:"spice"`
	Vegan       bool   `json:"vegan"`
	Tags        string `json:"tags"`
}

type OrderItem struct {
	MenuID         int    `json:"menu_item_id"`
	Name           string `json:"name"`
	Qty            int    `json:"qty"`
	UnitPriceCents int    `json:"unit_price_cents"`
}

type Order struct {
	ID         int         `json:"id"`
	Code       string      `json:"code"`
	Customer   string      `json:"customer"`
	Status     string      `json:"status"`
	TotalCents int         `json:"total_cents"`
	ETAMinutes int         `json:"eta_minutes"`
	CreatedAt  time.Time   `json:"created_at"`
	Items      []OrderItem `json:"items"`
}

type TopSeller struct {
	Name string `json:"name"`
	Qty  int    `json:"qty"`
}

type HourBucket struct {
	Hour   string `json:"hour"`
	Orders int    `json:"orders"`
}

type DBInfo struct {
	Version         string  `json:"version"`
	UptimeSeconds   int64   `json:"uptime_seconds"`
	LatencyMS       float64 `json:"latency_ms"`
	OpenConnections int     `json:"open_connections"`
}

type Stats struct {
	RevenueCents   int          `json:"revenue_cents"`
	OrdersToday    int          `json:"orders_today"`
	AvgTicketCents int          `json:"avg_ticket_cents"`
	QueueDepth     int          `json:"queue_depth"`
	BusiestHour    string       `json:"busiest_hour"`
	TopSellers     []TopSeller  `json:"top_sellers"`
	Hourly         []HourBucket `json:"hourly"`
	Runtime        string       `json:"runtime"`
	Placement      Placement    `json:"placement"`
	DB             DBInfo       `json:"db"`
	At             time.Time    `json:"at"`
}

type OrderLine struct {
	MenuID int `json:"menu_item_id"`
	Qty    int `json:"qty"`
}

type NewOrder struct {
	Customer string      `json:"customer"`
	Items    []OrderLine `json:"items"`
}

var (
	ErrNotFound    = errors.New("order not found")
	ErrDone        = errors.New("order already served")
	ErrUnknownItem = errors.New("unknown menu item")
)

// SoldOutError carries the offending dish so the SPA can name it in an alert.
type SoldOutError struct{ Item string }

func (e *SoldOutError) Error() string { return "sold out: " + e.Item }

type Store struct{ db *sql.DB }

func NewStore(db *sql.DB) *Store { return &Store{db: db} }

// Validate rejects obviously wrong baskets before touching the database.
func (n NewOrder) Validate() error {
	if len(n.Items) == 0 {
		return errors.New("empty basket")
	}
	if len(n.Items) > 8 {
		return errors.New("too many lines")
	}
	for _, line := range n.Items {
		if line.MenuID <= 0 {
			return errors.New("invalid menu item")
		}
		if line.Qty < 1 || line.Qty > 9 {
			return errors.New("quantity must be 1-9")
		}
	}
	if len(strings.TrimSpace(n.Customer)) > 60 {
		return errors.New("customer name too long")
	}
	return nil
}

// ETA is derived from the queue at commit time, not stored per item.
func etaMinutes(queueSeconds, prepSeconds int) int {
	const baseline = 3
	wait := queueSeconds + prepSeconds
	minutes := baseline + (wait+59)/60
	if minutes > 45 {
		return 45
	}
	return minutes
}

func nextStatus(current string) (string, bool) {
	for i, s := range statusFlow {
		if s == current && i+1 < len(statusFlow) {
			return statusFlow[i+1], true
		}
	}
	return "", false
}

func formatHour(t time.Time) string { return t.Format("15:00") }

// hourlyWindow zero-fills the last `hours` hour buckets ending at `now`, so the
// chart always has a stable x-axis even before any orders exist.
func hourlyWindow(counts map[string]int, now time.Time, hours int) []HourBucket {
	out := make([]HourBucket, 0, hours)
	start := now.Truncate(time.Hour).Add(-time.Duration(hours-1) * time.Hour)
	for i := 0; i < hours; i++ {
		label := formatHour(start.Add(time.Duration(i) * time.Hour))
		out = append(out, HourBucket{Hour: label, Orders: counts[label]})
	}
	return out
}

// Menu returns active dishes, optionally filtered with a FULLTEXT search.
func (s *Store) Menu(ctx context.Context, query string) ([]MenuItem, error) {
	const base = `SELECT id, name, emoji, description, price_cents, prep_seconds, stock, spice, vegan, tags
	              FROM menu_items WHERE active`
	query = strings.TrimSpace(query)
	var (
		rows *sql.Rows
		err  error
	)
	if query == "" {
		rows, err = s.db.QueryContext(ctx, base+" ORDER BY id")
	} else if terms := booleanTerms(query); terms != "" {
		rows, err = s.db.QueryContext(ctx, base+" AND MATCH (name, description, tags) AGAINST (? IN BOOLEAN MODE) ORDER BY id", terms)
	} else {
		like := "%" + query + "%"
		rows, err = s.db.QueryContext(ctx, base+" AND (name LIKE ? OR description LIKE ? OR tags LIKE ?) ORDER BY id", like, like, like)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := []MenuItem{}
	for rows.Next() {
		var m MenuItem
		if err := rows.Scan(&m.ID, &m.Name, &m.Emoji, &m.Description, &m.PriceCents,
			&m.PrepSeconds, &m.Stock, &m.Spice, &m.Vegan, &m.Tags); err != nil {
			return nil, err
		}
		items = append(items, m)
	}
	return items, rows.Err()
}

// booleanTerms turns "spicy pork" into "+spicy* +pork*" for a prefix search.
func booleanTerms(query string) string {
	parts := strings.FieldsFunc(query, func(r rune) bool { return r == ' ' || r == ',' })
	terms := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if len([]rune(p)) < 3 {
			continue
		}
		terms = append(terms, "+"+p+"*")
	}
	return strings.Join(terms, " ")
}

// CreateOrder is the transactional core of the demo: lock stock, price the
// basket, decrement inventory, record the order and its first event, commit.
func (s *Store) CreateOrder(ctx context.Context, in NewOrder) (*Order, error) {
	if err := in.Validate(); err != nil {
		return nil, err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	ids := make([]int, 0, len(in.Items))
	for _, line := range in.Items {
		ids = append(ids, line.MenuID)
	}
	sort.Ints(ids)
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	args := make([]interface{}, len(ids))
	for i, id := range ids {
		args[i] = id
	}

	rows, err := tx.QueryContext(ctx,
		`SELECT id, name, price_cents, prep_seconds, stock FROM menu_items
		 WHERE active AND id IN (`+placeholders+`) FOR UPDATE`, args...)
	if err != nil {
		return nil, err
	}
	type dish struct {
		name               string
		price, prep, stock int
	}
	dishes := map[int]dish{}
	for rows.Next() {
		var d dish
		var id int
		if err := rows.Scan(&id, &d.name, &d.price, &d.prep, &d.stock); err != nil {
			rows.Close()
			return nil, err
		}
		dishes[id] = d
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	total, prep := 0, 0
	items := make([]OrderItem, 0, len(in.Items))
	for _, line := range in.Items {
		d, ok := dishes[line.MenuID]
		if !ok {
			return nil, ErrUnknownItem
		}
		if d.stock < line.Qty {
			return nil, &SoldOutError{Item: d.name}
		}
		total += d.price * line.Qty
		prep += d.prep * line.Qty
		items = append(items, OrderItem{MenuID: line.MenuID, Name: d.name, Qty: line.Qty, UnitPriceCents: d.price})
	}

	var queueSeconds int
	if err := tx.QueryRowContext(ctx,
		`SELECT COALESCE(SUM(prep_seconds), 0) FROM orders WHERE status <> ?`, StatusServed).
		Scan(&queueSeconds); err != nil {
		return nil, err
	}

	customer := strings.TrimSpace(in.Customer)
	if customer == "" {
		customer = "Cadet"
	}
	eta := etaMinutes(queueSeconds, prep)

	res, err := tx.ExecContext(ctx,
		`INSERT INTO orders (customer, status, total_cents, prep_seconds, eta_minutes) VALUES (?, ?, ?, ?, ?)`,
		customer, StatusQueued, total, prep, eta)
	if err != nil {
		return nil, err
	}
	id64, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	id := int(id64)
	code := fmt.Sprintf("M-%04d", id)
	if _, err := tx.ExecContext(ctx, `UPDATE orders SET code = ? WHERE id = ?`, code, id); err != nil {
		return nil, err
	}

	for _, it := range items {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO order_items (order_id, menu_item_id, name, qty, unit_price_cents) VALUES (?, ?, ?, ?, ?)`,
			id, it.MenuID, it.Name, it.Qty, it.UnitPriceCents); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE menu_items SET stock = stock - ? WHERE id = ?`, it.Qty, it.MenuID); err != nil {
			return nil, err
		}
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO order_events (order_id, status, note) VALUES (?, ?, ?)`,
		id, StatusQueued, "mission accepted"); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return &Order{
		ID: id, Code: code, Customer: customer, Status: StatusQueued,
		TotalCents: total, ETAMinutes: eta, CreatedAt: time.Now(), Items: items,
	}, nil
}

// AdvanceOrder moves one order to the next station in the galley.
func (s *Store) AdvanceOrder(ctx context.Context, id int) (*Order, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	var current string
	if err := tx.QueryRowContext(ctx, `SELECT status FROM orders WHERE id = ? FOR UPDATE`, id).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	next, ok := nextStatus(current)
	if !ok {
		return nil, ErrDone
	}
	if next == StatusServed {
		_, err = tx.ExecContext(ctx, `UPDATE orders SET status = ?, served_at = NOW() WHERE id = ?`, next, id)
	} else {
		_, err = tx.ExecContext(ctx, `UPDATE orders SET status = ? WHERE id = ?`, next, id)
	}
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO order_events (order_id, status, note) VALUES (?, ?, ?)`,
		id, next, "station "+next); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	orders, err := s.Orders(ctx, 1, id)
	if err != nil {
		return nil, err
	}
	if len(orders) == 0 {
		return nil, ErrNotFound
	}
	return &orders[0], nil
}

// Orders lists recent orders; when onlyID > 0 it returns just that order.
func (s *Store) Orders(ctx context.Context, limit, onlyID int) ([]Order, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	const q = `SELECT o.id, o.code, o.customer, o.status, o.total_cents, o.eta_minutes, o.created_at,
	                  oi.menu_item_id, oi.name, oi.qty, oi.unit_price_cents
	           FROM orders o
	           JOIN (%s) recent ON recent.id = o.id
	           LEFT JOIN order_items oi ON oi.order_id = o.id
	           ORDER BY o.created_at DESC, o.id DESC, oi.id`
	// MariaDB rejects LIMIT inside IN subqueries, so the recent slice is a derived table.
	recent := "SELECT id FROM orders ORDER BY created_at DESC, id DESC LIMIT ?"
	args := []interface{}{limit}
	if onlyID > 0 {
		recent = "SELECT id FROM orders WHERE id = ?"
		args = []interface{}{onlyID}
	}
	rows, err := s.db.QueryContext(ctx, fmt.Sprintf(q, recent), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	orders := []Order{}
	index := map[int]int{}
	for rows.Next() {
		var o Order
		var menuID sql.NullInt64
		var name sql.NullString
		var qty, unit sql.NullInt64
		if err := rows.Scan(&o.ID, &o.Code, &o.Customer, &o.Status, &o.TotalCents,
			&o.ETAMinutes, &o.CreatedAt, &menuID, &name, &qty, &unit); err != nil {
			return nil, err
		}
		pos, seen := index[o.ID]
		if !seen {
			o.Items = []OrderItem{}
			orders = append(orders, o)
			pos = len(orders) - 1
			index[o.ID] = pos
		}
		if menuID.Valid {
			orders[pos].Items = append(orders[pos].Items, OrderItem{
				MenuID: int(menuID.Int64), Name: name.String, Qty: int(qty.Int64), UnitPriceCents: int(unit.Int64),
			})
		}
	}
	return orders, rows.Err()
}

// Stats feeds the ops strip and the stack badges; every number is a DB answer.
func (s *Store) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	st.At = time.Now()

	err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(SUM(total_cents), 0), COUNT(*) FROM orders WHERE created_at >= CURDATE()`).
		Scan(&st.RevenueCents, &st.OrdersToday)
	if err != nil {
		return st, err
	}
	if st.OrdersToday > 0 {
		st.AvgTicketCents = st.RevenueCents / st.OrdersToday
	}

	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM orders WHERE status <> ?`, StatusServed).Scan(&st.QueueDepth); err != nil {
		return st, err
	}

	var busiest sql.NullInt64
	if err := s.db.QueryRowContext(ctx,
		`SELECT HOUR(created_at) FROM orders WHERE created_at >= CURDATE()
		 GROUP BY HOUR(created_at) ORDER BY COUNT(*) DESC LIMIT 1`).Scan(&busiest); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return st, err
	}
	if busiest.Valid {
		st.BusiestHour = fmt.Sprintf("%02d:00", busiest.Int64)
	}

	st.TopSellers, err = s.topSellers(ctx)
	if err != nil {
		return st, err
	}

	counts := map[string]int{}
	rows, err := s.db.QueryContext(ctx,
		`SELECT DATE_FORMAT(created_at, '%H:00'), COUNT(*) FROM orders
		 WHERE created_at >= NOW() - INTERVAL 12 HOUR GROUP BY 1`)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	for rows.Next() {
		var label string
		var n int
		if err := rows.Scan(&label, &n); err != nil {
			return st, err
		}
		counts[label] = n
	}
	st.Hourly = hourlyWindow(counts, st.At, 12)

	st.Runtime = runtimeName()
	st.Placement = placement()
	st.DB, err = s.dbInfo(ctx)
	return st, err
}

func (s *Store) topSellers(ctx context.Context) ([]TopSeller, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT oi.name, SUM(oi.qty) AS qty
		 FROM order_items oi JOIN orders o ON o.id = oi.order_id
		 WHERE o.created_at >= CURDATE()
		 GROUP BY oi.name ORDER BY qty DESC LIMIT 3`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TopSeller{}
	for rows.Next() {
		var t TopSeller
		if err := rows.Scan(&t.Name, &t.Qty); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) dbInfo(ctx context.Context) (DBInfo, error) {
	var info DBInfo
	start := time.Now()
	if err := s.db.QueryRowContext(ctx, `SELECT VERSION()`).Scan(&info.Version); err != nil {
		return info, err
	}
	info.LatencyMS = float64(time.Since(start).Microseconds()) / 1000.0
	var name, value string
	if err := s.db.QueryRowContext(ctx, `SHOW GLOBAL STATUS LIKE 'Uptime'`).Scan(&name, &value); err == nil {
		var uptime int64
		_, _ = fmt.Sscanf(value, "%d", &uptime)
		info.UptimeSeconds = uptime
	}
	info.OpenConnections = s.db.Stats().OpenConnections
	return info, nil
}

// ResetOrders clears the board for a rehearsal or a fresh run. Only the order
// tables are touched; the menu and its stock are reset separately by Restock.
func (s *Store) ResetOrders(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM order_events`); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM order_items`); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM orders`); err != nil {
		return err
	}
	// MariaDB commits DDL implicitly, so this runs outside a transaction.
	_, err := s.db.ExecContext(ctx, `ALTER TABLE orders AUTO_INCREMENT = 1`)
	return err
}

// Restock refills the galley so the demo can run again without a redeploy.
func (s *Store) Restock(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `UPDATE menu_items SET stock = restock_to WHERE active`)
	return err
}

func (s *Store) Ping(ctx context.Context) (time.Duration, error) {
	start := time.Now()
	err := s.db.PingContext(ctx)
	return time.Since(start), err
}
