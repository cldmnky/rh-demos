#!/usr/bin/env bash
# Git-Driven VM Lifecycle Demo — VMware Admin Edition
# Run from: gitops-vmware-virt-demo/
#
# Usage:
#   ./demo/demo.sh [-n] [-d] [-w <seconds>]
#     -n  No wait (auto-advance)
#     -d  Debug — disable simulated typing
#     -w  Auto-advance after N seconds

########################
# include the magic
########################
. ../../scripts/demo-magic.sh

########################
# config
########################
TYPE_SPEED=40
DEMO_PROMPT="${GREEN}❯ ${COLOR_RESET}"
NAMESPACE="vm-demo"
REPO_ROOT=$(git rev-parse --show-toplevel)
DEMO_DIR="gitops-vmware-virt-demo"

# Resolve LB IP at startup so we can use it throughout
LB_IP=$(oc get svc demo-app-lb -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "192.168.10.50")

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
  if command -v gum &>/dev/null; then
    echo "$1" | gum style --italic --foreground=245 --padding="0 2"
  else
    echo -e "${GREY}# $1${COLOR_RESET}"
  fi
}

########################
# intro
########################
clear
redhatsay "Git-Driven VM Lifecycle Demo 🎩
VMware Admin Edition"
wait
clear
echo "In VMware, your VMs live in vCenter — not in version control.
Upgrades mean clicking wizards, manual LB re-pointing, and snapshot-pray rollbacks.
This demo shows a different model: every VM is a YAML file in Git.
ArgoCD is the authoritative controller. Tekton writes Git commits, not vCenter tasks." \
  | gum style --bold --padding="1 2" --margin="1 0" --foreground="117" | redhatsay
wait
clear

########################
# ACT 1 — GitOps VM Creation
########################
act 1 "GitOps VM Creation"

pe "cat ${DEMO_DIR}/base/vm-blue.yaml"
wait
clear

pe "cat ${DEMO_DIR}/base/vm-green.yaml"
wait
clear

comment "Notice: vm-green has runStrategy: Halted — standby with zero CPU/RAM consumed."
echo "In vCenter, there is no concept of 'desired off' expressed in code.
Here it's just a field in a YAML file. ArgoCD enforces it." \
  | gum style --italic --padding="0 2" --foreground=245 | redhatsay
wait

comment "ArgoCD watches this Git repository and keeps the cluster in sync."
pe "oc get application -n openshift-gitops"
wait
pe "oc get application vm-demo -n openshift-gitops \
  -o jsonpath='{.status.sync.status} / {.status.health.status}' && echo"
wait
clear

comment "VMs on the cluster — ArgoCD created them straight from Git."
pe "oc get vm -n ${NAMESPACE}"
wait

comment "MetalLB assigned a real external IP — no IPAM ticket, no NSX config."
pe "oc get svc demo-app-lb -n ${NAMESPACE}"
wait
clear

comment "Service selector is pointing at blue right now."
pe "oc get svc demo-app-lb -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector}' && echo"
wait

echo "Two YAML files. One Git commit.
No wizards. No IPAM ticket. No NSX config.
Same result — running VM with a real external IP. 🎩" \
  | gum style --bold --padding="1 2" --margin="1 0" --foreground="82" | redhatsay
wait
clear

########################
# ACT 2 — Tekton + Ansible Application Deploy
########################
act 2 "Tekton + Ansible Application Deploy"

pe "oc get pipeline -n ${NAMESPACE}"
wait

comment "Trigger the install pipeline — Ansible will install nginx + v1.0 on blue."
pe "oc create -f ${DEMO_DIR}/pipelines/install-pipelinerun.yaml -n ${NAMESPACE}"
wait
clear

comment "Watch the pipeline run in real time."
pe "tkn pipelinerun logs -f -n ${NAMESPACE} -L"
wait
clear

comment "Pipeline done. Let's hit the app."
pe "curl -s http://${LB_IP}/"
wait

echo "v1.0 is live on demo-vm-blue — via MetalLB, via ArgoCD, deployed by Tekton + Ansible.
No SSH session left open. No manual steps. Full audit trail in git log." \
  | gum style --bold --padding="1 2" --margin="1 0" --foreground="82" | redhatsay
wait
clear

########################
# ACT 3 — Blue/Green Upgrade
########################
act 3 "Blue/Green Upgrade — Git Commits Drive the Cluster"

