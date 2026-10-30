#!/usr/bin/env bash
# Pre-stage cluster resources without changing live traffic or existing VMs.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
command -v oc >/dev/null
oc whoami >/dev/null
oc -n "$NAMESPACE" get vm orders-web orders-app orders-db >/dev/null
"$DEMO_DIR/modernization/configure-rollouts.sh"
oc -n "$NAMESPACE" apply -f "$DEMO_DIR/modernization/resources.yaml"
printf 'Waiting for the namespace-scoped Rollouts controller...\n'
for ((attempt=0; attempt<90; attempt++)); do
  phase=$(oc -n "$NAMESPACE" get rolloutmanager rocket-ramen -o jsonpath='{.status.phase}')
  [[ "$phase" == Available ]] && break
  [[ $attempt -lt 89 ]] || { echo 'RolloutManager did not become Available; inspect its status and the GitOps operator.' >&2; exit 1; }
  sleep 5
done
printf 'Building the frontend bundle...\n'
"$DEMO_DIR/scripts/build-frontend.sh"
printf 'Starting cluster builds from the current workspace...\n'
"$DEMO_DIR/modernization/build.sh" api
"$DEMO_DIR/modernization/build.sh" web
printf 'Applying container workloads (the existing Route and Services still point at the VMs)...\n'
"$DEMO_DIR/modernization/deploy.sh"
printf 'Container workloads are ready; live traffic still targets the VMs.\n'
