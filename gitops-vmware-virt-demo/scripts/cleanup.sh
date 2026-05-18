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
REPO_ROOT=$(git rev-parse --show-toplevel)
DEMO_DIR="gitops-vmware-virt-demo"

echo "🧹 Cleaning up demo resources..."

# Delete ArgoCD Applications (in vm-demo namespace — apps-in-any-namespace)
echo "→ Removing ArgoCD Applications from ${NAMESPACE} namespace..."
oc delete application vm-demo vm-demo-infra -n "${NAMESPACE}" --ignore-not-found

# Delete AppProject from ArgoCD control-plane namespace
echo "→ Removing AppProject from ${ARGOCD_NS}..."
oc delete appproject vm-demo -n "${ARGOCD_NS}" --ignore-not-found

# Remove sourceNamespaces patch from ArgoCD CR
echo "→ Removing sourceNamespaces from ArgoCD CR..."
oc patch argocd openshift-gitops -n "${ARGOCD_NS}" \
  --type=json \
  -p '[{"op":"remove","path":"/spec/sourceNamespaces"}]' 2>/dev/null || true

# Delete MetalLB config
echo "→ Removing MetalLB configuration..."
oc delete -f metallb/ --ignore-not-found 2>/dev/null || true

# Delete entire vm-demo namespace (removes VMs, pipelines, secrets, services, etc.)
echo "→ Deleting namespace ${NAMESPACE} (VMs, pipelines, secrets, services)..."
oc delete namespace "${NAMESPACE}" --ignore-not-found
echo "   Waiting for namespace deletion..."
oc wait --for=delete namespace/"${NAMESPACE}" --timeout=180s 2>/dev/null || true

echo "✅ Cluster resources removed."

# Optionally reset Git-modified files
if [[ "${RESET_GIT}" == "true" ]]; then
  echo ""
  echo "→ Resetting demo-modified Git files..."

  # Reset app-version.yaml back to v1.0
  if grep -q '"v2.0"' "${DEMO_DIR}/pipelines/app-version.yaml" 2>/dev/null; then
    sed -i '' 's/version: "v2.0"/version: "v1.0"/' "${DEMO_DIR}/pipelines/app-version.yaml"
    echo "   Reverted app-version.yaml to v1.0"
  fi

  # Reset vm-blue.yaml to initial state (runStrategy: Always — it should already be there)
  # Reset vm-green.yaml to Halted
  yq e '.spec.runStrategy = "Halted"' -i "${REPO_ROOT}/${DEMO_DIR}/base/vm-green.yaml" 2>/dev/null || true
  yq e '.spec.runStrategy = "Always"' -i "${REPO_ROOT}/${DEMO_DIR}/base/vm-blue.yaml" 2>/dev/null || true

  # Restore service selector to blue
  if command -v yq &>/dev/null; then
    yq e '.spec.selector.version = "blue"' -i "${REPO_ROOT}/${DEMO_DIR}/base/service-lb.yaml" 2>/dev/null || true
  fi

  git -C "${REPO_ROOT}" add \
    "${DEMO_DIR}/pipelines/app-version.yaml" \
    "${DEMO_DIR}/base/vm-blue.yaml" \
    "${DEMO_DIR}/base/vm-green.yaml" \
    "${DEMO_DIR}/base/service-lb.yaml" 2>/dev/null || true

  if ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    git -C "${REPO_ROOT}" commit -m "chore: reset demo state to initial"
    git -C "${REPO_ROOT}" push origin main
    echo "   Git state reset and pushed."
  else
    echo "   Git state already clean — nothing to reset."
  fi
fi

echo ""
echo "🎩 Cleanup complete. Cluster is ready for the next demo run."
