#!/usr/bin/env bash
# Starting fleet orchestration. Default --check is read-only. Never run automatically.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/lib.sh"
demo_require DEMO_ROOT DEMO_VALUES_DIR HUB_CONTEXT HUB_API PROD_CLUSTER QA_CLUSTER ZTP_CLUSTER ZTP_VM IMAGE_SET
phase_work=''
trap 'if [[ -n $phase_work ]]; then rm -r "$phase_work"; fi' EXIT
mode=${1:---check}
[[ $# -le 1 && ( $mode == --check || $mode == --apply ) ]] || { echo 'Usage: prereqs.sh [--check|--apply]' >&2; exit 1; }
for tool in oc helm ruby jq; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
values="$DEMO_VALUES_DIR/prereqs.local.yaml"
[[ -f $values ]] || { echo 'Missing prereqs.local.yaml; see docs/setup.md.' >&2; exit 1; }
cfg() { ruby -ryaml -e 'v=ARGV[1].split(".").reduce(YAML.load_file(ARGV[0])){|o,k| o.is_a?(Hash) ? o[k] : nil}; puts(v.nil? ? "" : v)' "$values" "$1"; }
cred_name=$(cfg credentials.name); cred_name=${cred_name:-aws}
cred_ns=$(cfg credentials.namespace); cred_ns=${cred_ns:-default}
virt_ns=$(cfg virtualization.namespace); virt_ns=${virt_ns:-openshift-cnv}
mch_name=$(cfg mch.name); mch_name=${mch_name:-multiclusterhub}
mch_ns=$(cfg mch.namespace); mch_ns=${mch_ns:-open-cluster-management}
wait_time=$(cfg waitTimeout); wait_time=${wait_time:-90m}
wait_seconds=$(ruby -e 'm=ARGV[0].match(/\A([1-9][0-9]*)(s|m|h)\z/); abort "waitTimeout must be a positive duration such as 90m" unless m; puts m[1].to_i * {"s"=>1,"m"=>60,"h"=>3600}.fetch(m[2])' "$wait_time")
for name in "$PROD_CLUSTER" "$QA_CLUSTER" "$ZTP_CLUSTER" "$ZTP_VM"; do
  [[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 63 ]] || { echo 'Cluster/VM names must be DNS labels.' >&2; exit 1; }
done
[[ $PROD_CLUSTER != "$QA_CLUSTER" && $ZTP_CLUSTER != "$PROD_CLUSTER" && $ZTP_CLUSTER != "$QA_CLUSTER" ]] || { echo 'Targets must have distinct names.' >&2; exit 1; }
[[ ${AGENT_CLUSTER:-} == "$PROD_CLUSTER" || ${AGENT_CLUSTER:-} == "$QA_CLUSTER" || ${AGENT_CLUSTER:-} == "$ZTP_CLUSTER" ]] || { echo 'AGENT_CLUSTER must be one of the prepared managed clusters.' >&2; exit 1; }
[[ -n $(cfg production.region) && -n $(cfg qa.region) ]] || { echo 'Both approved AWS regions are required.' >&2; exit 1; }
# Validate local file existence before creating any infrastructure. No values are printed.
for component in assisted-service kubevirtbmc ztp-target ztp-site; do
  [[ -f "$DEMO_VALUES_DIR/$component.local.yaml" ]] || { echo "Missing $component.local.yaml" >&2; exit 1; }
done
components=()
while IFS= read -r component; do
  [[ -n $component ]] || continue
  case $component in ztp-network|ztp-dns-guest|ztp-dns-hub|ztp-endpoints|ztp-target|ztp-boot-transition|ztp-site) ;; *) echo "Unsupported ZTP component: $component" >&2; exit 1 ;; esac
  [[ -f "$DEMO_VALUES_DIR/$component.local.yaml" ]] || { echo "Missing $component.local.yaml" >&2; exit 1; }
  components+=("$component")
