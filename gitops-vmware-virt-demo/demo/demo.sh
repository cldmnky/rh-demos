#!/usr/bin/env bash
# Git-Driven VM Lifecycle Demo — VMware Admin Edition
#
# Starts from a clean cluster (ArgoCD + Virtualization + Pipelines installed, nothing else).
# Walks through: secrets → MetalLB → ArgoCD setup → VM creation → app install → blue/green upgrade → rollback
#
# Run from repo root or gitops-vmware-virt-demo/:
#   ./gitops-vmware-virt-demo/demo/demo.sh
#   cd gitops-vmware-virt-demo && ./demo/demo.sh
#
# Flags:
#   -n  No wait (auto-advance)
#   -d  Debug — disable simulated typing
#   -w  Auto-advance after N seconds

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
DEMO_DIR="gitops-vmware-virt-demo"

########################
# include the magic
########################
. "${REPO_ROOT}/scripts/demo-magic.sh"
cd "${REPO_ROOT}"

########################
# config
########################
[[ -v TYPE_SPEED ]] && TYPE_SPEED=40
DEMO_PROMPT="${GREEN}❯ ${COLOR_RESET}"
NAMESPACE="vm-demo"
ARGOCD_NS="openshift-gitops"
METALLB_POOL=$(awk -F': ' '/metallb.universe.tf\/address-pool/ {print $2}' "${DEMO_DIR}/base/service-lb.yaml")
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/rh-demos.pub}"
LB_IP=""  # resolved after LB is ready

########################
# helpers
########################
function act() {
  clear
  redhatsay "Act $1 — $2"
  wait
  clear
}

function say() {
  echo "$1" | gum style --bold --padding="1 2" --margin="1 0" --foreground="${2:-117}" | redhatsay
}

function comment() {
  echo "$1" | gum style --italic --foreground=245 --padding="0 2"
}

function wait_for_argo_sync() {
  local app="$1"
  comment "Waiting for ArgoCD to sync ${app}..."
  until oc get application "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q "^Synced$"; do
    sleep 5
  done
  until oc get application "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.health.status}' 2>/dev/null | grep -q "^Healthy$"; do
    sleep 5
  done
  echo "✅ ${app}: Synced / Healthy"
}

##############################################################
# INTRO
##############################################################
clear
redhatsay "Git-Driven VM Lifecycle Demo 🎩
VMware Admin Edition"
wait
clear

say "Starting from a clean cluster.
Only ArgoCD, OpenShift Virtualization, and OpenShift Pipelines are installed.
No VMs. No pipelines. Nothing in the vm-demo namespace.

We will build everything live — from Git commits to running VMs." 196
wait
clear

##############################################################
# SETUP 1 — Namespace + Secrets
##############################################################
say "Setup 1 of 3 — Secrets

The demo uses a single SSH key pair for two purposes:
  🔑  GitHub deploy key — Tekton commits changes back to Git using SSH
  🖥️  VM SSH key        — public key is injected via cloud-init into every VM

One key pair. No passwords stored. No tokens rotated. Fully auditable." 226
wait
clear

comment "Create the vm-demo namespace where everything will live."
pe "oc create namespace ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -"
wait

comment "vm-ssh-key — private key used by Tekton tasks for git SSH push and Ansible SSH access to VMs."
pe "oc create secret generic vm-ssh-key \
  --from-file=id_rsa=${SSH_PRIVATE_KEY} \
  --namespace=${NAMESPACE} \
  --dry-run=client -o yaml | oc apply -f -"
wait

comment "vm-cloud-init — cloud-init userdata that injects the public SSH key into the VM's authorized_keys."
PUB_KEY=$(cat "${SSH_PUBLIC_KEY}")
pe "oc create secret generic vm-cloud-init \
  --from-literal=userdata='#cloud-config
user: cloud-user
password: redhat
chpasswd: { expire: False }
ssh_authorized_keys:
  - ${PUB_KEY}' \
  --namespace=${NAMESPACE} \
  --dry-run=client -o yaml | oc apply -f -"
wait

