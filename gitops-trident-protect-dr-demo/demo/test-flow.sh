#!/usr/bin/env bash
# End-to-End Test and Validation Flow for NetApp Trident Protect DR & VM Lifecycle Demo
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEMO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"

echo "🚀 Starting E2E validation for Trident Protect & VM Lifecycle DR Demo..."

# Authenticate argocd CLI once at startup
if command -v argocd &>/dev/null; then
  argocd login --core 2>/dev/null || true
fi

# Helper: use argocd app set if available, fall back to oc patch
function helm_param() {
  local app="$1"; shift
  local params=""
  for p in "$@"; do
    params="${params} --parameter ${p}"
  done
  if command -v argocd &>/dev/null && argocd app get "${app}" -N openshift-gitops &>/dev/null; then
    argocd app set "${app}" ${params} -N openshift-gitops >/dev/null 2>&1
  else
    local json="["; local first=true
    for p in "$@"; do
      local name="${p%%=*}"
      local value="${p#*=}"
      if [ "$first" = true ]; then first=false; else json="${json},"; fi
      json="${json}{\"name\":\"${name}\",\"value\":\"${value}\"}"
    done
    json="${json}]"
    oc patch application.argoproj.io "${app}" -n openshift-gitops --type=merge \
      -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":${json}}}}}" >/dev/null 2>&1
  fi
}

function wait_for_pipeline_infra() {
  local resources=(
    task/trident-protect-backup
    task/trident-protect-restore
    task/ansible-run-playbook
    task/smoke-test
    pipeline/trident-dr-pipeline
    pipeline/install-app
    pipeline/upgrade-app
    eventlistener/trident-upgrade-trigger
    route/trident-upgrade-trigger
  )

  echo "⏳ Waiting for ArgoCD-managed pipeline infrastructure in vm-prod..."
  for resource in "${resources[@]}"; do
    local deadline=$(( $(date +%s) + 120 ))
    until oc get "${resource}" -n vm-prod >/dev/null 2>&1; do
      if [ "$(date +%s)" -gt "${deadline}" ]; then
        echo "❌ Error: Timed out waiting for ${resource} in vm-prod" >&2
        exit 1
      fi
      sleep 2
    done
    echo "   ${resource} is ready"
  done
}

# Step 1: Force clean prior resources
echo "🧹 Step 1: Performing pre-run cleanup..."
"${DEMO_ROOT}/scripts/cleanup.sh"

# Step 2: Create SSH key Secrets across namespaces (cloud-init is managed by the Helm chart)
echo "🔑 Step 2: Creating vm-ssh-key Secrets across namespaces..."
for ns in "vm-prod" "vm-dr-backup" "vm-dr-mirror"; do
  oc create namespace "${ns}" --dry-run=client -o yaml | oc apply -f -
  oc create secret generic vm-ssh-key \
    --namespace="${ns}" \
    --from-file=id_rsa="${SSH_PRIVATE_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
done

# Step 3: Deploy Production VM + Kick off S3 Backup/Restore
echo "📦 Step 3: Deploying Production Application via ArgoCD..."
echo "   Creating global ArgoCD controller ClusterRoleBinding..."
oc create clusterrolebinding openshift-gitops-controller-admin-global --clusterrole=cluster-admin --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller --dry-run=client -o yaml | oc apply -f -

oc apply -f "${DEMO_ROOT}/argocd/argocd-prod-app.yaml"

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
  echo "❌ Error: Trident Protect Application did not reach Ready state." >&2; exit 1
fi

echo "⏳ Waiting for Production CentOS VM Blue to be Running..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Blue status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then break; fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: VM Blue did not reach Running state." >&2; exit 1
fi
echo "✅ Production VM Blue is successfully Running!"

# Kick off S3 Backup/Restore pipeline EARLY — it runs in background (Kopia restore takes ~14 min)
echo "☁️ Step 3.5: Firing S3 Backup/Restore DR pipeline (runs in background while we do lifecycle steps)..."
oc apply -f "${DEMO_ROOT}/argocd/argocd-infra-app.yaml"
wait_for_pipeline_infra

DR_PR=$(cat <<EOF | oc create -f - -o name
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
  taskRunTemplate:
    serviceAccountName: pipeline
EOF
)
echo "   DR PipelineRun created: ${DR_PR}"

# Step 4: Install App v1.0 on Blue VM via Tekton & Ansible
echo "🤖 Step 4: Installing App v1.0 on Blue VM via Tekton & Ansible..."

INSTALL_PR=$(oc create -f "${DEMO_ROOT}/pipelines/install-pipelinerun.yaml" -n vm-prod -o name)
echo "   Install PipelineRun created: ${INSTALL_PR}"

