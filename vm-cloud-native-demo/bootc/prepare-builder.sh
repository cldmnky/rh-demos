#!/usr/bin/env bash
# Provision a separate RHEL build VM and configure it through Tekton + Ansible.
set -euo pipefail
DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
if [[ -z ${SSH_KEY+x} ]]; then
  SSH_KEY="$HOME/.ssh/rh-demos"
  [[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
fi
VALUES="$PRIVATE_DIR/values.yaml"
[[ -f "$VALUES" && -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]] || { echo 'Run scripts/setup.sh first with the same PRIVATE_DIR and SSH_KEY.' >&2; exit 1; }
for tool in oc ruby ssh-keygen; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
export NAMESPACE PRIVATE_DIR SSH_KEY VALUES
private_real=$(cd "$PRIVATE_DIR" && pwd -P)
repo_real=$(cd "$DEMO_DIR/.." && pwd -P)
case "$private_real/" in "$repo_real/"*) echo 'PRIVATE_DIR must be outside the repository.' >&2; exit 1;; esac
umask 077
chmod 700 "$PRIVATE_DIR"
existing=$(oc -n "$NAMESPACE" get vm orders-builder --ignore-not-found -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')
if [[ -n $(oc -n "$NAMESPACE" get vm orders-builder --ignore-not-found -o name) && "$existing" != rocket-ramen-builder ]]; then
  echo 'An unrelated orders-builder VM exists; refusing to change it.' >&2; exit 1
fi
key="$PRIVATE_DIR/host-builder"
if [[ ! -f "$key" && ! -f "$key.pub" ]]; then
  [[ -z $(oc -n "$NAMESPACE" get secret orders-builder-cloudinit --ignore-not-found -o name) ]] || { echo 'Builder host key missing from private directory; refusing to replace it.' >&2; exit 1; }
  ssh-keygen -q -t ed25519 -N '' -f "$key"
fi
[[ -f "$key" && -f "$key.pub" ]] || { echo 'Incomplete builder host key.' >&2; exit 1; }
ruby -ryaml -e '
  dir=ENV.fetch("PRIVATE_DIR"); v=YAML.load_file(ENV.fetch("VALUES")); keys=[File.read(ENV.fetch("SSH_KEY")+".pub").strip]
  presenter=v.dig("vm","presenterPublicKey").to_s.strip
  unless presenter.empty?
    abort "Invalid presenter public key" unless presenter.match?(/\Assh-ed25519 [A-Za-z0-9+\/=]+(?: [^\r\n]*)?\z/)
    keys << presenter
  end
  data={"users"=>[{"name"=>"demo-automation","groups"=>["wheel"],"sudo"=>"ALL=(ALL) NOPASSWD:ALL","shell"=>"/bin/bash","ssh_authorized_keys"=>keys}],"ssh_pwauth"=>false,"ssh_keys"=>{"ed25519_private"=>File.read("#{dir}/host-builder"),"ed25519_public"=>File.read("#{dir}/host-builder.pub").strip}}
  File.write("#{dir}/builder-userdata", "#cloud-config\n"+YAML.dump(data).sub(/\A---\s*\n/, ""), perm:0600)
'
awk '{print "orders-builder " $1 " " $2}' "$key.pub" > "$PRIVATE_DIR/builder-known_hosts"
check_secret() {
  local secret=$1 field=$2 file=$3 actual expected
  expected=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$file")
  actual=$(oc -n "$NAMESPACE" get secret "$secret" -o json | ruby -rjson -rbase64 -rdigest -e 'print Digest::SHA256.hexdigest(Base64.strict_decode64(JSON.parse(STDIN.read).fetch("data").fetch(ARGV.fetch(0))))' "$field")
  [[ "$expected" == "$actual" ]] || { echo "Existing $secret does not match private setup files; refusing to rotate it." >&2; exit 1; }
}
if [[ -z $(oc -n "$NAMESPACE" get secret orders-builder-cloudinit --ignore-not-found -o name) ]]; then
  oc -n "$NAMESPACE" create secret generic orders-builder-cloudinit --from-file="userdata=$PRIVATE_DIR/builder-userdata"
else
  check_secret orders-builder-cloudinit userdata "$PRIVATE_DIR/builder-userdata"
fi
if [[ -z $(oc -n "$NAMESPACE" get secret orders-builder-ssh --ignore-not-found -o name) ]]; then
  oc -n "$NAMESPACE" create secret generic orders-builder-ssh --from-file="id_rsa=$SSH_KEY" --from-file="known_hosts=$PRIVATE_DIR/builder-known_hosts"
else
  check_secret orders-builder-ssh id_rsa "$SSH_KEY"
  check_secret orders-builder-ssh known_hosts "$PRIVATE_DIR/builder-known_hosts"
fi
oc -n "$NAMESPACE" get secret orders-rhsm >/dev/null
oc -n "$NAMESPACE" create configmap orders-builder-ansible --from-file="$DEMO_DIR/bootc/builder/inventory.yml" --from-file="$DEMO_DIR/bootc/builder/setup.yml" --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
# Match the original boot DataSource and storage class; do not alter application VMs.
ruby -ryaml -rjson -e '
  v=YAML.load_file(ENV.fetch("VALUES")); cfg=v.fetch("vm"); ns=ENV.fetch("NAMESPACE")
  storage={"resources"=>{"requests"=>{"storage"=>"40Gi"}}}; storage["storageClassName"]=cfg["storageClass"] unless cfg["storageClass"].to_s.empty?
  vm={"apiVersion"=>"kubevirt.io/v1","kind"=>"VirtualMachine","metadata"=>{"name"=>"orders-builder","namespace"=>ns,"labels"=>{"app.kubernetes.io/part-of"=>"rocket-ramen-builder"}},"spec"=>{"runStrategy"=>"Always","dataVolumeTemplates"=>[{"metadata"=>{"name"=>"orders-builder-root"},"spec"=>{"sourceRef"=>{"kind"=>"DataSource","name"=>cfg.fetch("sourceName"),"namespace"=>cfg.fetch("sourceNamespace")},"storage"=>storage}}],"template"=>{"metadata"=>{"labels"=>{"app"=>"orders-builder"}},"spec"=>{"domain"=>{"cpu"=>{"cores"=>4},"memory"=>{"guest"=>"4Gi"},"devices"=>{"disks"=>[{"name"=>"rootdisk","disk"=>{"bus"=>"virtio"}},{"name"=>"cloudinit","disk"=>{"bus"=>"virtio"}}],"interfaces"=>[{"name"=>"default","masquerade"=>{}}]}},"networks"=>[{"name"=>"default","pod"=>{}}],"volumes"=>[{"name"=>"rootdisk","dataVolume"=>{"name"=>"orders-builder-root"}},{"name"=>"cloudinit","cloudInitNoCloud"=>{"secretRef"=>{"name"=>"orders-builder-cloudinit"}}}]}}}}
  service={"apiVersion"=>"v1","kind"=>"Service","metadata"=>{"name"=>"orders-builder","namespace"=>ns},"spec"=>{"selector"=>{"vm.kubevirt.io/name"=>"orders-builder"},"ports"=>[{"name"=>"ssh","port"=>22,"targetPort"=>22}]}}
  puts JSON.generate({"apiVersion"=>"v1","kind"=>"List","items"=>[vm,service]})
' | oc -n "$NAMESPACE" apply -f -
image=$(ruby -ryaml -e 'print YAML.load_file(ARGV.fetch(0)).dig("images","ansible")' "$VALUES")
[[ "$image" =~ ^[a-zA-Z0-9._:/@-]+$ ]] || { echo 'Invalid Ansible image in private values.' >&2; exit 1; }
sed "s|BUILDER_ANSIBLE_IMAGE|$image|g" "$DEMO_DIR/bootc/builder/pipeline.yaml" | oc -n "$NAMESPACE" apply -f -
oc -n "$NAMESPACE" wait --for=condition=Ready vm/orders-builder --timeout=15m
"$DEMO_DIR/automation/scripts/run.sh" builder
printf 'Builder VM ready; use it to build bootc OCI and QCOW2 artifacts.\n'
