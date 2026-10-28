#!/usr/bin/env bash
# Preview only. Infrastructure and controller-aware teardown are never automatic.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Automatic reset is disabled. Follow docs/reset.md with separate approval.' >&2
  exit 1
fi
printf '%s\n' \
  'Preview only; no cluster access or mutation.' \
  'Restore reviewed inform/v1 local values through their existing Helm/Git owner.' \
  'Never uninstall cloud/ZTP prerequisite releases or delete their namespaces during routine reset.' \
  'See docs/reset.md.'
