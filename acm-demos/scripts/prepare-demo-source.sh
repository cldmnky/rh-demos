#!/usr/bin/env bash
# Prepare a lab-only Git/Helm source. Default: offline summary. --apply mutates hub.
# Commits exist ONLY in a disposable temp repo; no pushes or changes to the real repo.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib.sh"
demo_require DEMO_ROOT DEMO_VALUES_DIR SOURCE_NS SOURCE_RELEASE SOURCE_BUNDLE
mode=${1:---render}
[[ $# -le 1 && ( $mode == --render || $mode == --apply ) ]] || { echo 'Usage: prepare-demo-source.sh [--render|--apply]' >&2; exit 1; }
values="$DEMO_VALUES_DIR/demo-source.local.yaml"
[[ -f $values ]] || { echo 'Missing demo-source.local.yaml' >&2; exit 1; }
ruby -ryaml -e 'v=YAML.load_file(ARGV[0]); abort "bundleConfigMap must match SOURCE_BUNDLE" unless v["bundleConfigMap"]==ARGV[1]' "$values" "$SOURCE_BUNDLE"
if [[ $mode == --apply ]]; then
  demo_identity HUB
  demo_confirm "$SOURCE_RELEASE/$SOURCE_NS"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/acm-demo-source.XXXXXXXX")
trap 'rm -r "$work"' EXIT
mkdir -p "$work/work/acm-demos/charts" "$work/content/charts" "$work/bundle-chart/templates"
cp -R "$DEMO_ROOT/charts/demo-app" "$work/work/acm-demos/charts/demo-app"
cp "$DEMO_ROOT/charts/demo-source/files/server.py" "$work/content/server.py"
git -C "$work/work" -c core.hooksPath=/dev/null init -b demo >/dev/null
git -C "$work/work" -c core.hooksPath=/dev/null add acm-demos/charts/demo-app
git -C "$work/work" -c core.hooksPath=/dev/null -c user.name='ACM Demo' -c user.email='demo@example.invalid' commit --no-gpg-sign -m 'Prepare demo chart' >/dev/null
git clone --quiet --bare "$work/work" "$work/content/git"
git --git-dir="$work/content/git" update-server-info
helm package "$DEMO_ROOT/charts/demo-app" -d "$work/content/charts" >/dev/null
helm package "$DEMO_ROOT/charts/demo-app" --version 0.2.0 --app-version 2.0.0 -d "$work/content/charts" >/dev/null
# Relative package URLs work through either the service DNS or the actual Route.
helm repo index "$work/content/charts"
tar -C "$work/content" -czf "$work/source.tgz" .
[[ $(wc -c < "$work/source.tgz") -lt 750000 ]] || { echo 'Bundle too large for this ConfigMap-based lab source.' >&2; exit 1; }
printf 'apiVersion: v2\nname: demo-source-bundle\nversion: 0.1.0\n' > "$work/bundle-chart/Chart.yaml"
cat > "$work/bundle-chart/templates/bundle.yaml" <<'TEMPLATE'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace }}
binaryData:
  source.tgz: {{ .Values.bundle | b64enc | quote }}
TEMPLATE
if [[ $mode == --render ]]; then
  helm template "$SOURCE_RELEASE" "$DEMO_ROOT/charts/demo-source" -n "$SOURCE_NS" -f "$values" |
    ruby -ryaml -e 'YAML.load_stream(STDIN.read).compact.each { |o| puts [o["kind"], o.dig("metadata", "name")].join("\t") }'
  printf '%s\n' 'Prepared temporary Git/Helm bundle. No cluster changes, real-repo commits, or pushes.'
  exit 0
fi
demo_helm upgrade --install "$SOURCE_RELEASE-bundle" "$work/bundle-chart" -n "$SOURCE_NS" \
  --create-namespace --set-string "name=$SOURCE_BUNDLE" --set-file "bundle=$work/source.tgz" --wait --timeout 2m
demo_helm upgrade --install "$SOURCE_RELEASE" "$DEMO_ROOT/charts/demo-source" -n "$SOURCE_NS" -f "$values" --wait --timeout 5m
# Existing server reads its bundle at startup, so refresh it after a bundle update.
demo_oc HUB rollout restart "deployment/$SOURCE_RELEASE" -n "$SOURCE_NS"
demo_oc HUB rollout status "deployment/$SOURCE_RELEASE" -n "$SOURCE_NS" --timeout=120s
demo_oc HUB get route "$SOURCE_RELEASE" -n "$SOURCE_NS"
