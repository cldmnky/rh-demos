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
      echo "=== $@ ==="
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

# helm_param: set ArgoCD Application Helm parameters via argocd CLI or oc patch fallback
function helm_param() {
  local app="$1"; shift
  local params=""
  for p in "$@"; do
    params="${params} --parameter ${p}"
  done
  if command -v argocd &>/dev/null; then
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
  argocd login --core 2>/dev/null || true
fi

########################
# DEMO START
########################
clear
redhatsay "Modern Virtualization: GitOps, Tekton, & NetApp Trident Protect
Disaster Recovery, App Mobility, and Blue/Green Upgrades"
wait

# ==========================================
# ACT 1: Kick off S3 Backup & Restore DR (Pattern B)
# ==========================================
act "1" "Kick off S3 Cloud Backup & Restore"

comment "First, let's create all our namespaces and deploy the production environment."
comment "We'll fire off an offsite S3 backup pipeline right away — it will run in the background."
pei "oc create clusterrolebinding openshift-gitops-controller-admin-global --clusterrole=cluster-admin --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller --dry-run=client -o yaml | oc apply -f -"
wait

comment "Let's inspect our production ArgoCD Application."
pe "show_yaml ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
wait

comment "Deploy the production environment (Blue VM active, Green halted) via ArgoCD."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
wait

comment "While the VM boots, let's get our DR backup pipeline plumbing in place."
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-backup.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-restore.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/dr-pipeline.yaml -n vm-prod"
pei "oc create clusterrolebinding pipeline-admin-vm-dr-backup --clusterrole=cluster-admin --serviceaccount=vm-dr-backup:pipeline --dry-run=client -o yaml | oc apply -f -"
wait

comment "Now let's kick off the DR pipeline. It will backup our VM to AWS S3 and restore it to vm-dr-backup."
comment "This is a 30GB volume copy — it will take several minutes and run entirely in the background."
comment "Once the Tekton backup task completes, the Kopia data mover will start restoring blocks from S3."
pe "tkn pipeline start trident-dr-pipeline -n vm-prod -p application-name=centos-vm-app -p destination-namespace=vm-dr-backup --showlog"
wait
clear

# ==========================================
# ACT 2: Deploy App v1.0
# ==========================================
act "2" "Tekton + Ansible — App v1.0 Deployment"

comment "Let's check on our VMs. Blue should be Running, Green is Stopped (zero compute)."
pe "oc get vm -n vm-prod"
wait

comment "Trident Protect is declarative. We defined an 'Application' tracking vm-prod as a single unit."
pe "oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o yaml"
wait

comment "Now let's configure our guest VM. Instead of a manual SSH session, we run a Tekton pipeline."
comment "It will wait for the VM, then run an Ansible playbook to install httpd and deploy v1.0."
pe "show_yaml ${DEMO_DIR}/pipelines/install-pipeline.yaml"
wait

comment "Applying the pipeline plumbing and granting RBAC."
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/ansible-run-playbook.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/smoke-test.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/install-pipeline.yaml -n vm-prod"
pei "oc create clusterrolebinding pipeline-admin-vm-prod --clusterrole=cluster-admin --serviceaccount=vm-prod:pipeline --dry-run=client -o yaml | oc apply -f -"
wait

comment "Trigger the install pipeline. Ansible will install httpd and serve v1.0 on the Blue VM."
pe "tkn pipeline start install-app -n vm-prod --showlog"
wait
clear

# ==========================================
# ACT 3: Blue/Green Upgrade using Trident Snapshots
# ==========================================
act "3" "Blue/Green Application Upgrade"

comment "Time to deploy v2.0. We push one Git commit, and Tekton orchestrates a zero-downtime upgrade."
comment "The pipeline will: Trident Snapshot Blue -> start Green from that snapshot -> upgrade Green to v2.0 -> smoke test -> cut traffic."
comment "First, we bump the app version in Git."
pe "ruby -0pi -e 'gsub(/version: \"v[0-9.]+\"/, \"version: \\\"v2.0\\\"\")' ${DEMO_DIR}/pipelines/app-version.yaml"
pe "show_yaml ${DEMO_DIR}/pipelines/app-version.yaml"
wait

comment "Commit and push the version bump."
pe "git add ${DEMO_DIR}/pipelines/app-version.yaml"
pe "git commit --no-gpg-sign -m 'bump app version to v2.0'"
pe "git push origin main"
wait

comment "Let's inspect the Trident-powered upgrade pipeline."
pe "show_yaml ${DEMO_DIR}/pipelines/upgrade-pipeline.yaml"
wait

comment "Applying and running the upgrade pipeline."
pei "oc apply -f ${DEMO_DIR}/pipelines/upgrade-pipeline.yaml -n vm-prod"
wait

comment "Running the upgrade. Green is cloned from the live Blue storage snapshot — instant clone via ONTAP!"
pe "tkn pipeline start upgrade-app -n vm-prod --showlog"
wait

comment "Let's check our VMs. Green is Running (v2.0), Blue is Stopped. Traffic has cut over."
pe "oc get vm -n vm-prod"
wait
clear

# ==========================================
# ACT 4: Presenter-Driven Rollback
# ==========================================
act "4" "GitOps Declarative Rollback"

comment "If anything goes wrong, rolling back is declarative. No Git commits needed."
comment "We use argocd app set to change Helm parameters — ArgoCD reconciles the state."
comment "Step 1: Restart Blue while traffic still flows to Green."
helm_param trident-dr-prod \
  "blue.runStrategy=Always" \
  "green.runStrategy=Always" \
  "traffic.activeSlot=green"
wait

comment "Step 2: Shifting traffic back to Blue, and halting Green."
helm_param trident-dr-prod \
  "blue.runStrategy=Always" \
  "green.runStrategy=Halted" \
  "traffic.activeSlot=blue"
wait

comment "Step 3: Clear all parameter overrides. ArgoCD restores the Git baseline."
helm_param trident-dr-prod
wait

comment "Our VMs are back to the Git baseline: Blue Running (v1.0), Green Stopped."
pe "oc get vm -n vm-prod"
wait
clear

# ==========================================
# ACT 5: SnapMirror Replication DR (Pattern A)
# ==========================================
act "5" "GitOps-Driven SnapMirror DR Failover"

comment "Now let's explore Pattern A: high-performance block replication via NetApp SnapMirror."
comment "First, we take a source Snapshot to seed the mirror relationship."
pe "cat <<EOF | oc apply -f -
apiVersion: protect.trident.netapp.io/v1
kind: Snapshot
metadata:
  name: source-vm-snap
  namespace: vm-prod
spec:
  applicationRef: centos-vm-app
  appVaultRef: lab-vault
EOF"
wait

comment "Let's watch our source snapshot reach Completed state."
pe "oc get snapshot source-vm-snap -n vm-prod"
wait

comment "Now let's establish a high-performance block-level active-passive mirror using NetApp SnapMirror."
comment "An AppMirrorRelationship performs asynchronous block replication at the ONTAP storage layer,"
comment "while staging the Kubernetes metadata in our S3 AppVault."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-dr-mirror-app.yaml"
wait

SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "STALE-UID")
comment "Link the mirror relationship to the source Application's UID."
if command -v argocd &>/dev/null; then
  argocd app set trident-dr-mirror -N "${ARGOCD_NS}" -p "trident.amr.sourceAppUID=${SOURCE_UID}" >/dev/null 2>&1 || true
else
  oc patch application.argoproj.io trident-dr-mirror -n "${ARGOCD_NS}" --type=merge \
    -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"trident.amr.sourceAppUID\",\"value\":\"${SOURCE_UID}\"}]}}}}"
fi
wait

comment "Let's observe the standby mirror relationship state."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "In standby state, the target VM is powered down and the PVC is Read-Only."
comment "Let's simulate a DR Failover entirely via GitOps! We promote the relationship to 'Promoted'."
if command -v argocd &>/dev/null; then
  argocd app set trident-dr-mirror -N "${ARGOCD_NS}" -p "trident.amr.sourceAppUID=${SOURCE_UID}" -p "trident.amr.desiredState=Promoted" >/dev/null 2>&1 || true
else
  oc patch application.argoproj.io trident-dr-mirror -n "${ARGOCD_NS}" --type=merge \
    -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"trident.amr.sourceAppUID\",\"value\":\"${SOURCE_UID}\"},{\"name\":\"trident.amr.desiredState\",\"value\":\"Promoted\"}]}}}}"
fi
wait

comment "ArgoCD syncs the Promotion state. Let's watch the AMR state transition to Promoted..."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "Once promoted, the volume becomes Read-Write and Trident Protect boots up the CentOS VM!"
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
