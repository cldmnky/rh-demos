#!/usr/bin/env bash
set -euo pipefail
ARGO_NAMESPACE=${ARGO_NAMESPACE:-openshift-gitops}
ARGO_APPLICATION=${ARGO_APPLICATION:-vm-cloud-native-pipelines}
DEVSPACES_APPLICATION=${DEVSPACES_APPLICATION:-vm-cloud-native-devspaces}
PREREQ_GIT_URL=${PREREQ_GIT_URL:-https://github.com/cldmnky/rh-demos.git}
PREREQ_GIT_REF=${PREREQ_GIT_REF:-main}
PREREQ_GIT_PATH=${PREREQ_GIT_PATH:-vm-cloud-native-demo/prereqs/pipelines}
DEVSPACES_GIT_PATH=${DEVSPACES_GIT_PATH:-vm-cloud-native-demo/prereqs/devspaces}
WORKSPACE_APPLICATION=${WORKSPACE_APPLICATION:-vm-cloud-native-devspace}
WORKSPACE_GIT_PATH=${WORKSPACE_GIT_PATH:-vm-cloud-native-demo/prereqs/devspace}
DEVSPACE_NAME=${DEVSPACE_NAME:-rocket-ramen}
DEVSPACE_USER=${DEVSPACE_USER:-}
OC_TIMEOUT=${OC_TIMEOUT:-15s}
mode=${1:---check}
case "$mode" in --check|--apply) ;; *) echo 'Usage: prereqs.sh [--check|--apply]' >&2; exit 2 ;; esac
for cmd in oc ruby; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }; done
context=$(oc config current-context)
printf 'Cluster context: %s\n' "$context"
oc --context "$context" --request-timeout="$OC_TIMEOUT" whoami >/dev/null
ocx() { oc --context "$context" --request-timeout="$OC_TIMEOUT" "$@"; }
DEVSPACE_USER=${DEVSPACE_USER:-$(ocx whoami 2>/dev/null || true)}
# Dev Spaces provisions <username>-devspaces on first dashboard login. Deriving
# it from a service account identity would produce a namespace nobody owns, so
# that case requires DEVSPACE_NAMESPACE instead of a guess.
sanitize_namespace() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40
}
if [[ -z ${DEVSPACE_NAMESPACE:-} ]]; then
  case "$DEVSPACE_USER" in
    ''|system:serviceaccount:*|system:*) DEVSPACE_NAMESPACE='' ;;
    *) DEVSPACE_NAMESPACE="$(sanitize_namespace "$DEVSPACE_USER")-devspaces" ;;
  esac
fi

printf 'Argo CD: '
ocx get argocd openshift-gitops -n "$ARGO_NAMESPACE" -o jsonpath='{.status.phase}{"\n"}'
printf 'Pipelines catalog channel: '
ocx get packagemanifest openshift-pipelines-operator-rh -n openshift-marketplace -o jsonpath='{.status.channels[?(@.name=="pipelines-1.24")].currentCSV}{"\n"}'
printf 'Dev Spaces catalog channel: '
ocx get packagemanifest devspaces -n openshift-marketplace -o jsonpath='{.status.channels[?(@.name=="stable")].currentCSV}{"\n"}'
if [[ "$mode" == --check ]]; then
  ocx get application "$ARGO_APPLICATION" -n "$ARGO_NAMESPACE" --ignore-not-found
  ocx get application "$DEVSPACES_APPLICATION" -n "$ARGO_NAMESPACE" --ignore-not-found
  ocx get subscription openshift-pipelines-operator -n openshift-operators --ignore-not-found
  ocx get subscription devspaces -n openshift-operators --ignore-not-found
  ocx get crd pipelines.tekton.dev --ignore-not-found
  if ocx get crd tektonconfigs.operator.tekton.dev >/dev/null 2>&1; then
    ocx get tektonconfig config --ignore-not-found
  fi
  if ocx get crd checlusters.org.eclipse.che >/dev/null 2>&1; then
    ocx get checluster devspaces -n openshift-devspaces --ignore-not-found
  fi
  if [[ -n $DEVSPACE_NAMESPACE ]]; then
    ocx get application "$WORKSPACE_APPLICATION" -n "$ARGO_NAMESPACE" --ignore-not-found
    if ocx get namespace "$DEVSPACE_NAMESPACE" >/dev/null 2>&1; then
      ocx get devworkspace "$DEVSPACE_NAME" -n "$DEVSPACE_NAMESPACE" --ignore-not-found
      printf 'Workspace IDE: %s\n' "$(ocx get devworkspace "$DEVSPACE_NAME" -n "$DEVSPACE_NAMESPACE" -o jsonpath='{.status.mainUrl}' 2>/dev/null || true)"
    else
      printf 'Workspace namespace %s does not exist yet: log in to Dev Spaces once, then re-run --check.\n' "$DEVSPACE_NAMESPACE"
    fi
  else
    printf 'Workspace not configured: DEVSPACE_NAMESPACE is required when oc identifies as a service account.\n'
  fi
  exit 0
