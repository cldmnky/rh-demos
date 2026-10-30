#!/usr/bin/env bash
set -euo pipefail
AUTOMATION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${NAMESPACE:?Set NAMESPACE to the dedicated demo namespace}"
if [[ $# -lt 2 || $1 != -f ]]; then
  echo 'Usage: install.sh -f PRIVATE_VALUES.yaml [additional Helm options]' >&2
  exit 2
fi
command -v helm >/dev/null
command -v oc >/dev/null
command -v ruby >/dev/null
oc whoami >/dev/null
helm template orders-vm-automation "$AUTOMATION_DIR/chart" --namespace "$NAMESPACE" "$@" | ruby -ryaml -e '
  docs = YAML.load_stream(STDIN.read).compact
  settings = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "orders-bootstrap-settings" }.fetch("data")
  %w[API_URL FRONTEND_URL SCHEMA_URL].each { |key| abort "#{key} must be an HTTPS URL" unless settings.fetch(key).start_with?("https://") }
  %w[API_SHA256 FRONTEND_SHA256 SCHEMA_SHA256].each { |key| abort "#{key} must be a SHA-256 digest" unless settings.fetch(key).match?(/\A[0-9a-fA-F]{64}\z/) }
'
helm upgrade --install orders-vm-automation "$AUTOMATION_DIR/chart" --namespace "$NAMESPACE" --create-namespace "$@"
printf 'Installed automation. Next run: scripts/run.sh provision, then scripts/run.sh configure.\n'
