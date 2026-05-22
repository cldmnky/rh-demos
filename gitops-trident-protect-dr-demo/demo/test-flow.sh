#!/usr/bin/env bash
# End-to-End Test and Validation Flow for NetApp Trident Protect DR & VM Lifecycle Demo
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEMO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/rh-demos.pub}"

echo "🚀 Starting E2E validation for Trident Protect & VM Lifecycle DR Demo..."

# Step 1: Force clean prior resources
echo "🧹 Step 1: Performing pre-run cleanup..."
"${DEMO_ROOT}/scripts/cleanup.sh"

# Step 2: Create Secrets
echo "🔑 Step 2: Creating SSH & cloud-init Secrets across namespaces..."
for ns in "vm-prod" "vm-dr-backup" "vm-dr-mirror"; do
  oc create namespace "${ns}" --dry-run=client -o yaml | oc apply -f -
  
  # Create vm-ssh-key secret
  oc create secret generic vm-ssh-key \
    --namespace="${ns}" \
    --from-file=id_rsa="${SSH_PRIVATE_KEY}" \
    --dry-run=client -o yaml | oc apply -f -

  # Create vm-cloud-init secret
  PUB_KEY_CONTENT=$(cat "${SSH_PUBLIC_KEY}")
  oc create secret generic vm-cloud-init \
    --namespace="${ns}" \
    --from-literal=userdata="#cloud-config
user: cloud-user
password: redhat
chpasswd: { expire: False }
ssh_authorized_keys:
  - ${PUB_KEY_CONTENT}" \
    --dry-run=client -o yaml | oc apply -f -
done

# Step 3: Deploy Production application via ArgoCD
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
  echo "❌ Error: Trident Protect Application did not reach Ready state." >&2
  exit 1
fi

echo "⏳ Waiting for Production CentOS VM Blue to be Running..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Blue status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: VM Blue did not reach Running state." >&2
  exit 1
fi
echo "✅ Production VM Blue is successfully Running!"

# Step 4: Install App v1.0 on Blue VM via Tekton & Ansible
echo "🤖 Step 4: Installing App v1.0 on Blue VM via Tekton & Ansible..."
oc create clusterrolebinding pipeline-admin-vm-prod --clusterrole=cluster-admin --serviceaccount=vm-prod:pipeline --dry-run=client -o yaml | oc apply -f - || true

oc apply -f "${DEMO_ROOT}/pipelines/tasks/ansible-run-playbook.yaml" -n vm-prod
oc apply -f "${DEMO_ROOT}/pipelines/tasks/smoke-test.yaml" -n vm-prod
oc apply -f "${DEMO_ROOT}/pipelines/install-pipeline.yaml" -n vm-prod

INSTALL_PR=$(oc create -f "${DEMO_ROOT}/pipelines/install-pipelinerun.yaml" -n vm-prod -o name)
echo "   Install PipelineRun created: ${INSTALL_PR}"

echo "⏳ Waiting for Install PipelineRun to complete..."
for i in {1..60}; do
  COND=$(oc get "${INSTALL_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  REASON=$(oc get "${INSTALL_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  echo "   Install Pipeline status: ${COND} (Reason: ${REASON})"
  if [[ "${COND}" == "True" ]]; then
    break
  fi
  if [[ "${COND}" == "False" ]]; then
    echo "❌ Error: Install PipelineRun failed!" >&2
    oc logs -n vm-prod -l tekton.dev/pipeline=install-app --all-containers --tail=100 || true
    exit 1
  fi
  sleep 10
done
echo "✅ App v1.0 successfully installed on Blue VM!"

# Step 5: Upgrade to App v2.0 on Green VM via Blue Snapshot Clone
echo "🚀 Step 5: Upgrading App to v2.0 on Green VM using Trident Snapshot clone..."
oc apply -f "${DEMO_ROOT}/pipelines/upgrade-pipeline.yaml" -n vm-prod

UPGRADE_PR=$(oc create -f "${DEMO_ROOT}/pipelines/upgrade-pipelinerun.yaml" -n vm-prod -o name)
echo "   Upgrade PipelineRun created: ${UPGRADE_PR}"

echo "⏳ Waiting for Upgrade PipelineRun to complete..."
for i in {1..60}; do
  COND=$(oc get "${UPGRADE_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  REASON=$(oc get "${UPGRADE_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  echo "   Upgrade Pipeline status: ${COND} (Reason: ${REASON})"
  if [[ "${COND}" == "True" ]]; then
    break
  fi
  if [[ "${COND}" == "False" ]]; then
    echo "❌ Error: Upgrade PipelineRun failed!" >&2
    oc logs -n vm-prod -l tekton.dev/pipeline=upgrade-app --all-containers --tail=100 || true
    exit 1
  fi
  sleep 10
done

echo "🔍 Verifying VM Green is Running and VM Blue is Halted..."
VM_GREEN_STATUS=$(oc get vm centos-vm-green -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
VM_BLUE_STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
echo "   VM Green Status: ${VM_GREEN_STATUS}, VM Blue Status: ${VM_BLUE_STATUS}"
if [[ "${VM_GREEN_STATUS}" != "Running" || "${VM_BLUE_STATUS}" != "Stopped" ]]; then
  echo "❌ Error: Upgrade states mismatch. Green must be Running, Blue must be Stopped." >&2
  exit 1
fi
echo "✅ App v2.0 Blue/Green upgrade completed successfully!"

# Step 6: Presenter-Driven Rollback to Blue
echo "🔁 Step 6: Simulating presenter-driven manual rollback to Blue VM..."
echo "   Step 6.1: Restarting Blue VM while traffic still flows to Green..."
oc patch application.argoproj.io trident-dr-prod -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"helm":{"parameters":[
    {"name":"blue.runStrategy","value":"Always"},
    {"name":"green.runStrategy","value":"Always"},
    {"name":"traffic.activeSlot","value":"green"}
  ]}}}}'
oc patch vm centos-vm-blue -n vm-prod --type=merge -p '{"spec":{"runStrategy":"Always"}}'

echo "⏳ Waiting for Blue VM to return to Running state..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-blue -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Blue Status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done

echo "   Step 6.2: Redirecting traffic to Blue VM and halting Green VM..."
oc patch application.argoproj.io trident-dr-prod -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"helm":{"parameters":[
    {"name":"blue.runStrategy","value":"Always"},
    {"name":"green.runStrategy","value":"Halted"},
    {"name":"traffic.activeSlot","value":"blue"}
  ]}}}}'
