#!/usr/bin/env bash
# Git-Driven VM Lifecycle Demo — VMware Admin Edition
#
# Starts from a clean cluster (ArgoCD + Virtualization + Pipelines installed, nothing else).
# Walks through: secrets → AWS LoadBalancer → ArgoCD setup → VM creation → app install → blue/green upgrade → rollback
#
# Run from repo root or gitops-vmware-virt-demo/:
#   ./gitops-vmware-virt-demo/demo/demo-rosa.sh
#   cd gitops-vmware-virt-demo && ./demo/demo-rosa.sh
#
# Flags:
#   -n         No wait (auto-advance)
#   -d         Disable simulated typing
#   -w <secs>  Auto-advance after N seconds
#   --debug    Trace execution to a temp log; dump log on exit

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
DEMO_DIR="gitops-vmware-virt-demo"
DEMO_ROOT="${REPO_ROOT}/${DEMO_DIR}"

# ── Strip --debug from $@ before demo-magic's getopts sees it ────
_DEMO_ARGS=()
for _a in "$@"; do
  if [[ "$_a" == "--debug" ]]; then
    # shellcheck source=debug.sh
    . "${SCRIPT_DIR}/debug.sh"
  else
    _DEMO_ARGS+=("$_a")
  fi
done
set -- "${_DEMO_ARGS[@]}"
unset _DEMO_ARGS _a

########################
# include the magic
########################
. "${REPO_ROOT}/scripts/demo-magic.sh"
cd "${REPO_ROOT}"

########################
# config
########################
NAMESPACE="vm-demo"
ARGOCD_NS="openshift-gitops"
[[ ! -v TYPE_SPEED ]] && TYPE_SPEED=40
DEMO_PROMPT="${GREEN}❯ ${COLOR_RESET}"
ROSA_VALUES="${DEMO_ROOT}/chart/values-rosa.yaml"
ROSA_STORAGE_CLASS=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("storage", "storageClass")' "${ROSA_VALUES}")
DEFAULT_GREEN_SNAPSHOT_NAME=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("green", "diskSnapshot", "name")' "${ROSA_VALUES}")
DEFAULT_GREEN_SNAPSHOT_NS=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("green", "diskSnapshot", "namespace")' "${ROSA_VALUES}")
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/rh-demos.pub}"
LB_IP=""  # resolved after the AWS LoadBalancer is ready

HAS_GUM=false; command -v gum &>/dev/null && HAS_GUM=true
HAS_BAT=false; command -v bat &>/dev/null && HAS_BAT=true
HAS_PYTHON3=false; command -v python3 &>/dev/null && HAS_PYTHON3=true
HAS_JQ=false; command -v jq &>/dev/null && HAS_JQ=true

if ! command -v redhatsay &>/dev/null; then
  redhatsay() {
    if [ "$#" -gt 0 ]; then
      echo -e "\033[1;31m$*\033[0m"
    else
      echo -ne "\033[1;31m"
      cat
      echo -e "\033[0m"
    fi
  }
fi

# dbg_step / dbg_run are defined by debug.sh when --debug is given; no-ops otherwise.
command -v dbg_step &>/dev/null || dbg_step() { :; }
command -v dbg_run  &>/dev/null || dbg_run()  { :; }