pe "oc get secret vm-ssh-key vm-cloud-init -n ${NAMESPACE}"
wait
clear

##############################################################
# SETUP 2 — MetalLB
##############################################################
say "Setup 2 of 3 — MetalLB LoadBalancer Pool

In vCenter you'd file an IPAM ticket and wait for NSX configuration.
Here we reuse the cluster's existing MetalLB pool.
The demo defaults to a pool named '${METALLB_POOL}' in metallb-system." 226
wait
clear

comment "Verify the existing MetalLB pool. The demo does not create IPAddressPools by default."
pe "oc get ipaddresspool ${METALLB_POOL} -n metallb-system"
wait
comment "The LoadBalancer service requests that existing pool via annotation."
pe "grep 'metallb.universe.tf/address-pool' ${DEMO_DIR}/base/service-lb.yaml"
wait
clear

##############################################################
# SETUP 3 — ArgoCD
##############################################################
say "Setup 3 of 3 — ArgoCD: AppProject + Applications

ArgoCD will watch this GitHub repository and reconcile the cluster
to match whatever is committed to main — continuously, automatically.

We will never kubectl apply the VMs directly.
ArgoCD does it. Forever." 226
wait
clear

comment "Patch the ArgoCD instance to allow Applications to live in the vm-demo namespace."
comment "This is the 'Apps in any namespace' feature — Applications are owned by the team, not the platform."
pe "oc patch argocd openshift-gitops -n ${ARGOCD_NS} \
  --type=merge \
  -p '{\"spec\":{\"sourceNamespaces\":[\"${NAMESPACE}\"]}}'"
wait

comment "Create the AppProject — scopes this demo to our GitHub repo and the vm-demo namespace."
pe "cat ${DEMO_DIR}/argocd/appproject.yaml"
wait
pe "oc apply -f ${DEMO_DIR}/argocd/appproject.yaml"
wait
clear

comment "Grant the ArgoCD application controller admin access in vm-demo so it can create VMs, Services, and pipelines."
pe "cat ${DEMO_DIR}/argocd/rbac.yaml"
wait
pe "oc apply -f ${DEMO_DIR}/argocd/rbac.yaml"
wait
clear

comment "Application 1: VMs and services — ArgoCD syncs gitops-vmware-virt-demo/base/ to the cluster."
comment "This Application lives in the vm-demo namespace — not in openshift-gitops."
pe "cat ${DEMO_DIR}/argocd/application.yaml"
wait
pe "oc apply -f ${DEMO_DIR}/argocd/application.yaml -n ${NAMESPACE}"
wait
clear

comment "Application 2: Pipeline infrastructure — Tekton tasks, pipelines, event-listener."
pe "cat ${DEMO_DIR}/argocd/application-infra.yaml"
wait
pe "oc apply -f ${DEMO_DIR}/argocd/application-infra.yaml -n ${NAMESPACE}"
wait
clear

say "ArgoCD is now watching GitHub.
It will reconcile the cluster to match Git — continuously.
Let's watch it work." 117
wait

pe "oc get applications -n ${NAMESPACE}"
wait_for_argo_sync "vm-demo"
wait_for_argo_sync "vm-demo-infra"
wait
clear

##############################################################
# SETUP — Wait for VMs
##############################################################
say "Waiting for VMs...

ArgoCD has applied the VirtualMachine manifests from Git.
CDI is now cloning the RHEL 9 golden image into two DataVolumes.

Blue will come up Running.
Green stays Halted — zero CPU, zero RAM consumed." 226
wait
clear

pe "oc get vm -n ${NAMESPACE} -w &"
WATCH_PID=$!
until oc get vm demo-vm-blue -n "${NAMESPACE}" \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null | grep -q "Running"; do
  sleep 5
done
kill $WATCH_PID 2>/dev/null
pei ""
pe "oc get vm -n ${NAMESPACE}"
wait

comment "MetalLB has assigned a real external IP from our address pool."
pe "oc get svc demo-app-lb -n ${NAMESPACE}"
wait
until LB_IP=$(oc get svc demo-app-lb -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) && [[ -n "${LB_IP}" ]]; do
  sleep 5
