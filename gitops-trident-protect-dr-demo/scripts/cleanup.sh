#!/usr/bin/env bash
# Cleanup script for gitops-trident-protect-dr-demo
set -euo pipefail

NAMESPACES=("vm-prod" "vm-dr-mirror" "vm-dr-backup")
ARGOCD_NS="openshift-gitops"

echo "🧹 Cleaning up Trident Protect DR Demo resources..."

# Delete ArgoCD Applications
echo "→ Removing ArgoCD Applications..."
oc delete application trident-dr-prod trident-dr-mirror trident-dr-infra -n "${ARGOCD_NS}" --ignore-not-found --timeout=30s 2>/dev/null || true

# Delete cluster-level rolebindings
echo "→ Removing cluster rolebindings..."
oc delete clusterrolebinding pipeline-admin-vm-prod pipeline-admin-vm-dr-backup openshift-gitops-controller-admin-global --ignore-not-found 2>/dev/null || true

# Force-remove finalizers from any AppMirrorRelationships, BackupRestores, Backups, Snapshots, Applications
for ns in "${NAMESPACES[@]}"; do
  echo "→ Cleaning up Trident Protect resources in namespace ${ns}..."
  oc delete appmirrorrelationship --all -n "${ns}" --ignore-not-found --timeout=15s 2>/dev/null || true
  oc delete backuprestore --all -n "${ns}" --ignore-not-found --timeout=15s 2>/dev/null || true
  oc delete backup --all -n "${ns}" --ignore-not-found --timeout=15s 2>/dev/null || true
  oc delete snapshot --all -n "${ns}" --ignore-not-found --timeout=15s 2>/dev/null || true
  oc delete application.protect.trident.netapp.io --all -n "${ns}" --ignore-not-found --timeout=15s 2>/dev/null || true
done

# Delete namespaces
for ns in "${NAMESPACES[@]}"; do
  echo "→ Deleting namespace ${ns}..."
  oc delete namespace "${ns}" --ignore-not-found --timeout=15s 2>/dev/null || true
done

# Force-clean VolumeSnapshots and VolumeSnapshotContents to avoid hangs
for ns in "${NAMESPACES[@]}"; do
  echo "→ Checking for remaining VolumeSnapshots in namespace ${ns}..."
  vss=$(oc get volumesnapshot -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [[ -n "${vss}" ]]; then
    echo "   Force-removing finalizers from remaining VolumeSnapshots in ${ns}..."
    for vs in ${vss}; do
      oc patch volumesnapshot "${vs}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  fi

  vscs=$(oc get volumesnapshotcontent -o jsonpath='{range .items[?(@.spec.volumeSnapshotRef.namespace=="'"${ns}"'")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
  if [[ -n "${vscs}" ]]; then
    echo "   Force-removing finalizers from remaining VolumeSnapshotContents for namespace ${ns}..."
    for vsc in ${vscs}; do
      oc patch volumesnapshotcontent "${vsc}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  fi
done

# Wait for namespaces to terminate
for ns in "${NAMESPACES[@]}"; do
  echo "→ Waiting for namespace ${ns} to terminate..."
  oc wait --for=delete namespace/"${ns}" --timeout=60s 2>/dev/null || true
done

echo "✅ Cleanup complete!"