########################
# pre-flight checks, cleanup, helpers
########################
check_prereqs() {
  local missing=0
  for cmd in oc git ruby; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Required command not found: $cmd" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

_BG_PIDS=()
_CLEANUP_FILES=()
_cleanup() {
  local p f
  for p in "${_BG_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for f in "${_CLEANUP_FILES[@]}"; do rm -f "$f" 2>/dev/null || true; done
  oc patch application.argoproj.io vm-demo -n "${NAMESPACE}" \
    --type=merge \
    -p '{"spec":{"source":{"helm":{"parameters":null}}}}' >/dev/null 2>&1 || true
}
trap '_cleanup' EXIT INT TERM

_DEMO_START=$(date +%s)

# verify_green_snapshot_source: assert green VM was cloned from a specific snapshot
function verify_green_snapshot_source() {
  local expected_snapshot="$1"
  local vm_snapshot_content rootdisk_snapshot

  vm_snapshot_content=$(oc get virtualmachinesnapshot "${expected_snapshot}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.virtualMachineSnapshotContentName}')
  rootdisk_snapshot=$(oc get virtualmachinesnapshotcontent "${vm_snapshot_content}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.volumeSnapshotStatus[0].volumeSnapshotName}')

  pe "oc get virtualmachinesnapshotcontent ${vm_snapshot_content} -n ${NAMESPACE} \
    -o jsonpath='{.status.volumeSnapshotStatus[0].volumeSnapshotName}' && echo"

  if ! oc get vm demo-vm-green -n "${NAMESPACE}" \
    -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.snapshot.name}' 2>/dev/null | grep -q "${rootdisk_snapshot}"; then
    echo "Green VM snapshot source mismatch: expected ${NAMESPACE}/${rootdisk_snapshot}"
    return 1
  fi

  echo "Ready: green disk source is ${NAMESPACE}/${rootdisk_snapshot}"
}

########################
# helpers
########################
function act() {
  local elapsed=$(( $(date +%s) - _DEMO_START ))
  clear
  redhatsay "Act $1 — $2"
  comment "Elapsed: $((elapsed / 60))m $((elapsed % 60))s"
  wait
  clear
}

function say() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --bold --padding="1 2" --margin="1 0" --foreground="${2:-117}" | redhatsay
  else
    echo "$1" | redhatsay
  fi
}

function comment() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --italic --foreground=245 --padding="0 2"
  else
    echo -e "\033[3;90m# $1\033[0m"
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

# set_app_version: idempotent replacement of version string in app-version.yaml
function set_app_version() {
  local version="$1"
  ruby -0pi -e "gsub(/version: \"v[0-9.]+\"/, 'version: \"${version}\"')" \
    "${DEMO_ROOT}/pipelines/app-version.yaml"
}

# commit_and_push_if_changed: only commits if there are staged changes; uses --autostash on rebase
function commit_and_push_if_changed() {
  local message="$1"
  shift
  git -C "${REPO_ROOT}" add "$@"
  if git -C "${REPO_ROOT}" diff --cached --quiet; then
    return 0
  fi
  git -C "${REPO_ROOT}" commit --no-gpg-sign -m "${message}"
  git -C "${REPO_ROOT}" pull --rebase --autostash origin main
  git -C "${REPO_ROOT}" push origin main
}

# patch_vm_demo_parameters: applies Helm parameter overrides on the vm-demo ArgoCD Application
function patch_vm_demo_parameters() {
  local parameters_json="$1"
  oc patch application.argoproj.io vm-demo -n "${NAMESPACE}" --type=merge \
    --patch "{\"spec\":{\"source\":{\"helm\":{\"parameters\":${parameters_json}}}}}" \
    >/dev/null 2>&1
}

# sync_argo: trigger a sync and wait for a *new* operation to Succeed/Fail (with deadline)
function sync_argo() {
  local app="$1"
  local old_finished deadline phase finished health message

  comment "Triggering ArgoCD sync for ${app}..."

  # Clear a stale top-level operation if one exists.
  oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type=json \
    -p '[{"op":"remove","path":"/operation"}]' \
    >/dev/null 2>&1 || true

  # Record current finishedAt so we can detect when a NEW operation completes.
  old_finished=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || echo "")

  oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type merge \
    --patch '{"operation":{"initiatedBy":{"username":"demo"},"sync":{"prune":true}}}' \
    >/dev/null 2>&1

  deadline=$(( $(date +%s) + 300 ))
  while true; do
    finished=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)
    phase=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)

    if [[ "${finished}" != "${old_finished}" && "${phase}" == "Succeeded" ]]; then
      break
    fi
    if [[ "${finished}" != "${old_finished}" && "${phase}" == "Failed" ]]; then
      message=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
      echo "ArgoCD sync failed for ${app}: ${message}"
      return 1
    fi
    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for ${app} sync"
      return 1
    }
    sleep 3
  done

  health=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null)
  echo "✅ ${app}: Synced / ${health}"
}

# sync_argo_git: trigger a sync and wait until the app is at the current HEAD SHA (with deadline + failure detection)
function sync_argo_git() {
  local app="$1"
  local revision deadline sync_status health current_revision phase message

  revision=$(git -C "${REPO_ROOT}" rev-parse HEAD)

  comment "Triggering ArgoCD sync for ${app} @ ${revision:0:7}..."
  oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type=json \
    -p '[{"op":"remove","path":"/operation"}]' \
    >/dev/null 2>&1 || true

  oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type merge \
    --patch "{\"operation\":{\"initiatedBy\":{\"username\":\"demo\"},\"sync\":{\"revision\":\"${revision}\",\"prune\":true}}}" \
    >/dev/null 2>&1

  deadline=$(( $(date +%s) + 300 ))
  while true; do
    current_revision=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
    sync_status=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)

    if [[ "${current_revision}" == "${revision}" && "${sync_status}" == "Synced" ]]; then
      break
    fi
    phase=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
    if [[ "${current_revision}" == "${revision}" && "${phase}" == "Failed" ]]; then
      message=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
      echo "ArgoCD sync failed for ${app} at ${revision}: ${message}"
      return 1
    fi
    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for ${app} to sync to ${revision}"
      return 1
    }
    sleep 3
  done

  health=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null)
  echo "✅ ${app}: Synced @ ${revision:0:7} / ${health}"
}

