#!/usr/bin/env bash
# Copy the application sources the chart embeds into cloud-init.
#
# The web bundle is packed from frontend/dist. Build it when it is missing, or
# force a rebuild with REBUILD_WEB=1 (needed after any frontend change).
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILES="$DEMO_DIR/chart/files"
mkdir -p "$FILES"

cp "$DEMO_DIR/frontend/server.js" "$FILES/server.js"
for file in main.go store.go hub.go go.mod go.sum; do
  cp "$DEMO_DIR/backend/$file" "$FILES/$file"
done
cp "$DEMO_DIR/db/schema.sql" "$FILES/schema.sql"

if [[ ! -f "$FILES/web.tar.gz" || ${REBUILD_WEB:-0} == 1 ]]; then
  "$DEMO_DIR/scripts/build-frontend.sh"
fi

# Leftovers from the single-file scaffold this demo started with.
rm -f "$FILES/index.html"