done

say "The cluster now exactly matches Git.
Blue running. Green halted at zero cost.
ArgoCD will keep it that way — any drift is auto-corrected. 🎩" 82
wait
clear

##############################################################
# ACT 1 — What's in Git drives the cluster
##############################################################
act 1 "What's in Git drives the cluster"

comment "These two files are everything ArgoCD needs to create and manage both VMs."
pe "cat ${DEMO_DIR}/base/vm-blue.yaml"
wait
clear

pe "cat ${DEMO_DIR}/base/vm-green.yaml"
wait
clear

say "vm-green has runStrategy: Halted.
In vCenter there is no concept of 'desired powered-off state' expressed as code.
Here it's one field in a YAML file — and ArgoCD enforces it continuously.
Edit that field, push to Git, ArgoCD starts the VM. That's it." 245
wait

comment "ArgoCD Application status — lives in vm-demo namespace, watched by the openshift-gitops instance."
pe "oc get application vm-demo -n ${NAMESPACE} \
  -o jsonpath='{.status.sync.status} / {.status.health.status}' && echo"
wait

comment "Tekton pipeline infrastructure — also managed by ArgoCD from Git."
pe "oc get pipeline -n ${NAMESPACE}"
wait

comment "Traffic is currently routed to blue via the MetalLB LoadBalancer."
pe "oc get svc demo-app-lb -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector}' && echo"
wait

say "Two YAML files in Git.
No vCenter wizards. No IPAM ticket. No NSX configuration.
A running VM with a real external IP — fully described in code. 🎩" 82
wait
clear

##############################################################
# ACT 2 — Tekton + Ansible Application Deploy
##############################################################
act 2 "Tekton + Ansible — Application Deploy"

say "We need to install an application on the running VM.
In VMware: SSH in manually, run your scripts, pray you documented the steps.
Here: a Tekton pipeline runs an Ansible playbook.
Repeatable. Auditable. No shell history to clean up." 226
wait
clear

comment "The install pipeline: wait for VM ready → Ansible installs nginx + v1.0 → smoke test."
pe "oc get pipeline install-app -n ${NAMESPACE} \
  -o jsonpath='{.spec.tasks[*].name}' && echo"
wait

comment "Trigger the install — Ansible will install nginx and serve v1.0 on demo-vm-blue."
pe "oc create -f ${DEMO_DIR}/pipelines/install-pipelinerun.yaml -n ${NAMESPACE}"
wait
clear

pe "tkn pipelinerun logs -f -n ${NAMESPACE} -L"
wait
clear

pe "curl -s http://${LB_IP}/"
wait

say "v1.0 is live on demo-vm-blue.
Deployed by Ansible, orchestrated by Tekton, infrastructure managed by ArgoCD.
No SSH sessions left open. Every step is in the Tekton audit log." 82
wait
clear

##############################################################
# ACT 3 — Blue/Green Upgrade
##############################################################
act 3 "Blue/Green Upgrade — Git commits drive VM power state"

say "Time to deploy v2.0.
In vCenter: provision new VM, install manually, re-point the load balancer, hope the snapshot works.
Here: push one Git commit. Tekton orchestrates the entire upgrade.
Watch what happens." 226
wait
clear

say "The upgrade pipeline — every step is a Git commit or waits on one:

  [1] snapshot-blue      VirtualMachineSnapshot — safety net before touching anything
  [2] git-start-green    Commit: vm-green runStrategy → Always  → ArgoCD starts the VM
  [3] wait-for-green     Polls VMI until Running
  [4] ansible-upgrade    Ansible deploys v2.0 onto green
  [5] smoke-test         curl /health directly on green
  [6-PASS] git-cutover   Commit: service selector → green, vm-blue → Halted
  [6-FAIL] git-stop      Commit: vm-green → Halted  (blue untouched, users unaffected)" 117
wait
clear

