# LogQL Queries — Observability Demo

All queries target namespace `user1-observability-demo` and parse the two-level JSON structure
(outer Kubernetes-envelope JSON → inner application JSON in the `message` field).

## Core Pipeline

Every metric query follows this pattern to extract the inner JSON fields:

```logql
{kubernetes_namespace_name="user1-observability-demo"}
  |= "access"
  | json
  | line_format "{{.message}}"
  | json
```

- `|= "access"` — filter to application access logs
- `| json` — parse the outer JSON envelope (extracts `message` label)
- `| line_format "{{.message}}"` — replace log line with the inner JSON string
- `| json` — parse inner JSON → labels: `method`, `path`, `route`, `status`, `duration_ms`, `bytes`, `remote_addr`

---

## Latency

### P99 latency by route

```logql
quantile_over_time(0.99,
  {kubernetes_namespace_name="user1-observability-demo"}
  |= "access"
  | json
  | line_format "{{.message}}"
  | json
  | unwrap duration_ms
  | __error__=""
  [5m]
) by (route, method)
```

Swap `0.99` → `0.95` / `0.50` for p95 / p50.

### Average latency by route

```logql
avg_over_time(
  {kubernetes_namespace_name="user1-observability-demo"}
  |= "access"
  | json
  | line_format "{{.message}}"
  | json
  | unwrap duration_ms
  | __error__=""
  [5m]
) by (route, method)
```

### Max latency (spike detection)

```logql
max_over_time(
  {kubernetes_namespace_name="user1-observability-demo"}
  |= "access"
  | json
  | line_format "{{.message}}"
  | json
  | unwrap duration_ms
  | __error__=""
  [5m]
) by (route)
```

---

## Throughput

### Bytes per second by route

```logql
sum by (route) (
  rate(
    {kubernetes_namespace_name="user1-observability-demo"}
    |= "access"
    | json
    | line_format "{{.message}}"
    | json
    | unwrap bytes
    | __error__=""
    [5m]
  )
)
```

### Total bytes transferred over time

```logql
sum_over_time(
  {kubernetes_namespace_name="user1-observability-demo"}
  |= "access"
  | json
  | line_format "{{.message}}"
  | json
  | unwrap bytes
  | __error__=""
  [1h]
) by (route)
```

---

## Request Rate

### Requests per second by status code

```logql
sum by (status) (
  rate(
    {kubernetes_namespace_name="user1-observability-demo"}
    |= "access"
    | json
    | line_format "{{.message}}"
    | json
    [5m]
  )
)
```

### Requests per second by route

```logql
sum by (route) (
  rate(
    {kubernetes_namespace_name="user1-observability-demo"}
    |= "access"
    | json
    | line_format "{{.message}}"
    | json
    [5m]
  )
)
```

---

## Errors

### Error rate (percentage of requests with status >= 400)

```logql
(
  sum(rate(
    {kubernetes_namespace_name="user1-observability-demo"}
    |= "access" | json | line_format "{{.message}}" | json
    | status >= "400" [5m]
  ))
  /
  sum(rate(
    {kubernetes_namespace_name="user1-observability-demo"}
    |= "access" | json | line_format "{{.message}}" | json
    [5m]
  ))
) * 100
```

### Error count by route

```logql
sum by (route) (
  count_over_time(
    {kubernetes_namespace_name="user1-observability-demo"}
    |= "access" | json | line_format "{{.message}}" | json
    | status >= "400"
    [5m]
  )
)
```

---

## Dashboard-Ready Multi-Stat

### Request count + P95 latency summary

```logql
# Count (top stat)
count_over_time(
  {kubernetes_namespace_name="user1-observability-demo"}
  |= "access" | json | line_format "{{.message}}" | json
  [5m]
)

# P95 latency (bottom stat)
quantile_over_time(0.95,
  {kubernetes_namespace_name="user1-observability-demo"}
  |= "access" | json | line_format "{{.message}}" | json
  | unwrap duration_ms | __error__=""
  [5m]
)
```