# wait_argo_git: wait (without triggering a sync) for ArgoCD to reach HEAD on its own
function wait_argo_git() {
  local app="$1"
  local revision deadline sync_status current_revision phase message

  revision=$(git -C "${REPO_ROOT}" rev-parse HEAD)
  comment "Waiting for ArgoCD Application ${app} to reach ${revision:0:7}..."

  deadline=$(( $(date +%s) + 300 ))
  while true; do
    current_revision=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
    sync_status=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)

    if [[ "${current_revision}" == "${revision}" && "${sync_status}" == "Synced" ]]; then
      break
    fi
    phase=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
    if [[ "${current_revision}" == "${revision}" && "${phase}" == "Failed" ]]; then
      message=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
      echo "ArgoCD sync failed for ${app} at ${revision}: ${message}"
      return 1
    fi
    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for ${app} to reach ${revision}"
      return 1
    }
    sleep 3
  done

  local health
  health=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null)
  echo "✅ ${app}: reached ${revision:0:7} / ${health}"
}

function wait_for_pr() {
  local pr_name="$1"
  local timeout="${2:-900}"
  local waited=0

  comment "Waiting for PipelineRun ${pr_name} to complete..."
  while true; do
    local status reason
    status=$(oc get pipelinerun "${pr_name}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null)
    reason=$(oc get pipelinerun "${pr_name}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null)
    case "${status}" in
      True)  echo "✅ PipelineRun ${pr_name}: Succeeded"; return 0 ;;
      False) echo "❌ PipelineRun ${pr_name}: Failed (${reason})"; return 1 ;;
      *)
        sleep 5
        (( waited += 5 ))
        [[ $waited -ge $timeout ]] && {
          echo "Timed out waiting for ${pr_name}"
          oc get pipelinerun,taskrun -n "${NAMESPACE}" || true
          return 1
        }
        ;;
    esac
  done
}

function wait_for_blue_running() {
  local deadline=$(( $(date +%s) + 600 ))

  comment "Waiting for blue VM to be Running..."
  until oc get vm demo-vm-blue -n "${NAMESPACE}" \
      -o jsonpath='{.status.printableStatus}' 2>/dev/null | grep -q "Running"; do
    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for demo-vm-blue to run"
      oc get vm,vmi,dv,pvc -n "${NAMESPACE}" || true
      return 1
    }
    sleep 5
  done
}

function wait_for_lb_ip() {
  local deadline=$(( $(date +%s) + 300 ))

  comment "Waiting for AWS LoadBalancer hostname/IP..."
  until LB_IP=$(oc get svc demo-app-lb -n "${NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) && [[ -n "${LB_IP}" ]]; do
    LB_IP=$(oc get svc demo-app-lb -n "${NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "${LB_IP}" ]] && break
    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for demo-app-lb external hostname/IP"
      oc get svc demo-app-lb -n "${NAMESPACE}" || true
      return 1
    }
    sleep 5
  done
}

function curl_lb_command() {
  printf 'curl --retry 12 --retry-delay 5 --retry-all-errors -s http://%s/' "${LB_IP}"
}

function wait_for_green_reset() {
  local deadline=$(( $(date +%s) + 120 ))
  local parameters selector run_strategy source_name source_namespace

  comment "Waiting for green to reset: halted, blue traffic, golden-image disk..."
  while true; do
    parameters=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
      -o jsonpath='{.spec.source.helm.parameters}' 2>/dev/null || true)
    selector=$(oc get service demo-app-lb -n "${NAMESPACE}" \
      -o jsonpath='{.spec.selector.kubevirt\.io/domain}' 2>/dev/null || true)
    run_strategy=$(oc get vm demo-vm-green -n "${NAMESPACE}" \
      -o jsonpath='{.spec.runStrategy}' 2>/dev/null || true)
    source_name=$(oc get vm demo-vm-green -n "${NAMESPACE}" \
      -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.snapshot.name}' 2>/dev/null || true)
    source_namespace=$(oc get vm demo-vm-green -n "${NAMESPACE}" \
      -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.snapshot.namespace}' 2>/dev/null || true)

    if [[ -z "${parameters}" && "${selector}" == "demo-vm-blue" && \
          "${run_strategy}" == "Halted" && \
          "${source_name}" == "${DEFAULT_GREEN_SNAPSHOT_NAME}" && \
          "${source_namespace}" == "${DEFAULT_GREEN_SNAPSHOT_NS}" ]]; then
      break
    fi

    if ! oc get vm demo-vm-green -n "${NAMESPACE}" >/dev/null 2>&1 && \
       ! oc get datavolume centos10-green -n "${NAMESPACE}" >/dev/null 2>&1 && \
       ! oc get pvc centos10-green -n "${NAMESPACE}" >/dev/null 2>&1; then
      helm template vm-demo "${DEMO_ROOT}/chart" \
        -f "${DEMO_ROOT}/chart/values.yaml" \
        -f "${ROSA_VALUES}" | oc apply -f - >/dev/null
    fi

    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for green to reset to defaults"
      return 1
    }
    sleep 3
  done
}

