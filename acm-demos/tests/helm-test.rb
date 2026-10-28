#!/usr/bin/env ruby
# Offline tests. All Helm calls are local lint/template; never server dry-runs.
require 'yaml'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)
def check(condition, message)
  abort "FAIL: #{message}" unless condition
end
def helm(*args, success: true)
  out, err, status = Open3.capture3('helm', *args)
  check(status.success? == success, "helm #{args.join(' ')}: #{err}")
  out
end
def render(chart, namespace, *args)
  YAML.load_stream(helm('template', 'test', "charts/#{chart}", '-n', namespace, *args)).compact
end

fixtures = {
  'aws-sno' => ['cluster2-sno', '-f', 'values/cluster2-sno.example.yaml'],
  'governance' => ['acm-demo-policies'],
  'demo-app' => ['acm-demo-argo'],
  'delivery' => ['openshift-gitops', '-f', 'values/push.example.yaml'],
  'bootstrap' => ['openshift-operators', '--set', 'gitopsOperator.enabled=true'],
  'agent-principal' => ['acm-agent-hub'],
  'demo-source' => ['acm-demo-sources'],
  'ztp-target' => ['ztp-sno', '-f', 'values/ztp-target.example.yaml', '--set', 'prerequisitesAcknowledged=true,rebootPolicySupported=true'],
  'ztp-site' => ['ztp-sno', '-f', 'values/ztp-site.example.yaml', '--set', 'prerequisitesAcknowledged=true,labBmcTransportAccepted=true'],
  'ztp-endpoints' => ['ztp-sno'],
  'ztp-boot-transition' => ['ztp-sno'],
  'ztp-network' => ['ztp-network-check', '--set', 'subnet=10.254.230.0/24'],
  'ztp-dns' => ['ztp-network-check', '--set', 'clusterDomain=ztp-sno.example.invalid,apiAddress=10.254.230.100,ingressAddress=10.254.230.101,upstream=172.231.0.10'],
  'assisted-service' => ['multicluster-engine', '-f', 'values/assisted-service.example.yaml', '--set', 'prerequisitesAcknowledged=true']
}
fixtures.each do |chart, args|
  namespace, *values = args
  helm('lint', "charts/#{chart}", '--strict', '-n', namespace, *values)
  objects = render(chart, namespace, *values)
  check(!objects.empty?, "#{chart} renders resources")
  check(objects.all? { |o| o['apiVersion'] && o['kind'] && o.dig('metadata', 'name') }, "#{chart} object structure")
end

sno = render('aws-sno', 'cluster2-sno', '-f', 'values/cluster2-sno.example.yaml')
check(sno.none? { |o| o['kind'] == 'Secret' }, 'reference-only render must never include credentials')
check(sno.none? { |o| o.dig('metadata', 'name') == 'cluster1' }, 'console-owned cluster1 excluded')
cd = sno.find { |o| o['kind'] == 'ClusterDeployment' }
check(cd.dig('spec', 'platform', 'aws', 'region') == 'us-west-2', 'QA AWS region')
check(cd.dig('metadata', 'annotations', 'helm.sh/resource-policy') == 'keep', 'infrastructure keep annotation')
addon = sno.find { |o| o['kind'] == 'KlusterletAddonConfig' }
check(!addon['spec'].key?('configPolicyController'), 'ACM 2.17 KlusterletAddonConfig rejects configPolicyController')
helm('template', 'test', 'charts/aws-sno', '-n', 'wrong', '-f', 'values/cluster2-sno.example.yaml', success: false)
helm('template', 'test', 'charts/aws-sno', '-n', 'cluster1', '-f', 'values/cluster2-sno.example.yaml', '--set', 'clusterName=cluster1', success: false)
helm('template', 'test', 'charts/aws-sno', '-n', 'cluster2-sno', success: false)
helm('template', 'test', 'charts/aws-sno', '-n', 'cluster2-sno', '-f', 'values/cluster2-sno.example.yaml', '--set', 'credentials.copyFromHub=true', success: false)
helm('template', 'test', 'charts/aws-sno', '-n', 'cluster2-sno', '-f', 'values/cluster2-sno.example.yaml', '--set', 'credentials.copyFromHub=true,credentials.acceptReleaseSecretStorage=true', success: false)

