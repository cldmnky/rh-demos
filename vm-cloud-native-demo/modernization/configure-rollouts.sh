#!/usr/bin/env bash
# Opt the GitOps operator into namespace-scoped RolloutManagers.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
GITOPS_OPERATOR_NAMESPACE=${GITOPS_OPERATOR_NAMESPACE:-openshift-gitops-operator}
GITOPS_SUBSCRIPTION=${GITOPS_SUBSCRIPTION:-openshift-gitops-operator}
export NAMESPACE
# A change of operator mode is incompatible with any existing cluster-scoped manager.
oc get rolloutmanagers -A -o json | ruby -rjson -e '
  managers=JSON.parse(STDIN.read).fetch("items")
  incompatible=managers.reject { |m| m.dig("spec","namespaceScoped") == true || (m.dig("metadata","namespace") == ENV.fetch("NAMESPACE") && m.dig("metadata","name") == "rocket-ramen") }
  abort "An existing cluster-scoped RolloutManager is present; refusing to change GitOps operator mode." unless incompatible.empty?
'
patch=$(mktemp "${TMPDIR:-/tmp}/rocket-ramen-rollouts.XXXXXXXX")
trap 'rm -f "$patch"' EXIT
chmod 600 "$patch"
oc -n "$GITOPS_OPERATOR_NAMESPACE" get subscription "$GITOPS_SUBSCRIPTION" -o json | ruby -rjson -e '
  sub=JSON.parse(STDIN.read); env=sub.dig("spec","config","env") || []
  setting=env.find { |e| e["name"] == "NAMESPACE_SCOPED_ARGO_ROLLOUTS" }
  if setting
    abort "Unsupported valueFrom for Rollouts scope setting" if setting.key?("valueFrom")
    setting["value"]="true"
  else
    env << {"name"=>"NAMESPACE_SCOPED_ARGO_ROLLOUTS", "value"=>"true"}
  end
  puts JSON.generate({"spec"=>{"config"=>{"env"=>env}}})
' > "$patch"
oc -n "$GITOPS_OPERATOR_NAMESPACE" patch subscription "$GITOPS_SUBSCRIPTION" --type=merge --patch-file "$patch"
