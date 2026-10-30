#!/usr/bin/env bash
# Restore an offline snapshot to a new data PVC; never replace the source PVC.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
SNAPSHOT=${SNAPSHOT:-orders-db-before-bootc}
TARGET_PVC=${TARGET_PVC:-orders-db-bootc-data}
SOURCE_PVC=${SOURCE_PVC:-$(oc -n "$NAMESPACE" get volumesnapshot "$SNAPSHOT" -o jsonpath='{.spec.source.persistentVolumeClaimName}')}
[[ "$SNAPSHOT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "$TARGET_PVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "$TARGET_PVC" != "$SOURCE_PVC" ]] || { echo 'Invalid snapshot or target PVC name.' >&2; exit 1; }
[[ $(oc -n "$NAMESPACE" get volumesnapshot "$SNAPSHOT" -o jsonpath='{.status.readyToUse}') == true ]] || { echo 'Snapshot is not ready.' >&2; exit 1; }
source_pvc=$(oc -n "$NAMESPACE" get volumesnapshot "$SNAPSHOT" -o jsonpath='{.spec.source.persistentVolumeClaimName}')
[[ "$source_pvc" == "$SOURCE_PVC" ]] || { echo 'Snapshot does not belong to the legacy database disk.' >&2; exit 1; }
[[ -z $(oc -n "$NAMESPACE" get pvc "$TARGET_PVC" --ignore-not-found -o name) ]] || { echo 'Target PVC exists; inspect it rather than replacing data.' >&2; exit 1; }
export NAMESPACE SNAPSHOT TARGET_PVC
oc -n "$NAMESPACE" get pvc "$SOURCE_PVC" -o json | ruby -rjson -e '
  source=JSON.parse(STDIN.read).fetch("spec")
  spec={"accessModes"=>source.fetch("accessModes"), "resources"=>{"requests"=>{"storage"=>source.fetch("resources").fetch("requests").fetch("storage")}}, "volumeMode"=>source.fetch("volumeMode","Filesystem"), "dataSource"=>{"apiGroup"=>"snapshot.storage.k8s.io", "kind"=>"VolumeSnapshot", "name"=>ENV.fetch("SNAPSHOT")}}
  spec["storageClassName"]=source["storageClassName"] if source.key?("storageClassName")
  puts JSON.generate({"apiVersion"=>"v1", "kind"=>"PersistentVolumeClaim", "metadata"=>{"name"=>ENV.fetch("TARGET_PVC"),"namespace"=>ENV.fetch("NAMESPACE")}, "spec"=>spec})
' | oc -n "$NAMESPACE" create -f -
printf 'Created clone PVC %s from snapshot %s. A WaitForFirstConsumer storage class may not bind until the target VM starts.\n' "$TARGET_PVC" "$SNAPSHOT"