%w[inform enforce].each do |action|
  objects = render('governance', 'acm-demo-policies', '-f', "values/governance-#{action}.yaml")
  policy = objects.find { |o| o['kind'] == 'Policy' }
  check(!policy['spec'].key?('remediationAction'), 'single remediation owner')
  child = policy['spec']['policy-templates'][0]['objectDefinition']['spec']
  check(child['remediationAction'] == action, "#{action} policy mode")
  templates = child['object-templates']
  check(templates[1]['objectDefinition']['metadata']['namespace'] == 'acm-demo-baseline', 'dedicated target namespace')
  placement = objects.find { |o| o['kind'] == 'Placement' }
  selector = placement['spec']['predicates'][0]['requiredClusterSelector']['labelSelector']
  check(selector['matchLabels']['demo.redhat.com/enabled'] == 'true', 'explicit demo opt-in selector')
  check(selector['matchExpressions'][0]['values'] == ['true'], 'hub exclusion')
end

gitops_policy = render('governance', 'acm-demo-policies', '--set', 'gitops.enabled=true,gitops.agentNamespace=acm-demo-agent')
check(gitops_policy.any? { |o| o['kind'] == 'Policy' && o.dig('metadata', 'name').include?('gitops') }, 'GitOps operator policy renders')

v1 = render('demo-app', 'acm-demo-argo')
v2 = render('demo-app', 'acm-demo-argo', '-f', 'values/app-v2.yaml')
checksum = lambda { |docs| docs.find { |o| o['kind'] == 'Deployment' }.dig('spec', 'template', 'metadata', 'annotations', 'checksum/content') }
check(checksum.call(v1) != checksum.call(v2), 'content update triggers pod rollout even with subPath mount')
check(v2.find { |o| o['kind'] == 'ConfigMap' }['data']['index.html'].include?('v2.0.0'), 'v2 content')
check(v1.find { |o| o['kind'] == 'Deployment' }.dig('spec', 'template', 'spec', 'containers', 0, 'image') !~ /:latest$/, 'no latest tag')

push = render('delivery', 'openshift-gitops', '-f', 'values/push.example.yaml')
appset = push.find { |o| o['kind'] == 'ApplicationSet' }
check(appset.dig('spec', 'template', 'spec', 'source', 'helm', 'releaseName') == 'acm-demo-app', 'Argo renders Helm chart')
check(push.any? { |o| o['kind'] == 'ConfigMap' && o.dig('data', 'matchKey') == 'clusterName' }, 'decision generator configuration exists')
helm('template', 'test', 'charts/delivery', '-n', 'acm-agent-hub', '-f', 'values/agent.example.yaml', success: false)
agent = render('delivery', 'acm-agent-hub', '-f', 'values/agent.example.yaml', '--set', 'agent.platformReady=true,agent.serverAddress=principal.example.invalid')
check(agent.find { |o| o['kind'] == 'GitOpsCluster' }.dig('spec', 'gitopsAddon', 'argoCDAgent', 'mode') == 'managed', 'agent mode')
scoped_agent = render('delivery', 'acm-agent-hub', '-f', 'values/agent.example.yaml', '--set', 'agent.platformReady=true,agent.serverAddress=principal.example.invalid,applicationSetServiceAccount=agent-principal-applicationset-controller')
binding = scoped_agent.find { |o| o['kind'] == 'RoleBinding' }
check(binding.dig('subjects', 0, 'name') == 'agent-principal-applicationset-controller', 'custom ApplicationSet service account receives scoped placement access')
sub = render('delivery', 'acm-demo-subscription', '-f', 'values/subscription.example.yaml')
check(sub.find { |o| o['kind'] == 'Channel' }.dig('spec', 'type') == 'HelmRepo', 'subscription uses packaged Helm chart')
check(sub.find { |o| o['kind'] == 'Subscription' }.dig('spec', 'packageFilter', 'version') == '0.1.0', 'subscription chart pin')

