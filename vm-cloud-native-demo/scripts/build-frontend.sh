#!/usr/bin/env bash
# Build the PatternFly SPA and pack it for the web VM.
#
# The VM does not run npm: cloud-init writes the tarball into the guest and
# extracts it. The same dist/ directory is what the container image copies, so
# the VM tier and the container tier serve byte-identical assets.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FRONTEND="$DEMO_DIR/frontend"
CHART_FILES="$DEMO_DIR/chart/files"
TARBALL="$CHART_FILES/web.tar.gz"

cd "$FRONTEND"
if ! command -v npm >/dev/null; then
  echo 'npm is required to build the SPA. Install Node.js >= 20.19, or build in Dev Spaces and copy chart/files/web.tar.gz.' >&2
  exit 1
fi
if [[ ! -d node_modules ]]; then
  npm ci --no-fund --no-audit
fi
npm run build


rm -f "$TARBALL"
# COPYFILE_DISABLE stops macOS tar from adding AppleDouble ._ members that
# would otherwise be extracted into the guest.
COPYFILE_DISABLE=1 tar czf "$TARBALL" --exclude "._*" -C dist .

# cloud-init userdata becomes a Kubernetes Secret, which is capped at 1 MiB.
# The tarball is base64-encoded into that userdata, so keep a safety margin.
ENCODED=$(base64 < "$TARBALL" | tr -d '\n' | wc -c | tr -d ' ')
printf 'Packed %s (%s bytes base64) -> chart/files/web.tar.gz\n' \
  "$(du -h "$TARBALL" | cut -f1)" "$ENCODED"
if [[ "$ENCODED" -gt 900000 ]]; then
  printf 'Refusing to continue: the web bundle needs %s encoded bytes, and the cloud-init Secret is capped at 1 MiB.\n' "$ENCODED" >&2
  printf 'Remove unused fonts or split the bundle before shipping it through userdata.\n' >&2
  exit 1
fi
