#!/usr/bin/env bash
# SOURCE this file in Bash. No API requests, mutations, global context switches, or file writes.
if [[ -z ${BASH_VERSION:-} ]]; then
  printf '%s\n' 'Use Bash, then: source scripts/demo-shell.sh' >&2
  return 1
fi
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  printf '%s\n' 'Source this script so variables remain in your shell: source scripts/demo-shell.sh' >&2
  exit 1
fi

_acm_demo_collect() (
  local root env_file interactive=true prerequisites_only=false name value default role context_key config_key api_key option
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
  env_file=${DEMO_ENV_FILE:-$root/config/demo.env}
  for option in "$@"; do
    case $option in
      --non-interactive) interactive=false ;;
      --prereqs) prerequisites_only=true ;;
      *) printf '%s\n' 'Usage: source scripts/demo-shell.sh [--prereqs] [--non-interactive]' >&2; return 1 ;;
    esac
  done
  if [[ -f $env_file ]]; then
    # Local shell input must be trusted. Its effects stay in this subshell; only
    # allowlisted non-secret variables below are exported to the caller.
    source "$env_file" >&2 || return 1
  fi
  command -v oc >/dev/null || { printf '%s\n' 'Missing oc CLI' >&2; return 1; }
  _ask() {
    local key=$1 label=$2 suggestion=${3:-} answer
    value=${!key:-}
    if [[ -n $value && $value != *'<'* && $value != *'>'* ]]; then return 0; fi
    if [[ $interactive != true || ! -t 0 ]]; then
      printf 'Missing %s. Set it in your environment or trusted %s.\n' "$key" "$env_file" >&2
      return 1
    fi
    while :; do
      printf '%s%s: ' "$label" "${suggestion:+ [$suggestion]}" >&2
      IFS= read -r answer || return 1
      answer=${answer:-$suggestion}
      if [[ -n $answer && $answer != *'<'* && $answer != *'>'* ]]; then
        printf -v "$key" '%s' "$answer"
        return 0
      fi
      printf '%s\n' 'A non-placeholder value is required.' >&2
    done
  }
  _default() { [[ -n ${!1:-} ]] || printf -v "$1" '%s' "$2"; }
  DEMO_ROOT=$root
  _default DEMO_VALUES_DIR "$root/values"
  # Optional per-target kubeconfigs are paths only, never kubeconfig contents.
  for role in HUB PROD ZTP AGENT EXCLUDED; do
    if [[ $prerequisites_only == true && $role != HUB ]]; then continue; fi
    context_key=${role}_CONTEXT; config_key=${role}_KUBECONFIG; api_key=${role}_API
    if [[ $role == AGENT && -z ${AGENT_KUBECONFIG:-} && -n ${QA_KUBECONFIG:-} ]]; then AGENT_KUBECONFIG=$QA_KUBECONFIG; fi
    if [[ $role == EXCLUDED && -z ${EXCLUDED_KUBECONFIG:-} && -n ${AGENT_KUBECONFIG:-} && ( -z ${EXCLUDED_CONTEXT:-} || ${EXCLUDED_CONTEXT:-} == "$AGENT_CONTEXT" ) ]]; then EXCLUDED_KUBECONFIG=$AGENT_KUBECONFIG; fi
    if [[ -z ${!config_key:-} && $interactive == true && -t 0 ]]; then
      printf '%s kubeconfig file (blank uses your normal kubeconfig): ' "$role" >&2
      IFS= read -r value || return 1
      [[ -z $value ]] || printf -v "$config_key" '%s' "$value"
    fi
    default=''
    if [[ -n ${!config_key:-} ]]; then
      [[ -f ${!config_key} ]] || { printf 'Missing kubeconfig for %s\n' "$role" >&2; return 1; }
      default=$(oc --kubeconfig "${!config_key}" config current-context 2>/dev/null) || return 1
    fi
    if [[ $role == AGENT ]]; then default=${AGENT_CONTEXT:-${QA_CONTEXT:-$default}}; fi
    if [[ $role == EXCLUDED ]]; then default=${AGENT_CONTEXT:-$default}; fi
    _ask "$context_key" "$role kubeconfig context" "$default" || return 1
    local args=(--context "${!context_key}")
    [[ -z ${!config_key:-} ]] || args+=(--kubeconfig "${!config_key}")
    default=$(oc "${args[@]}" config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null) || return 1
    _ask "$api_key" "Expected $role API URL (confirm identity)" "$default" || return 1
    [[ ${!api_key} == https://* ]] || { printf 'Expected HTTPS API for %s\n' "$role" >&2; return 1; }
  done
  _ask PROD_CLUSTER 'Production ManagedCluster name' || return 1
  _ask AGENT_CLUSTER 'Agent target ManagedCluster name' || return 1
  _ask ZTP_CLUSTER 'Precreated ZTP ClusterInstance / namespace' || return 1
  _ask ZTP_VM 'Precreated ZTP VirtualMachine name' || return 1
  _default QA_CLUSTER "$AGENT_CLUSTER"
  _default CENTRAL_NS openshift-gitops
  _default PRINCIPAL_NS acm-agent-hub
  _default AGENT_GITOPS_NS openshift-gitops
  _default POLICY_NS acm-demo-policies
  _default SUB_NS acm-demo-subscription
  _default PUSH_NS acm-demo-argo
  _default AGENT_APP_NS acm-demo-agent
  _default SOURCE_NS acm-demo-sources
  _default SOURCE_RELEASE demo-sources
  _default SOURCE_BUNDLE acm-demo-source-bundle
  _default GOVERNANCE_RELEASE governance
  _default SUB_RELEASE subscription
  _default PUSH_RELEASE push
  _default AGENT_RELEASE agent
  _default APP_RELEASE acm-demo-app
  _default PUSH_APP "$PUSH_RELEASE-$PROD_CLUSTER"
  _default AGENT_APP "$AGENT_RELEASE-$AGENT_CLUSTER"
  if [[ $prerequisites_only != true ]]; then
    _ask LOCAL_AGENT_APP 'Application name on managed agent instance' || return 1
    _ask SUB_DEPLOYMENT 'Subscription-generated Deployment name' || return 1
    _ask SUB_ROUTE 'Subscription-generated Route name' || return 1
  fi
  _ask IMAGE_SET 'Approved ClusterImageSet name' || return 1
  if [[ -f $DEMO_VALUES_DIR/governance-enforce.local.yaml ]]; then
    command -v ruby >/dev/null || { echo 'Ruby is required to read local values.' >&2; return 1; }
    default=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("targetNamespace", "acm-demo-baseline")' "$DEMO_VALUES_DIR/governance-enforce.local.yaml") || return 1
    _default BASELINE_NS "$default"
  else _default BASELINE_NS acm-demo-baseline; fi
  local names=(DEMO_ROOT DEMO_VALUES_DIR PROD_CLUSTER AGENT_CLUSTER QA_CLUSTER ZTP_CLUSTER ZTP_VM
    CENTRAL_NS PRINCIPAL_NS AGENT_GITOPS_NS POLICY_NS BASELINE_NS SUB_NS PUSH_NS AGENT_APP_NS SOURCE_NS
    SOURCE_RELEASE SOURCE_BUNDLE GOVERNANCE_RELEASE SUB_RELEASE PUSH_RELEASE AGENT_RELEASE APP_RELEASE
    PUSH_APP AGENT_APP LOCAL_AGENT_APP SUB_DEPLOYMENT SUB_ROUTE IMAGE_SET)
  for role in HUB PROD ZTP AGENT EXCLUDED; do
    names+=("${role}_CONTEXT" "${role}_API" "${role}_KUBECONFIG")
  done
  for name in "${names[@]}"; do
    [[ -z ${!name:-} ]] || printf 'export %s=%q\n' "$name" "${!name}"
  done
)

if _acm_demo_exports=$(_acm_demo_collect "$@"); then
  eval "$_acm_demo_exports"
else
  unset _acm_demo_exports
  unset -f _acm_demo_collect
  return 1
fi
unset _acm_demo_exports
unset -f _acm_demo_collect

# Explicit target wrappers: caller supplies read-only commands in the runbooks.
# No global KUBECONFIG or current-context is changed.
_acm_oc() {
  local role=$1 context_key config_key
  shift
  context_key=${role}_CONTEXT; config_key=${role}_KUBECONFIG
  local args=(--context "${!context_key}" --request-timeout=15s)
  [[ -z ${!config_key:-} ]] || args+=(--kubeconfig "${!config_key}")
  command oc "${args[@]}" "$@"
}
oc_hub() { _acm_oc HUB "$@"; }
oc_prod() { _acm_oc PROD "$@"; }
oc_ztp() { _acm_oc ZTP "$@"; }
oc_agent() { _acm_oc AGENT "$@"; }
oc_excluded() { _acm_oc EXCLUDED "$@"; }
printf '%s\n' 'Demo shell ready. Run scripts/preflight.sh before setup; no API calls or changes performed.'
