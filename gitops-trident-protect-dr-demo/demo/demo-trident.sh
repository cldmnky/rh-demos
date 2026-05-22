#!/usr/bin/env bash
# GitOps & Pipeline-Driven Disaster Recovery with NetApp Trident Protect
#
# Walks through: 
#   Act 1: Active Production VM & Application definitions (vm-prod)
#   Act 2: S3 Cloud Backup & Restore-Based DR via Tekton Pipelines (vm-dr-backup)
#   Act 3: SnapMirror AppMirrorRelationship (AMR) via ArgoCD GitOps (vm-dr-mirror)
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

function prompt_done() {
  echo ""
  if [ "$HAS_GUM" = true ]; then
    gum style --bold --foreground=82 "✔ Done. Press any key to continue..."
  else
    echo -e "\033[1;32m✔ Done. Press any key to continue...\033[0m"
  fi
  wait
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
redhatsay "Disaster Recovery and Application Mobility
with OpenShift Virtualization & NetApp Trident Protect"
wait

# ==========================================
# ACT 1: Active Production VM
# ==========================================
act "1" "Deploying Active Production VM"

comment "First we grant ArgoCD controller the permissions it needs — this is plumbing, so we auto-execute."
pei "oc create clusterrolebinding openshift-gitops-controller-admin-global --clusterrole=cluster-admin --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller --dry-run=client -o yaml | oc apply -f -"
prompt_done

comment "We deploy our production CentOS VM environment declaratively via ArgoCD."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-prod-app.yaml"
prompt_done

comment "Let's watch the production VM boot up inside the vm-prod namespace..."
pe "oc get vm -n vm-prod"
prompt_done

comment "Trident Protect is declarative. We define a protect 'Application' that tracks all namespace resources."
pe "oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o yaml"
prompt_done
clear

# ==========================================
# ACT 2: S3 Cloud Backup & Restore DR (Pattern B)
# ==========================================
act "2" "Pipeline-Driven S3 Backup & Restore"

comment "We have a critical CentOS VirtualMachine running. Let's create an on-demand offsite S3-backed backup."
comment "To do this safely and application-consistently, we run an OpenShift Pipeline (Tekton)."
comment "Applying pipeline tasks and definitions — plumbing, auto-executed."
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-backup.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-restore.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/dr-pipeline.yaml -n vm-prod"
prompt_done

comment "Granting pipeline service accounts the RBAC they need — also plumbing, auto-executed."
pei "oc create clusterrolebinding pipeline-admin-vm-prod --clusterrole=cluster-admin --serviceaccount=vm-prod:pipeline --dry-run=client -o yaml | oc apply -f -"
pei "oc create clusterrolebinding pipeline-admin-vm-dr-backup --clusterrole=cluster-admin --serviceaccount=vm-dr-backup:pipeline --dry-run=client -o yaml | oc apply -f -"
prompt_done

comment "Now we trigger the DR pipeline. This will freeze guest FS, back up to S3, thaw, and restore to vm-dr-backup."
pe "tkn pipeline start trident-dr-pipeline -n vm-prod -p application-name=centos-vm-app -p destination-namespace=vm-dr-backup --showlog"
prompt_done

comment "Let's verify that the restored application and VirtualMachine are running in vm-dr-backup namespace!"
pe "oc get vm -n vm-dr-backup"
prompt_done
clear

# ==========================================
# ACT 3: SnapMirror Replication DR (Pattern A)
# ==========================================
act "3" "GitOps-Driven SnapMirror DR Failover"

comment "Now let's establish a high-performance block-level active-passive mirror using NetApp SnapMirror."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-dr-mirror-app.yaml"
prompt_done

SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "STALE-UID")
comment "Link the mirror relationship to the source Application's UID — auto-executed."
pei "oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"trident.amr.sourceAppUID\",\"value\":\"${SOURCE_UID}\"}]}}}}'"
prompt_done

comment "Let's observe the standby mirror relationship state."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
prompt_done

comment "In standby state, the target VM is powered down and the underlying PVC is completely Read-Only."
comment "Let's simulate a DR Failover entirely via GitOps! We promote the AppMirrorRelationship to 'Promoted'."
pe "oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/source/helm/parameters/1\",\"value\":{\"name\":\"trident.amr.desiredState\",\"value\":\"Promoted\"}}]'"
prompt_done

comment "ArgoCD will sync the Promotion state. Let's watch the AMR state transition to Promoted..."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
prompt_done

comment "Once promoted, the volume becomes Read-Write and Trident Protect automatically boots up the CentOS VM!"
pe "oc get vm -n vm-dr-mirror"
prompt_done

clear
redhatsay "Demo Complete!
Both S3 Backup/Restore & SnapMirror DR patterns demonstrated successfully!"
wait
