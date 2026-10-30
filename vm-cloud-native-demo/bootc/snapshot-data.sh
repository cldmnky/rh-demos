#!/usr/bin/env bash
# Take an offline snapshot of the stopped legacy database VM's dedicated data disk.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
SNAPSHOT=${SNAPSHOT:-orders-db-before-bootc}
SOURCE_VM=${SOURCE_VM:-orders-db}
SOURCE_PVC=${SOURCE_PVC:-$(oc -n "$NAMESPACE" get vm "$SOURCE_VM" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="datadisk")].persistentVolumeClaim.claimName}')}
SNAPSHOT_CLASS=${SNAPSHOT_CLASS:?Set SNAPSHOT_CLASS to the matching CSI VolumeSnapshotClass}
[[ $SOURCE_VM =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && $SOURCE_PVC =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid source VM or PVC name.' >&2; exit 1; }
[[ $SNAPSHOT =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && $SNAPSHOT_CLASS =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || { echo 'Invalid snapshot or class name.' >&2; exit 1; }
attached=$(oc -n "$NAMESPACE" get vm "$SOURCE_VM" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="datadisk")].persistentVolumeClaim.claimName}')
[[ "$attached" == "$SOURCE_PVC" ]] || { echo 'Source VM is not configured with the specified data PVC.' >&2; exit 1; }
# Stop is deliberate and must be done by the migration orchestrator after writes are quiesced.
[[ -z $(oc -n "$NAMESPACE" get vmi "$SOURCE_VM" --ignore-not-found -o name) ]] || { echo 'Database VMI is still running; stop MariaDB and the VM first.' >&2; exit 1; }
[[ $(oc -n "$NAMESPACE" get vm "$SOURCE_VM" -o jsonpath='{.spec.runStrategy}') == Halted ]] || { echo 'Database VM must have runStrategy Halted.' >&2; exit 1; }
[[ -z $(oc -n "$NAMESPACE" get volumesnapshot "$SNAPSHOT" --ignore-not-found -o name) ]] || { echo 'Snapshot name exists; use a fresh name after inspecting it.' >&2; exit 1; }
cat <<YAML | oc -n "$NAMESPACE" create -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $SNAPSHOT
spec:
  volumeSnapshotClassName: $SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: $SOURCE_PVC
YAML
oc -n "$NAMESPACE" wait --for=jsonpath='{.status.readyToUse}'=true "volumesnapshot/$SNAPSHOT" --timeout=10m
printf 'Offline database snapshot %s is ready.\n' "$SNAPSHOT"
