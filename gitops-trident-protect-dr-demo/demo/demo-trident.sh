#!/usr/bin/env bash
# GitOps & Pipeline-Driven Disaster Recovery with NetApp Trident Protect
#
# Walks through: 
#   Act 1: Kick off S3 Cloud Backup & Restore DR (runs in background ~14 min)
#   Act 2: Deploy Production VM & App v1.0 via Tekton + Ansible
#   Act 3: Blue/Green App Upgrade to v2.0 using Trident Snapshots
#   Act 4: Presenter-Driven GitOps Rollback (ArgoCD parameters)
#   Act 5: SnapMirror AppMirrorRelationship (AMR) via ArgoCD GitOps
#   Act 6: Verify S3 Backup/Restore results in vm-dr-backup
#
# Run from repo root:
#   ./gitops-trident-protect-dr-demo/demo/demo-trident.sh
#
# Flags:
#   -n         No wait (auto-advance)
#   -d         Disable simulated typing
#   -w <secs>  Auto-advance after N seconds

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
DEMO_DIR="gitops-trident-protect-dr-demo"
DEMO_ROOT="${REPO_ROOT}/${DEMO_DIR}"

SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"

########################
# include the magic
########################
. "${REPO_ROOT}/scripts/demo-magic.sh"
cd "${REPO_ROOT}"

########################
# config
########################
NAMESPACE_PROD="vm-prod"
NAMESPACE_MIRROR="vm-dr-mirror"
NAMESPACE_BACKUP="vm-dr-backup"
ARGOCD_NS="openshift-gitops"
[[ ! -v TYPE_SPEED ]] && TYPE_SPEED=40
DEMO_PROMPT="${GREEN}❯ ${COLOR_RESET}"

HAS_GUM=false && command -v gum &>/dev/null && HAS_GUM=true
HAS_BAT=false && command -v bat &>/dev/null && HAS_BAT=true

if ! command -v redhatsay &>/dev/null; then
  redhatsay() {
    if [ "$HAS_GUM" = true ]; then
      gum style --border="double" --border-foreground="196" --padding="1 2" --margin="1 1" --align="center" "$@"
    else
      echo "=== $* ==="
    fi
  }
fi

########################
# helpers
########################
function act() {
  clear
  redhatsay "Act $1 — $2"
  wait
  clear
}

function comment() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --italic --foreground=245 --padding="0 2"
  else
    echo "# $1"
  fi
}

function show_yaml() {
  local file="$1"
  if [ "$HAS_BAT" = true ]; then
    bat --style=plain --color=always --language=yaml "$file"
  else
    cat "$file"
  fi
}

function show_image() {
  local file="$1"
  if command -v viu &>/dev/null; then
    viu "$file"
  else
    echo "Missing viu. Install with: brew install viu" >&2
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

  echo "Waiting for ArgoCD-managed pipeline infrastructure in ${NAMESPACE_PROD}..."
  for resource in "${resources[@]}"; do
    local deadline=$(( $(date +%s) + 120 ))
    until oc get "${resource}" -n "${NAMESPACE_PROD}" >/dev/null 2>&1; do
      if [ "$(date +%s)" -gt "${deadline}" ]; then
        echo "Timed out waiting for ${resource} in ${NAMESPACE_PROD}" >&2
        return 1
      fi
      sleep 2
    done
    echo "  ${resource} is ready"
  done
}

# helm_param: set ArgoCD Application Helm parameters via argocd CLI or oc patch fallback
function helm_param() {
  local app="$1"; shift
  local params=""
  for p in "$@"; do
    params="${params} --parameter ${p}"
  done
  if command -v argocd &>/dev/null && argocd app get "${app}" -N "${ARGOCD_NS}" &>/dev/null; then
    argocd app set "${app}" ${params} -N "${ARGOCD_NS}" >/dev/null 2>&1
  else
    local json="["; local first=true
    for p in "$@"; do
      local name="${p%%=*}"
      local value="${p#*=}"
      if [ "$first" = true ]; then first=false; else json="${json},"; fi
      json="${json}{\"name\":\"${name}\",\"value\":\"${value}\"}"
    done
    json="${json}]"
    oc patch application.argoproj.io "${app}" -n "${ARGOCD_NS}" --type=merge \
      -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":${json}}}}}" >/dev/null 2>&1
  fi
}

########################
# Pre-flight
########################
clear
comment "Checking environment readiness..."
if ! oc get ns "${ARGOCD_NS}" &>/dev/null; then
  echo "Error: openshift-gitops namespace not found." >&2
  exit 1
