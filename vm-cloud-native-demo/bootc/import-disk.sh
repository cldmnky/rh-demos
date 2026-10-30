#!/usr/bin/env bash
# Import the staged QCOW2 into a new CDI DataVolume. The URL must be reachable by CDI.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
: "${BOOTC_DISK_URL:?Set BOOTC_DISK_URL to the trusted QCOW2 URL}"
case "$BOOTC_DISK_URL" in https://*|http://orders-bootc-artifacts."$NAMESPACE".svc:8081/*) ;; *) echo 'Use HTTPS or the demo builder internal HTTP service.' >&2; exit 1;; esac
if [[ -n $(oc -n "$NAMESPACE" get dv orders-bootc-root --ignore-not-found -o name) ]]; then
  echo 'orders-bootc-root already exists; inspect it instead of replacing it.' >&2; exit 1
fi
export NAMESPACE BOOTC_DISK_URL
ruby -rjson -e '
  spec={source:{http:{url:ENV.fetch("BOOTC_DISK_URL")}},storage:{resources:{requests:{storage:"20Gi"}}}}
  doc={apiVersion:"cdi.kubevirt.io/v1beta1",kind:"DataVolume",metadata:{name:"orders-bootc-root",namespace:ENV.fetch("NAMESPACE"),annotations:{"cdi.kubevirt.io/storage.bind.immediate.requested"=>"true"}},spec:spec}
  puts JSON.generate(doc)
' | oc -n "$NAMESPACE" create -f -
oc -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded dv/orders-bootc-root --timeout=20m