# ZTP: bootstrap substrate and site intent have different controller ownership.
%w[ztp-target ztp-site assisted-service].each do |chart|
  helm('template', 'test', "charts/#{chart}", '-n', 'ztp-sno', success: false)
end
target = render('ztp-target', 'ztp-sno', '-f', 'values/ztp-target.example.yaml', '--set', 'prerequisitesAcknowledged=true,rebootPolicySupported=true')
vm = target.find { |o| o['kind'] == 'VirtualMachine' }
check(vm.dig('spec', 'runStrategy') == 'Halted', 'VM cannot boot before BMC workflow')
check(vm.dig('spec', 'template', 'spec', 'domain', 'rebootPolicy') == 'Terminate', 'ISO-to-disk reboot requires reviewed policy')
check(vm.dig('spec', 'template', 'spec', 'networks', 0, 'multus', 'networkName'), 'explicit secondary network, never masquerade fallback')
check(vm.dig('spec', 'template', 'spec', 'domain', 'devices', 'disks', 0, 'bootOrder') == 1, 'disk is the normal boot target')
bmc = target.find { |o| o['kind'] == 'VirtualMachineBMC' }
check(bmc.dig('metadata', 'annotations', 'bmc.kubevirt.io/datavolume-size-margin') == '50', 'virtual media includes scratch-space margin')
check(bmc.dig('spec', 'ipmi', 'enabled') == false, 'IPMI disabled')
check(bmc.dig('spec', 'service', 'type') == 'ClusterIP', 'BMC not exposed externally')
check(bmc.dig('spec', 'redfish', 'virtualMedia', 'storage', 'volumeMode') == 'Block', 'v0.11 nested virtual-media storage path')
check(target.none? { |o| o['kind'] == 'Secret' }, 'no credentials in ZTP render')
udn = render('ztp-network', 'ztp-network-check', '--set', 'subnet=10.254.230.0/24').first
check(udn.dig('spec', 'layer2', 'role') == 'Primary' && udn.dig('spec', 'layer2', 'ipam', 'lifecycle') == 'Persistent', 'primary UDN has persistent addressing')
udn_vm = render('ztp-target', 'ztp-sno', '-f', 'values/ztp-target.example.yaml', '--set', 'prerequisitesAcknowledged=true,rebootPolicySupported=true,networkMode=udn').find { |o| o['kind'] == 'VirtualMachine' }
check(udn_vm.dig('spec', 'template', 'spec', 'domain', 'devices', 'interfaces', 0, 'binding', 'name') == 'l2bridge', 'primary UDN uses l2bridge binding')
check(udn_vm.dig('spec', 'template', 'spec', 'networks', 0, 'pod') == {}, 'primary UDN uses the pod network attachment')
udn_dns_vm = render('ztp-target', 'ztp-sno', '-f', 'values/ztp-target.example.yaml', '--set', 'prerequisitesAcknowledged=true,rebootPolicySupported=true,networkMode=udn,podDNSServers[0]=172.231.10.199').find { |o| o['kind'] == 'VirtualMachine' }
check(udn_dns_vm.dig('spec', 'template', 'spec', 'dnsConfig', 'nameservers') == ['172.231.10.199'], 'UDN VM accepts explicit pod DNS configuration')
dns = render('ztp-dns', 'ztp-network-check', '--set', 'clusterDomain=ztp-sno.example.invalid,apiAddress=10.254.230.100,ingressAddress=10.254.230.101,upstream=172.231.0.10')
zone = dns.find { |o| o['kind'] == 'ConfigMap' }.dig('data', 'site.zone')
check(zone.include?('api IN A 10.254.230.100') && zone.include?('*.apps IN A 10.254.230.101'), 'site DNS uses explicit API and ingress addresses')
check(dns.find { |o| o['kind'] == 'Service' }.dig('spec', 'ports').map { |p| p['protocol'] }.sort == %w[TCP UDP], 'DNS service exposes TCP and UDP')
dns_v2 = render('ztp-dns', 'ztp-network-check', '--set', 'clusterDomain=ztp-sno.example.invalid,apiAddress=10.254.230.102,ingressAddress=10.254.230.101,upstream=172.231.0.10')
dns_checksum = ->(docs) { docs.find { |o| o['kind'] == 'Deployment' }.dig('spec', 'template', 'metadata', 'annotations', 'checksum/config') }
check(dns_checksum.call(dns) != dns_checksum.call(dns_v2), 'DNS endpoint changes trigger rollout')
dhcp_site = render('ztp-site', 'ztp-sno', '-f', 'values/ztp-site.example.yaml', '--set', 'prerequisitesAcknowledged=true,labBmcTransportAccepted=true,node.networkMode=dhcp')
check(!dhcp_site.first.dig('spec', 'nodes', 0).key?('nodeNetwork'), 'DHCP site does not generate an empty NMStateConfig')
helm('template', 'test', 'charts/ztp-target', '-n', 'ztp-sno', '-f', 'values/ztp-target.example.yaml', '--set', 'prerequisitesAcknowledged=true', success: false)
helm('template', 'test', 'charts/ztp-target', '-n', 'ztp-sno', '-f', 'values/ztp-target.example.yaml', '--set', 'prerequisitesAcknowledged=true,rebootPolicySupported=true,networkAttachment=', success: false)
site = render('ztp-site', 'ztp-sno', '-f', 'values/ztp-site.example.yaml', '--set', 'prerequisitesAcknowledged=true,labBmcTransportAccepted=true')
check(site.length == 1 && site[0]['kind'] == 'ClusterInstance', 'SiteConfig exclusively owns rendered install resources')
check(site[0].dig('spec', 'holdInstallation') == true, 'OS installation held by default')
check(site[0].dig('spec', 'nodes', 0, 'templateRefs', 0, 'name') == 'ai-node-templates-v1', 'node template reference present')
check(site[0].dig('spec', 'nodes', 0, 'bootMACAddress') == vm.dig('spec', 'template', 'spec', 'domain', 'devices', 'interfaces', 0, 'macAddress'), 'VM/discovery MAC matches')
helm('template', 'test', 'charts/ztp-site', '-n', 'ztp-sno', '-f', 'values/ztp-site.example.yaml', '--set', 'prerequisitesAcknowledged=true', success: false)

