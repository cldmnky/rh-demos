#!/usr/bin/env bash
# Copies already-configured Virtualization registration settings into the demo namespace.
# The credentials are passed through a pipe, never printed or embedded in a command line.
set -euo pipefail
: "${NAMESPACE:?Set NAMESPACE to the demo namespace}"
RHSM_SECRET=${RHSM_SECRET:-orders-rhsm}
VIRT_NAMESPACE=${VIRT_NAMESPACE:-openshift-cnv}
if oc -n "$NAMESPACE" get secret "$RHSM_SECRET" >/dev/null 2>&1; then
  echo "Secret $RHSM_SECRET already exists; retaining it. Update it explicitly if the activation settings changed."
  exit 0
fi
export NAMESPACE RHSM_SECRET
oc -n "$VIRT_NAMESPACE" get configmap kubevirt-ui-features -o json | ruby -rjson -e '
  data=JSON.parse(STDIN.read).fetch("data")
  org=data.fetch("automaticSubscriptionOrganizationId", "").strip
  key=data.fetch("automaticSubscriptionActivationKey", "").strip
  abort "Virtualization activation key or organization ID is not configured" if org.empty? || key.empty?
  puts JSON.generate({apiVersion:"v1",kind:"Secret",metadata:{name:ENV.fetch("RHSM_SECRET"),namespace:ENV.fetch("NAMESPACE")},type:"Opaque",stringData:{RHSM_ORG:org,RHSM_ACTIVATION_KEY:key}})
' | oc -n "$NAMESPACE" create -f -
