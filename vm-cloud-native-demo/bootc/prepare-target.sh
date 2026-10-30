#!/usr/bin/env bash
# Prepare a bootc VM without attaching the legacy data disk or changing traffic.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
[[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
[[ -f "$SSH_KEY.pub" ]] || { echo 'Missing automation SSH key.' >&2; exit 1; }
[[ $(oc -n "$NAMESPACE" get dv orders-bootc-root -o jsonpath='{.status.phase}') == Succeeded ]] || { echo 'Bootc root import is not ready.' >&2; exit 1; }
[[ -z $(oc -n "$NAMESPACE" get vm orders-db-bootc --ignore-not-found -o name) ]] || { echo 'Target VM exists; inspect it rather than replacing it.' >&2; exit 1; }
key="$PRIVATE_DIR/host-db-bootc"
umask 077
if [[ ! -f "$key" && ! -f "$key.pub" ]]; then
  [[ -z $(oc -n "$NAMESPACE" get secret orders-db-bootc-cloudinit --ignore-not-found -o name) ]] || { echo 'Target host key is missing; refusing to replace it.' >&2; exit 1; }
  ssh-keygen -q -t ed25519 -N '' -f "$key"
fi
[[ -f "$key" && -f "$key.pub" ]] || { echo 'Incomplete target host key.' >&2; exit 1; }
export PRIVATE_DIR SSH_KEY
ruby -ryaml -e '
 dir=ENV.fetch("PRIVATE_DIR"); keys=[File.read(ENV.fetch("SSH_KEY")+".pub").strip]
 values=YAML.load_file("#{dir}/values.yaml"); presenter=values.dig("vm","presenterPublicKey").to_s.strip
 unless presenter.empty?
   abort "Invalid presenter public key" unless presenter.match?(/\Assh-ed25519 [A-Za-z0-9+\/=]+(?: [^\r\n]*)?\z/)
   keys << presenter
 end
 data={"users"=>[{"name"=>"demo-automation","groups"=>["wheel"],"sudo"=>"ALL=(ALL) NOPASSWD:ALL","shell"=>"/bin/bash","ssh_authorized_keys"=>keys}],"ssh_pwauth"=>false,"ssh_keys"=>{"ed25519_private"=>File.read("#{dir}/host-db-bootc"),"ed25519_public"=>File.read("#{dir}/host-db-bootc.pub").strip}}
 File.write("#{dir}/db-bootc-userdata", "#cloud-config\n"+YAML.dump(data).sub(/\A---\s*\n/, ""), perm:0600)
'
awk '{print "orders-db-bootc " $1 " " $2}' "$key.pub" > "$PRIVATE_DIR/db-bootc-known_hosts"
if [[ -n $(oc -n "$NAMESPACE" get secret orders-db-bootc-cloudinit --ignore-not-found -o name) ]]; then
  actual=$(oc -n "$NAMESPACE" get secret orders-db-bootc-cloudinit -o json | ruby -rjson -rbase64 -rdigest -e 'print Digest::SHA256.hexdigest(Base64.strict_decode64(JSON.parse(STDIN.read).fetch("data").fetch("userdata")))')
  expected=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$PRIVATE_DIR/db-bootc-userdata")
  [[ "$actual" == "$expected" ]] || { echo 'Target cloud-init Secret does not match; refusing to rotate.' >&2; exit 1; }
else
  oc -n "$NAMESPACE" create secret generic orders-db-bootc-cloudinit --from-file="userdata=$PRIVATE_DIR/db-bootc-userdata"
fi
cat <<'YAML' | oc -n "$NAMESPACE" create -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: orders-db-bootc
spec:
  runStrategy: Always
  template:
    metadata:
      labels: {app: orders-db-bootc}
    spec:
      domain:
        cpu: {cores: 2}
        memory: {guest: 2Gi}
        devices:
          disks:
            - {name: rootdisk, disk: {bus: virtio}}
            - {name: cloudinit, disk: {bus: virtio}}
          interfaces:
            - {name: default, masquerade: {}}
      networks:
        - {name: default, pod: {}}
      volumes:
        - {name: rootdisk, persistentVolumeClaim: {claimName: orders-bootc-root}}
        - {name: cloudinit, cloudInitNoCloud: {secretRef: {name: orders-db-bootc-cloudinit}}}
---
apiVersion: v1
kind: Service
metadata:
  name: orders-db-bootc
spec:
  selector: {vm.kubevirt.io/name: orders-db-bootc}
  ports:
    - {name: ssh, port: 22, targetPort: 22}
    - {name: mysql, port: 3306, targetPort: 3306}
YAML
oc -n "$NAMESPACE" wait --for=condition=Ready vm/orders-db-bootc --timeout=15m
printf 'Bootc target VM is ready; database disk and traffic have not been changed.\n'