echo "⏳ Waiting for Install PipelineRun to complete..."
for i in {1..60}; do
  COND=$(oc get "${INSTALL_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  REASON=$(oc get "${INSTALL_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  echo "   Install Pipeline status: ${COND} (Reason: ${REASON})"
  if [[ "${COND}" == "True" ]]; then break; fi
  if [[ "${COND}" == "False" ]]; then
    echo "❌ Error: Install PipelineRun failed!" >&2
    exit 1
  fi
  sleep 10
done
echo "✅ App v1.0 successfully installed on Blue VM!"

# Step 5: Upgrade to App v2.0 on Green VM via Blue Snapshot Clone
echo "🚀 Step 5: Triggering App Upgrade to v2.0 via Simulated GitHub Webhook..."

EL_ROUTE=$(oc get route trident-upgrade-trigger -n vm-prod -o jsonpath='{.spec.host}')
echo "   EventListener Route: ${EL_ROUTE}"

echo "   Sending mock GitHub push webhook payload..."
curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: push" \
  -d "{
    \"ref\": \"refs/heads/main\",
    \"commits\": [
      {
        \"id\": \"$(git -C ${DEMO_ROOT} rev-parse HEAD)\",
        \"message\": \"bump app version to v2.0\",
        \"modified\": [
          \"gitops-trident-protect-dr-demo/pipelines/app-version.yaml\"
        ]
      }
    ]
  }" \
  "http://${EL_ROUTE}" >/dev/null