done < <(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("ztp","components")' "$values")
[[ ${#components[@]} -gt 0 && ${components[${#components[@]}-1]} == ztp-site ]] || { echo 'ztp.components must list reviewed components with ztp-site last.' >&2; exit 1; }
[[ " ${components[*]} " == *' ztp-target '* ]] || { echo 'ztp.components must include ztp-target.' >&2; exit 1; }
# Cross-check names so no local override silently creates a different environment.
ruby -ryaml -e '
  dir, name, vm = ARGV
  t=YAML.load_file(File.join(dir,"ztp-target.local.yaml")); s=YAML.load_file(File.join(dir,"ztp-site.local.yaml"))
  abort "ZTP values must match ZTP_CLUSTER/ZTP_VM" unless t["name"]==name && s["name"]==name && t["vmName"]==vm
  abort "Complete the precreated site: holdInstallation must be false" unless s["holdInstallation"]==false
' "$DEMO_VALUES_DIR" "$ZTP_CLUSTER" "$ZTP_VM"
demo_identity HUB
missing=0
found() {
  local args=(get "$1" "$2" --ignore-not-found -o name)
  [[ -z ${3:-} ]] || args+=(-n "$3")
  FOUND=$(demo_oc HUB "${args[@]}") || { echo 'Read failed; refusing to treat an API/access error as absence.' >&2; exit 1; }
  [[ -n $FOUND ]]
}
phase() {
  local phase=$1 release=$2 namespace=$3 work result
  shift 3
  work=$(mktemp -d "${TMPDIR:-/tmp}/acm-prereq-values.XXXXXXXX")
  phase_work=$work
  # A private profile may contain cloud/BMC inputs. Never persist that whole
  # profile into unrelated operator/image-set Helm releases.
  if (umask 077; ruby -ryaml -e '
    p=YAML.load_file(ARGV[0]); phase=ARGV[1]
    c=p.fetch("credentials",{}).select{|k,_| %w[name namespace].include?(k)}
    v={"approvals"=>{"credentialStorage"=>p.dig("approvals","credentialStorage")},"credentials"=>c}
    case phase
    when "credentials"; v["credentials"]=p.fetch("credentials")
    when "aws"; v["aws"]=p.fetch("aws",{})
    when "image-set"; v["releaseImage"]=p["releaseImage"]
    when "virtualization-operator"; v["virtualization"]=p.fetch("virtualization",{})
    when "ztp-secrets"; z=p.fetch("ztp"); v["ztp"]=z.select{|k,_| %w[pullSecret bmcSecret bmcCredentials].include?(k)}
    end
    File.write(ARGV[2],YAML.dump(v))
  ' "$values" "$phase" "$work/values.yaml"); then
    if demo_helm upgrade --install "$release" "$DIR/charts/prereqs" -n "$namespace" --create-namespace \
      -f "$work/values.yaml" --set-string "phase=$phase" "$@" --wait --timeout 5m; then result=0; else result=$?; fi
  else result=1; fi
  rm -r "$work"
  phase_work=''
  return "$result"
}
need() { printf 'MISSING: %s\n' "$1"; missing=1; }
wait_crd() {
  local name=$1 deadline=$((SECONDS + 900))
  until found crd "$name"; do
    [[ $SECONDS -lt $deadline ]] || { echo "Timed out waiting for $name" >&2; return 1; }
    sleep 5
  done
  demo_oc HUB wait "crd/$name" --for=condition=Established --timeout=120s
}
site_exists=false
if found crd clusterinstances.siteconfig.open-cluster-management.io; then
  if found clusterinstance "$ZTP_CLUSTER" "$ZTP_CLUSTER"; then site_exists=true; fi
fi
boot_ns=$(cfg ztp.bootControllerNamespace); boot_deployment=$(cfg ztp.bootControllerDeployment)
boot_chart=$(cfg ztp.bootControllerChart); boot_values=$(cfg ztp.bootControllerValuesFile)
boot_release=$(cfg ztp.bootControllerRelease)
if [[ $site_exists != true ]]; then
  [[ -n $boot_ns && -n $boot_deployment ]] || { echo 'Specify the reviewed unattended boot-controller namespace/deployment.' >&2; exit 1; }
  if ! found deployment "$boot_deployment" "$boot_ns"; then
    if [[ -z $boot_chart || ! -f $boot_chart/Chart.yaml || -z $boot_values || ! -f $boot_values || -z $boot_release ]]; then
      need 'unattended boot backend: supply its reviewed local Helm chart, values, and release or prepare it through its existing owner'
      [[ $mode != --apply ]] || exit 1
    fi
  fi
fi
if [[ $mode == --apply ]]; then
  for approval in infrastructure sharedOperators communityBmc developerPreview credentialStorage; do
    [[ $(cfg "approvals.$approval") == true ]] || { echo "Set approvals.$approval=true after review." >&2; exit 1; }
  done
  demo_confirm 'create-demo-prerequisites'
fi

# Reuse source credential; never overwrite an existing Secret.
if found secret "$cred_name" "$cred_ns"; then
  demo_oc HUB get secret "$cred_name" -n "$cred_ns" -o json |
    jq -e '.data as $d | ["aws_access_key_id","aws_secret_access_key","baseDomain","pullSecret","ssh-publickey","ssh-privatekey"] | all(.[]; $d[.] != null and $d[.] != "")' >/dev/null || { echo 'ACM credential missing required fields; not replacing it.' >&2; exit 1; }
  echo 'OK: existing ACM credential (values not displayed)'
elif [[ $mode == --apply ]]; then phase credentials demo-acm-credential "$cred_ns"
else need 'ACM AWS credential'; fi
if ! found clusterimageset "$IMAGE_SET"; then
  if [[ $mode == --apply ]]; then phase image-set demo-image-set "$mch_ns" --set-string "imageSet=$IMAGE_SET"; else need 'release ClusterImageSet'; fi
fi

# Start AWS installs without serial full-install waits; existing clusters are never adopted.
for topology in production sno; do
  if [[ $topology == production ]]; then name=$PROD_CLUSTER; region=$(cfg production.region); else name=$QA_CLUSTER; region=$(cfg qa.region); fi
  [[ -n $region ]] || { echo "Missing region for $topology" >&2; exit 1; }
  if found managedcluster "$name"; then
    echo "REUSE: managed cluster $name (no Helm adoption or label changes)"
  elif found clusterdeployment "$name" "$name"; then
    echo "REUSE: in-progress/existing ClusterDeployment $name"
  elif [[ $mode == --apply ]]; then
    if found namespace "$name"; then echo "Namespace $name already exists without a recognized cluster; resolve ownership before creation." >&2; exit 1; fi
    phase aws "demo-aws-$name" "$name" --set-string "aws.name=$name,aws.topology=$topology,aws.region=$region,aws.imageSet=$IMAGE_SET"
  else need "AWS cluster $name"; fi
done

# Install CNV only if no existing subscription for this package is present.
sub=$(demo_oc HUB get subscriptions.operators.coreos.com -A -o json | jq -r '.items[] | select(.spec.name=="kubevirt-hyperconverged") | .metadata.namespace')
if [[ -n $sub && $sub != "$virt_ns" ]]; then echo 'Virtualization subscription elsewhere; resolve ownership.' >&2; exit 1; fi
existing_hco=false
if found crd hyperconvergeds.hco.kubevirt.io; then
  if found hyperconverged kubevirt-hyperconverged "$virt_ns"; then existing_hco=true; fi
fi
if [[ -z $sub && $existing_hco == true ]]; then
  echo 'REUSE: existing Virtualization configuration; no second OLM installation'
elif [[ -z $sub ]]; then
  if [[ $mode == --apply ]]; then
    groups=$(demo_oc HUB get operatorgroups.operators.coreos.com -n "$virt_ns" --ignore-not-found -o name)
    [[ -z $groups ]] || { echo 'Existing OperatorGroup: review before installing CNV.' >&2; exit 1; }
    phase virtualization-operator demo-virtualization-operator "$virt_ns"
  else need 'OpenShift Virtualization operator'; fi
fi
if [[ $mode == --apply ]]; then wait_crd hyperconvergeds.hco.kubevirt.io; fi
if found crd hyperconvergeds.hco.kubevirt.io; then
  if ! found hyperconverged kubevirt-hyperconverged "$virt_ns"; then
    if [[ $mode == --apply ]]; then phase virtualization-config demo-virtualization-config "$virt_ns"; else need 'HyperConverged configuration'; fi
  fi
else need 'HyperConverged API'; fi
if [[ $mode == --apply ]]; then
  demo_oc HUB wait hyperconverged/kubevirt-hyperconverged -n "$virt_ns" --for=condition=Available --timeout=15m
  # Only the approved keys, guarded by resourceVersion; preserve other settings.
  DEMO_SHARED_SETTINGS_APPROVED=1 ruby "$DIR/shared-settings.rb" hco "$virt_ns" kubevirt-hyperconverged
  DEMO_SHARED_SETTINGS_APPROVED=1 ruby "$DIR/shared-settings.rb" siteconfig "$mch_ns" "$mch_name"
  wait_crd clusterinstances.siteconfig.open-cluster-management.io
else
  echo 'CHECK: shared SiteConfig/HCO settings require review; no patch performed.'
fi

if found agentserviceconfig agent; then echo 'REUSE: AgentServiceConfig';
elif [[ $mode == --apply ]]; then
  demo_helm upgrade --install assisted "$DEMO_ROOT/charts/assisted-service" -n multicluster-engine -f "$DEMO_VALUES_DIR/assisted-service.local.yaml" --wait --timeout 5m
else need 'AgentServiceConfig'; fi
if ! found crd virtualmachinebmcs.bmc.kubevirt.io; then
  if [[ $mode == --apply ]]; then
    demo_helm upgrade --install kubevirtbmc kubevirtbmc --repo https://charts.kubevirtbmc.io --version 0.8.0 -n kubevirtbmc-system --create-namespace -f "$DEMO_VALUES_DIR/kubevirtbmc.local.yaml" --wait --timeout 5m
  else need 'KubeVirtBMC controller/API'; fi
fi

# Existing site is read-only: never reapply its target/boot templates on rerun.
if [[ $site_exists == true ]]; then
  echo 'REUSE: existing ZTP site; no target/media/boot reconciliation'
elif [[ $mode == --apply ]]; then
  if ! found deployment "$boot_deployment" "$boot_ns"; then
    demo_helm upgrade --install "$boot_release" "$boot_chart" -n "$boot_ns" --create-namespace -f "$boot_values" --wait --timeout 5m
  fi
  demo_oc HUB wait "deployment/$boot_deployment" -n "$boot_ns" --for=condition=Available --timeout=5m
  phase ztp-secrets demo-ztp-secrets "$ZTP_CLUSTER"
  for component in "${components[@]}"; do
    if [[ $component == ztp-target ]] && found virtualmachine "$ZTP_VM" "$ZTP_CLUSTER"; then
      echo 'REUSE: prepared VM; not reapplying initial boot/power fields'
      continue
    fi
    if [[ $component == ztp-boot-transition ]] && found job "$component" "$ZTP_CLUSTER"; then
      echo 'REUSE: existing boot-transition Job; not repeating it'
      continue
    fi
    chart=$component
    case $component in ztp-dns-guest|ztp-dns-hub) chart=ztp-dns ;; esac
    demo_helm upgrade --install "$component" "$DEMO_ROOT/charts/$chart" -n "$ZTP_CLUSTER" -f "$DEMO_VALUES_DIR/$component.local.yaml" --wait --timeout 5m
  done
else need 'precreated ZTP site'; fi

if [[ $mode == --check ]]; then
  for name in "$PROD_CLUSTER" "$QA_CLUSTER" "$ZTP_CLUSTER"; do
    if found managedcluster "$name"; then
      if ! demo_oc HUB get managedcluster "$name" -o json | jq -e 'any(.status.conditions[]?; .type=="ManagedClusterConditionAvailable" and .status=="True")' >/dev/null; then need "available managed cluster $name"; fi
    fi
  done
  demo_oc HUB get managedclusters
  printf '%s\n' 'Read-only check finished. Missing prerequisites are not a passing readiness check.'
  exit "$missing"
fi
# A release existing is not proof that installation/import finished.
wait_object() {
  local resource=$1 name=$2 namespace=${3:-} deadline=$((SECONDS + wait_seconds))
  until found "$resource" "$name" "$namespace"; do
    [[ $SECONDS -lt $deadline ]] || { echo "Timed out waiting for $resource/$name creation" >&2; return 1; }
    sleep 5
  done
}
for name in "$PROD_CLUSTER" "$QA_CLUSTER" "$ZTP_CLUSTER"; do
  wait_object managedcluster "$name"
  demo_oc HUB wait "managedcluster/$name" --for=condition=ManagedClusterJoined --timeout="$wait_time"
  demo_oc HUB wait "managedcluster/$name" --for=condition=ManagedClusterConditionAvailable --timeout="$wait_time"
done
wait_object agentclusterinstall "$ZTP_CLUSTER" "$ZTP_CLUSTER"
demo_oc HUB wait "agentclusterinstall/$ZTP_CLUSTER" -n "$ZTP_CLUSTER" --for=condition=Completed --timeout="$wait_time"
printf '%s\n' 'Hub-side starting fleet ready. Source demo-shell.sh without --prereqs, then run verify.sh for guest node/operator health. Nothing was deleted.'
