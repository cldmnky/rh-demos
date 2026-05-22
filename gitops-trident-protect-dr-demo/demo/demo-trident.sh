#!/usr/bin/env bash
# GitOps & Pipeline-Driven Disaster Recovery with NetApp Trident Protect
#
# Walks through: 
#   Act 1: Active Production VM & Application definitions (vm-prod)
#   Act 2: Tekton + Ansible deploys App v1.0
#   Act 3: Blue/Green App Upgrade to v2.0 using Trident Snapshots
#   Act 4: Presenter-Driven GitOps Rollback (ArgoCD parameters)
#   Act 5: S3 Cloud Backup & Restore-Based DR via Tekton Pipelines (vm-dr-backup)
#   Act 6: SnapMirror AppMirrorRelationship (AMR) via ArgoCD GitOps (vm-dr-mirror)
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

########################
# Pre-flight
########################
clear
comment "Checking environment readiness..."
if ! oc get ns "${ARGOCD_NS}" &>/dev/null; then
  echo "Error: openshift-gitops namespace not found." >&2
  exit 1
fi

########################
# DEMO START
########################
clear
redhatsay "Modern Virtualization: GitOps, Tekton, & NetApp Trident Protect
Disaster Recovery, App Mobility, and Blue/Green Upgrades"
wait

# ==========================================
# ACT 1: Active Production VM
# ==========================================
act "1" "Deploying Active Production VM"

comment "First we grant ArgoCD controller the necessary cluster-level permissions."
pei "oc create clusterrolebinding openshift-gitops-controller-admin-global --clusterrole=cluster-admin --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller --dry-run=client -o yaml | oc apply -f -"
wait

comment "Let's inspect our production ArgoCD Application definition."
pe "show_yaml ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
wait

comment "We deploy our production CentOS VM environment declaratively via ArgoCD."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
wait

comment "Let's watch the production Blue VM boot up inside the vm-prod namespace (Green is halted/stopped)."
pe "oc get vm -n vm-prod"
wait

comment "Trident Protect is declarative. We define an 'Application' resource (centos-vm-app) tracking vm-prod."
pe "oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o yaml"
wait
clear

# ==========================================
# ACT 2: Tekton + Ansible App Installation
# ==========================================
act "2" "Tekton + Ansible — App Deployment"

comment "To configure our guest VM, we run an automated Tekton Pipeline which invokes an Ansible playbook."
comment "Let's view the Ansible install pipeline definition."
pe "show_yaml ${DEMO_DIR}/pipelines/install-pipeline.yaml"
wait

comment "Applying the pipeline tasks, definitions, and RBAC to the cluster."
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/ansible-run-playbook.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/smoke-test.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/install-pipeline.yaml -n vm-prod"
pei "oc create clusterrolebinding pipeline-admin-vm-prod --clusterrole=cluster-admin --serviceaccount=vm-prod:pipeline --dry-run=client -o yaml | oc apply -f -"
wait

comment "Now we trigger the installation pipeline to deploy App v1.0 on the Blue VM."
pe "tkn pipeline start install-app -n vm-prod --showlog"
wait
clear

# ==========================================
# ACT 3: Blue/Green VM Upgrade using Trident Snapshots
# ==========================================
act "3" "Blue/Green Application Upgrade"

comment "Time to deploy v2.0. We will edit Git, and Tekton will orchestrate a zero-downtime Blue/Green upgrade."
comment "First, we bump the target app version in our Git repository."
pe "ruby -0pi -e 'gsub(/version: \"v[0-9.]+\"/, \"version: \\\"v2.0\\\"\")' ${DEMO_DIR}/pipelines/app-version.yaml"
pe "show_yaml ${DEMO_DIR}/pipelines/app-version.yaml"
wait

comment "Let's commit and push the version bump to Git."
pe "git add ${DEMO_DIR}/pipelines/app-version.yaml"
pe "git commit --no-gpg-sign -m 'bump app version to v2.0'"
pe "git push origin main"
wait

comment "Let's inspect our Tekton Upgrade Pipeline."
comment "It will: snapshot blue -> start green from snapshot -> upgrade green to v2.0 -> smoke test green -> cut traffic."
pe "show_yaml ${DEMO_DIR}/pipelines/upgrade-pipeline.yaml"
wait

comment "Applying the upgrade pipeline to the cluster."
pei "oc apply -f ${DEMO_DIR}/pipelines/upgrade-pipeline.yaml -n vm-prod"
wait

