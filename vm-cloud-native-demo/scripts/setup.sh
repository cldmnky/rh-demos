#!/usr/bin/env bash
# Prepare the pre-presentation, three-VM baseline. Safe to rerun with the same private directory.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AUTOMATION_DIR="$DEMO_DIR/automation"
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
export NAMESPACE PRIVATE_DIR
umask 077
for tool in oc helm ruby go npm tar ssh-keygen curl python3; do
  command -v "$tool" >/dev/null || { echo "Missing required command: $tool" >&2; exit 1; }
done
oc whoami >/dev/null
printf 'Preparing demo on context %s, namespace %s\n' "$(oc config current-context)" "$NAMESPACE"
mkdir -p "$PRIVATE_DIR"
private_real=$(cd "$PRIVATE_DIR" && pwd -P)
repo_real=$(cd "$DEMO_DIR/.." && pwd -P)
case "$private_real/" in "$repo_real/"*) echo 'PRIVATE_DIR must be outside the repository.' >&2; exit 1;; esac
chmod 700 "$PRIVATE_DIR"

"$DEMO_DIR/prereqs/scripts/prereqs.sh" --apply
if [[ -z $(oc get namespace "$NAMESPACE" --ignore-not-found -o name) ]]; then
  oc create namespace "$NAMESPACE"
fi
# Never adopt unrelated VMs or a pre-existing data disk into a new release.
release=$(helm list -n "$NAMESPACE" -o json | ruby -rjson -e 'puts JSON.parse(STDIN.read).any? { |r| r["name"] == "orders-vm-automation" }')
if [[ "$release" != true ]]; then
  existing=$(oc -n "$NAMESPACE" get vm/orders-db vm/orders-app vm/orders-web pvc/orders-db-data --ignore-not-found -o name)
  [[ -z "$existing" ]] || { echo 'Demo VM or database disk exists without the automation release; refusing to adopt it.' >&2; exit 1; }
fi
if [[ -n $(oc -n "$NAMESPACE" get secret orders-automation-ssh --ignore-not-found -o name) ]]; then
  [[ -f "$PRIVATE_DIR/host-db" && -f "$PRIVATE_DIR/host-app" && -f "$PRIVATE_DIR/host-web" && -f "$PRIVATE_DIR/db-password" ]] || {
    echo "Existing demo secrets found, but private setup files are missing from $PRIVATE_DIR. Set PRIVATE_DIR to the original directory." >&2; exit 1;
  }
fi
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
if [[ ! -f "$SSH_KEY" && ! -f "$SSH_KEY.pub" && "$SSH_KEY" == "$HOME/.ssh/rh-demos" ]]; then
  SSH_KEY="$PRIVATE_DIR/automation-key"
  if [[ ! -f "$SSH_KEY" && ! -f "$SSH_KEY.pub" ]]; then ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"; fi
fi
export SSH_KEY
"$AUTOMATION_DIR/scripts/prepare-rhsm-secret.sh"
"$AUTOMATION_DIR/scripts/prepare-secrets.sh"

# Keep the existing source when rerunning; changing the source of an existing VM is unsafe.
VALUES="$PRIVATE_DIR/values.yaml"
if [[ -f "$VALUES" ]]; then
  SOURCE_NAMESPACE=$(ruby -ryaml -e 'v=YAML.load_file(ARGV[0]); print v.dig("vm","sourceNamespace").to_s' "$VALUES")
  SOURCE_NAME=$(ruby -ryaml -e 'v=YAML.load_file(ARGV[0]); print v.dig("vm","sourceName").to_s' "$VALUES")
else
  [[ "$release" != true ]] || { echo "Existing release requires its original $VALUES." >&2; exit 1; }
  SOURCE_NAMESPACE=${RHEL_SOURCE_NAMESPACE:-openshift-virtualization-os-images}
  SOURCE_NAME=${RHEL_SOURCE_NAME:-rhel10}