function verify_rosa_prereqs() {
  local current_snapshot snapshot_ns

  current_snapshot=$(oc get datasource centos-stream10 -n openshift-virtualization-os-images \
    -o jsonpath='{.status.source.snapshot.name}')
  snapshot_ns=$(oc get datasource centos-stream10 -n openshift-virtualization-os-images \
    -o jsonpath='{.status.source.snapshot.namespace}')
  if [[ "${current_snapshot}" != "${DEFAULT_GREEN_SNAPSHOT_NAME}" || "${snapshot_ns}" != "${DEFAULT_GREEN_SNAPSHOT_NS}" ]]; then
    echo "ROSA values boot source ${DEFAULT_GREEN_SNAPSHOT_NS}/${DEFAULT_GREEN_SNAPSHOT_NAME} does not match current DataSource ${snapshot_ns}/${current_snapshot}" >&2
    exit 1
  fi
}

########################
# pre-flight: reset state that may be left over from a previous demo run (hidden from audience)
########################
check_prereqs
verify_rosa_prereqs
# Clear any runtime Helm parameter overrides left from a previous pipeline/rollback run.
oc patch application.argoproj.io vm-demo -n "${NAMESPACE}" --type=merge \
  -p '{"spec":{"source":{"helm":{"parameters":null}}}}' >/dev/null 2>&1 || true

# Reset app version to v1.0 idempotently and push only if needed.
set_app_version "v1.0"
commit_and_push_if_changed "chore: reset demo state to v1.0 before demo" \
  "${DEMO_DIR}/pipelines/app-version.yaml"

##############################################################
# INTRO
##############################################################
dbg_step "INTRO"
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

say "
  ┌────────────────────────────────────────────────────────┐
  │            OpenShift + GitOps VM Lifecycle             │
  └────────────────────────────────────────────────────────┘
                              │ (Git Push Version)
                              ▼
                      ┌───────────────┐
                      │    ArgoCD     │
                      └───────┬───────┘
                              │ (Sync Loop)
                              ▼
           ┌──────────────────┴──────────────────┐
           ▼                                     ▼
   ┌───────────────┐                     ┌───────────────┐
   │  demo-vm-blue │                     │ demo-vm-green │
   │   (Running)   │                     │   (Halted)    │
   └───────┬───────┘                     └───────────────┘
           │ (Active Route)                      │ (In-Place Snapshot Clone)
           ▼                                     ▼
   ┌───────────────┐                     ┌───────────────┐
   │AWS LoadBalancer                     │  Smoke Tested │
   └───────────────┘                     └───────────────┘" 117
wait
clear

##############################################################
# SETUP 1 — Namespace + Secrets
##############################################################
dbg_step "SETUP 1 — Secrets"
say "Setup 1 of 3 — Secrets

The demo uses a single SSH key pair for two purposes:
  🔑  Tekton workspace  — Ansible tasks use the private key to SSH into VMs
  🖥️  cloud-init        — public key is injected into every VM

One key pair. No passwords stored. No tokens rotated. Fully auditable." 226
wait
clear

comment "Create the vm-demo namespace where everything will live."
pe "oc create namespace ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -"
wait

comment "vm-ssh-key — private key mounted into Tekton tasks for Ansible SSH access to VMs."
pei "oc create secret generic vm-ssh-key \
  --from-file=id_rsa=${SSH_PRIVATE_KEY} \
  --namespace=${NAMESPACE} \
  --dry-run=client -o yaml | oc apply -f -"

comment "vm-cloud-init — cloud-init userdata that injects the public SSH key into the cloud-user's authorized_keys."
PUB_KEY=$(cat "${SSH_PUBLIC_KEY}")
# Write to a temp file — pe/eval collapses multi-line --from-literal strings into invalid YAML
cloud_init_file=$(mktemp)
_CLEANUP_FILES+=("${cloud_init_file}")
{
  printf '#cloud-config\n'
  printf 'users:\n'
  printf '  - name: cloud-user\n'
  printf '    sudo: ALL=(ALL) NOPASSWD:ALL\n'
  printf '    ssh_authorized_keys:\n'
  printf '      - %s\n' "${PUB_KEY}"
  printf 'chpasswd:\n'
  printf '  list: |\n'
  printf '    cloud-user:redhat\n'
  printf '  expire: false\n'
} > "${cloud_init_file}"
comment "Here is the cloud-init we just generated:"
pe "show_yaml ${cloud_init_file}"
wait
pei "oc create secret generic vm-cloud-init \
  --from-file=userdata=${cloud_init_file} \
  --namespace=${NAMESPACE} \
  --dry-run=client -o yaml | oc apply -f -"