oc patch service centos-vm-lb -n vm-prod --type=merge -p '{"spec":{"selector":{"kubevirt.io/domain":"centos-vm-blue"}}}'
oc patch vm centos-vm-green -n vm-prod --type=merge -p '{"spec":{"runStrategy":"Halted"}}'

echo "⏳ Waiting for Green VM to be Halted..."
for i in {1..40}; do
  STATUS=$(oc get vm centos-vm-green -n vm-prod -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   VM Green Status: ${STATUS}"
  if [[ "${STATUS}" == "Stopped" ]]; then
    break
  fi
  sleep 5
done

echo "   Step 6.3: Clearing ArgoCD parameter overrides to restore Git baseline..."
oc patch application.argoproj.io trident-dr-prod -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"helm":{"parameters":null}}}}'
echo "✅ Manual rollback to Blue VM completed successfully!"

# Step 7: S3 Cloud Backup & Restore DR (Pattern B)
echo "☁️ Step 7: Testing Pattern B (S3 Backup & Restore) via Tekton..."
oc apply -f "${DEMO_ROOT}/pipelines/tasks/trident-protect-backup.yaml" -n vm-prod
oc apply -f "${DEMO_ROOT}/pipelines/tasks/trident-protect-restore.yaml" -n vm-prod
oc apply -f "${DEMO_ROOT}/pipelines/dr-pipeline.yaml" -n vm-prod
oc create clusterrolebinding pipeline-admin-vm-dr-backup --clusterrole=cluster-admin --serviceaccount=vm-dr-backup:pipeline --dry-run=client -o yaml | oc apply -f - || true

DR_PR=$(oc create -f "${DEMO_ROOT}/pipelines/dr-pipelinerun.yaml" 2>/dev/null || cat <<EOF | oc create -f - -o name
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

echo "⏳ Waiting for DR PipelineRun to complete..."
for i in {1..60}; do
  COND=$(oc get "${DR_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  REASON=$(oc get "${DR_PR}" -n vm-prod -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  echo "   DR Pipeline status: ${COND} (Reason: ${REASON})"
  if [[ "${COND}" == "True" ]]; then
    break
  fi
  if [[ "${COND}" == "False" ]]; then
    echo "❌ Error: DR PipelineRun failed!" >&2
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
  STATUS=$(oc get vm centos-vm-blue -n vm-dr-backup -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   Restored VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: Restored VM did not reach Running state in vm-dr-backup." >&2
  exit 1
fi
echo "✅ Pattern B E2E Backup & Restore Successful!"

# Step 8: SnapMirror Replication DR (Pattern A)
echo "🔗 Step 8: Testing Pattern A (SnapMirror AMR) via ArgoCD..."
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
  if [[ "${STATE}" == "Completed" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATE}" != "Completed" ]]; then
  echo "❌ Error: Source snapshot did not complete." >&2
  exit 1
fi

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
  STATUS=$(oc get vm centos-vm-blue -n vm-dr-mirror -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
  echo "   Mirrored VM status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    break
  fi
  sleep 5
done
if [[ "${STATUS}" != "Running" ]]; then
  echo "❌ Error: Mirrored VM did not reach Running state in vm-dr-mirror." >&2
  exit 1
fi

echo "✅ Pattern A E2E Mirror DR Promotion Successful!"
echo "🎉 All E2E Flows passed successfully!"
