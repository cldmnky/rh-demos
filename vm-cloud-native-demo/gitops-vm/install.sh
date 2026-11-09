#!/usr/bin/env bash
# Point Argo CD at the published GitOps VM chart, not the local checkout.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
ARGO_NAMESPACE=${ARGO_NAMESPACE:-openshift-gitops}
GITOPS_VM_APPLICATION=${GITOPS_VM_APPLICATION:-rocket-ramen-gitops-vm}
PREREQ_GIT_URL=${PREREQ_GIT_URL:-https://github.com/cldmnky/rh-demos.git}
PREREQ_GIT_REF=${PREREQ_GIT_REF:-main}
SOURCE_NAMESPACE=${SOURCE_NAMESPACE:-openshift-virtualization-os-images}
SOURCE_NAME=${SOURCE_NAME:-rhel10}
SOURCE_ROOT_SIZE=${SOURCE_ROOT_SIZE:-30Gi}
export NAMESPACE ARGO_NAMESPACE GITOPS_VM_APPLICATION PREREQ_GIT_URL PREREQ_GIT_REF SOURCE_NAMESPACE SOURCE_NAME SOURCE_ROOT_SIZE
ruby -rjson -e '
  puts JSON.generate(apiVersion: "argoproj.io/v1alpha1", kind: "Application",
    metadata: {name: ENV.fetch("GITOPS_VM_APPLICATION"), namespace: ENV.fetch("ARGO_NAMESPACE")},
    spec: {project: "default", source: {repoURL: ENV.fetch("PREREQ_GIT_URL"), targetRevision: ENV.fetch("PREREQ_GIT_REF"),
      path: "vm-cloud-native-demo/gitops-vm/chart", helm: {parameters: [
        {name: "sourceNamespace", value: ENV.fetch("SOURCE_NAMESPACE")},
        {name: "sourceName", value: ENV.fetch("SOURCE_NAME")},
        {name: "rootSize", value: ENV.fetch("SOURCE_ROOT_SIZE")}] }},
      destination: {server: "https://kubernetes.default.svc", namespace: ENV.fetch("NAMESPACE")},
      syncPolicy: {automated: {prune: false, selfHeal: true}, retry: {limit: 10, backoff: {duration: "30s", factor: 2, maxDuration: "5m"}}}})
' | oc apply -f -
printf 'Argo CD Application %s/%s tracks %s at %s.\n' "$ARGO_NAMESPACE" "$GITOPS_VM_APPLICATION" "$PREREQ_GIT_URL" "$PREREQ_GIT_REF"
printf 'Check: oc -n %s get application %s; oc -n %s get vm rocket-ramen-gitops-demo\n' "$ARGO_NAMESPACE" "$GITOPS_VM_APPLICATION" "$NAMESPACE"