# Shell safety failure paths: missing identity, wrong identity, and old cleanup flag.
%w[preflight verify].each do |script|
  _, _, status = Open3.capture3({ 'HUB_CONTEXT' => nil, 'HUB_API' => nil }, 'bash', "scripts/#{script}.sh")
  check(!status.success?, "#{script} must require explicit identity")
end
Dir.mktmpdir('acm-oc-fixture-') do |dir|
  oc = File.join(dir, 'oc')
  File.write(oc, "#!/bin/sh\nprintf '%s' 'https://wrong.example.invalid:6443'\n")
  File.chmod(0755, oc)
  env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'HUB_CONTEXT' => 'fixture', 'HUB_API' => 'https://expected.example.invalid:6443' }
  %w[preflight verify].each do |script|
    _, _, status = Open3.capture3(env, 'bash', "scripts/#{script}.sh")
    check(!status.success?, "#{script} must reject wrong identity")
  end
end
_, _, reset = Open3.capture3('bash', 'scripts/reset.sh', '--confirm')
check(!reset.success?, 'old reset confirmation must not delete resources')

# Validate local Markdown links, excluding explicit URL fragments.
Dir['**/*.md'].each do |path|
  File.read(path).scan(/\]\(([^\s)]+)\)/).flatten.each do |link|
    next if link.start_with?('http:', 'https:', '#', 'mailto:')
    check(File.exist?(File.expand_path(link.split('#')[0], File.dirname(path))), "broken link in #{path}: #{link}")
  end
end
puts 'PASS: fourteen charts lint/render, ZTP network/DNS/boot gates, policy isolation, app checksum, delivery, and local links.'
puts 'NOT TESTED: live admission, BMC virtual media/reboot, ZTP/AWS installation, credential copy, application runtime, or agent connectivity.'
