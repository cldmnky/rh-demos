#!/usr/bin/env bash
# Upload only application source from this workspace and start the Tekton build.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-pipeline}
[[ $NAMESPACE =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && $SERVICE_ACCOUNT =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid namespace or service account.' >&2; exit 1; }
for tool in oc tar awk; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
active=$(oc -n "$NAMESPACE" get pipelineruns -l app=orders-container-build -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' | awk -F= '$2 != "True" && $2 != "False" {print $1}')
[[ -z "$active" ]] || { echo "Another container build PipelineRun is active: $active" >&2; exit 1; }
staging=$(mktemp -d "${TMPDIR:-/tmp}/rocket-ramen-source.XXXXXXXX")
trap 'rm -rf "$staging"' EXIT
name="container-source-$(basename "$staging" | tr -cd '[:alnum:]').tar.gz"
archive="$staging/$name"
# An explicit allowlist avoids uploading .env files, credentials or node_modules.
COPYFILE_DISABLE=1 tar --format ustar --exclude='.env' --exclude='.env.*' -C "$DEMO_DIR" -czf "$archive" \
  backend/Containerfile backend/go.mod backend/go.sum backend/main.go backend/store.go backend/hub.go \
  frontend/Containerfile frontend/server.js frontend/index.html frontend/package.json frontend/package-lock.json \
  frontend/tsconfig.json frontend/vite.config.ts frontend/src frontend/public
if command -v sha256sum >/dev/null; then
  digest=$(sha256sum "$archive" | awk '{print $1}')
elif command -v shasum >/dev/null; then
  digest=$(shasum -a 256 "$archive" | awk '{print $1}')
else
  echo 'sha256sum or shasum is required.' >&2; exit 1
fi
[[ $name =~ ^container-source-[A-Za-z0-9]+\.tar\.gz$ && $digest =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid source archive or checksum.' >&2; exit 1; }
pod=$(oc -n "$NAMESPACE" get pod -l app=orders-artifacts -o jsonpath='{.items[0].metadata.name}')
[[ -n "$pod" ]] || { echo 'Artifact service pod not found; run setup first.' >&2; exit 1; }
oc -n "$NAMESPACE" cp "$archive" "$pod:/artifacts/$name"
run=$(cat <<YAML | oc -n "$NAMESPACE" create -f - -o name
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: orders-build-containers-
  labels:
    app: orders-container-build
spec:
  pipelineRef:
    name: orders-build-containers
  taskRunTemplate:
    serviceAccountName: $SERVICE_ACCOUNT
  params:
    - name: source-name
      value: $name
    - name: source-sha256
      value: $digest
YAML
)
printf 'Started %s from the current workspace source (SHA-256 %s).\n' "$run" "$digest"
printf 'Inspect in OpenShift Pipelines or: oc -n %s describe %s\n' "$NAMESPACE" "$run"
for ((attempt=0;attempt<480;attempt++)); do
  status=$(oc -n "$NAMESPACE" get "$run" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
  case "$status" in
    True) echo 'Tekton built both container images.'; exit 0 ;;
    False) oc -n "$NAMESPACE" describe "$run"; exit 1 ;;
  esac
  sleep 5
done
echo "Timed out waiting for $run; inspect its TaskRun logs." >&2
exit 1