fi

# Authenticate argocd CLI
if command -v argocd &>/dev/null; then
  oc config set-context --current --namespace="${ARGOCD_NS}" 2>/dev/null || true
  argocd login --core 2>/dev/null || true
fi

# Pre-create vm-ssh-key secret with the presenter's SSH private key.
# vm-cloud-init is created by the Helm chart from values.
for ns in "vm-prod" "vm-dr-backup" "vm-dr-mirror"; do
  oc create namespace "${ns}" --dry-run=client -o yaml | oc apply -f - 2>/dev/null || true
  oc create secret generic vm-ssh-key \
    --namespace="${ns}" \
    --from-file=id_rsa="${SSH_PRIVATE_KEY}" \
    --dry-run=client -o yaml | oc apply -f - 2>/dev/null || true
done

# Reset app-version.yaml to a known baseline so the bump in Act 3 produces a real change
sed -i '' 's/v[0-9][0-9.]*/v1.0/' "${DEMO_DIR}/pipelines/app-version.yaml" 2>/dev/null || true

########################
# DEMO START
########################
clear
redhatsay "Modern Virtualization: GitOps, Tekton, & NetApp Trident Protect
Disaster Recovery, App Mobility, and Blue/Green Upgrades"
wait

comment "Here is the high-level architecture overview."
pe "show_image ${DEMO_ROOT}/assets/architecture-overview.png"
wait

# ==========================================
# ACT 1: Kick off S3 Backup & Restore DR (Pattern B)
# ==========================================
act "1" "S3 Cloud Backup & Restore (Pattern B)"

comment "Here is the S3 Backup and Restore DR flow."
pe "show_image ${DEMO_ROOT}/assets/backup-restore.png"
wait

comment "We are going to deploy our production CentOS VM environment and fire off an"
comment "on-demand offsite S3 backup and restore pipeline. Since Kopia block transfers"
comment "take time, this will run in the background while we explore application lifecycles."
wait

comment "Let's inspect our production ArgoCD Application definition."
pe "show_yaml ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
wait

comment "We deploy our production CentOS VM environment declaratively via ArgoCD."
comment "ArgoCD will ensure our namespace, VMs, services, and Trident resources conform to Git."
pe "oc create clusterrolebinding openshift-gitops-controller-admin-global --clusterrole=cluster-admin --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller --dry-run=client -o yaml | oc apply -f -"
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
wait

comment "While the VM boots, let's deploy our pipeline infrastructure via ArgoCD (RBAC included)."
pei "oc apply -f ${DEMO_DIR}/argocd/argocd-infra-app.yaml"
pei "wait_for_pipeline_infra"
wait

comment "Now we trigger the DR pipeline. Under the hood, Trident Protect will communicate with KubeVirt"
comment "and use an ExecHook to cleanly freeze the guest filesystem. Once frozen, it takes an instant"
comment "storage snapshot, thaws the VM guest, and streams both volume blocks and Kubernetes metadata"
comment "securely to our AWS S3 bucket (AppVault) using the secure Kopia deduplication data mover."
comment "Once backed up, the pipeline submits a BackupRestore in vm-dr-backup namespace."
pe "tkn pipeline start trident-dr-pipeline -n vm-prod -p application-name=centos-vm-app -p destination-namespace=vm-dr-backup -s pipeline"
wait
clear

# ==========================================
# ACT 2: Deploy App v1.0
# ==========================================
act "2" "Tekton + Ansible — App v1.0 Deployment"

comment "Here is the full VM lifecycle: deploy, install, upgrade, and rollback."
pe "show_image ${DEMO_ROOT}/assets/vm-lifecycle.png"
wait

comment "Let's check on our production VM. Blue is up and Running — the only VM deployed."
comment "The Green VM is defined in Git (green.enabled=false), ready to be activated on upgrade."
pe "oc get vm -n vm-prod"
wait

comment "Trident Protect is fully declarative. We have defined an 'Application' custom resource (centos-vm-app)."
comment "This Application CR groups all namespace resources (VMs, DataVolumes, ConfigMaps, Secrets, Services)"
comment "into a single logical application unit for unified, transactionally-safe protection."
pe "oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o yaml"
wait

comment "Instead of manually SSHing in and running ad-hoc shell commands, guest VM configuration"
comment "should be managed as code. We run an automated Tekton Pipeline which invokes an Ansible playbook."
pe "show_yaml ${DEMO_DIR}/pipelines/install-pipeline.yaml"
wait

