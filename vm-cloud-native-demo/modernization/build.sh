#!/usr/bin/env bash
# Run in the Dev Spaces OpenShift CLI terminal after building the frontend bundle.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
case ${1:-} in
  api)
    build=$(oc -n "$NAMESPACE" start-build orders-api-container --from-dir="$DEMO_DIR/backend" -o name)
    ;;
  web)
    [[ -f "$DEMO_DIR/frontend/dist/index.html" ]] || { echo 'Build the frontend bundle first: ./scripts/build-frontend.sh' >&2; exit 1; }
    context=$(mktemp -d "${TMPDIR:-/tmp}/rocket-ramen-web.XXXXXXXX")
    trap 'rm -rf "$context"' EXIT
    cp "$DEMO_DIR/frontend/Containerfile" "$DEMO_DIR/frontend/server.js" "$context/"
    cp -R "$DEMO_DIR/frontend/dist" "$context/dist"
    chmod -R a+rX "$context"
    build=$(oc -n "$NAMESPACE" start-build orders-web-container --from-dir="$context" -o name)
    ;;
  *) echo 'Usage: modernization/build.sh api|web' >&2; exit 2 ;;
esac
printf 'Started %s\n' "$build"
oc -n "$NAMESPACE" logs -f "$build" || true
for ((attempt=0; attempt<120; attempt++)); do
  phase=$(oc -n "$NAMESPACE" get "$build" -o jsonpath='{.status.phase}')
  case "$phase" in
    Complete) echo 'Build completed.'; exit 0 ;;
    Failed|Error|Cancelled) echo "Build $build ended in phase $phase." >&2; exit 1 ;;
  esac
  sleep 5
done
echo "Timed out waiting for $build." >&2
exit 1