pei "oc get secret vm-ssh-key vm-cloud-init -n ${NAMESPACE}"
dbg_run oc get secret vm-ssh-key vm-cloud-init -n ${NAMESPACE} -o yaml
wait
clear

##############################################################
# SETUP 2 — AWS LoadBalancer
##############################################################
dbg_step "SETUP 2 — AWS LoadBalancer"
say "Setup 2 of 3 — AWS native LoadBalancer

In vCenter you'd file an IPAM ticket and wait for NSX configuration.
On ROSA, OpenShift asks AWS to provision the external load balancer.
No MetalLB pool is required for this path." 226
wait
clear

comment "Verify the ROSA storage and boot-source prerequisites before ArgoCD creates VMs."
pe "oc get storageprofile ${ROSA_STORAGE_CLASS}"
wait
pe "oc get datasource centos-stream10 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.source.snapshot.namespace}/{.status.source.snapshot.name}{\" ready=\"}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}'"
wait
clear

##############################################################
# SETUP 3 — ArgoCD
##############################################################
dbg_step "SETUP 3 — ArgoCD"
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
pe "show_yaml ${DEMO_DIR}/argocd/appproject.yaml"
wait
pei "oc apply -f ${DEMO_DIR}/argocd/appproject.yaml"
wait
clear

comment "Grant the ArgoCD application controller admin access in vm-demo so it can create VMs, Services, and pipelines."
pe "show_yaml ${DEMO_DIR}/argocd/rbac.yaml"
wait
pei "oc apply -f ${DEMO_DIR}/argocd/rbac.yaml"
wait
clear

comment "Application 1: VMs and services — ArgoCD renders a Helm chart with ROSA values."
comment "Runtime Helm parameters override values without Git commits — used by the upgrade pipeline."
pe "show_yaml ${DEMO_DIR}/argocd/application-rosa.yaml"
wait
pei "oc apply -f ${DEMO_DIR}/argocd/application-rosa.yaml -n ${NAMESPACE}"
wait
clear

comment "Application 2: Pipeline infrastructure — Tekton tasks, pipelines, event-listener."
pe "show_yaml ${DEMO_DIR}/argocd/application-infra.yaml"
wait
pei "oc apply -f ${DEMO_DIR}/argocd/application-infra.yaml -n ${NAMESPACE}"
wait
clear

say "ArgoCD is now watching GitHub.
It will reconcile the cluster to match Git — continuously.
Let's watch it work." 117
wait

pe "oc get applications.argoproj.io -n ${NAMESPACE}"
# Wait for vm-demo to self-sync (selfHeal) then explicitly sync infra.
wait_argo_git "vm-demo"
sync_argo_git "vm-demo-infra"
dbg_run oc get applications.argoproj.io -n ${NAMESPACE} -o wide
dbg_run oc get all -n ${NAMESPACE}
wait
clear

##############################################################
# SETUP — Wait for VMs
##############################################################
dbg_step "SETUP — waiting for VMs"
say "Waiting for VMs...

ArgoCD has applied the VirtualMachine manifests from the Helm chart.
CDI is now cloning the CentOS Stream 10 golden image into two DataVolumes.

Blue will come up Running.
Green stays Halted — zero CPU, zero RAM consumed." 226
wait
clear

pe "oc get vm -n ${NAMESPACE} -w &"
WATCH_PID=$!
_BG_PIDS+=($WATCH_PID)
wait_for_blue_running
kill $WATCH_PID 2>/dev/null
pei ""
pe "oc get vm -n ${NAMESPACE}"
dbg_run oc get vm,vmi -n ${NAMESPACE} -o wide
dbg_run oc get svc -n ${NAMESPACE}
wait

comment "AWS has assigned a real external LoadBalancer endpoint."
pe "oc get svc demo-app-lb -n ${NAMESPACE}"
wait_for_lb_ip
wait

say "The cluster now exactly matches Git.
Blue running. Green halted at zero cost.
ArgoCD will keep it that way — any drift is auto-corrected. 🎩" 82
wait
clear

##############################################################
# ACT 1 — What's in Git drives the cluster
##############################################################
dbg_step "ACT 1 — What's in Git drives the cluster"
act 1 "What's in Git drives the cluster"

comment "This Helm chart is everything ArgoCD needs to create and manage both VMs."
comment "values.yaml is the reset state. The pipeline overrides values at runtime — no Git commits."
pe "show_yaml ${DEMO_DIR}/chart/values.yaml"
wait
clear