echo "⏳ Waiting for EventListener to trigger the Upgrade PipelineRun..."
UPGRADE_PR=""
for i in {1..15}; do
  UPGRADE_PR_NAME=$(oc get pipelinerun -n vm-prod -l tekton.dev/pipeline=upgrade-app --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
  if [[ -n "${UPGRADE_PR_NAME}" ]]; then
    UPGRADE_PR="pipelinerun.tekton.dev/${UPGRADE_PR_NAME}"
    break
  fi
  sleep 2
done
if [[ -z "${UPGRADE_PR}" ]]; then
  echo "❌ Error: EventListener did not trigger the Upgrade PipelineRun." >&2; exit 1
fi
echo "   Upgrade PipelineRun detected: ${UPGRADE_PR}"

echo "⏳ Waiting for Upgrade PipelineRun to complete..."
for i in {1..60}; do
  COND=$(oc get "${UPGRADE_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  REASON=$(oc get "${UPGRADE_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  echo "   Upgrade Pipeline status: ${COND} (Reason: ${REASON})"
  if [[ "${COND}" == "True" ]]; then break; fi
  if [[ "${COND}" == "False" ]]; then
    echo "❌ Error: Upgrade PipelineRun failed!" >&2
    exit 1
  fi
  sleep 10
done

echo "🔍 Verifying VM Green is Running and VM Blue is Halted..."
for i in {1..20}; do
  VM_GREEN_STATUS=$(oc get vm centos-vm-green -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  VM_BLUE_STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Green Status: ${VM_GREEN_STATUS}, VM Blue Status: ${VM_BLUE_STATUS}"
  if [[ "${VM_GREEN_STATUS}" == "Running" && ("${VM_BLUE_STATUS}" == "Stopped" || "${VM_BLUE_STATUS}" == "Stopping") ]]; then
    break
  fi
  sleep 3
done
VM_GREEN_STATUS=$(oc get vm centos-vm-green -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
VM_BLUE_STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
echo "   VM Green Status: ${VM_GREEN_STATUS}, VM Blue Status: ${VM_BLUE_STATUS}"
if [[ "${VM_GREEN_STATUS}" != "Running" ]]; then
  echo "❌ Error: Green VM must be Running after upgrade." >&2; exit 1
fi
if [[ "${VM_BLUE_STATUS}" != "Stopped" && "${VM_BLUE_STATUS}" != "Stopping" ]]; then
  echo "❌ Error: Blue VM must be Stopped or Stopping after upgrade cutover." >&2; exit 1
fi
echo "✅ App v2.0 Blue/Green upgrade completed successfully!"

# Step 6: Presenter-Driven Rollback to Blue
echo "🔁 Step 6: Simulating presenter-driven manual rollback to Blue VM..."
echo "   Step 6.1: Restarting Blue VM while traffic still flows to Green..."
helm_param trident-dr-prod \
  "blue.runStrategy=Always" \
  "green.runStrategy=Always" \
  "traffic.activeSlot=green"

echo "⏳ Waiting for Blue VM to return to Running state..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Blue Status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then break; fi
  sleep 5
done

echo "   Step 6.2: Redirecting traffic to Blue VM and halting Green VM..."
helm_param trident-dr-prod \
  "blue.runStrategy=Always" \
  "green.runStrategy=Halted" \
  "traffic.activeSlot=blue"

echo "⏳ Waiting for Green VM to be Halted..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-green -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Green Status: ${STATUS}"
  if [[ "${STATUS}" == "Stopped" || "${STATUS}" == "Stopping" ]]; then break; fi
  sleep 5
done

echo "   Step 6.3: Clearing ArgoCD parameter overrides to restore Git baseline..."
helm_param trident-dr-prod

echo "⏳ Waiting for ArgoCD to reconcile back to Git baseline..."
for i in {1..30}; do
  BLUE_STRAT=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.spec.runStrategy}' 2>/dev/null || true)
  GREEN_STRAT=$(oc get vm centos-vm-green -n vm-prod -o jsonpath='{.spec.runStrategy}' 2>/dev/null || true)
  echo "   Blue: ${BLUE_STRAT}, Green: ${GREEN_STRAT}"
  if [[ "${BLUE_STRAT}" == "Always" && "${GREEN_STRAT}" == "Halted" ]]; then break; fi
  sleep 5
done
echo "✅ Manual rollback to Blue VM completed successfully!"

# Step 7: SnapMirror Replication DR (Pattern A)
echo "🔗 Step 7: Testing Pattern A (SnapMirror AMR) via ArgoCD..."
echo "   📸 Creating source snapshot for SnapMirror relationship..."
cat <<EOF | oc apply -f -
apiVersion: protect.trident.netapp.io/v1
kind: Snapshot
metadata:
  name: source-vm-snap
  namespace: vm-prod
spec:
  applicationRef: centos-vm-app
  appVaultRef: lab-vault
EOF

echo "⏳ Waiting for source snapshot to reach Completed state..."
for i in {1..30}; do
  STATE=$(oc get snapshot source-vm-snap -n vm-prod -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "   Snapshot state: ${STATE}"
  if [[ "${STATE}" == "Completed" ]]; then break; fi
  sleep 5
done
if [[ "${STATE}" != "Completed" ]]; then
  echo "❌ Error: Source snapshot did not complete." >&2; exit 1
fi

SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}')
echo "   Source Application UID resolved: ${SOURCE_UID}"

echo "   Deploying DR Mirror Application in ArgoCD..."
oc apply -f "${DEMO_ROOT}/argocd/argocd-dr-mirror-app.yaml"

echo "⏳ Waiting for namespace vm-dr-mirror to be created..."
until oc get ns vm-dr-mirror &>/dev/null; do sleep 2; done

echo "   Injecting Source App UID into ArgoCD Helm Parameters..."
helm_param trident-dr-mirror "trident.amr.sourceAppUID=${SOURCE_UID}"

echo "⏳ Waiting for AppMirrorRelationship to become Established..."
for i in {1..60}; do
  STATE=$(oc get amr vm-mirror-relationship -n vm-dr-mirror -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "   AMR State: ${STATE}"
  if [[ "${STATE}" == "Established" ]]; then break; fi
  sleep 10
done
if [[ "${STATE}" != "Established" ]]; then
  echo "❌ Error: AppMirrorRelationship did not reach Established state." >&2; exit 1
fi

echo "📢 Simulating GitOps-Driven DR Failover (Promoting relationship)..."
helm_param trident-dr-mirror "trident.amr.sourceAppUID=${SOURCE_UID}" "trident.amr.desiredState=Promoted"

echo "⏳ Waiting for AppMirrorRelationship to become Promoted..."
for i in {1..30}; do
  STATE=$(oc get amr vm-mirror-relationship -n vm-dr-mirror -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "   AMR State after promotion: ${STATE}"
  if [[ "${STATE}" == "Promoted" ]]; then break; fi
  sleep 10
done
if [[ "${STATE}" != "Promoted" ]]; then
  echo "❌ Error: AppMirrorRelationship did not reach Promoted state." >&2; exit 1
fi

echo "⏳ Waiting for Mirrored VM to become Running in vm-dr-mirror..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-blue -n vm-dr-mirror -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   Mirrored VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then break; fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: Mirrored VM did not reach Running state in vm-dr-mirror." >&2; exit 1
fi
echo "✅ Pattern A E2E Mirror DR Promotion Successful!"

# Step 8: Verify S3 Backup/Restore Results (should be done by now, Kopia has been running in background)
echo "☁️ Step 8: Checking S3 Backup/Restore results (Kopia restore has been running in background)..."
echo "⏳ Waiting for DR PipelineRun to complete..."
for i in {1..30}; do
  COND=$(oc get "${DR_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  echo "   DR Pipeline status: ${COND}"
  if [[ "${COND}" == "True" ]]; then break; fi
  if [[ "${COND}" == "False" ]]; then echo "❌ Error: DR PipelineRun failed!" >&2; exit 1; fi
  sleep 10
done

echo "🔍 Verifying Pattern B Restored Application in vm-dr-backup..."
for i in {1..60}; do
  STATE=$(oc get application.protect.trident.netapp.io centos-vm-app-restored -n vm-dr-backup -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "${STATE}" == "True" ]]; then break; fi
  sleep 5
done
if [[ "${STATE}" != "True" ]]; then
  echo "❌ Error: Restored Trident Application is not Ready." >&2; exit 1
fi

echo "⏳ Waiting for Restored VM to become Running in vm-dr-backup..."
for i in {1..90}; do
  STATUS=$(oc get vm centos-vm-blue -n vm-dr-backup -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   Restored VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then break; fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: Restored VM did not reach Running state in vm-dr-backup." >&2; exit 1
fi
echo "✅ Pattern B E2E Backup & Restore Successful!"
echo "🎉 All E2E Flows passed successfully!"
