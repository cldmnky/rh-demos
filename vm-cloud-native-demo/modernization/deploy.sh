#!/usr/bin/env bash
# Apply the staged container workloads; does not route user traffic to them.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
[[ $NAMESPACE =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid namespace' >&2; exit 1; }
api_image=$(oc -n "$NAMESPACE" get istag/orders-api-container:demo -o jsonpath='{.image.dockerImageReference}')
web_image=$(oc -n "$NAMESPACE" get istag/orders-web-container:demo -o jsonpath='{.image.dockerImageReference}')
for image in "$api_image" "$web_image"; do
  [[ $image =~ ^[a-zA-Z0-9._:/-]+@sha256:[a-f0-9]{64}$ ]] || { echo 'Expected a built image with a SHA-256 digest.' >&2; exit 1; }
done
sed -e "s|DEMO_API_IMAGE|$api_image|g" -e "s|DEMO_WEB_IMAGE|$web_image|g" "$DEMO_DIR/modernization/workloads.yaml" | oc -n "$NAMESPACE" apply -f -
oc -n "$NAMESPACE" rollout status deployment/orders-api-container --timeout=5m
for ((attempt=0; attempt<60; attempt++)); do
  state=$(oc -n "$NAMESPACE" get rollout orders-web-container -o jsonpath='{.metadata.generation} {.status.observedGeneration} {.status.phase} {.status.availableReplicas}')
  read -r generation observed phase available <<< "$state"
  [[ "$generation" == "$observed" && "$phase" == Healthy && ${available:-0} -ge 2 ]] && { echo 'Frontend Rollout is ready.'; exit 0; }
  sleep 5
done
echo 'Frontend Rollout did not become ready; inspect its pods and RolloutManager.' >&2
exit 1
