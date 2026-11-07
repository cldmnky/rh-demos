#!/usr/bin/env bash
# Source from local setup and bootc commands so they resolve the same private state.
# An explicit override also supports existing installations using the old flat path.
if [[ -z ${PRIVATE_DIR:-} ]]; then
  demo_cluster_uid=$(oc --request-timeout=15s get namespace kube-system -o jsonpath='{.metadata.uid}') || return 1
  [[ $demo_cluster_uid =~ ^[a-zA-Z0-9-]+$ ]] || { echo 'Cannot determine cluster identity for private setup files.' >&2; return 1; }
  PRIVATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo/$demo_cluster_uid/${NAMESPACE:-rocket-ramen}"
  unset demo_cluster_uid
fi
export PRIVATE_DIR
