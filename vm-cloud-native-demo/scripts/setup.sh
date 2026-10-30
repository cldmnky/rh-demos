#!/usr/bin/env bash
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-vm-cloud-native}
command -v oc >/dev/null
command -v helm >/dev/null
oc whoami >/dev/null
"$DEMO_DIR/scripts/sync-sources.sh"
helm upgrade --install vm-cloud-native "$DEMO_DIR/chart" --namespace "$NAMESPACE" --create-namespace --set web.enabled=false,web.active=false,app.enabled=false,app.active=false "$@"
run=$(cat <<'YAML' | oc create -n "$NAMESPACE" -f - -o name
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: provision-orders-
spec:
  pipelineRef:
    name: provision-orders
  taskRunTemplate:
    serviceAccountName: vm-provisioner
YAML
)
printf 'Created %s in %s\n' "$run" "$NAMESPACE"
printf 'Inspect: oc -n %q describe %q\n' "$NAMESPACE" "$run"
oc wait -n "$NAMESPACE" --for=condition=Succeeded "$run" --timeout=25m
printf 'VMs are ready. Guest package installation can take longer; run scripts/verify.sh.\n'
