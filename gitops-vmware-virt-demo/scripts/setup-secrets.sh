#!/usr/bin/env bash
# Creates the secrets required by the vm-demo before running ArgoCD sync / pipelines.
# Run this once per cluster. Safe to re-run (uses --dry-run=client | oc apply).
#
# Usage:
#   ./scripts/setup-secrets.sh [namespace]
#   NAMESPACE=vm-demo ./scripts/setup-secrets.sh
#
# Required files (default paths, override via env vars):
#   SSH_PRIVATE_KEY  - path to deploy key private half  (default: ~/.ssh/rh-demos)
#   SSH_PUBLIC_KEY   - path to deploy key public half   (default: ~/.ssh/rh-demos.pub)

set -euo pipefail

NAMESPACE="${1:-${NAMESPACE:-vm-demo}}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/rh-demos}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/rh-demos.pub}"

if [[ ! -f "$SSH_PRIVATE_KEY" ]]; then
  echo "ERROR: private key not found at $SSH_PRIVATE_KEY" >&2
  exit 1
fi
if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
  echo "ERROR: public key not found at $SSH_PUBLIC_KEY" >&2
  exit 1
fi

echo "Ensuring namespace $NAMESPACE exists..."
oc get namespace "$NAMESPACE" &>/dev/null || oc create namespace "$NAMESPACE"

echo "Creating/updating vm-ssh-key secret (private key for Ansible + GitHub deploy key)..."
oc create secret generic vm-ssh-key \
  --namespace="$NAMESPACE" \
  --from-file=id_rsa="$SSH_PRIVATE_KEY" \
  --dry-run=client -o yaml | oc apply -f -

echo "Creating/updating vm-cloud-init secret (public key injected into VM authorized_keys)..."
PUB_KEY_CONTENT=$(cat "$SSH_PUBLIC_KEY")
oc create secret generic vm-cloud-init \
  --namespace="$NAMESPACE" \
  --from-literal=userdata="#cloud-config
user: cloud-user
password: redhat
chpasswd: { expire: False }
ssh_authorized_keys:
  - ${PUB_KEY_CONTENT}" \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "Done. Secrets created in namespace $NAMESPACE:"
oc get secret vm-ssh-key vm-cloud-init -n "$NAMESPACE"
echo ""
echo "Next steps:"
echo "  1. Add ~/.ssh/rh-demos.pub as a deploy key (with write access) in:"
echo "     https://github.com/cldmnky/rh-demos/settings/keys"
echo "  2. Apply ArgoCD resources: oc apply -f argocd/"
echo "  3. Trigger install: oc create -f pipelines/install-pipelinerun.yaml -n $NAMESPACE"
