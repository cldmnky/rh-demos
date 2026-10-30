package main

import (
	"testing"
	"time"
)

func TestEnv(t *testing.T) {
	t.Setenv("RAMEN_DEMO_TEST", "configured")
	if got := env("RAMEN_DEMO_TEST", "default"); got != "configured" {
		t.Fatalf("got %q", got)
	}
	if got := env("RAMEN_DEMO_MISSING", "default"); got != "default" {
		t.Fatalf("got %q", got)
	}
}

func TestRuntimeNameDefaultsToVM(t *testing.T) {
	t.Setenv("APP_RUNTIME", "")
	if got := runtimeName(); got != "VM" {
		t.Fatalf("want VM, got %q", got)
	}
	t.Setenv("APP_RUNTIME", "container")
	if got := runtimeName(); got != "container" {
		t.Fatalf("want container, got %q", got)
	}
}

func TestETAMinutes(t *testing.T) {
	cases := []struct {
		queue, prep, want int
	}{
		{0, 0, 3},
		{0, 60, 4},
		{0, 61, 5},
		{120, 240, 9},
		{0, 5400, 45}, // capped
	}
	for _, c := range cases {
		if got := etaMinutes(c.queue, c.prep); got != c.want {
			t.Errorf("etaMinutes(%d,%d)=%d want %d", c.queue, c.prep, got, c.want)
		}
	}
}

func TestNextStatus(t *testing.T) {
	steps := map[string]string{
		StatusQueued:  StatusCooking,
		StatusCooking: StatusPlating,
		StatusPlating: StatusServed,
	}
	for from, want := range steps {
		got, ok := nextStatus(from)
		if !ok || got != want {
			t.Errorf("nextStatus(%q)=(%q,%v) want %q", from, got, ok, want)
		}
	}
	if _, ok := nextStatus(StatusServed); ok {
		t.Error("served order must not advance")
	}
	if _, ok := nextStatus("bogus"); ok {
		t.Error("unknown status must not advance")
	}
}

func TestNewOrderValidate(t *testing.T) {
	valid := NewOrder{Customer: "Cadet", Items: []OrderLine{{MenuID: 1, Qty: 2}}}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid basket rejected: %v", err)
	}
	bad := []NewOrder{
		{Items: nil},
		{Items: []OrderLine{{MenuID: 0, Qty: 1}}},
		{Items: []OrderLine{{MenuID: 1, Qty: 0}}},
		{Items: []OrderLine{{MenuID: 1, Qty: 10}}},
		{Items: []OrderLine{{MenuID: 1, Qty: 1}, {MenuID: 2, Qty: 1}, {MenuID: 3, Qty: 1}, {MenuID: 4, Qty: 1}, {MenuID: 5, Qty: 1}, {MenuID: 6, Qty: 1}, {MenuID: 7, Qty: 1}, {MenuID: 8, Qty: 1}, {MenuID: 9, Qty: 1}}},
		{Customer: string(make([]rune, 61)), Items: []OrderLine{{MenuID: 1, Qty: 1}}},
	}
	for i, b := range bad {
		if err := b.Validate(); err == nil {
			t.Errorf("case %d: expected validation error", i)
		}
	}
}

func TestBooleanTerms(t *testing.T) {
	cases := map[string]string{
		"":            "",
		"spicy":       "+spicy*",
		"spicy pork":  "+spicy* +pork*",
		"a bb":        "",
		"miso, vegan": "+miso* +vegan*",
	}
	for in, want := range cases {
		if got := booleanTerms(in); got != want {
			t.Errorf("booleanTerms(%q)=%q want %q", in, got, want)
		}
	}
}

func TestHourlyWindowZeroFills(t *testing.T) {
	now := time.Date(2026, 2, 20, 14, 37, 0, 0, time.UTC)
	counts := map[string]int{"14:00": 5, "12:00": 2}
	got := hourlyWindow(counts, now, 4)
	want := []HourBucket{{"11:00", 0}, {"12:00", 2}, {"13:00", 0}, {"14:00", 5}}
	if len(got) != len(want) {
		t.Fatalf("got %d buckets, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("bucket %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestContainerPlacementFromDownwardAPI(t *testing.T) {
	t.Setenv("APP_RUNTIME", "container")
	t.Setenv("POD_NAME", "orders-api-123")
	t.Setenv("POD_NAMESPACE", "rocket-ramen")
	t.Setenv("NODE_NAME", "worker-2")
	got := placement()
	if got.Name != "orders-api-123" || got.Namespace != "rocket-ramen" || got.Node != "worker-2" || got.ReportedBy != "Downward API" {
		t.Fatalf("unexpected container placement: %+v", got)
	}
}
