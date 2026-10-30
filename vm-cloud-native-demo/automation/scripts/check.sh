#!/usr/bin/env bash
set -euo pipefail
AUTOMATION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helm lint "$AUTOMATION_DIR/chart" --set-string vm.sshPublicKey='ssh-ed25519 AAAA test' --set-string images.ansible=example/ansible:test
helm template test "$AUTOMATION_DIR/chart" --set-string vm.sshPublicKey='ssh-ed25519 AAAA test' --set-string images.ansible=example/ansible:test | ruby -ryaml -e '
  docs = YAML.load_stream(STDIN.read).compact
  secret = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "orders-bootstrap-cloudinit" }
  YAML.safe_load(secret.fetch("stringData").fetch("userdata"))
  vms = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "orders-vm-definitions" }
  abort "expected three VMs" unless vms.fetch("data").length == 3
  vms.fetch("data").each_value { |content| abort "not a VM" unless YAML.safe_load(content)["kind"] == "VirtualMachine" }
  puts "Rendered resources and embedded VM/cloud-init YAML parsed"
'
ANSIBLE_LOCAL_TEMP="${TMPDIR:-/tmp}/orders-ansible-check" ansible-playbook -i "$AUTOMATION_DIR/chart/files/ansible/inventory.yml" "$AUTOMATION_DIR/chart/files/ansible/site.yml" --syntax-check
bash -n "$AUTOMATION_DIR"/scripts/*.sh
