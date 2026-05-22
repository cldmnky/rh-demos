#!/usr/bin/env bash
# Cleanup script — removes everything the demo created from the cluster.
# Leaves ArgoCD, OpenShift Virtualization, and OpenShift Pipelines intact.
#
# Run from repo root or gitops-vmware-virt-demo/:
#   ./scripts/cleanup.sh
#
# Set RESET_GIT=true to also revert demo-modified Git files and push.

set -euo pipefail

NAMESPACE="vm-demo"
ARGOCD_NS="openshift-gitops"
RESET_GIT="${RESET_GIT:-false}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
DEMO_DIR="gitops-vmware-virt-demo"
DEMO_ROOT="${REPO_ROOT}/${DEMO_DIR}"

echo "🧹 Cleaning up demo resources..."

# Clear any runtime Helm parameter overrides from the ArgoCD Application before deleting it.
# This ensures the Application is in a clean state for inspection or re-use.
echo "→ Clearing ArgoCD Helm parameter overrides..."
oc patch application.argoproj.io vm-demo -n "${NAMESPACE}" --type=merge \
  -p '{"spec":{"source":{"helm":{"parameters":null}}}}' 2>/dev/null || true

# Delete ArgoCD Applications (in vm-demo namespace — apps-in-any-namespace)
echo "→ Removing ArgoCD Applications from ${NAMESPACE} namespace..."
oc delete application vm-demo vm-demo-infra -n "${NAMESPACE}" --ignore-not-found

# Delete AppProject from ArgoCD control-plane namespace
echo "→ Removing AppProject from ${ARGOCD_NS}..."
oc delete appproject vm-demo -n "${ARGOCD_NS}" --ignore-not-found

# Delete ArgoCD controller permissions in the demo namespace
echo "→ Removing ArgoCD controller RoleBinding from ${NAMESPACE}..."
oc delete rolebinding openshift-gitops-argocd-application-controller-admin -n "${NAMESPACE}" --ignore-not-found

# Remove sourceNamespaces patch from ArgoCD CR
echo "→ Removing sourceNamespaces from ArgoCD CR..."
oc patch argocd openshift-gitops -n "${ARGOCD_NS}" \
  --type=json \
  -p '[{"op":"remove","path":"/spec/sourceNamespaces"}]' 2>/dev/null || true

# MetalLB pools are cluster-level shared infrastructure and are not created by
# the demo flow, so cleanup intentionally leaves metallb-system untouched.
echo "→ Leaving existing MetalLB configuration untouched..."
# Remove any demo-pool/demo-l2 resources that may have been applied in error.
oc delete ipaddresspool demo-pool -n metallb-system --ignore-not-found 2>/dev/null || true
oc delete l2advertisement demo-l2 -n metallb-system --ignore-not-found 2>/dev/null || true

# Delete VirtualMachineSnapshots before namespace deletion to avoid finalizer-induced stalls.
# The upgrade pipeline creates blue-pre-upgrade-<run-id> snapshots; their VirtualMachineSnapshotContent
# objects are namespace-scoped and cascade-deleted when the snapshot is deleted.
echo "→ Removing VirtualMachineSnapshots from ${NAMESPACE}..."
oc delete virtualmachinesnapshot --all -n "${NAMESPACE}" --ignore-not-found

# Delete VolumeSnapshots before namespace deletion. If they get stuck due to CSI finalizer issues,
# we force-remove their finalizers to prevent namespace deletion hangs.
echo "→ Removing VolumeSnapshots from ${NAMESPACE}..."
oc delete volumesnapshot --all -n "${NAMESPACE}" --ignore-not-found --timeout=15s 2>/dev/null || true

vss=$(oc get volumesnapshot -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [[ -n "${vss}" ]]; then
  echo "   Force-removing finalizers from remaining VolumeSnapshots in ${NAMESPACE}..."
  for vs in ${vss}; do
    oc patch volumesnapshot "${vs}" -n "${NAMESPACE}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
fi

vscs=$(oc get volumesnapshotcontent -o jsonpath='{range .items[?(@.spec.volumeSnapshotRef.namespace=="'"${NAMESPACE}"'")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
if [[ -n "${vscs}" ]]; then
  echo "   Force-removing finalizers from remaining VolumeSnapshotContents for ${NAMESPACE}..."
  for vsc in ${vscs}; do
    oc patch volumesnapshotcontent "${vsc}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
fi

# Delete entire vm-demo namespace (removes VMs, DataVolumes, PVCs, pipelines, secrets, services, etc.)
echo "→ Deleting namespace ${NAMESPACE} (VMs, DataVolumes, PVCs, pipelines, secrets, services)..."
oc delete namespace "${NAMESPACE}" --ignore-not-found
echo "   Waiting for namespace deletion..."
oc wait --for=delete namespace/"${NAMESPACE}" --timeout=180s 2>/dev/null || true

echo "✅ Cluster resources removed."

# Optionally reset Git-modified files
if [[ "${RESET_GIT}" == "true" ]]; then
  echo ""
  echo "→ Resetting demo-modified Git files..."

  # Reset app-version.yaml back to v1.0
  if grep -q '"v2.0"' "${DEMO_ROOT}/pipelines/app-version.yaml" 2>/dev/null; then
    sed -i '' 's/version: "v2.0"/version: "v1.0"/' "${DEMO_ROOT}/pipelines/app-version.yaml"
    echo "   Reverted app-version.yaml to v1.0"
  fi

  git -C "${REPO_ROOT}" add \
    "${DEMO_DIR}/pipelines/app-version.yaml" 2>/dev/null || true

  if ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    git -C "${REPO_ROOT}" commit -m "chore: reset demo state to initial"
    git -C "${REPO_ROOT}" pull --rebase --autostash origin main && git -C "${REPO_ROOT}" push origin main
    echo "   Git state reset and pushed."
  else
    echo "   Git state already clean — nothing to reset."
  fi
fi

echo ""
echo "🎩 Cleanup complete. Cluster is ready for the next demo run."
