#!/usr/bin/env ruby
# Configure optional agent infrastructure without modifying the demo workloads.
require 'json'
require 'yaml'
require 'open3'
require 'securerandom'
require 'tempfile'

mode = ARGV.fetch(0, '--check')
abort 'Usage: ruby agentic.rb [--check|--apply]' unless %w[--check --apply].include?(mode)
context, status = Open3.capture2('oc', 'config', 'current-context')
abort 'Cannot determine oc context' unless status.success?
OC = ['oc', '--context', context.strip, '--request-timeout=20s'].freeze
def run(*args, input: nil)
  output, error, status = Open3.capture3(*args, stdin_data: input.to_s)
  abort "#{args.first} failed: #{error.strip}" unless status.success?
  output
end
def get(*args)
  JSON.parse(run(*OC, 'get', *args, '-o', 'json'))
end
def secret(namespace, name)
  data = run(*OC, '-n', namespace, 'get', 'secret', name, '--ignore-not-found', '-o', 'json')
  data.empty? ? nil : JSON.parse(data)
end
def save_key(namespace, data, mount: false, workspace: nil)
  name = 'rocket-ramen-agent-llm-key'
  existing = secret(namespace, name)
  if existing && existing.dig('metadata', 'labels', 'app.kubernetes.io/part-of') != 'rocket-ramen-agentic-prereqs'
    abort "Unrelated #{namespace}/#{name} exists; refusing to overwrite it"
  end
  metadata = {'name' => name, 'namespace' => namespace, 'labels' => {'app.kubernetes.io/part-of' => 'rocket-ramen-agentic-prereqs'}}
  if mount
    metadata['labels']['controller.devfile.io/mount-to-devworkspace'] = 'true'
    metadata['labels']['controller.devfile.io/watch-secret'] = 'true'
    metadata['annotations'] = {
      'controller.devfile.io/mount-as' => 'file',
      'controller.devfile.io/mount-path' => '/etc/rocket-ramen-agent-key',
      'controller.devfile.io/mount-to-devworkspace-include' => workspace,
      'controller.devfile.io/mount-on-start' => 'true'
    }
  end
  metadata['resourceVersion'] = existing.dig('metadata', 'resourceVersion') if existing
  object = {apiVersion: 'v1', kind: 'Secret', type: 'Opaque', metadata: metadata, data: data}
  # Do not place credentials in arguments, temp files or last-applied annotations.
  run(*OC, existing ? 'replace' : 'create', '-f', '-', input: JSON.generate(object))
end

ols_namespace = ENV.fetch('OLS_NAMESPACE', 'openshift-lightspeed')
demo_namespace = ENV.fetch('NAMESPACE', 'rocket-ramen')
workspace_name = ENV.fetch('DEVSPACE_NAME', 'rocket-ramen')
workspace_namespace = ENV['DEVSPACE_NAMESPACE']
if workspace_namespace.to_s.empty?
  user = run(*OC, 'whoami').strip
  abort 'Set DEVSPACE_NAMESPACE for a service-account login' if user.start_with?('system:')
  workspace_namespace = user.downcase.gsub(/[^a-z0-9]/, '-').gsub(/-+/, '-').sub(/^-/, '').sub(/-$/, '')[0, 40] + '-devspaces'
end
[ols_namespace, demo_namespace, workspace_namespace, workspace_name].each do |name|
  abort 'Invalid namespace or workspace name' unless name.match?(/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/)
