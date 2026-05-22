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
redhatsay "Disaster Recovery and Application Mobility
with OpenShift Virtualization & NetApp Trident Protect"
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

comment "Let's watch the production VM boot up inside the vm-prod namespace..."
pe "oc get vm -n vm-prod"
wait

comment "Trident Protect is declarative. We define an 'Application' resource (centos-vm-app)."
comment "This defines the logical boundary of our app, letting Trident Protect manage all resources"
comment "in the namespace (VM definitions, Secrets, Services, and PVCs) as a single, consistent unit."
pe "oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o yaml"
wait
clear

# ==========================================
# ACT 2: S3 Cloud Backup & Restore DR (Pattern B)
# ==========================================
act "2" "Pipeline-Driven S3 Backup & Restore"

comment "Let's view our Tekton DR pipeline definition."
pe "show_yaml ${DEMO_DIR}/pipelines/dr-pipeline.yaml"
wait

comment "Applying the pipeline tasks and definitions to the cluster."
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-backup.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/tasks/trident-protect-restore.yaml -n vm-prod"
pei "oc apply -f ${DEMO_DIR}/pipelines/dr-pipeline.yaml -n vm-prod"
wait

comment "Granting the pipeline service accounts the RBAC they need."
pei "oc create clusterrolebinding pipeline-admin-vm-prod --clusterrole=cluster-admin --serviceaccount=vm-prod:pipeline --dry-run=client -o yaml | oc apply -f -"
pei "oc create clusterrolebinding pipeline-admin-vm-dr-backup --clusterrole=cluster-admin --serviceaccount=vm-dr-backup:pipeline --dry-run=client -o yaml | oc apply -f -"
wait

comment "Now we trigger the DR pipeline. It uses an offsite S3-compatible target represented by an 'AppVault' CR."
comment "Trident Protect uses ExecHooks to freeze the guest filesystems for application-consistency,"
comment "takes a snapshot, and copies both volume blocks and Kubernetes metadata to the AWS S3 vault via Kopia."
pe "tkn pipeline start trident-dr-pipeline -n vm-prod -p application-name=centos-vm-app -p destination-namespace=vm-dr-backup --showlog"
wait

comment "Let's verify that the restored application and VirtualMachine are running in vm-dr-backup namespace!"
comment "Trident Protect automatically recreated the PVCs, recovered data from S3, and redeployed the KubeVirt resources."
pe "oc get vm -n vm-dr-backup"
wait
clear

# ==========================================
# ACT 3: SnapMirror Replication DR (Pattern A)
# ==========================================
act "3" "GitOps-Driven SnapMirror DR Failover"

comment "Let's inspect the target SnapMirror ArgoCD Application definition."
pe "show_yaml ${DEMO_DIR}/argocd/argocd-dr-mirror-app.yaml"
wait

comment "Before we establish SnapMirror replication, the source application must have at least one Completed Snapshot."
comment "This provides a valid source recovery point for the mirror relationship to synchronize from."
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
comment "An AppMirrorRelationship (AMR) performs asynchronous block replication directly at the ONTAP storage layer"
comment "for maximum speed, while staging the application YAML manifests and metadata in our S3 AppVault."
pe "oc apply -f ${DEMO_DIR}/argocd/argocd-dr-mirror-app.yaml"
wait

SOURCE_UID=$(oc get application.protect.trident.netapp.io centos-vm-app -n vm-prod -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "STALE-UID")
comment "Link the mirror relationship to the source Application's UID."
pei "oc patch application.argoproj.io trident-dr-mirror -n openshift-gitops --type=merge -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"trident.amr.sourceAppUID\",\"value\":\"${SOURCE_UID}\"}]}}}}'"
wait

comment "Let's observe the standby mirror relationship state."
pe "oc get amr vm-mirror-relationship -n vm-dr-mirror"
wait

comment "In standby state, the target VM is powered down and the underlying PVC is completely Read-Only."
comment "Let's simulate a DR Failover entirely via GitOps! We promote the AppMirrorRelationship to 'Promoted'."
comment "ArgoCD will sync the Promotion state, prompting Trident Protect to shift the target volume to Read-Write"
comment "and instantly redeploy the CentOS VM definition."
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
Both S3 Backup/Restore & SnapMirror DR patterns demonstrated successfully!"
wait
