#!/usr/bin/env bash
# End-to-End Test and Validation Flow for NetApp Trident Protect DR Demo
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEMO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

echo "🚀 Starting E2E validation for Trident Protect DR Demo..."

# Step 1: Force clean prior resources
echo "🧹 Step 1: Performing pre-run cleanup..."
"${DEMO_ROOT}/scripts/cleanup.sh"

# Step 2: Deploy Production application via ArgoCD
echo "📦 Step 2: Deploying Production Application via ArgoCD..."
echo "   Creating global ArgoCD controller ClusterRoleBinding..."
oc create clusterrolebinding openshift-gitops-controller-admin-global --clusterrole=cluster-admin --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller --dry-run=client -o yaml | oc apply -f -

oc apply -f "${DEMO_ROOT}/argocd/argocd-prod-app.yaml"

echo "⏳ Waiting for namespace vm-prod to be created..."
until oc get ns vm-prod &>/dev/null; do
  sleep 2
done

echo "⏳ Waiting for Trident Protect Application to become Ready..."
for i in {1..30}; do
  STATE=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  echo "   Current state: ${STATE}"
  if [[ "${STATE}" == "True" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATE}" != "True" ]]; then
  echo "❌ Error: Trident Protect Application did not reach Ready state." >&2
  exit 1
fi

echo "⏳ Waiting for Production CentOS VM to be Running..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: VM did not reach Running state." >&2
  exit 1
fi
echo "✅ Production VM is successfully Running!"

# Step 3: Test Pattern B - S3 Backup & Restore-Based DR via Tekton
echo "🤖 Step 3: Testing Pattern B (S3 Backup & Restore) via Tekton..."
echo "   Granting RBAC permissions to Tekton pipeline service accounts..."
oc create clusterrolebinding pipeline-admin-vm-prod --clusterrole=cluster-admin --serviceaccount=vm-prod:pipeline --dry-run=client -o yaml | oc apply -f - || true
oc create clusterrolebinding pipeline-admin-vm-dr-backup --clusterrole=cluster-admin --serviceaccount=vm-dr-backup:pipeline --dry-run=client -o yaml | oc apply -f - || true

echo "   Applying Tekton pipeline resources..."
oc apply -f "${DEMO_ROOT}/pipelines/tasks/trident-protect-backup.yaml" -n vm-prod
oc apply -f "${DEMO_ROOT}/pipelines/tasks/trident-protect-restore.yaml" -n vm-prod
oc apply -f "${DEMO_ROOT}/pipelines/dr-pipeline.yaml" -n vm-prod

echo "   Triggering Tekton DR Pipeline..."
PR_NAME=$(cat <<EOF | oc create -f - -o name
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: trident-dr-run-
  namespace: vm-prod
spec:
  pipelineRef:
    name: trident-dr-pipeline
  params:
    - name: application-name
      value: centos-vm-app
    - name: destination-namespace
      value: vm-dr-backup
EOF
)
echo "   PipelineRun created: ${PR_NAME}"

echo "⏳ Waiting for Tekton PipelineRun to complete..."
for i in {1..60}; do
  COND=$(oc get "${PR_NAME}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  REASON=$(oc get "${PR_NAME}" -n vm-prod -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  echo "   Pipeline status: ${COND} (Reason: ${REASON})"
  if [[ "${COND}" == "True" ]]; then
    break
  fi
  if [[ "${COND}" == "False" ]]; then
    echo "❌ Error: PipelineRun failed!" >&2
    oc get pipelinerun -n vm-prod || true
    exit 1
  fi
  sleep 10
done

echo "🔍 Verifying Pattern B Restored Application in vm-dr-backup..."
for i in {1..30}; do
  STATE=$(oc get application.protect.trident.netapp.io centos-vm-app-restored -n vm-dr-backup -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "${STATE}" == "True" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATE}" != "True" ]]; then
  echo "❌ Error: Restored Trident Application is not Ready." >&2
  exit 1
fi

echo "⏳ Waiting for Restored VM to become Running in vm-dr-backup..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm -n vm-dr-backup -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   Restored VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: Restored VM did not reach Running state." >&2
  exit 1
fi
echo "✅ Pattern B E2E Restore Successful!"

# Step 4: Test Pattern A - SnapMirror AppMirrorRelationship (AMR)
echo "🔗 Step 4: Testing Pattern A (SnapMirror AMR) via ArgoCD..."
SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}')
echo "   Source Application UID resolved: ${SOURCE_UID}"

echo "   Deploying DR Mirror Application in ArgoCD..."
oc apply -f "${DEMO_ROOT}/argocd/argocd-dr-mirror-app.yaml"

echo "⏳ Waiting for namespace vm-dr-mirror to be created..."
until oc get ns vm-dr-mirror &>/dev/null; do
  sleep 2
done

echo "   Injecting Source App UID into ArgoCD Helm Parameters..."
oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=merge -p '{"spec":{"source":{"helm":{"parameters":[{"name":"trident.amr.sourceAppUID","value":"'"${SOURCE_UID}"'"}]}}}}'

echo "⏳ Waiting for AppMirrorRelationship to become Established..."
for i in {1..40}; do
  STATE=$(oc get amr vm-mirror-relationship -n vm-dr-mirror -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "   AMR State: ${STATE}"
  if [[ "${STATE}" == "Established" ]]; then
    break
  fi
  sleep 10
done
if [[ "${STATE}" != "Established" ]]; then
  echo "❌ Error: AppMirrorRelationship did not reach Established state." >&2
  exit 1
fi

echo "📢 Simulating GitOps-Driven DR Failover (Promoting relationship)..."
oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=json -p '[{"op":"add","path":"/spec/source/helm/parameters/1","value":{"name":"trident.amr.desiredState","value":"Promoted"}}]'

echo "⏳ Waiting for AppMirrorRelationship to become Promoted..."
for i in {1..30}; do
  STATE=$(oc get amr vm-mirror-relationship -n vm-dr-mirror -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "   AMR State after promotion: ${STATE}"
  if [[ "${STATE}" == "Promoted" ]]; then
    break
  fi
  sleep 10
done
if [[ "${STATE}" != "Promoted" ]]; then
  echo "❌ Error: AppMirrorRelationship did not reach Promoted state." >&2
  exit 1
fi

echo "⏳ Waiting for Mirrored VM to become Running in vm-dr-mirror..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm -n vm-dr-mirror -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   Mirrored VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: Mirrored VM did not reach Running state." >&2
  exit 1
fi

echo "✅ Pattern A E2E Mirror DR Promotion Successful!"
echo "🎉 All E2E Flows passed successfully!"
