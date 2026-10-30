#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../frontend"
[[ -d node_modules ]] || npm ci --no-fund --no-audit
npm run build
