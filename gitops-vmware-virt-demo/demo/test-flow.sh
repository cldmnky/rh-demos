#!/usr/bin/env bash
# Non-interactive end-to-end flow test for the VM GitOps demo.
# Mirrors demo.sh cluster actions without demo-magic, typing effects, or pauses.
#
# Run from repo root or gitops-vmware-virt-demo/:
#   ./gitops-vmware-virt-demo/demo/test-flow.sh
#   cd gitops-vmware-virt-demo && ./demo/test-flow.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
DEMO_DIR="gitops-vmware-virt-demo"
DEMO_ROOT="${REPO_ROOT}/${DEMO_DIR}"

NAMESPACE="${NAMESPACE:-vm-demo}"
ARGOCD_NS="${ARGOCD_NS:-openshift-gitops}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/rh-demos.pub}"
ARGO_SYNC_TIMEOUT="${ARGO_SYNC_TIMEOUT:-600}"
METALLB_POOL=$(awk -F': ' '/metallb.universe.tf\/address-pool/ {print $2}' "${DEMO_ROOT}/chart/templates/service-lb.yaml" | head -1 | tr -d ' "')
LB_IP=""

cd "${REPO_ROOT}"

log() {
  printf '\n==> %s\n' "$*"
}

run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

set_app_version() {
  local version="$1"
  ruby -0pi -e "gsub(/version: \"v[0-9.]+\"/, 'version: \"${version}\"')" \
    "${DEMO_ROOT}/pipelines/app-version.yaml"
}

commit_and_push_if_changed() {
  local message="$1"
  shift

  run git -C "${REPO_ROOT}" add "$@"
  if git -C "${REPO_ROOT}" diff --cached --quiet; then
    echo "No Git changes to commit."
    return 0
  fi

  run git -C "${REPO_ROOT}" commit -m "${message}"
  run git -C "${REPO_ROOT}" pull --rebase --autostash origin main
  run git -C "${REPO_ROOT}" push origin main
}

sync_argo() {
  local app="$1"
  local old_finished deadline phase finished health message

  log "Syncing ArgoCD Application ${app}"
  oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type=json \
    -p '[{"op":"remove","path":"/operation"}]' >/dev/null 2>&1 || true

  old_finished=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || echo "")

  run oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type merge \
    --patch '{"operation":{"initiatedBy":{"username":"test-flow"},"sync":{"prune":true}}}'

  deadline=$(( $(date +%s) + ARGO_SYNC_TIMEOUT ))
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
      echo "Timed out waiting for ${app} sync (phase=${phase}, finishedAt=${finished})"
      return 1
    }
    sleep 3
  done

  health=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  echo "${app}: sync completed, health=${health}"
}

sync_argo_git() {
  local app="$1"
  local revision deadline sync_status health current_revision phase message

  revision=$(git -C "${REPO_ROOT}" rev-parse HEAD)
  log "Syncing ArgoCD Application ${app} to Git revision ${revision:0:7}"
  run oc patch application.argoproj.io "${app}" -n "${NAMESPACE}" \
    --type merge \
    --patch '{"operation":{"initiatedBy":{"username":"test-flow"},"sync":{"prune":true}}}'

  deadline=$(( $(date +%s) + ARGO_SYNC_TIMEOUT ))
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
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  echo "${app}: synced to ${revision:0:7}, health=${health}"
}