fi
source_ready() {
  [[ $(oc -n "$1" get datasource "$2" --ignore-not-found -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]
}
if ! source_ready "$SOURCE_NAMESPACE" "$SOURCE_NAME"; then
  if [[ "$release" == true ]]; then
    echo "Existing VM source $SOURCE_NAMESPACE/$SOURCE_NAME is not ready; refusing to change it." >&2; exit 1
  fi
  if [[ -n ${RHEL_SOURCE_NAMESPACE:-} || -n ${RHEL_SOURCE_NAME:-} ]]; then
    echo "Requested RHEL DataSource $SOURCE_NAMESPACE/$SOURCE_NAME is not ready." >&2; exit 1
  fi
  SOURCE_NAMESPACE=$NAMESPACE SOURCE_NAME=rhel10-demo
  if ! source_ready "$SOURCE_NAMESPACE" "$SOURCE_NAME"; then
    if [[ -z $(oc -n "$NAMESPACE" get secret rhel-registry-auth --ignore-not-found -o name) ]]; then
      # Translate the cluster pull secret to the CDI registry-import credential format.
      oc -n openshift-config get secret pull-secret -o json | NAMESPACE="$NAMESPACE" ruby -rjson -rbase64 -e '
        secret=JSON.parse(STDIN.read); config=JSON.parse(Base64.strict_decode64(secret.fetch("data").fetch(".dockerconfigjson")))
        auth=config.fetch("auths").fetch("registry.redhat.io"); user,pass=Base64.strict_decode64(auth.fetch("auth")).split(":",2)
        abort "Registry pull credentials are missing" if user.to_s.empty? || pass.to_s.empty?
        puts JSON.generate(apiVersion:"v1",kind:"Secret",metadata:{name:"rhel-registry-auth",namespace:ENV.fetch("NAMESPACE")},type:"Opaque",stringData:{accessKeyId:user,secretKey:pass})
      ' | oc -n "$NAMESPACE" create -f -
    fi
    "$AUTOMATION_DIR/scripts/import-rhel10.sh"
  fi
fi
export SOURCE_NAMESPACE SOURCE_NAME
printf 'Using RHEL DataSource %s/%s\n' "$SOURCE_NAMESPACE" "$SOURCE_NAME"
# CDI clones cannot be smaller than their source PVC. Preserve an existing
# installation's root size; on a new installation use the source size.
SOURCE_PVC_NAMESPACE=$(oc -n "$SOURCE_NAMESPACE" get datasource "$SOURCE_NAME" -o jsonpath='{.status.source.pvc.namespace}')
SOURCE_PVC_NAME=$(oc -n "$SOURCE_NAMESPACE" get datasource "$SOURCE_NAME" -o jsonpath='{.status.source.pvc.name}')
[[ -n "$SOURCE_PVC_NAMESPACE" && -n "$SOURCE_PVC_NAME" ]] || { echo 'Ready RHEL DataSource has no PVC source; configure a compatible PVC-backed DataSource.' >&2; exit 1; }
SOURCE_ROOT_SIZE=$(oc -n "$SOURCE_PVC_NAMESPACE" get pvc "$SOURCE_PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
[[ -n "$SOURCE_ROOT_SIZE" ]] || { echo 'Cannot determine RHEL source PVC size.' >&2; exit 1; }
export SOURCE_ROOT_SIZE
"$AUTOMATION_DIR/scripts/prepare-artifacts.sh"
if [[ -n ${ANSIBLE_IMAGE+x} ]]; then export ANSIBLE_IMAGE_OVERRIDE=true; fi
ANSIBLE_IMAGE=${ANSIBLE_IMAGE:-registry.redhat.io/ansible-automation-platform-26/ee-supported-rhel9@sha256:eb29d277b7a7ad59b918ae7635e889599b55b86cad1d84ba8589de66fd48cecd}
export ANSIBLE_IMAGE VALUES
if [[ -n ${PRESENTER_PUBLIC_KEY_FILE:-} ]]; then
  [[ -f "$PRESENTER_PUBLIC_KEY_FILE" ]] || { echo 'Presenter public key file not found.' >&2; exit 1; }
  PRESENTER_PUBLIC_KEY=$(cat "$PRESENTER_PUBLIC_KEY_FILE")
  export PRESENTER_PUBLIC_KEY
fi
# On first install the PVC belongs to this dedicated demo and starts empty. Never
# approve formatting on an existing PVC automatically.
DATA_CLAIM=orders-db-data
if [[ -f "$VALUES" ]]; then
  DATA_CLAIM=$(ruby -ryaml -e 'v=YAML.load_file(ARGV.fetch(0)); print(v.dig("vm","dataClaim") || "orders-db-data")' "$VALUES")
fi
[[ $DATA_CLAIM =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid database PVC name.' >&2; exit 1; }
EXISTING_DISK=$(oc -n "$NAMESPACE" get pvc "$DATA_CLAIM" --ignore-not-found -o name)
if [[ "$DATA_CLAIM" != orders-db-data && -z "$EXISTING_DISK" ]]; then
  echo 'Configured external database PVC does not exist; refusing to initialize a new disk.' >&2; exit 1
fi
export EXISTING_DISK
ruby -ryaml -rdigest -e '
  path=ENV.fetch("VALUES"); v=File.exist?(path) ? YAML.load_file(path) : {}; v ||= {}
  vm=(v["vm"] ||= {}); vm["rootSize"] ||= ENV.fetch("SOURCE_ROOT_SIZE"); vm["sourceNamespace"]=ENV.fetch("SOURCE_NAMESPACE"); vm["sourceName"]=ENV.fetch("SOURCE_NAME")
  vm["presenterPublicKey"]=ENV["PRESENTER_PUBLIC_KEY"].strip if ENV.key?("PRESENTER_PUBLIC_KEY")
  (v["images"] ||= {})["ansible"]=ENV.fetch("ANSIBLE_IMAGE") if !v.dig("images","ansible") || ENV["ANSIBLE_IMAGE_OVERRIDE"] == "true"
  a=(v["artifacts"] ||= {}); dir=ENV.fetch("PRIVATE_DIR")+"/artifacts"; base="http://orders-artifacts.#{ENV.fetch("NAMESPACE")}.svc:8080"
  {"api"=>"orders-api", "frontend"=>"frontend.tar.gz", "schema"=>"schema.sql"}.each { |k,f| a["#{k}Url"]="#{base}/#{f}"; a["#{k}Sha256"]=Digest::SHA256.file("#{dir}/#{f}").hexdigest }
  a["dataFormatApproved"]=ENV.fetch("EXISTING_DISK").empty?
  File.write(path, YAML.dump(v), mode:"w", perm:0600)
'
"$AUTOMATION_DIR/scripts/install.sh" -f "$VALUES"
"$AUTOMATION_DIR/scripts/run.sh" bootstrap
"$DEMO_DIR/scripts/verify.sh"
"$DEMO_DIR/bootc/snapshot-class.sh" >/dev/null
"$DEMO_DIR/modernization/prepare.sh"
"$DEMO_DIR/bootc/prepare.sh"
printf 'Private setup files: %s\n' "$PRIVATE_DIR"
