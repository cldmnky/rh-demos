#!/usr/bin/env bash
# Presenter segment for the Dev Spaces OpenShift CLI terminal.
set -eo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$DEMO_DIR/.." && pwd)
cd "$DEMO_DIR"
if ! command -v pv >/dev/null; then set -- -d "$@"; fi
. "$REPO_ROOT/scripts/demo-magic.sh"
. "$REPO_ROOT/scripts/helpers.sh"
NAMESPACE=${NAMESPACE:-rocket-ramen}
export NAMESPACE
oc -n "$NAMESPACE" get pipeline orders-build-containers >/dev/null

act 1 'Build the edited application with Tekton'
pe './modernization/run-pipeline.sh'
pe 'oc -n "$NAMESPACE" get pipelineruns'

act 2 'Apply the container workloads'
pe 'cat modernization/workloads.yaml'
pe 'API_IMAGE=$(oc -n "$NAMESPACE" get istag/orders-api-container:demo -o jsonpath="{.image.dockerImageReference}")'
pe 'WEB_IMAGE=$(oc -n "$NAMESPACE" get istag/orders-web-container:demo -o jsonpath="{.image.dockerImageReference}")'
for image in "$API_IMAGE" "$WEB_IMAGE"; do
  [[ $image =~ ^[a-zA-Z0-9._:/-]+@sha256:[a-f0-9]{64}$ ]] || { echo 'Expected built image digests.' >&2; exit 1; }
done
pe 'sed -e "s|DEMO_API_IMAGE|$API_IMAGE|g" -e "s|DEMO_WEB_IMAGE|$WEB_IMAGE|g" modernization/workloads.yaml | oc -n "$NAMESPACE" apply -f -'
pe './modernization/deploy.sh'
pe 'oc -n "$NAMESPACE" get builds,deploy,rollout'
say 'The containers are ready beside the VMs. Return to the local presenter terminal for traffic and database cutover.'
