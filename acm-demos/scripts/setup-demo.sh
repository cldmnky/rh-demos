#!/usr/bin/env bash
# One component at a time. Default is offline resource summary; --apply is opt-in.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib.sh"
demo_require DEMO_ROOT DEMO_VALUES_DIR
component=${1:-}
mode=${2:---render}
[[ $# -le 2 && ( $mode == --render || $mode == --apply ) ]] || { echo 'Usage: setup-demo.sh COMPONENT [--render|--apply]' >&2; exit 1; }
case "$component" in
  gitops-operator) chart=bootstrap; release=acm-gitops-operator; namespace=openshift-operators ;;
  governance|governance-inform|governance-enforce) chart=governance; release=${GOVERNANCE_RELEASE:?}; namespace=${POLICY_NS:?} ;;
  push|push-v2) chart=delivery; release=${PUSH_RELEASE:?}; namespace=${CENTRAL_NS:?} ;;
  agent|agent-v2) chart=delivery; release=${AGENT_RELEASE:?}; namespace=${PRINCIPAL_NS:?} ;;
  subscription|subscription-v2) chart=delivery; release=${SUB_RELEASE:?}; namespace=${SUB_NS:?} ;;
  agent-principal) chart=agent-principal; release=agent-principal; namespace=${PRINCIPAL_NS:?} ;;
  *) printf '%s\n' 'Components: gitops-operator, governance[-inform|-enforce], subscription[-v2], push[-v2], agent-principal, agent[-v2]. Infrastructure is managed only by prereqs.sh.' >&2; exit 1 ;;
esac
values="$DEMO_VALUES_DIR/$component.local.yaml"
[[ -f $values ]] || { printf 'Missing local values: %s. See docs/setup.md.\n' "$values" >&2; exit 1; }
printf 'Component: %s | release: %s | namespace: %s\n' "$component" "$release" "$namespace"
if [[ $mode == --render ]]; then
  # Local-only render. Print metadata, never secret material or full Helm values.
  helm template "$release" "$DEMO_ROOT/charts/$chart" -n "$namespace" -f "$values" |
    ruby -ryaml -e 'YAML.load_stream(STDIN.read).compact.each { |o| puts [o["kind"], o.dig("metadata", "namespace"), o.dig("metadata", "name")].compact.join("\t") }'
  exit 0
fi
demo_identity HUB
demo_confirm "$release/$namespace"
# No --take-ownership, --atomic, or automatic cleanup for infrastructure.
demo_helm upgrade --install "$release" "$DEMO_ROOT/charts/$chart" -n "$namespace" \
  --create-namespace -f "$values" --wait --timeout 5m
printf '%s\n' 'Helm operation finished. Check controller/target outcomes separately; see docs/setup.md.'
