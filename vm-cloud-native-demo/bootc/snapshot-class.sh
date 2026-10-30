#!/usr/bin/env bash
# Resolve a unique snapshot class for the database Service target's CSI driver.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
source_vm=$(oc -n "$NAMESPACE" get svc orders-db -o jsonpath='{.spec.selector.vm\.kubevirt\.io/name}')
case "$source_vm" in orders-db|orders-db-bootc) ;; *) echo 'Database Service does not select an expected VM.' >&2; exit 1;; esac
source_pvc=$(oc -n "$NAMESPACE" get vm "$source_vm" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="datadisk")].persistentVolumeClaim.claimName}')
[[ -n "$source_pvc" ]] || { echo 'Cannot determine active database PVC.' >&2; exit 1; }
class=$(oc -n "$NAMESPACE" get pvc "$source_pvc" -o jsonpath='{.spec.storageClassName}')
driver=$(oc get storageclass "$class" -o jsonpath='{.provisioner}')
[[ -n "$driver" ]] || { echo 'Cannot determine database CSI driver.' >&2; exit 1; }
oc get volumesnapshotclass -o json | DRIVER="$driver" ruby -rjson -e '
  matches=JSON.parse(STDIN.read).fetch("items").select{|x|x["driver"]==ENV.fetch("DRIVER")}
  requested=ENV.fetch("SNAPSHOT_CLASS", "")
  if requested.empty?
    abort "Expected exactly one compatible VolumeSnapshotClass, found #{matches.length}; set SNAPSHOT_CLASS explicitly." unless matches.length==1
    puts matches.fetch(0).fetch("metadata").fetch("name")
  else
    abort "Snapshot class #{requested} does not match the database storage driver." unless matches.any?{|x|x.dig("metadata","name")==requested}
    puts requested
  end
'