end
ols = get('olsconfig', 'cluster')
spec = ols.fetch('spec')
provider = spec.fetch('llm').fetch('providers').find { |p| p['name'] == spec.dig('ols', 'defaultProvider') }
abort 'This integration expects the existing Azure OpenAI provider' unless provider && provider['type'] == 'azure_openai'
credential_name = provider.fetch('credentialsSecretRef').fetch('name')
keys = run(*OC, '-n', ols_namespace, 'get', 'secret', credential_name, '-o', 'go-template={{range $k,$v := .data}}{{printf "%s\n" $k}}{{end}}').lines.map(&:strip)
abort 'Azure provider must have client_id, client_secret and tenant_id credentials' unless %w[client_id client_secret tenant_id].all? { |key| keys.include?(key) }
workspace_json = run(*OC, 'get', 'devworkspace', workspace_name, '-n', workspace_namespace, '--ignore-not-found', '-o', 'json')
if workspace_json.empty?
  if ENV['AGENTIC_ALLOW_MISSING_WORKSPACE'] == 'true'
    puts "Agent prerequisites deferred: initialize #{workspace_namespace}/#{workspace_name}, then run ruby prereqs/scripts/agentic.rb --apply."
    exit 0
  end
  abort "Initialize Dev Spaces workspace #{workspace_namespace}/#{workspace_name} before configuring agent access"
end
workspace = JSON.parse(workspace_json)
workspace_id = workspace.dig('status', 'devworkspaceId')
abort 'Workspace must have been started once to establish its service account' if workspace_id.to_s.empty?
get('serviceaccount', "#{workspace_id}-sa", '-n', workspace_namespace)
get('namespace', demo_namespace)
puts "Context: #{context.strip}"
puts "Lightspeed provider: #{provider.fetch('name')} / #{spec.dig('ols', 'defaultModel')} (deployment #{provider.fetch('deploymentName')})"
puts "Built-in MCP introspection: #{spec.dig('ols', 'introspectionEnabled')}"
puts "Workspace: #{workspace_namespace}/#{workspace_name} (#{workspace.dig('status', 'phase')})"
if mode == '--check'
  run(*OC, '-n', ols_namespace, 'get', 'deploy/rocket-ramen-agent-llm', '--ignore-not-found').then { |s| puts s unless s.empty? }
  exit 0
end

# Retain the provider and every unrelated OLS setting. Do not add a duplicate MCP
# server or a legacy feature gate: the shipped server is already operator-managed.
patch = {spec: {ols: {introspectionEnabled: true, toolsApprovalConfig: {approvalType: 'tool_annotations', approvalTimeout: 600}}}}
run(*OC, 'patch', 'olsconfig', 'cluster', '--type=merge', '-p', JSON.generate(patch))

source = secret(ols_namespace, 'rocket-ramen-agent-llm-key')
if source
  abort 'Unrelated LLM key secret exists' unless source.dig('metadata', 'labels', 'app.kubernetes.io/part-of') == 'rocket-ramen-agentic-prereqs'
  key_data = source.fetch('data')
else
  require 'base64'
  key_data = {'apikey' => Base64.strict_encode64('sk-' + SecureRandom.hex(32))}
  save_key(ols_namespace, key_data)
end
save_key(workspace_namespace, key_data, mount: true, workspace: workspace_name)
values = {
  'workspaceNamespace' => workspace_namespace, 'workspaceName' => workspace_name,
  'workspaceId' => workspace_id, 'demoNamespace' => demo_namespace,
  'provider' => {'url' => provider.fetch('url'), 'deployment' => provider.fetch('deploymentName'),
                 'credentialsSecret' => credential_name, 'apiVersion' => provider.fetch('apiVersion', '2024-10-21')}
}
chart = File.expand_path('../agentic/chart', __dir__)
Tempfile.create(['rocket-ramen-agentic-', '.yaml']) do |file|
  file.chmod(0600)
  file.write(YAML.dump(values))
  file.flush
  puts run('helm', '--kube-context', context.strip, 'upgrade', '--install', 'rocket-ramen-agentic-prereqs', chart,
           '-n', ols_namespace, '-f', file.path, '--wait', '--timeout', '10m')
end
puts 'Agent prerequisites configured. Azure credentials remain in the Lightspeed namespace.'
puts 'Start/restart the workspace to mount the agent configuration, then in its node container:'
puts '  bash /etc/rocket-ramen-agent/agent.sh'
puts 'The launcher uses the workspace service account; no presenter token is copied.'
