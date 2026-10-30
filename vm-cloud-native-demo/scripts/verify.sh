#!/usr/bin/env bash
# Verify the running demo end to end through the Route.
#
# This checks behaviour, not just liveness: the menu comes from MariaDB, a real
# order can be committed, the stats endpoint answers from SQL, and the SPA the
# web tier serves is the built PatternFly bundle.
set -euo pipefail
NAMESPACE=${NAMESPACE:-vm-cloud-native}
for tier in db app web; do
  oc wait -n "$NAMESPACE" --for=condition=Ready "vm/orders-$tier" --timeout=5m
done

host=$(oc get route orders -n "$NAMESPACE" -o jsonpath='{.spec.host}')
if [[ -z "$host" ]]; then
  echo 'Route has no host' >&2
  exit 1
fi
BASE="http://$host"
printf 'Verifying %s\n' "$BASE"

for ((attempt = 1; attempt <= 60; attempt++)); do
  if curl --fail --silent --show-error --max-time 5 "$BASE/api/menu" >/tmp/ramen-menu.json 2>/dev/null; then
    break
  fi
  printf 'waiting for the galley (%d/60)\n' "$attempt"
  sleep 5
done

python3 - "$BASE" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1]

def call(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.status, json.loads(response.read() or b"{}")

def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)

with open("/tmp/ramen-menu.json") as handle:
    menu = json.load(handle)["items"]
if len(menu) < 8:
    fail(f"expected at least 8 dishes, got {len(menu)}")
print(f"menu: {len(menu)} dishes, first is {menu[0]['name']} at {menu[0]['price_cents'] / 100:.2f}")

spicy = [dish for dish in menu if "spicy" in dish["tags"]]
if not spicy:
    fail("FULLTEXT index/tags missing: no spicy dish found")

status, web = call("/api/webinfo")
if web.get("runtime") not in {"VM", "container"}:
    fail(f"unexpected web runtime {web.get('runtime')!r}")
print(f"web tier: runtime={web['runtime']} node={web['node']}")

status, order = call("/api/orders", "POST", {"customer": "verify.sh", "items": [{"menu_item_id": menu[0]["id"], "qty": 1}]})
if status != 201 or not order.get("code", "").startswith("M-"):
    fail(f"order was not created: {status} {order}")
print(f"order: {order['code']} total={order['total_cents'] / 100:.2f} eta={order['eta_minutes']}m status={order['status']}")

status, stats = call("/api/stats")
if "MariaDB" not in stats["db"]["version"]:
    fail(f"unexpected database {stats['db']['version']!r}")
if stats["runtime"] not in {"VM", "container"}:
    fail(f"unexpected API runtime {stats['runtime']!r}")
print(f"api tier: runtime={stats['runtime']} | db: {stats['db']['version']} up {stats['db']['uptime_seconds']}s")
print(f"stats: revenue={stats['revenue_cents'] / 100:.2f} queue={stats['queue_depth']} top={[t['name'] for t in stats['top_sellers']]}")

with urllib.request.urlopen(base + "/", timeout=15) as response:
    html = response.read().decode()
if "assets/app.js" not in html:
    fail("the web tier is not serving the built PatternFly bundle")
print("spa: index.html references assets/app.js")
PY

echo 'Verification passed.'
