#!/usr/bin/env bash
# Build the demo application and stage public artifacts on a namespace-internal service.
set -euo pipefail
AUTOMATION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEMO_DIR=$(cd "$AUTOMATION_DIR/.." && pwd)
: "${NAMESPACE:?Set NAMESPACE to the demo namespace}"
: "${PRIVATE_DIR:?Set PRIVATE_DIR to a private directory}"
VM_ARCH=${VM_ARCH:-amd64}
for tool in go npm tar oc ruby; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
umask 077
mkdir -p "$PRIVATE_DIR/artifacts"
(
  cd "$DEMO_DIR/frontend"
  [[ -d node_modules ]] || npm ci --no-fund --no-audit
  npm run build
  COPYFILE_DISABLE=1 tar -czf "$PRIVATE_DIR/artifacts/frontend.tar.gz" server.js dist
)
(
  cd "$DEMO_DIR/backend"
  GOOS=linux GOARCH="$VM_ARCH" CGO_ENABLED=0 go build -o "$PRIVATE_DIR/artifacts/orders-api" .
)
cp "$DEMO_DIR/db/schema.sql" "$PRIVATE_DIR/artifacts/schema.sql"
oc -n "$NAMESPACE" apply -f "$AUTOMATION_DIR/artifact-server.yaml"
oc -n "$NAMESPACE" rollout status deployment/orders-artifacts --timeout=5m
pod=$(oc -n "$NAMESPACE" get pod -l app=orders-artifacts -o jsonpath='{.items[0].metadata.name}')
[[ -n "$pod" ]] || { echo 'Artifact server pod was not found' >&2; exit 1; }
oc -n "$NAMESPACE" cp "$PRIVATE_DIR/artifacts/." "$pod:/artifacts"
ARTIFACT_NAMESPACE="$NAMESPACE" ARTIFACT_DIR="$PRIVATE_DIR/artifacts" ruby -rdigest -e '
  dir=ENV.fetch("ARTIFACT_DIR"); base="http://orders-artifacts.#{ENV.fetch("ARTIFACT_NAMESPACE")}.svc:8080"
  {"api"=>"orders-api", "frontend"=>"frontend.tar.gz", "schema"=>"schema.sql"}.each do |name,file|
    puts "#{name}: #{base}/#{file} sha256:#{Digest::SHA256.file("#{dir}/#{file}").hexdigest}"
  end
'