comment "The upgrade flow:"
comment "  [1] Snapshot blue (safety net)"
comment "  [2] Git commit → vm-green: Always   → ArgoCD starts green"
comment "  [3] Wait for green Running"
comment "  [4] Ansible deploys v2.0 onto green"
comment "  [5] Smoke test green"
comment "  [6-PASS] Git commit → service selector green, vm-blue Halted"
comment "  [6-FAIL] Git commit → vm-green Halted  (blue untouched)"
wait
clear

comment "Trigger the upgrade by pushing a Git commit — webhook fires the EventListener."
pei "cd ${REPO_ROOT}"
pe "git -C ${REPO_ROOT} log --oneline -3 -- ${DEMO_DIR}/base/"
wait

comment "Bump the app version — this is the Git push that fires the pipeline."
pe "sed -i '' 's/version: \"v1.0\"/version: \"v2.0\"/' ${DEMO_DIR}/pipelines/app-version.yaml"
pe "cat ${DEMO_DIR}/pipelines/app-version.yaml"
wait

pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/pipelines/app-version.yaml"
pe "git -C ${REPO_ROOT} commit -m 'bump app version to v2.0'"
pe "git -C ${REPO_ROOT} push origin main"
wait
clear

comment "GitHub webhook → Tekton EventListener → upgrade-app pipeline starts."
comment "Watch VMs change state in real time."
pe "oc get vm -n ${NAMESPACE} -w &"
WATCH_PID=$!

comment "Watch the pipeline logs."
sleep 3
pe "tkn pipelinerun logs -f -n ${NAMESPACE} -L"

kill $WATCH_PID 2>/dev/null
wait
clear

comment "Pipeline complete. What did Git record?"
pe "git -C ${REPO_ROOT} log --oneline -5 -- ${DEMO_DIR}/base/"
wait

echo "Two commits by Tekton: 'start green' and 'cutover'.
Full audit trail. PR reviewable. Revertable.
Blue is Halted — zero compute, still in Git, ready for rollback. 🎩" \
  | gum style --bold --padding="1 2" --margin="1 0" --foreground="82" | redhatsay
wait
pe "oc get svc demo-app-lb -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector}' && echo"
wait
pe "oc get vm -n ${NAMESPACE}"
wait

pe "curl -s http://${LB_IP}/"
wait
clear

########################
# BONUS — Rollback
########################
redhatsay "Bonus: Rollback is a Git Revert 🔁
In vCenter: find snapshot, revert, re-point LB manually.
Here: git revert. ArgoCD does the rest."
wait
clear

comment "Step 1: start blue while traffic still flows to green (zero downtime)"
pe "yq e '.spec.runStrategy = \"Always\"' -i ${DEMO_DIR}/base/vm-blue.yaml"
pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/base/vm-blue.yaml"
pe "git -C ${REPO_ROOT} commit -m 'rollback: start blue standby'"
pe "git -C ${REPO_ROOT} push origin main"
wait

comment "ArgoCD starts blue. Wait for it..."
pe "oc wait vmi demo-vm-blue -n ${NAMESPACE} --for=condition=Ready --timeout=120s"
wait

comment "Step 2: revert the cutover commit — traffic goes back to blue, green halts."
CUTOVER_SHA=$(git -C "${REPO_ROOT}" log --oneline -- "${DEMO_DIR}/base/service-lb.yaml" | head -1 | awk '{print $1}')
pe "git -C ${REPO_ROOT} revert ${CUTOVER_SHA} --no-edit"
pe "yq e '.spec.runStrategy = \"Halted\"' -i ${DEMO_DIR}/base/vm-green.yaml"
pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/base/vm-green.yaml"
pe "git -C ${REPO_ROOT} commit --amend --no-edit"
pe "git -C ${REPO_ROOT} push origin main"
wait
clear

comment "ArgoCD reconciles. Back to v1.0 on blue."
pe "oc get vm -n ${NAMESPACE}"
wait
pe "curl -s http://${LB_IP}/"
wait
clear

########################
# closing
########################
echo "VMware / vCenter                     OpenShift + GitOps
─────────────────────────────────    ──────────────────────────────────
VM defined in vCenter (no code)      VM defined in Git (YAML, versioned)
Standby = powered-off clone          Standby = runStrategy: Halted (zero cost)
Upgrade = wizard + manual LB         Upgrade = Git commit + Tekton pipeline
Rollback = vCenter snapshot revert   Rollback = git revert
Audit trail = vCenter task history   Audit trail = git log
NSX / F5 needed for LB              MetalLB — included in OpenShift" \
  | gum style --bold --padding="1 2" --margin="1 0" --foreground="226" | redhatsay
wait

redhatsay "Everything in Git. ArgoCD is authoritative throughout. 🎩"
wait
clear
