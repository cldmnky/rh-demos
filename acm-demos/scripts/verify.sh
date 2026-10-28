#!/usr/bin/env bash
# Read-only guest and hub readiness. Not an application delivery acceptance test.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/lib.sh"
demo_require PROD_CLUSTER QA_CLUSTER ZTP_CLUSTER PROD_CONTEXT AGENT_CONTEXT ZTP_CONTEXT
demo_identity HUB
for name in "$PROD_CLUSTER" "$QA_CLUSTER" "$ZTP_CLUSTER"; do
  demo_oc HUB get managedcluster "$name" -o json |
    jq -e '.status.conditions as $c | ["HubAcceptedManagedCluster","ManagedClusterJoined","ManagedClusterConditionAvailable"] | all(.[]; . as $t | any($c[]; .type==$t and .status=="True"))' >/dev/null
  printf 'Ready on hub: %s\n' "$name"
done
for role in PROD AGENT ZTP; do
  demo_identity "$role"
  demo_oc "$role" get nodes -o json | jq -e '.items | length>0 and all(.[]; any(.status.conditions[]; .type=="Ready" and .status=="True"))' >/dev/null
  demo_oc "$role" get clusteroperators -o json |
    jq -e '.items | length>0 and all(.[]; any(.status.conditions[]; .type=="Available" and .status=="True") and any(.status.conditions[]; .type=="Degraded" and .status=="False") and any(.status.conditions[]; .type=="Progressing" and .status=="False"))' >/dev/null
  printf 'Ready guest nodes/operators: %s\n' "$role"
done
printf '%s\n' 'Starting fleet health passed. Prepare governance/app starting states separately with setup-demo.sh.'
