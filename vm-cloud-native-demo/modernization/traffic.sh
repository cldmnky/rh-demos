#!/usr/bin/env bash
# Reversible runtime traffic changes; do not write transient weights to Git.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
case "${1:-}:${2:-}" in
  api:container)
    oc -n "$NAMESPACE" rollout status deployment/orders-api-container --timeout=2m
    oc -n "$NAMESPACE" patch service orders-app --type=merge -p '{"spec":{"selector":{"vm.kubevirt.io/name":null,"app":"orders-api-container"}}}'
    ;;
  api:vm)
    oc -n "$NAMESPACE" wait --for=condition=Ready vm/orders-app --timeout=2m
    oc -n "$NAMESPACE" patch service orders-app --type=merge -p '{"spec":{"selector":{"app":null,"vm.kubevirt.io/name":"orders-app"}}}'
    ;;
  web:0|web:50|web:100)
    if [[ $2 != 0 ]]; then
      ready=$(oc -n "$NAMESPACE" get endpoints orders-web-container -o jsonpath='{.subsets[*].addresses[*].ip}')
      [[ -n "$ready" ]] || { echo 'No ready container frontend endpoints; refusing to change the Route.' >&2; exit 1; }
    fi
    oc -n "$NAMESPACE" annotate route orders --overwrite haproxy.router.openshift.io/balance=roundrobin haproxy.router.openshift.io/disable_cookies=true
    oc -n "$NAMESPACE" set route-backends orders "orders-web=$((100-$2))" "orders-web-container=$2"
    ;;
  *) echo 'Usage: traffic.sh api vm|container OR traffic.sh web 0|50|100' >&2; exit 2 ;;
esac
