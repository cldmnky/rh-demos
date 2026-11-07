require 'minitest/autorun'
require 'open3'
require 'yaml'
require 'json'

class AgentPrerequisitesChartTest < Minitest::Test
  def setup
    output, error, status = Open3.capture3('helm', 'template', 'agent-test', File.join(__dir__, 'chart'),
      '-n', 'lightspeed-test', '--set', 'workspaceNamespace=presenter-devspaces',
      '--set', 'workspaceName=demo-workspace', '--set', 'workspaceId=workspace-123',
      '--set', 'demoNamespace=demo-test', '--set', 'provider.url=https://example.openai.azure.com',
      '--set', 'provider.deployment=deployment-test', '--set', 'provider.credentialsSecret=existing-azure')
    assert status.success?, error
    @objects = YAML.load_stream(output).compact
  end

  def find(kind, name)
    @objects.find { |o| o['kind'] == kind && o.dig('metadata', 'name') == name } || flunk("Missing #{kind}/#{name}")
  end

  def test_workspace_mounts_target_the_literal_workspace_name
    %w[rocket-ramen-agent rocket-ramen-agent-ca].each do |name|
      resource = find('ConfigMap', name)
      assert_equal 'presenter-devspaces', resource.dig('metadata', 'namespace')
      annotations = resource.dig('metadata', 'annotations')
      assert_equal 'demo-workspace', annotations['controller.devfile.io/mount-to-devworkspace-include']
      assert_equal 'true', annotations['controller.devfile.io/mount-on-start']
      assert_equal 'true', resource.dig('metadata', 'labels', 'controller.devfile.io/watch-configmap')
    end
  end

  def test_credentials_are_file_references_and_tool_approval_is_required
    config = JSON.parse(find('ConfigMap', 'rocket-ramen-agent').dig('data', 'opencode.json'))
    assert_equal '{file:/etc/rocket-ramen-agent-key/apikey}', config.dig('provider', 'demo', 'options', 'apiKey')
    assert_equal 'Bearer {file:/var/run/secrets/kubernetes.io/serviceaccount/token}', config.dig('mcp', 'openshift', 'headers', 'Authorization')
    assert_equal 'ask', config.dig('permission', '*')
    assert_equal 'disabled', config['share']
    assert config.dig('mcp', 'openshift', 'url').start_with?('https://')
  end

  def test_role_is_namespace_scoped_without_secrets_exec_delete_or_rbac
    refute @objects.any? { |o| %w[ClusterRole ClusterRoleBinding].include?(o['kind']) }
    role = find('Role', 'rocket-ramen-workspace-agent')
    assert_equal 'demo-test', role.dig('metadata', 'namespace')
    role['rules'].each do |rule|
      assert_empty rule['resources'] & %w[secrets pods/exec *]
      refute_includes rule['verbs'], 'delete'
      refute_includes rule['apiGroups'], 'rbac.authorization.k8s.io'
    end
    binding = find('RoleBinding', 'rocket-ramen-workspace-agent')
    assert_equal 'workspace-123-sa', binding['subjects'][0]['name']
    assert_equal 'presenter-devspaces', binding['subjects'][0]['namespace']
  end

  def test_network_policies_require_namespace_and_workspace_together
    @objects.select { |o| o['kind'] == 'NetworkPolicy' }.each do |policy|
      peers = policy.dig('spec', 'ingress', 0, 'from')
      assert_equal 1, peers.size
      assert_equal 'presenter-devspaces', peers[0].dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name')
      assert_equal 'workspace-123', peers[0].dig('podSelector', 'matchLabels', 'controller.devfile.io/devworkspace_id')
    end
    refute @objects.any? { |o| o['kind'] == 'Route' }
  end

  def test_azure_credentials_stay_in_gateway_with_no_kubernetes_token
    pod = find('Deployment', 'rocket-ramen-agent-llm').dig('spec', 'template', 'spec')
    assert_equal false, pod['automountServiceAccountToken']
    assert_match(/@sha256:[a-f0-9]{64}\z/, pod['containers'][0]['image'])
    azure_refs = pod['containers'][0]['env'].select { |e| e['name'].start_with?('AZURE_') }
    assert_equal %w[existing-azure], azure_refs.map { |e| e.dig('valueFrom', 'secretKeyRef', 'name') }.uniq
    refute @objects.any? { |o| %w[Secret OLSConfig].include?(o['kind']) }
  end
end
