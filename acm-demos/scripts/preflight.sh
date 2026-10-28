#!/usr/bin/env bash
# Read-only inventory. Explicit identity, no credential values or global context changes.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/lib.sh"
demo_require HUB_CONTEXT HUB_API IMAGE_SET
demo_identity HUB
printf 'Read-only inventory at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
demo_oc HUB get clusterversion
demo_oc HUB get multiclusterhub -A
demo_oc HUB get managedclusters
demo_oc HUB get clusterdeployments -A
demo_oc HUB get clusterimageset "$IMAGE_SET"
printf '%s\n' 'For prerequisite existence/creation planning use scripts/prereqs.sh --check.'