fi
# Do not adopt an existing subscription installed under another name.
ocx get subscriptions.operators.coreos.com -A -o json | ruby -rjson -e '
  JSON.parse(STDIN.read).fetch("items").each do |s|
    package = s.dig("spec", "name")
    expected = {"openshift-pipelines-operator-rh" => "openshift-pipelines-operator", "devspaces" => "devspaces"}[package]
    if expected && (s.dig("metadata", "namespace") != "openshift-operators" || s.dig("metadata", "name") != expected)
      abort "Another #{package} Subscription exists; review its owner before applying."
    end
    if package == "devworkspace-operator" && s.dig("metadata", "namespace") != "openshift-operators"
      abort "A Dev Workspace subscription exists outside openshift-operators; review it before applying."
    end
  end
'
export ARGO_NAMESPACE PREREQ_GIT_URL PREREQ_GIT_REF
apply_application() {
  local application=$1 path=$2 destination=${3:-openshift-operators} self_heal=${4:-true}
  APP_NAME="$application" APP_PATH="$path" APP_DESTINATION="$destination" APP_SELF_HEAL="$self_heal" ruby -rjson -e '
    puts JSON.generate({apiVersion:"argoproj.io/v1alpha1",kind:"Application",metadata:{name:ENV.fetch("APP_NAME"),namespace:ENV.fetch("ARGO_NAMESPACE")},spec:{project:"default",source:{repoURL:ENV.fetch("PREREQ_GIT_URL"),targetRevision:ENV.fetch("PREREQ_GIT_REF"),path:ENV.fetch("APP_PATH")},destination:{server:"https://kubernetes.default.svc",namespace:ENV.fetch("APP_DESTINATION")},syncPolicy:{automated:{prune:false,selfHeal:ENV.fetch("APP_SELF_HEAL")=="true"},syncOptions:["SkipDryRunOnMissingResource=true"],retry:{limit:10,backoff:{duration:"30s",factor:2,maxDuration:"5m"}}}}})
  ' | ocx apply -f -
}
apply_application "$ARGO_APPLICATION" "$PREREQ_GIT_PATH"
apply_application "$DEVSPACES_APPLICATION" "$DEVSPACES_GIT_PATH"
if [[ -n $DEVSPACE_NAMESPACE ]]; then
  # selfHeal is off for the workspace: idling sets spec.started=false, and drift
  # correction would otherwise restart a workspace the presenter deliberately
  # stopped. Git changes still sync.
  apply_application "$WORKSPACE_APPLICATION" "$WORKSPACE_GIT_PATH" "$DEVSPACE_NAMESPACE" false
else
  printf 'Workspace Application skipped: set DEVSPACE_NAMESPACE (see the Dev Spaces dashboard once as the presenting user).\n'