pe "show_yaml ${DEMO_DIR}/chart/templates/vm-blue.yaml"
wait
clear

pe "show_yaml ${DEMO_DIR}/chart/templates/vm-green.yaml"
wait
clear

say "vm-green has runStrategy: Halted in values.yaml.
The upgrade pipeline overrides it to Always — directly on the ArgoCD Application.
No Git commit. ArgoCD re-renders the chart and starts the VM immediately." 245
wait

comment "ArgoCD Application status — lives in vm-demo namespace, watched by the openshift-gitops instance."
pe "oc get applications.argoproj.io vm-demo -n ${NAMESPACE} \
  -o jsonpath='{.status.sync.status} / {.status.health.status}' && echo"
wait

comment "Tekton pipeline infrastructure — also managed by ArgoCD from Git."
pe "oc get pipelines.tekton.dev -n ${NAMESPACE}"
wait

comment "Traffic is currently routed to blue via the AWS LoadBalancer."
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
dbg_step "ACT 2 — Tekton + Ansible Application Deploy"
act 2 "Tekton + Ansible — Application Deploy"

say "We need to install an application on the running VM.
In VMware: SSH in manually, run your scripts, pray you documented the steps.
Here: a Tekton pipeline runs an Ansible playbook.
Repeatable. Auditable. No shell history to clean up." 226
wait
clear

comment "The install pipeline: wait for VM ready → Ansible installs httpd + v1.0 → smoke test."
pe "oc get pipelines.tekton.dev install-app -n ${NAMESPACE}"
wait

