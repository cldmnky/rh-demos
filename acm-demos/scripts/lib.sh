#!/usr/bin/env bash
# Shared helpers for executable scripts; source after set -euo pipefail.
demo_require() {
  local key
  for key in "$@"; do
    [[ -n ${!key:-} ]] || { printf 'Missing %s. First source scripts/demo-shell.sh.\n' "$key" >&2; return 1; }
  done
}
demo_oc() {
  local role=$1 context_key config_key
  shift
  context_key=${role}_CONTEXT; config_key=${role}_KUBECONFIG
  demo_require "$context_key"
  local args=(--context "${!context_key}" --request-timeout=15s)
  [[ -z ${!config_key:-} ]] || args+=(--kubeconfig "${!config_key}")
  oc "${args[@]}" "$@"
}
demo_identity() {
  local role=$1 api_key actual
  api_key=${role}_API
  demo_require "$api_key"
  actual=$(demo_oc "$role" whoami --show-server) || return 1
  [[ "$actual" == "${!api_key}" ]] || { printf '%s API identity mismatch; stopped.\n' "$role" >&2; return 1; }
}
demo_helm() {
  demo_require HUB_CONTEXT
  local args=(--kube-context "$HUB_CONTEXT")
  [[ -z ${HUB_KUBECONFIG:-} ]] || args+=(--kubeconfig "$HUB_KUBECONFIG")
  helm "$@" "${args[@]}"
}
demo_confirm() {
  local expected=$1 answer
  [[ -t 0 ]] || { printf '%s\n' 'Apply requires an interactive approval terminal.' >&2; return 1; }
  printf 'Changes cluster resources. Type "%s" to approve this operation: ' "$expected" >&2
  IFS= read -r answer || return 1
  [[ $answer == "$expected" ]] || { printf '%s\n' 'Cancelled.' >&2; return 1; }
}
