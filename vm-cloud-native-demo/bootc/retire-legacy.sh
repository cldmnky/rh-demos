#!/usr/bin/env bash
# Remove the legacy VM objects only after traffic has moved; data PVCs remain.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
[[ $(oc -n "$NAMESPACE" get svc orders-db -o jsonpath='{.spec.selector.vm\.kubevirt\.io/name}') == orders-db-bootc ]] || { echo 'Database traffic is not on the bootc VM.' >&2; exit 1; }
[[ $(oc -n "$NAMESPACE" get svc orders-app -o jsonpath='{.spec.selector.app}') == orders-api-container ]] || { echo 'API traffic is not on the container.' >&2; exit 1; }
oc -n "$NAMESPACE" get route orders -o json | ruby -rjson -e 'r=JSON.parse(STDIN.read).fetch("spec"); all=[r.fetch("to"),*(r["alternateBackends"]||[])]; abort "Frontend Route still sends traffic to a legacy service" unless all.any?{|x|x["name"]=="orders-web-container" && (x["weight"]||100)>0} && all.all?{|x|x["name"]=="orders-web-container" || (x["weight"]||100)==0}'
# Confirm the data disk is separate from the VM lifecycle before removing it.
data_pvc=$(oc -n "$NAMESPACE" get vm orders-db -o jsonpath='{.spec.template.spec.volumes[?(@.name=="datadisk")].persistentVolumeClaim.claimName}')
[[ -n "$data_pvc" ]] || { echo 'Legacy data PVC is missing; refusing VM removal.' >&2; exit 1; }
oc -n "$NAMESPACE" get pvc "$data_pvc" -o json | ruby -rjson -e 'pvc=JSON.parse(STDIN.read); abort "Legacy data PVC is owned by a VM; refusing removal." if (pvc.dig("metadata","ownerReferences")||[]).any?{|r|r["kind"]=="VirtualMachine"}'
for vm in orders-app orders-web orders-db; do
  if [[ $(oc -n "$NAMESPACE" get vm "$vm" -o jsonpath='{.spec.runStrategy}') != Halted ]]; then
    virtctl -n "$NAMESPACE" stop "$vm"
    oc -n "$NAMESPACE" wait --for=delete "vmi/$vm" --timeout=5m
  fi
done
# VM-owned root DataVolumes are disposable; the separate database data PVC and
# the pre-migration snapshot remain. Reset recreates VMs from their definitions.
oc -n "$NAMESPACE" delete vm orders-app orders-web orders-db --cascade=foreground --wait=true
printf 'Legacy VM objects removed. Their separate data PVC and recovery snapshots remain.\n'
