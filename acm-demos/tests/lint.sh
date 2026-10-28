#!/usr/bin/env bash
# Offline only. No oc, cloud calls, Helm installation, or server dry-runs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for tool in helm ruby; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
while IFS= read -r script; do bash -n "$script"; done < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh')
if command -v shellcheck >/dev/null; then
  shellcheck "$ROOT"/scripts/*.sh "$ROOT/tests/lint.sh"
else
  echo 'ShellCheck not available; shell syntax checks only.'
fi
ruby -c "$ROOT/tests/helm-test.rb"
ruby "$ROOT/tests/helm-test.rb"
# Report filenames only: never echo possible credential contents.
if grep -rlE --exclude='lint.sh' --exclude-dir=rendered --exclude-dir=private -- '-----BEGIN (RSA |OPENSSH )?PRIVATE KEY-----|AKIA[A-Z0-9]{16}' "$ROOT"; then
  echo 'Potential secret detected. Inspect privately; do not paste its contents.' >&2
  exit 1
fi
