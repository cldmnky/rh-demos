#!/usr/bin/env bash
# Default: inspect. --apply changes ONE field on the approved demo ConfigMap.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/lib.sh"
demo_require DEMO_VALUES_DIR PROD_CONTEXT PROD_API
mode=${1:---check}
[[ $# -le 1 && ( $mode == --check || $mode == --apply ) ]] || { echo 'Usage: drift-demo.sh [--check|--apply]' >&2; exit 1; }
values="$DEMO_VALUES_DIR/governance-enforce.local.yaml"
[[ -f $values ]] || { echo 'Missing governance-enforce.local.yaml' >&2; exit 1; }
namespace=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("targetNamespace", "acm-demo-baseline")' "$values")
baseline=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("baselineValue", "strict")' "$values")
[[ $namespace == acm-demo-* && $baseline =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Drift test is restricted to an acm-demo-* namespace and a simple baseline value.' >&2; exit 1; }
demo_identity PROD
if [[ $mode == --apply ]]; then
  demo_confirm "drift/$namespace/demo-security-baseline"
  demo_oc PROD patch configmap demo-security-baseline -n "$namespace" --type=merge -p '{"data":{"security-profile":"drifted"}}' >/dev/null
  demo_oc PROD wait configmap/demo-security-baseline -n "$namespace" --for="jsonpath={.data.security-profile}=$baseline" --timeout=60s
fi
demo_oc PROD get configmap demo-security-baseline -n "$namespace" -o 'jsonpath={.data.security-profile}{"\n"}'