comment "All pipeline tasks and definitions are already deployed by ArgoCD via the infra Application. RBAC was granted in Act 1."
wait

comment "Trigger the install pipeline. Ansible will install httpd and serve v1.0 on the Blue VM."
pe "oc create -f ${DEMO_DIR}/pipelines/install-pipelinerun.yaml -n vm-prod"
wait

comment "Let's wait for the install to finish before we move on to the upgrade."
pei "INSTALL_PR=\$(oc get pipelinerun -n vm-prod -l tekton.dev/pipeline=install-app --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')"
pei "tkn pipelinerun logs \${INSTALL_PR} -n vm-prod -f"
wait
clear

# ==========================================
# ACT 3: Blue/Green VM Upgrade using Trident Snapshots
# ==========================================
act "3" "Blue/Green Application Upgrade"

comment "Time to deploy v2.0. We will edit Git, and Tekton will orchestrate a zero-downtime Blue/Green upgrade."
comment "First, we bump the target app version in our Git repository."
pe "sed -i '' 's/v[0-9][0-9.]*/v2.0/' ${DEMO_DIR}/pipelines/app-version.yaml"
pe "show_yaml ${DEMO_DIR}/pipelines/app-version.yaml"
wait

comment "Let's commit and push the version bump to Git."
pe "git add ${DEMO_DIR}/pipelines/app-version.yaml"
pe "git commit --allow-empty --no-gpg-sign -m 'bump app version to v2.0'"
pe "git push origin main"
wait

comment "Let's inspect our Tekton Upgrade Pipeline."
comment "It will: take a Trident Snapshot of blue -> resolve the CSI VolumeSnapshot -> patch ArgoCD parameters"
comment "to boot green from that snapshot -> run Ansible upgrade to v2.0 on green -> smoke test green -> cut traffic."
pe "show_yaml ${DEMO_DIR}/pipelines/upgrade-pipeline.yaml"
wait

comment "Instead of manually running a PipelineRun, we simulate the GitOps webhook."
comment "When we pushed 'app-version.yaml' to Git, a real GitHub webhook would notify Tekton."
comment "Let's simulate that push notification by curling our local EventListener Route!"
wait

comment "Resolving the EventListener Route URL..."
pe "EL_ROUTE=\$(oc get route trident-upgrade-trigger -n vm-prod -o jsonpath='{.spec.host}')"
wait

comment "Simulating the GitHub push webhook payload..."
pe "curl -s -X POST \
  -H \"Content-Type: application/json\" \
  -H \"X-GitHub-Event: push\" \
  -d \"{
    \\\"ref\\\": \\\"refs/heads/main\\\",
    \\\"commits\\\": [
      {
        \\\"id\\\": \\\"\$(git rev-parse HEAD)\\\",
        \\\"message\\\": \\\"bump app version to v2.0\\\",
        \\\"modified\\\": [
          \\\"gitops-trident-protect-dr-demo/pipelines/app-version.yaml\\\"
        ],
        \\\"added\\\": [],
        \\\"removed\\\": []
      }
    ]
  }\" \
  \"http://\${EL_ROUTE}\""
wait

comment "The EventListener auto-triggered the upgrade PipelineRun!"

comment "Let's watch the upgrade pipeline as it clones the disk and deploys v2.0."
pei "UPGRADE_PR=\$(oc get pipelinerun -n vm-prod -l tekton.dev/pipeline=upgrade-app --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')"
pei "tkn pipelinerun logs \${UPGRADE_PR} -n vm-prod -f"
wait

comment "Let's check our VMs. Traffic has cut over: Green is Running (v2.0) and Blue is Stopped."
pe "oc get vm -n vm-prod"
wait
clear

# ==========================================
# ACT 4: Presenter-Driven Declarative Rollback
# ==========================================
act "4" "GitOps Declarative Rollback"

comment "If anything goes wrong, rolling back is declarative. No Git commits needed."
comment "We use the 'argocd app set' command to update Helm parameters directly, and ArgoCD reconciles."

