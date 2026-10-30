#!/usr/bin/env bash
set -euo pipefail
AUTOMATION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helm lint "$AUTOMATION_DIR/chart" --set-string images.ansible=example/ansible:test
helm template test "$AUTOMATION_DIR/chart" --set-string images.ansible=example/ansible:test | ruby -ryaml -e '
  docs = YAML.load_stream(STDIN.read).compact
  vms = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "orders-vm-definitions" }
  abort "expected three VMs" unless vms.fetch("data").length == 3
  vms.fetch("data").each do |name, content|
    vm = YAML.safe_load(content)
    abort "not a VM" unless vm["kind"] == "VirtualMachine"
    cloudinit = vm.dig("spec", "template", "spec", "volumes").find { |v| v["name"] == "cloudinit" }
    abort "missing tier cloud-init Secret" unless cloudinit.dig("cloudInitNoCloud", "secretRef", "name") == "orders-#{name.delete_suffix(".yaml")}-cloudinit"
  end
  puts "Rendered resources and embedded VM YAML parsed"
'
ANSIBLE_LOCAL_TEMP="${TMPDIR:-/tmp}/orders-ansible-check" ansible-playbook -i "$AUTOMATION_DIR/chart/files/ansible/inventory.yml" "$AUTOMATION_DIR/chart/files/ansible/site.yml" --syntax-check
bash -n "$AUTOMATION_DIR"/scripts/*.sh