comment "Trigger the install — Ansible will install httpd and serve v1.0 on demo-vm-blue."
dbg_step "ACT 2 — creating install PipelineRun"
INSTALL_PR=$(oc create -f ${DEMO_DIR}/pipelines/install-pipelinerun.yaml -n ${NAMESPACE} -o name)
INSTALL_PR_NAME=${INSTALL_PR##*/}
dbg_run oc get pipelinerun ${INSTALL_PR_NAME} -n ${NAMESPACE} -o yaml
pe "echo ${INSTALL_PR}"
wait
clear

comment "Watching the install-app pipeline logs stream in real-time. Every step is a Tekton Task."
dbg_step "ACT 2 — streaming install-app logs ${INSTALL_PR_NAME}"
pei "oc logs -f -n ${NAMESPACE} -l tekton.dev/pipeline=install-app --tail=-1 --prefix"
dbg_step "ACT 2 — waiting for install PipelineRun to complete"
wait_for_pr "${INSTALL_PR_NAME}"
dbg_run oc get pipelinerun,taskrun -n ${NAMESPACE}
dbg_run oc get vm,vmi -n ${NAMESPACE}
wait
clear

pe "$(curl_lb_command)"
wait

pei ""
say "v1.0 is live on demo-vm-blue.
Deployed by Ansible, orchestrated by Tekton, infrastructure managed by ArgoCD.
No SSH sessions left open. Every step is in the Tekton audit log." 82
wait
clear

##############################################################
# ACT 3 — Blue/Green Upgrade
##############################################################
dbg_step "ACT 3 — Blue/Green Upgrade"
act 3 "Blue/Green Upgrade — one Git commit triggers automation"

say "Time to deploy v2.0.
In vCenter: provision new VM, install manually, re-point the load balancer, hope the snapshot works.
Here: push one Git commit. Tekton orchestrates the entire upgrade.
Watch what happens." 226
wait
clear

say "The upgrade pipeline — one Git commit triggers it; everything else goes direct to ArgoCD:

  [1] snapshot-blue      VirtualMachineSnapshot — safety net before touching anything
  [2] patch-start-green  Patch ArgoCD params: green=Always, disk=blue-snapshot → sync
  [3] wait-for-green     Polls VMI until Running
  [4] ansible-upgrade    Ansible deploys v2.0 onto green (started from blue clone)
  [5] smoke-test         curl /health directly on green
  [6-PASS] patch-cutover Patch ArgoCD params: traffic=green, blue=Halted → sync
  [6-FAIL] patch-stop    Patch ArgoCD params: green=Halted (blue untouched, users unaffected)" 117
wait
clear

comment "Bump the app version and push — the upgrade pipeline is triggered manually below."
pe "ruby -0pi -e 'gsub(/version: \"v[0-9.]+\"/, \"version: \\\"v2.0\\\"\")' ${DEMO_DIR}/pipelines/app-version.yaml"
pe "show_yaml ${DEMO_DIR}/pipelines/app-version.yaml"
wait
pe "git -C ${REPO_ROOT} add ${DEMO_DIR}/pipelines/app-version.yaml"
pe "git -C ${REPO_ROOT} commit -m 'bump app version to v2.0'"
pe "git -C ${REPO_ROOT} pull --rebase --autostash origin main && git -C ${REPO_ROOT} push origin main"
sync_argo_git "vm-demo-infra"
wait
clear

comment "Triggering the upgrade pipeline directly — no webhook needed."
dbg_step "ACT 3 — creating upgrade PipelineRun"
UPGRADE_PR=$(oc create -f ${DEMO_DIR}/pipelines/upgrade-pipelinerun-rosa.yaml -n ${NAMESPACE} -o name)
UPGRADE_PR_NAME=${UPGRADE_PR##*/}
EXPECTED_SNAPSHOT="blue-pre-upgrade-${UPGRADE_PR_NAME}"
dbg_run oc get pipelinerun ${UPGRADE_PR_NAME} -n ${NAMESPACE} -o yaml
pe "echo ${UPGRADE_PR}"
wait
clear

comment "Streaming upgrade-app logs. ArgoCD syncs are triggered inside the pipeline after each parameter patch."
dbg_step "ACT 3 — streaming upgrade-app logs ${UPGRADE_PR_NAME}"
pei "oc logs -f -n ${NAMESPACE} -l tekton.dev/pipeline=upgrade-app --tail=-1 --prefix"
dbg_step "ACT 3 — waiting for upgrade PipelineRun to complete"
wait_for_pr "${UPGRADE_PR_NAME}"
dbg_run oc get pipelinerun,taskrun -n ${NAMESPACE}
dbg_run oc get vm,vmi -n ${NAMESPACE}
dbg_run oc get svc demo-app-lb -n ${NAMESPACE} -o jsonpath='{.spec.selector}{"\n"}'
dbg_run oc get virtualmachinesnapshot -n ${NAMESPACE}
wait
clear

comment "The green VM was not built from the golden image; it was cloned from blue's rootdisk snapshot."
pe "oc get virtualmachinesnapshot ${EXPECTED_SNAPSHOT} -n ${NAMESPACE} \
  -o jsonpath='{.status.virtualMachineSnapshotContentName}' && echo"
VM_SNAPSHOT_CONTENT=$(oc get virtualmachinesnapshot "${EXPECTED_SNAPSHOT}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.virtualMachineSnapshotContentName}')
pe "oc get virtualmachinesnapshotcontent ${VM_SNAPSHOT_CONTENT} -n ${NAMESPACE} \
  -o jsonpath='{.status.volumeSnapshotStatus[0].volumeSnapshotName}' && echo"
pe "oc get vm demo-vm-green -n ${NAMESPACE} \
  -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.snapshot.namespace}/{.spec.dataVolumeTemplates[0].spec.source.snapshot.name}' && echo"
verify_green_snapshot_source "${EXPECTED_SNAPSHOT}" || exit 1
wait
clear

comment "What did the pipeline change? No Git commits — it updated ArgoCD parameters directly."
if [ "$HAS_PYTHON3" = true ]; then
  pe "oc get application.argoproj.io vm-demo -n ${NAMESPACE} \
    -o jsonpath='{.spec.source.helm.parameters}' | python3 -m json.tool"
elif [ "$HAS_JQ" = true ]; then
  pe "oc get application.argoproj.io vm-demo -n ${NAMESPACE} \
    -o jsonpath='{.spec.source.helm.parameters}' | jq ."
else
  pe "oc get application.argoproj.io vm-demo -n ${NAMESPACE} \
    -o jsonpath='{.spec.source.helm.parameters}'"
fi
wait

comment "Traffic has moved. Service selector updated by ArgoCD after the parameter patch."
pe "oc get svc demo-app-lb -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector}' && echo"
wait
pe "oc get vm -n ${NAMESPACE}"
wait
pe "$(curl_lb_command)"
wait

say "One Git commit — the version bump — triggered the pipeline.
The pipeline patched ArgoCD parameters directly: no extra Git commits.
Same external IP. Zero downtime. Traffic on green. Blue halted: zero compute. 🎩" 82
wait
clear

##############################################################
# BONUS — Rollback
##############################################################
dbg_step "BONUS — Rollback"
redhatsay "Bonus: Rollback is two ArgoCD patches 🔁

In vCenter: find the snapshot, revert the VM, re-point the load balancer manually.
Here: patch ArgoCD parameters. No Git commits. ArgoCD reconciles. Done."
wait
clear

# Capture the current green disk snapshot parameters for use in rollback patches.
ROLLBACK_GREEN_SNAPSHOT_NAME=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
  -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.diskSnapshot.name")].value}' 2>/dev/null || true)
ROLLBACK_GREEN_SNAPSHOT_NS=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
  -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.diskSnapshot.namespace")].value}' 2>/dev/null || true)
ROLLBACK_GREEN_SNAPSHOT_NAME=${ROLLBACK_GREEN_SNAPSHOT_NAME:-${DEFAULT_GREEN_SNAPSHOT_NAME}}
ROLLBACK_GREEN_SNAPSHOT_NS=${ROLLBACK_GREEN_SNAPSHOT_NS:-${DEFAULT_GREEN_SNAPSHOT_NS}}

comment "Step 1 — restart blue while traffic still flows to green. Zero downtime."
comment "We patch ArgoCD parameters directly — no Git commit needed."
pe "oc patch application.argoproj.io vm-demo -n ${NAMESPACE} --type=merge \
  -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[
    {\"name\":\"blue.runStrategy\",\"value\":\"Always\"},
    {\"name\":\"green.runStrategy\",\"value\":\"Always\"},
    {\"name\":\"green.diskSnapshot.name\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NAME}\"},
    {\"name\":\"green.diskSnapshot.namespace\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NS}\"},
    {\"name\":\"traffic.activeSlot\",\"value\":\"green\"}
  ]}}}}'"
pe "oc patch vm demo-vm-blue -n ${NAMESPACE} --type=merge \
  -p '{\"spec\":{\"runStrategy\":\"Always\"}}'"
wait

comment "Blue boots. Waiting for VMI to exist and reach Ready state."
pei "until oc get vmi demo-vm-blue -n ${NAMESPACE} >/dev/null 2>&1; do sleep 3; done"
pe "oc wait vmi demo-vm-blue -n ${NAMESPACE} --for=condition=Ready --timeout=120s"
wait

comment "Step 2 — move traffic back to blue and halt green."
pe "oc patch application.argoproj.io vm-demo -n ${NAMESPACE} --type=merge \
  -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":[
    {\"name\":\"blue.runStrategy\",\"value\":\"Always\"},
    {\"name\":\"green.runStrategy\",\"value\":\"Halted\"},
    {\"name\":\"green.diskSnapshot.name\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NAME}\"},
    {\"name\":\"green.diskSnapshot.namespace\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NS}\"},
    {\"name\":\"traffic.activeSlot\",\"value\":\"blue\"}
  ]}}}}'"
pe "oc patch service demo-app-lb -n ${NAMESPACE} --type=merge \
  -p '{\"spec\":{\"selector\":{\"kubevirt.io/domain\":\"demo-vm-blue\"}}}'"
pe "oc patch vm demo-vm-green -n ${NAMESPACE} --type=merge \
  -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'"
wait

comment "Step 3 — delete green, then clear overrides so values.yaml recreates it halted from the golden image."
pe "oc delete vm demo-vm-green -n ${NAMESPACE} --ignore-not-found --wait=false && \
oc delete datavolume centos10-green -n ${NAMESPACE} --ignore-not-found --wait=false && \
oc delete pvc centos10-green -n ${NAMESPACE} --ignore-not-found --wait=false"
comment "Clear all Helm parameter overrides — values.yaml defaults take over (blue=Always, green=Halted, traffic=blue)."
pe "oc patch application.argoproj.io vm-demo -n ${NAMESPACE} --type=merge \
  -p '{\"spec\":{\"source\":{\"helm\":{\"parameters\":null}}}}'"
wait_for_green_reset
dbg_run oc get vm,vmi -n ${NAMESPACE}
dbg_run oc get svc demo-app-lb -n ${NAMESPACE} -o jsonpath='{.spec.selector}{"\n"}'
wait
pe "$(curl_lb_command)"
wait
clear

##############################################################
# CLOSING
##############################################################
CLOSING_TABLE="VMware / vCenter                       OpenShift + GitOps
───────────────────────────────────    ──────────────────────────────────────
VM defined in vCenter GUI              VM defined in Helm chart (versioned)
Standby = powered-off clone            Standby = runStrategy: Halted (free)
Upgrade = wizard + manual LB           Upgrade = Git commit + Tekton pipeline
Rollback = vCenter snapshot revert     Rollback = ArgoCD param patch (no commit)
Audit trail = vCenter task history     Audit trail = git log + Tekton logs
No PR review for VM changes            Full PR review + approval workflow
NSX / F5 / vRA = extra licenses        AWS LoadBalancer + Tekton — platform-integrated"
if [ "$HAS_GUM" = true ]; then
  echo "$CLOSING_TABLE" | gum style --bold --padding="1 2" --margin="1 0" --foreground="226" | redhatsay
else
  echo "$CLOSING_TABLE" | redhatsay
fi
wait

redhatsay "Everything in Git.
ArgoCD is authoritative throughout.
This is what running VMs like you run containers looks like. 🎩"
wait
clear
