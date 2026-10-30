#!/usr/bin/env bash
set -euo pipefail
: "${NAMESPACE:?Set NAMESPACE to the dedicated demo namespace}"
case ${1:-} in
  provision|configure|bootstrap) pipeline="orders-$1" ;;
  *) echo 'Usage: run.sh provision|configure|bootstrap' >&2; exit 2 ;;
esac
run=$(cat <<YAML | oc create -n "$NAMESPACE" -f - -o name
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ${pipeline}-
spec:
  pipelineRef:
    name: ${pipeline}
  taskRunTemplate:
    serviceAccountName: orders-vm-bootstrap
YAML
)
printf 'Created %s in %s\n' "$run" "$NAMESPACE"
printf 'Logs: oc logs -n %s -l tekton.dev/pipelineRun=%s --all-containers\n' "$NAMESPACE" "${run#*/}"
for ((attempt=0; attempt<600; attempt++)); do
  status=$(oc get -n "$NAMESPACE" "$run" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
  case "$status" in
    True) printf 'Pipeline succeeded.\n'; exit 0 ;;
    False) oc describe -n "$NAMESPACE" "$run"; exit 1 ;;
  esac
  sleep 5
done
printf 'Timed out waiting for %s; inspect the PipelineRun.\n' "$run" >&2
exit 1
