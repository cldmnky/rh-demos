#!/usr/bin/env ruby
# Offline only. All oc subprocesses below are fixture executables, never the real CLI.
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'json'
root = File.expand_path('..', __dir__)
def assert(value, message)
  abort "FAIL: #{message}" unless value
end
def run(*args, **options)
  Open3.capture3(*args, **options)
end
Dir[File.join(root, 'scripts', '*.sh')].each do |path|
  _, err, status = run('bash', '-n', path)
  assert(status.success?, "shell syntax #{File.basename(path)}: #{err}")
end
blocks = 0
Dir[File.join(root, 'docs', '**', '*.md')].each do |path|
  text = File.read(path)
  text.scan(/\]\(([^\s)]+)\)/).flatten.each do |link|
    next if link.match?(/\A(?:https?:|mailto:|#)/)
    assert(File.exist?(File.expand_path(link.split('#').first, File.dirname(path))), "local link #{path}: #{link}")
  end
  text.scan(/^```bash\n(.*?)^```/m).flatten.each do |code|
    _, err, status = run('bash', '-n', stdin_data: code)
    assert(status.success?, "doc shell syntax: #{err}")
    blocks += 1
  end
end
chart = File.join(root, 'scripts', 'charts', 'prereqs')
%w[image-set virtualization-operator virtualization-config].each do |phase|
  out, err, status = run('helm', 'template', 'fixture', chart, '-n', 'fixture', '--set-string', "phase=#{phase},imageSet=fixture,releaseImage=registry.example.invalid/release:fixture")
  assert(status.success?, "phase #{phase}: #{err}")
  assert(YAML.load_stream(out).compact.all? { |o| o['kind'] && o.dig('metadata', 'name') }, 'Helm objects')
end
_, _, status = run('helm', 'template', 'fixture', chart, '--set', 'phase=credentials')
assert(!status.success?, 'credential creation must reject missing storage approval/private input')
Dir.mktmpdir('acm-offline-') do |dir|
  bin = File.join(dir, 'bin'); values = File.join(dir, 'values')
  FileUtils.mkdir_p([bin, values])
  log = File.join(dir, 'oc.log')
  File.write(File.join(bin, 'oc'), <<~'MOCK')
    #!/usr/bin/env ruby
    require 'json'
    File.open(ENV.fetch('FIXTURE_LOG'), 'a') { |f| f.puts JSON.dump(ARGV) }
    if ARGV.include?('config')
      print ARGV.include?('current-context') ? 'fixture-context' : 'https://fixture.invalid:6443'
    elsif ARGV.include?('whoami')
      puts 'https://fixture.invalid:6443'
    else
      warn 'Fixture denies cluster access'
      exit 1
    end
  MOCK
  File.chmod(0755, File.join(bin, 'oc'))
  envfile = File.join(dir, 'demo.env')
  names = { 'HUB_CONTEXT'=>'fixture', 'HUB_API'=>'https://fixture.invalid:6443',
    'PROD_CLUSTER'=>'fixture-prod', 'QA_CLUSTER'=>'fixture-qa', 'AGENT_CLUSTER'=>'fixture-qa',
    'ZTP_CLUSTER'=>'fixture-site', 'ZTP_VM'=>'fixture-vm', 'IMAGE_SET'=>'fixture-image',
    'DEMO_VALUES_DIR'=>values }
  File.write(envfile, names.map { |k,v| "#{k}=#{v.inspect}\n" }.join + "NOT_ALLOWLISTED='fixture-private-marker'\n")
  env = { 'PATH'=>"#{bin}:#{ENV.fetch('PATH')}", 'DEMO_ENV_FILE'=>envfile, 'FIXTURE_LOG'=>log }
  script = File.join(root, 'scripts', 'demo-shell.sh')
  command = 'source "$1" --prereqs --non-interactive && [[ $PROD_CLUSTER == fixture-prod && ${NOT_ALLOWLISTED-unset} == unset ]]'
  out, err, status = run(env, 'bash', '-c', command, 'bash', script)
  assert(status.success?, "source initializer: #{err}")
  assert(!out.include?('fixture-private-marker'), 'no private marker in output')
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  assert(calls.all? { |args| args.include?('config') }, 'initializer uses only local config reads')
  _, _, status = run(env, 'bash', script)
  assert(!status.success?, 'executed initializer must ask to be sourced')
  File.write(File.join(values,'prereqs.local.yaml'), YAML.dump({
    'credentials'=>{'name'=>'aws','namespace'=>'default'},
    'production'=>{'region'=>'region-a'},'qa'=>{'region'=>'region-b'},
    'ztp'=>{'components'=>['ztp-target','ztp-site']}
  }))
  %w[assisted-service kubevirtbmc].each { |name| File.write(File.join(values,"#{name}.local.yaml"), "{}\n") }
  File.write(File.join(values,'ztp-target.local.yaml'), "name: fixture-site\nvmName: fixture-vm\n")
  File.write(File.join(values,'ztp-site.local.yaml'), "name: fixture-site\nholdInstallation: false\n")
  command = 'source "$1" --prereqs --non-interactive >/dev/null && "$2" --check'
  _, _, status = run(env, 'bash', '-c', command, 'bash', script, File.join(root,'scripts','prereqs.sh'))
  assert(!status.success?, 'API failures must stop read-only prereqs check')
  calls = File.readlines(log).map { |line| JSON.parse(line) }
  assert(calls.none? { |args| (args & %w[apply create patch delete edit]).any? }, 'check mode cannot mutate')
  _, _, status = run(env, 'ruby', File.join(root,'scripts','shared-settings.rb'), 'hco','fixture','fixture')
  assert(!status.success?, 'shared settings require explicit approval token')
end
# Ignore matching does not create files or access their contents.
%w[config/demo.env config/session.local.env values/prereqs.local.yaml private/fixture.kubeconfig rendered/fixture.yaml].each do |relative|
  _, _, status = run('git', '-C', root, 'check-ignore', '-q', '--no-index', relative)
  assert(status.success?, "private path ignored: #{relative}")
end
%w[config/demo.env.example values/ztp-site.example.yaml scripts/charts/prereqs/Chart.yaml docs/setup.md].each do |relative|
  _, _, status = run('git', '-C', root, 'check-ignore', '-q', '--no-index', relative)
  assert(!status.success?, "public artifact must not be ignored: #{relative}")
end
puts "PASS: script syntax, #{blocks} doc shell blocks, local links, phase renders, shell initialization, fail-closed check mode, and ignore rules."
puts 'NOT TESTED: live prerequisite installation, credential lookup/copy, operator readiness, cloud provisioning, unattended ZTP, or application transitions.'