comment "Let's run the upgrade pipeline. It clones our live production storage instantly and upgrades the Green VM!"
pe "tkn pipeline start upgrade-app -n vm-prod --showlog"
wait

comment "Let's check our VMs. Traffic has cut over: Green is Running (v2.0) and Blue is Stopped."
pe "oc get vm -n vm-prod"
wait
clear

# ==========================================
# ACT 4: Presenter-Driven Declarative Rollback
# ==========================================
act "4" "Presenter-Driven Declarative Rollback"

comment "If anything goes wrong, rolling back to Blue is extremely simple, declarative, and done without any Git commits."
comment "Step 1: Spin up our Blue VM in the background (zero-downtime, traffic still on Green)."
pe "oc patch application.argoproj.io trident-dr-prod -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"blue.runStrategy\",\"value\":\"Always\"},{\"name\":\"green.runStrategy\",\"value\":\"Always\"},{\"name\":\"traffic.activeSlot\",\"value\":\"green\"}]}}}}'"
pe "oc patch vm centos-vm-blue -n vm-prod --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'"
wait

comment "Step 2: Shifting traffic back to Blue, and halting Green."
pe "oc patch application.argoproj.io trident-dr-prod -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"blue.runStrategy\",\"value\":\"Always\"},{\"name\":\"green.runStrategy\",\"value\":\"Halted\"},{\"name\":\"traffic.activeSlot\",\"value\":\"blue\"}]}}}}'"
pe "oc patch service centos-vm-lb -n vm-prod --type=merge -p '{\"spec\":{\"selector\":{\"kubevirt.io/domain\":\"centos-vm-blue\"}}}'"
pe "oc patch vm centos-vm-green -n vm-prod --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'"
wait

comment "Step 3: Clear all parameter overrides and let our authoritative Git baseline take back over."
pe "oc patch application.argoproj.io trident-dr-prod -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":null}}}}'"
wait

comment "Our VMs are returned perfectly to our Git baseline: Blue Running (v1.0), Green Stopped."
pe "oc get vm -n vm-prod"
wait
clear

# ==========================================
# ACT 5: S3 Cloud Backup & Restore DR (Pattern B)
# ==========================================
act "5" "Pipeline-Driven S3 Backup & Restore"

comment "Let's trigger our S3-backed backup and restore pipeline to copy the application to vm-dr-backup."
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-backup.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-restore.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/dr-pipeline.yaml -n vm-prod"
pei "oc create clusterrolebinding pipeline-admin-vm-dr-backup --clusterrole=cluster-admin --serviceaccount=vm-dr-backup:pipeline --dry-run=client -o yaml | oc apply -f -"
wait

pe "tkn pipeline start trident-dr-pipeline -n vm-prod -p application-name=centos-vm-app -p destination-namespace=vm-dr-backup --showlog"
wait

comment "Let's verify that the restored application and VirtualMachine are running in vm-dr-backup namespace!"
pe "oc get vm -n vm-dr-backup"
wait
clear

# ==========================================
# ACT 6: SnapMirror Replication DR (Pattern A)
# ==========================================
act "6" "GitOps-Driven SnapMirror DR Failover"

comment "Before we establish SnapMirror replication, we take an initial source snapshot."
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

comment "Let's watch our source snapshot reach a Completed state."
pe "oc get snapshot source-vm-snap -n vm-prod"
wait

comment "Now let's establish a high-performance block-level active-passive mirror using NetApp SnapMirror."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-dr-mirror-app.yaml"
wait

SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "STALE-UID")
comment "Link the mirror relationship to the source Application's UID."
pei "oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"trident.amr.sourceAppUID\",\"value\":\"${SOURCE_UID}\"}]}}}}'"
wait

comment "Let's observe the standby mirror relationship state."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "Let's simulate a DR Failover entirely via GitOps! We promote the AppMirrorRelationship to 'Promoted'."
pe "oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/source/helm/parameters/1\",\"value\":{\"name\":\"trident.amr.desiredState\",\"value\":\"Promoted\"}}]'"
wait

comment "ArgoCD will sync the Promotion state. Let's watch the AMR state transition to Promoted..."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "Once promoted, the volume becomes Read-Write and Trident Protect automatically boots up the CentOS VM!"
pe "oc get vm -n vm-dr-mirror"
wait

clear
redhatsay "Demo Complete!
All lifecycle, blue/green upgrade, rollback, and disaster recovery flows completed successfully! 🎩"
wait
