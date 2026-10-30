#!/usr/bin/env bash
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-vm-cloud-native}
tier=${2:-}
case "$tier" in web|app) ;; *) echo 'Usage: service.sh prepare web|app IMAGE | activate web|app | revert web|app' >&2; exit 2 ;; esac
case ${1:-} in
  prepare)
    image=${3:?Provide a pullable container image}
    "$DEMO_DIR/scripts/sync-sources.sh"
    helm upgrade vm-cloud-native "$DEMO_DIR/chart" -n "$NAMESPACE" --reuse-values --set "$tier.enabled=true" --set-string "$tier.image=$image"
    oc rollout status "deployment/orders-$tier-container" -n "$NAMESPACE" --timeout=3m
    ;;
  activate)
    oc rollout status "deployment/orders-$tier-container" -n "$NAMESPACE" --timeout=3m
    helm upgrade vm-cloud-native "$DEMO_DIR/chart" -n "$NAMESPACE" --reuse-values --set "$tier.active=true"
    ;;
  revert)
    oc wait -n "$NAMESPACE" --for=condition=Ready "vm/orders-$tier" --timeout=3m
    helm upgrade vm-cloud-native "$DEMO_DIR/chart" -n "$NAMESPACE" --reuse-values --set "$tier.active=false"
    ;;
  *) echo 'Usage: service.sh prepare web|app IMAGE | activate web|app | revert web|app' >&2; exit 2 ;;
esac
