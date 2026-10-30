#!/usr/bin/env bash
set -euo pipefail
ARGO_NAMESPACE=${ARGO_NAMESPACE:-openshift-gitops}
ARGO_APPLICATION=${ARGO_APPLICATION:-vm-cloud-native-pipelines}
PREREQ_GIT_URL=${PREREQ_GIT_URL:-https://github.com/cldmnky/rh-demos.git}
PREREQ_GIT_REF=${PREREQ_GIT_REF:-vm-cloud-native-prereqs}
PREREQ_GIT_PATH=${PREREQ_GIT_PATH:-vm-cloud-native-demo/prereqs/pipelines}
OC_TIMEOUT=${OC_TIMEOUT:-15s}
mode=${1:---check}
case "$mode" in --check|--apply) ;; *) echo 'Usage: prereqs.sh [--check|--apply]' >&2; exit 2 ;; esac
for cmd in oc ruby; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }; done
context=$(oc config current-context)
printf 'Cluster context: %s\n' "$context"
oc --context "$context" --request-timeout="$OC_TIMEOUT" whoami >/dev/null
ocx() { oc --context "$context" --request-timeout="$OC_TIMEOUT" "$@"; }
printf 'Argo CD: '
ocx get argocd openshift-gitops -n "$ARGO_NAMESPACE" -o jsonpath='{.status.phase}{"\n"}'
printf 'Pipelines catalog channel: '
ocx get packagemanifest openshift-pipelines-operator-rh -n openshift-marketplace -o jsonpath='{.status.channels[?(@.name=="pipelines-1.24")].currentCSV}{"\n"}'
if [[ "$mode" == --check ]]; then
  ocx get application "$ARGO_APPLICATION" -n "$ARGO_NAMESPACE" --ignore-not-found
  ocx get subscription openshift-pipelines-operator -n openshift-operators --ignore-not-found
  ocx get crd pipelines.tekton.dev --ignore-not-found
  exit 0
fi
# Do not adopt an existing subscription installed under another name.
ocx get subscriptions.operators.coreos.com -A -o json | ruby -rjson -e '
  JSON.parse(STDIN.read).fetch("items").each do |s|
    next unless s.dig("spec", "name") == "openshift-pipelines-operator-rh"
    unless s.dig("metadata", "namespace") == "openshift-operators" && s.dig("metadata", "name") == "openshift-pipelines-operator"
      abort "Another OpenShift Pipelines Subscription exists; review its owner before applying."
    end
  end
'
export ARGO_NAMESPACE ARGO_APPLICATION PREREQ_GIT_URL PREREQ_GIT_REF PREREQ_GIT_PATH
ruby -rjson -e '
  puts JSON.generate({apiVersion:"argoproj.io/v1alpha1",kind:"Application",metadata:{name:ENV.fetch("ARGO_APPLICATION"),namespace:ENV.fetch("ARGO_NAMESPACE")},spec:{project:"default",source:{repoURL:ENV.fetch("PREREQ_GIT_URL"),targetRevision:ENV.fetch("PREREQ_GIT_REF"),path:ENV.fetch("PREREQ_GIT_PATH")},destination:{server:"https://kubernetes.default.svc",namespace:"openshift-operators"},syncPolicy:{automated:{prune:false,selfHeal:true}}}})
' | ocx apply -f -
printf 'Waiting for GitOps synchronization and Pipelines readiness (up to 15 minutes)...\n'
for ((attempt=0; attempt<90; attempt++)); do
  app=$(ocx get application "$ARGO_APPLICATION" -n "$ARGO_NAMESPACE" -o json)
  installed=$(ocx get subscription openshift-pipelines-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' --ignore-not-found)
  if [[ -n "$installed" ]]; then
    csvphase=$(ocx get csv "$installed" -n openshift-operators -o jsonpath='{.status.phase}' --ignore-not-found)
    if [[ "$csvphase" == Succeeded ]] && ocx get crd pipelines.tekton.dev >/dev/null 2>&1; then
      sync=$(printf '%s' "$app" | ruby -rjson -e 'print JSON.parse(STDIN.read).dig("status","sync","status")')
      if [[ "$sync" == Synced ]]; then
        printf 'Argo CD synchronized; operator %s is Succeeded; Tekton Pipeline CRD exists.\n' "$installed"
        exit 0
      fi
    fi
  fi
  sleep 10
done
printf 'Timed out. Inspect Application, Subscription, CSVs, and Tekton components.\n' >&2
ocx get application "$ARGO_APPLICATION" -n "$ARGO_NAMESPACE" -o yaml
ocx get subscription openshift-pipelines-operator -n openshift-operators --ignore-not-found -o yaml
exit 1