wait_argo_git() {
  local app="$1"
  local revision deadline sync_status health current_revision phase message

  revision=$(git -C "${REPO_ROOT}" rev-parse HEAD)
  log "Waiting for ArgoCD Application ${app} to reach Git revision ${revision:0:7}"

  deadline=$(( $(date +%s) + ARGO_SYNC_TIMEOUT ))
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

  health=$(oc get application.argoproj.io "${app}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  echo "${app}: reached ${revision:0:7}, health=${health}"
}

wait_for_pr() {
  local pr_name="$1"
  local timeout="${2:-900}"
  local waited=0 status reason

  log "Waiting for PipelineRun ${pr_name}"
  while true; do
    status=$(oc get pipelinerun "${pr_name}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)
    reason=$(oc get pipelinerun "${pr_name}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || true)

    case "${status}" in
      True)
        echo "PipelineRun ${pr_name}: Succeeded"
        return 0
        ;;
      False)
        echo "PipelineRun ${pr_name}: Failed (${reason})"
        oc logs -n "${NAMESPACE}" -l "tekton.dev/pipelineRun=${pr_name}" --tail=-1 --prefix || true
        return 1
        ;;
    esac

    sleep 5
    waited=$(( waited + 5 ))
    [[ "${waited}" -ge "${timeout}" ]] && {
      echo "Timed out waiting for PipelineRun ${pr_name}"
      oc get pipelinerun,taskrun -n "${NAMESPACE}" || true
      return 1
    }
  done
}

wait_for_blue_running() {
  local deadline=$(( $(date +%s) + 600 ))

  log "Waiting for blue VM to be Running"
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

wait_for_lb_ip() {
  local deadline=$(( $(date +%s) + 300 ))

  log "Waiting for LoadBalancer IP"
  until LB_IP=$(oc get svc demo-app-lb -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) && [[ -n "${LB_IP}" ]]; do
    [[ "$(date +%s)" -gt "${deadline}" ]] && {
      echo "Timed out waiting for demo-app-lb external IP"
      oc get svc demo-app-lb -n "${NAMESPACE}" || true
      return 1
    }
    sleep 5
  done
  echo "LoadBalancer IP: ${LB_IP}"
}

assert_green_uses_blue_snapshot() {
  local vm_snapshot="$1"
  local expected_snapshot
  local source_name source_namespace parameter_name parameter_namespace

  expected_snapshot=$(oc get virtualmachinesnapshot "${vm_snapshot}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.virtualMachineSnapshotContentName}' | \
    xargs -I{} oc get virtualmachinesnapshotcontent {} -n "${NAMESPACE}" \
      -o jsonpath='{.status.volumeSnapshotStatus[0].volumeSnapshotName}')

  log "Asserting green VM uses rootdisk VolumeSnapshot ${expected_snapshot} from ${vm_snapshot}"
  parameter_name=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
    -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.diskSnapshot.name")].value}')
  parameter_namespace=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
    -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.diskSnapshot.namespace")].value}')
  source_name=$(oc get vm demo-vm-green -n "${NAMESPACE}" \
    -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.snapshot.name}')
  source_namespace=$(oc get vm demo-vm-green -n "${NAMESPACE}" \
    -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.snapshot.namespace}')

  [[ "${parameter_name}" == "${expected_snapshot}" ]] || {
    echo "Expected ArgoCD green.diskSnapshot.name=${expected_snapshot}, got ${parameter_name}"
    return 1
  }
  [[ "${parameter_namespace}" == "${NAMESPACE}" ]] || {
    echo "Expected ArgoCD green.diskSnapshot.namespace=${NAMESPACE}, got ${parameter_namespace}"
    return 1
  }
  [[ "${source_name}" == "${expected_snapshot}" ]] || {
    echo "Expected green VM snapshot name=${expected_snapshot}, got ${source_name}"
    return 1
  }
  [[ "${source_namespace}" == "${NAMESPACE}" ]] || {
    echo "Expected green VM snapshot namespace=${NAMESPACE}, got ${source_namespace}"
    return 1
  }

  echo "Green VM disk source is snapshot ${source_namespace}/${source_name}"
}

patch_vm_demo_parameters() {
  local parameters_json="$1"
  run oc patch application.argoproj.io vm-demo -n "${NAMESPACE}" --type=merge \
    --patch "{\"spec\":{\"source\":{\"helm\":{\"parameters\":${parameters_json}}}}}"
}

log "Pre-flight reset"
oc patch application.argoproj.io vm-demo -n "${NAMESPACE}" --type=merge \
  -p '{"spec":{"source":{"helm":{"parameters":null}}}}' >/dev/null 2>&1 || true
set_app_version "v1.0"
commit_and_push_if_changed "chore: reset demo state to v1.0 before test flow" \
  "${DEMO_DIR}/pipelines/app-version.yaml"

log "Setup namespace and secrets"
run oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
run oc create secret generic vm-ssh-key \
  --from-file=id_rsa="${SSH_PRIVATE_KEY}" \
  --namespace="${NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -

PUB_KEY=$(cat "${SSH_PUBLIC_KEY}")
cloud_init_file=$(mktemp)
trap 'rm -f "${cloud_init_file}"' EXIT
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
run oc create secret generic vm-cloud-init \
  --from-file=userdata="${cloud_init_file}" \
  --namespace="${NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -

log "Verify existing MetalLB pool"
run oc get ipaddresspool "${METALLB_POOL}" -n metallb-system

log "Apply ArgoCD configuration"
run oc patch argocd openshift-gitops -n "${ARGOCD_NS}" \
  --type=merge \
  -p "{\"spec\":{\"sourceNamespaces\":[\"${NAMESPACE}\"]}}"
run oc apply -f "${DEMO_ROOT}/argocd/appproject.yaml"
run oc apply -f "${DEMO_ROOT}/argocd/rbac.yaml"
run oc apply -f "${DEMO_ROOT}/argocd/application.yaml" -n "${NAMESPACE}"
run oc apply -f "${DEMO_ROOT}/argocd/application-infra.yaml" -n "${NAMESPACE}"

wait_argo_git "vm-demo"
sync_argo_git "vm-demo-infra"
wait_for_blue_running
wait_for_lb_ip

log "Install application v1.0 on blue"
INSTALL_PR=$(oc create -f "${DEMO_ROOT}/pipelines/install-pipelinerun.yaml" -n "${NAMESPACE}" -o name)
INSTALL_PR_NAME=${INSTALL_PR##*/}
echo "Created ${INSTALL_PR}"
wait_for_pr "${INSTALL_PR_NAME}"
run curl -fsS "http://${LB_IP}/"

log "Bump app version to v2.0 and sync pipeline infra"
set_app_version "v2.0"
commit_and_push_if_changed "bump app version to v2.0" \
  "${DEMO_DIR}/pipelines/app-version.yaml"
sync_argo_git "vm-demo-infra"

log "Run blue/green upgrade pipeline"
UPGRADE_PR=$(oc create -f "${DEMO_ROOT}/pipelines/upgrade-pipelinerun.yaml" -n "${NAMESPACE}" -o name)
UPGRADE_PR_NAME=${UPGRADE_PR##*/}
EXPECTED_SNAPSHOT="blue-pre-upgrade-${UPGRADE_PR_NAME}"
echo "Created ${UPGRADE_PR}"
wait_for_pr "${UPGRADE_PR_NAME}"
assert_green_uses_blue_snapshot "${EXPECTED_SNAPSHOT}"

run oc get vm,vmi -n "${NAMESPACE}"
run oc get svc demo-app-lb -n "${NAMESPACE}" -o jsonpath='{.spec.selector}{"\n"}'
run curl -fsS "http://${LB_IP}/"

log "Rollback using ArgoCD parameter patches"
ROLLBACK_GREEN_SNAPSHOT_NAME=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
  -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.diskSnapshot.name")].value}' 2>/dev/null || true)
ROLLBACK_GREEN_SNAPSHOT_NS=$(oc get application.argoproj.io vm-demo -n "${NAMESPACE}" \
  -o jsonpath='{.spec.source.helm.parameters[?(@.name=="green.diskSnapshot.namespace")].value}' 2>/dev/null || true)
ROLLBACK_GREEN_SNAPSHOT_NAME=${ROLLBACK_GREEN_SNAPSHOT_NAME:-centos-stream10-8a1243274fb1}
ROLLBACK_GREEN_SNAPSHOT_NS=${ROLLBACK_GREEN_SNAPSHOT_NS:-openshift-virtualization-os-images}

patch_vm_demo_parameters "[
  {\"name\":\"blue.runStrategy\",\"value\":\"Always\"},
  {\"name\":\"green.runStrategy\",\"value\":\"Always\"},
  {\"name\":\"green.diskSnapshot.name\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NAME}\"},
  {\"name\":\"green.diskSnapshot.namespace\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NS}\"},
  {\"name\":\"traffic.activeSlot\",\"value\":\"green\"}
]"
sync_argo "vm-demo"
until oc get vmi demo-vm-blue -n "${NAMESPACE}" >/dev/null 2>&1; do sleep 3; done
run oc wait vmi demo-vm-blue -n "${NAMESPACE}" --for=condition=Ready --timeout=120s

patch_vm_demo_parameters "[
  {\"name\":\"blue.runStrategy\",\"value\":\"Always\"},
  {\"name\":\"green.runStrategy\",\"value\":\"Halted\"},
  {\"name\":\"green.diskSnapshot.name\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NAME}\"},
  {\"name\":\"green.diskSnapshot.namespace\",\"value\":\"${ROLLBACK_GREEN_SNAPSHOT_NS}\"},
  {\"name\":\"traffic.activeSlot\",\"value\":\"blue\"}
]"
sync_argo "vm-demo"

run oc delete vm demo-vm-green -n "${NAMESPACE}" --ignore-not-found --wait=false
run oc delete datavolume centos10-green -n "${NAMESPACE}" --ignore-not-found --wait=false
run oc delete pvc centos10-green -n "${NAMESPACE}" --ignore-not-found --wait=false
patch_vm_demo_parameters "null"
sync_argo "vm-demo"

run oc get vm,vmi -n "${NAMESPACE}"
run oc get svc demo-app-lb -n "${NAMESPACE}" -o jsonpath='{.spec.selector}{"\n"}'
run curl -fsS "http://${LB_IP}/"

log "End-to-end flow completed successfully"
