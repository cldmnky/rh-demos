#!/usr/bin/env bash
set -eo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$DEMO_DIR/.." && pwd)
cd "$DEMO_DIR"
if ! command -v pv >/dev/null; then set -- -d "$@"; fi
. "$REPO_ROOT/scripts/demo-magic.sh"
. "$REPO_ROOT/scripts/helpers.sh"
NAMESPACE=${NAMESPACE:-rocket-ramen}
export NAMESPACE
HOST=$(oc get route orders -n "$NAMESPACE" -o jsonpath='{.spec.host}')
export HOST

act 1 'A familiar three-tier application'
p '# In the browser: open Rocket Ramen, place an order, and point out the VM badges.'
pe 'oc get vm orders-web orders-app orders-db -n "$NAMESPACE"'
pe 'oc get pipelineruns -n "$NAMESPACE" | grep orders-bootstrap'
pe 'cat automation/chart/files/ansible/api.yml'
p '# Switch to Dev Spaces: show the source, devfile and Containerfiles.'

act 2 'Build the containers in Dev Spaces'
p '# In the node terminal: ./scripts/build-frontend.sh'
p '# In the OpenShift CLI terminal: ./modernization/build.sh api && ./modernization/build.sh web'
p '# Apply from the workspace: ./modernization/deploy.sh'
p '# These are OpenShift binary builds from the workspace; no container daemon is needed in Dev Spaces.'
pe 'oc get builds,deploy,rollout -n "$NAMESPACE"'
pe 'cat modernization/workloads.yaml'

act 3 'Run VMs and containers side by side'
pe './modernization/traffic.sh api container'
pe './modernization/traffic.sh web 50'
pe 'oc set route-backends orders -n "$NAMESPACE"'
p '# Refresh the browser or make new connections: the frontend is split between VM and container.'
pe './modernization/traffic.sh web 100'
p '# The VM frontend is still available for rollback; the API and frontend now run as containers.'

act 4 'The database stays a VM, with an image-managed OS'
pe 'cat bootc/Containerfile'
p '# The target bootc VM and its OS disk were prepared before the session.'
pe './bootc/migrate.sh'
pe './bootc/status.sh'
pe './bootc/retire-legacy.sh'
pe 'oc get vm,pods -n "$NAMESPACE"'
say 'We choose the modernization path for each tier, while keeping the application on one platform.'