comment "Bump the app version and push — the GitHub webhook fires the EventListener."
pe "sed -i '' 's/version: \"v1.0\"/version: \"v2.0\"/' ${DEMO_DIR}/pipelines/app-version.yaml"
pe "cat ${DEMO_DIR}/pipelines/app-version.yaml"
wait
pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/pipelines/app-version.yaml"
pe "git -C ${REPO_ROOT} commit -m 'bump app version to v2.0'"
pe "git -C ${REPO_ROOT} push origin main"
wait
clear

comment "GitHub webhook → Tekton EventListener → upgrade-app PipelineRun started."
comment "Watching VM state in the background while pipeline logs stream."
pe "oc get vm -n ${NAMESPACE} -w &"
WATCH_PID=$!
sleep 3
pe "tkn pipelinerun logs -f -n ${NAMESPACE} -L"
kill $WATCH_PID 2>/dev/null
pei ""
wait
clear

comment "What did Tekton commit to Git during the upgrade?"
pe "git -C ${REPO_ROOT} log --oneline -5 -- ${DEMO_DIR}/base/"
wait

comment "Traffic has moved. Service selector updated by Tekton's git commit → ArgoCD reconcile."
pe "oc get svc demo-app-lb -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector}' && echo"
wait
pe "oc get vm -n ${NAMESPACE}"
wait
pe "curl -s http://${LB_IP}/"
wait

say "Two Git commits — written by Tekton, not a human.
Same external IP. Zero downtime. Full rollout in git log.
Blue is Halted: zero compute consumed, still in Git, one commit from coming back. 🎩" 82
wait
clear

##############################################################
# BONUS — Rollback
##############################################################
redhatsay "Bonus: Rollback is a git revert 🔁

In vCenter: find the snapshot, revert the VM, re-point the load balancer manually.
Here: two Git commits. ArgoCD reconciles. Done."
wait
clear

comment "Step 1 — restart blue while traffic still flows to green. Zero downtime."
pe "yq e '.spec.runStrategy = \"Always\"' -i ${DEMO_DIR}/base/vm-blue.yaml"
pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/base/vm-blue.yaml"
pe "git -C ${REPO_ROOT} commit -m 'rollback: restart blue standby'"
pe "git -C ${REPO_ROOT} push origin main"
wait

comment "ArgoCD picks it up — blue boots. Waiting for Running state."
pe "oc wait vmi demo-vm-blue -n ${NAMESPACE} --for=condition=Ready --timeout=120s"
wait

comment "Step 2 — revert the cutover commit: traffic returns to blue, green halts."
CUTOVER_SHA=$(git -C "${REPO_ROOT}" log --oneline -- "${DEMO_DIR}/base/service-lb.yaml" | head -1 | awk '{print $1}')
pe "git -C ${REPO_ROOT} revert ${CUTOVER_SHA} --no-edit"
pe "yq e '.spec.runStrategy = \"Halted\"' -i ${DEMO_DIR}/base/vm-green.yaml"
pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/base/vm-green.yaml"
pe "git -C ${REPO_ROOT} commit --amend --no-edit"
pe "git -C ${REPO_ROOT} push origin main"
wait
clear

pe "oc get vm -n ${NAMESPACE}"
wait
pe "curl -s http://${LB_IP}/"
wait
clear

##############################################################
# CLOSING
##############################################################
echo "VMware / vCenter                       OpenShift + GitOps
───────────────────────────────────    ──────────────────────────────────────
VM defined in vCenter GUI              VM defined in Git (YAML, versioned)
Standby = powered-off clone            Standby = runStrategy: Halted (free)
Upgrade = wizard + manual LB           Upgrade = Git commit + Tekton pipeline
Rollback = vCenter snapshot revert     Rollback = git revert + push
Audit trail = vCenter task history     Audit trail = git log + Tekton logs
No PR review for VM changes            Full PR review + approval workflow
NSX / F5 / vRA = extra licenses        MetalLB + Tekton — included in OCP" \
  | gum style --bold --padding="1 2" --margin="1 0" --foreground="226" | redhatsay
wait

redhatsay "Everything in Git.
ArgoCD is authoritative throughout.
This is what running VMs like you run containers looks like. 🎩"
wait
clear
