#!/usr/bin/env bash
set -eo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$DEMO_DIR/.." && pwd)
cd "$DEMO_DIR"
if ! command -v pv >/dev/null; then set -- -d "$@"; fi
. "$REPO_ROOT/scripts/demo-magic.sh"
. "$REPO_ROOT/scripts/helpers.sh"
NAMESPACE=${NAMESPACE:-vm-cloud-native}
export NAMESPACE
HOST=$(oc get route orders -n "$NAMESPACE" -o jsonpath='{.spec.host}')
export HOST

act 1 'Three VM tiers, one noodle bar'
pe 'oc get vm -n "$NAMESPACE"'
say 'Rocket Ramen: a PatternFly SPA, a Go API that streams over SSE, and MariaDB holding every order.'
p '# In the browser: the masthead says web VM, API VM, and a MariaDB version. That strip follows us all session.'
pe 'curl -fsS "http://$HOST/api/menu" | python3 -c "import json,sys; d=json.load(sys.stdin)[\"items\"]; print(len(d), \"dishes, first:\", d[0][\"name\"])"'
pe 'curl -fsS "http://$HOST/api/stats" | python3 -m json.tool'

act 2 'Real work: a transaction, not a SELECT 1'
pe 'curl -fsS -X POST "http://$HOST/api/orders" -H "Content-Type: application/json" -d "{\"customer\":\"Cadet Vega\",\"items\":[{\"menu_item_id\":1,\"qty\":1}]}"'
p '# LOCKED stock, priced basket, ETA from queue depth, order_items, event, COMMIT. Sell out a dish and the whole basket rolls back.'
pe 'curl -fsS "http://$HOST/api/orders?limit=5" | python3 -m json.tool | head -40'

act 3 'Development in Dev Spaces'
pe 'cat devfile.yaml'
pe 'cat frontend/Containerfile'
pe 'cat backend/Containerfile'
p '# Switch to the prepared Dev Spaces workspace: show src/App.tsx, the SSE client, and run the Playwright suite.'
p '# npx playwright test --headed  => the audience watches a real browser place an order.'

act 4 'Modernize the application tiers'
if [[ ${RUN_CUTOVER:-false} == true ]]; then
  : "${API_IMAGE:?Set API_IMAGE before starting the cutover}"
  : "${FRONTEND_IMAGE:?Set FRONTEND_IMAGE before starting the cutover}"
  export API_IMAGE FRONTEND_IMAGE
  pe './scripts/service.sh prepare app "$API_IMAGE"'
  pe './scripts/service.sh activate app'
  p '# Masthead: web VM, api container. Same MariaDB, same orders.'
  pe '(cd frontend && EXPECTED_API_RUNTIME=container npx playwright test e2e/stack.spec.ts)'
  pe './scripts/service.sh prepare web "$FRONTEND_IMAGE"'
  pe './scripts/service.sh activate web'
  pe '(cd frontend && EXPECTED_WEB_RUNTIME=container EXPECTED_API_RUNTIME=container npx playwright test e2e/stack.spec.ts)'
  p '# Both tiers are containers now and every order placed on the VMs is still on the board.'
else
  p '# Set RUN_CUTOVER=true, API_IMAGE and FRONTEND_IMAGE to perform the cutover.'
fi

act 5 'MariaDB on an image-mode VM'
pe 'cat bootc/Containerfile'
p '# The database is the tier we deliberately keep on a VM. bootc VM creation and data cutover are planned, not yet implemented.'
say 'Same application, same data, three different operating models.'
