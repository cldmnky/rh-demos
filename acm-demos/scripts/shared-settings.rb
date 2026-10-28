#!/usr/bin/env ruby
# Called only by prereqs.sh --apply after approval. No adoption of MCH/HCO into Helm.
require 'json'
require 'open3'
abort 'Shared-setting mutation requires prereqs.sh --apply approval.' unless ENV['DEMO_SHARED_SETTINGS_APPROVED'] == '1'
kind, namespace, name = ARGV
abort 'Expected hco|siteconfig, namespace, name' unless %w[hco siteconfig].include?(kind) && namespace && name && ARGV.length == 3
context = ENV.fetch('HUB_CONTEXT')
args = ['oc', '--context', context, '--request-timeout=15s']
args += ['--kubeconfig', ENV['HUB_KUBECONFIG']] unless ENV.fetch('HUB_KUBECONFIG', '').empty?
oc = lambda do |*command|
  out, _err, status = Open3.capture3(*args, *command)
  abort 'Cluster operation failed; no automatic retry or fallback.' unless status.success?
  out
end
abort 'Hub API mismatch' unless oc.call('whoami', '--show-server').strip == ENV.fetch('HUB_API')
resource = kind == 'hco' ? 'hyperconverged' : 'multiclusterhub'
object = JSON.parse(oc.call('get', resource, name, '-n', namespace, '-o', 'json'))
patch = [{ 'op' => 'test', 'path' => '/metadata/resourceVersion', 'value' => object.fetch('metadata').fetch('resourceVersion') }]
if kind == 'hco'
  crd = JSON.parse(oc.call('get', 'crd', 'hyperconvergeds.hco.kubevirt.io', '-o', 'json'))
  version = crd.fetch('spec').fetch('versions').find { |v| v['name'] == object.fetch('apiVersion').split('/').last }
  properties = version.dig('schema', 'openAPIV3Schema', 'properties', 'spec', 'properties', 'featureGates', 'items', 'properties')
  abort 'Unsupported HCO feature-gate schema; review operator-owned configuration.' unless properties && properties.key?('state') && properties.dig('state', 'enum').to_a.include?('Enabled')
  list = object.dig('spec', 'featureGates')
  index = (list || []).index { |item| item['name'] == 'declarativeHotplugVolumes' }
  if index
    exit 0 if list[index]['state'] == 'Enabled'
    patch << { 'op' => 'add', 'path' => "/spec/featureGates/#{index}/state", 'value' => 'Enabled' }
  elsif list
    patch << { 'op' => 'add', 'path' => '/spec/featureGates/-', 'value' => { 'name' => 'declarativeHotplugVolumes', 'state' => 'Enabled' } }
  else
    patch << { 'op' => 'add', 'path' => '/spec/featureGates', 'value' => [{ 'name' => 'declarativeHotplugVolumes', 'state' => 'Enabled' }] }
  end
else
  list = object.dig('spec', 'overrides', 'components')
  entry = { 'name' => 'siteconfig', 'enabled' => true }
  index = (list || []).index { |item| item['name'] == 'siteconfig' }
  if index
    exit 0 if list[index]['enabled'] == true
    patch << { 'op' => 'add', 'path' => "/spec/overrides/components/#{index}/enabled", 'value' => true }
  elsif list
    patch << { 'op' => 'add', 'path' => '/spec/overrides/components/-', 'value' => entry }
  elsif object.dig('spec', 'overrides')
    patch << { 'op' => 'add', 'path' => '/spec/overrides/components', 'value' => [entry] }
  else
    patch << { 'op' => 'add', 'path' => '/spec/overrides', 'value' => { 'components' => [entry] } }
  end
end
oc.call('patch', resource, name, '-n', namespace, '--type=json', '-p', JSON.dump(patch))
puts "Enabled approved #{kind} setting; unrelated settings preserved."