# Resolve the active Green snapshot name from ArgoCD parameters to preserve it during rollback.
# This prevents ArgoCD from immediately deleting the Green VM when we change runStrategies.
SNAPSHOT=$(oc get application trident-dr-prod -n openshift-gitops -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.sourceSnapshot")].value}' 2>/dev/null || true)
if [[ -z "${SNAPSHOT}" ]]; then
  SNAPSHOT=$(oc get volumesnapshot -n vm-prod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

comment "Step 1: Spin up our Blue VM in the background (zero-downtime, traffic still on Green)."
pe "argocd app set trident-dr-prod -N ${ARGOCD_NS} \
  -p blue.runStrategy=Always \
  -p green.runStrategy=Always \
  -p green.enabled=true \
  -p green.sourceSnapshot=\${SNAPSHOT} \
  -p green.sourceSnapshotNamespace=vm-prod \
  -p traffic.activeSlot=green"
wait

comment "Step 2: Shifting traffic back to Blue, and halting Green."
pe "argocd app set trident-dr-prod -N ${ARGOCD_NS} \
  -p blue.runStrategy=Always \
  -p green.runStrategy=Halted \
  -p green.enabled=true \
  -p green.sourceSnapshot=\${SNAPSHOT} \
  -p green.sourceSnapshotNamespace=vm-prod \
  -p traffic.activeSlot=blue"
wait

comment "Step 3: Clear all parameter overrides and let our authoritative Git baseline take back over."
pe "argocd app set trident-dr-prod -N ${ARGOCD_NS}"
wait

comment "Our VMs are returned perfectly to our Git baseline: Blue Running, Green deleted (was never in the baseline)."
pe "oc get vm -n vm-prod"
wait
clear

# ==========================================
# ACT 5: SnapMirror Replication DR (Pattern A)
# ==========================================
act "5" "SnapMirror Replication DR (Pattern A)"

comment "Here is the SnapMirror replication DR flow."
pe "show_image ${DEMO_ROOT}/assets/snapmirror.png"
wait

comment "Now let's explore Pattern A: high-performance asynchronous replication via NetApp SnapMirror."
comment "First, we create a Snapshot on the production side to seed the mirror relationship."
pei "cat > /tmp/source-vm-snap.yaml <<'EOF'
apiVersion: protect.trident.netapp.io/v1
kind: Snapshot
metadata:
  name: source-vm-snap
  namespace: vm-prod
spec:
  applicationRef: centos-vm-app
  appVaultRef: lab-vault
EOF"
pe "oc apply -f /tmp/source-vm-snap.yaml"
wait

comment "Let's watch our source snapshot reach Completed state."
pe "oc get snapshot source-vm-snap -n vm-prod"
wait

comment "Now let's establish a high-performance block-level active-passive mirror using NetApp SnapMirror."
comment "An AppMirrorRelationship (AMR) orchestrates block-level volume replication directly on the ONTAP layer,"
comment "while copying the Kubernetes resources (VM definitions, Services) out of band to S3."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-dr-mirror-app.yaml"
wait

SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "STALE-UID")
comment "Link the mirror relationship to the source Application's UID."
pe "argocd app set trident-dr-mirror -N ${ARGOCD_NS} -p trident.amr.sourceAppUID=\${SOURCE_UID}"
wait

comment "Let's observe the standby mirror relationship state."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "In standby state, the target VM is powered down and the PVC is Read-Only."
comment "Let's simulate a DR Failover entirely via GitOps! We promote the relationship to 'Promoted'."
comment "ArgoCD syncs the Promotion. Trident Protect instantly promotes the storage to Read-Write,"
comment "reconstructs the KubeVirt virtual machine manifests, and boots the VM."
pe "argocd app set trident-dr-mirror -N ${ARGOCD_NS} -p trident.amr.sourceAppUID=\${SOURCE_UID} -p trident.amr.desiredState=Promoted"
wait

comment "ArgoCD syncs the Promotion state. Let's watch the AMR state transition to Promoted..."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "Once promoted, the volume becomes Read-Write and Trident Protect automatically boots up the CentOS VM!"
pe "oc get vm -n vm-dr-mirror"
wait
clear

# ==========================================
# ACT 6: Verify S3 Backup/Restore Results
# ==========================================
act "6" "Verify S3 Backup/Restore Results"

comment "Now let's go back and check on our S3 backup pipeline."
comment "The Kopia data mover has been restoring the 30GB volume from our AWS S3 AppVault in the background."
comment "Let's see if the restored application and VM are ready in vm-dr-backup."
pe "oc get vm -n vm-dr-backup"
wait

comment "Trident Protect has recreated the PVCs, recovered blocks from S3, and redeployed the VM definition."
pe "oc get application.protect.trident.netapp.io -n vm-dr-backup"
wait

comment "If the VM is already running, congratulations! Your offsite cloud-based DR is complete."
comment "This is portable DR: works with any object storage, any namespace, any cluster."
wait

clear
redhatsay "Demo Complete!
App lifecycle, blue/green upgrade, rollback, SnapMirror DR, and S3 backup/restore — all driven by GitOps! 🎩"
wait