fi
printf 'Waiting for Pipelines and Dev Spaces readiness (up to 20 minutes)...\n'
for ((attempt=0; attempt<120; attempt++)); do
  installed=$(ocx get subscription openshift-pipelines-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' --ignore-not-found)
  devinstalled=$(ocx get subscription devspaces -n openshift-operators -o jsonpath='{.status.installedCSV}' --ignore-not-found)
  if [[ -n "$installed" && -n "$devinstalled" ]]; then
    csvphase=$(ocx get csv "$installed" -n openshift-operators -o jsonpath='{.status.phase}' --ignore-not-found)
    devphase=$(ocx get csv "$devinstalled" -n openshift-operators -o jsonpath='{.status.phase}' --ignore-not-found)
    if [[ "$csvphase" == Succeeded && "$devphase" == Succeeded ]] && ocx get crd pipelines.tekton.dev checlusters.org.eclipse.che >/dev/null 2>&1; then
      tektonready=$(ocx get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' --ignore-not-found)
      chephase=$(ocx get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.chePhase}' --ignore-not-found)
      cheurl=$(ocx get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.cheURL}' --ignore-not-found)
      pipelinesync=$(ocx get application "$ARGO_APPLICATION" -n "$ARGO_NAMESPACE" -o jsonpath='{.status.sync.status}')
      devsync=$(ocx get application "$DEVSPACES_APPLICATION" -n "$ARGO_NAMESPACE" -o jsonpath='{.status.sync.status}')
      if [[ "$pipelinesync" == Synced && "$devsync" == Synced && "$tektonready" == True && "$chephase" == Active && -n "$cheurl" ]]; then
        printf 'Pipelines %s is ready; Dev Spaces %s is active: %s\n' "$installed" "$devinstalled" "$cheurl"
        printf 'Workspace dashboard: %s/dashboard/#/ide/%s/%s\n' "$cheurl" "$DEVSPACE_NAMESPACE" "$DEVSPACE_NAME"
        if [[ -n $DEVSPACE_NAMESPACE ]] && ocx get namespace "$DEVSPACE_NAMESPACE" >/dev/null 2>&1; then
          for ((wait = 0; wait < 60; wait++)); do
            mainurl=$(ocx get devworkspace "$DEVSPACE_NAME" -n "$DEVSPACE_NAMESPACE" -o jsonpath='{.status.mainUrl}' --ignore-not-found 2>/dev/null)
            wsphase=$(ocx get devworkspace "$DEVSPACE_NAME" -n "$DEVSPACE_NAMESPACE" -o jsonpath='{.status.phase}' --ignore-not-found 2>/dev/null)
            if [[ -n $mainurl && $wsphase == Running ]]; then
              printf 'Workspace %s/%s is %s: %s\n' "$DEVSPACE_NAMESPACE" "$DEVSPACE_NAME" "$wsphase" "$mainurl"
              exit 0
            fi
            sleep 5
          done
          printf 'Workspace %s/%s has not reached Running yet; inspect %s in %s.\n' \
            "$DEVSPACE_NAMESPACE" "$DEVSPACE_NAME" "$WORKSPACE_APPLICATION" "$ARGO_NAMESPACE" >&2
          exit 1
        fi
        printf 'ACTION REQUIRED: %s does not exist yet. Log in to %s once as the presenting user so Dev Spaces provisions it; the %s Application then syncs the workspace.\n' \
          "${DEVSPACE_NAMESPACE:-<username>-devspaces}" "$cheurl" "$WORKSPACE_APPLICATION"
        exit 0
      fi
    fi
  fi
  sleep 10
done
printf 'Timed out. Inspect both Applications, Subscriptions, CSVs, and component status.\n' >&2
ocx get applications -n "$ARGO_NAMESPACE"
ocx get subscriptions -n openshift-operators
exit 1
