# Act 4 — central Argo CD push

**36:00–45:00 · 9 minutes.** Argo UI → fleet decision/API evidence → remote rollout → APP.
Prepared inputs: existing `push.local.yaml`, with the v2 application version read from
`app-v2.local.yaml`. Use `HELM_HUB` and `DEMO_V2_VERSION` initialized in the
[master runbook](../presenter-runbook.md). Intent in `$CENTRAL_NS`, generated
`$PUSH_APP`, workload `$APP_RELEASE` in `$PUSH_NS`. ACM selects/registers targets; central Argo
reconciles applications. Argo renders Helm; do not install another Helm CLI owner on the workload.

## 1. ARGO — show the v1 application (36:00–37:30)

Central Argo → Applications → `$PUSH_APP` → Details / resource tree. Point to chart source/revision,
remote destination, Synced/Healthy, and workload tree. Briefly show v1 on the actual app page.
**Say:** “ACM connects fleet selection to delivery. The central application-controller talks to
the managed Kubernetes API.” Synced/Healthy is useful, but the browser response proves content.

## 2. CONSOLE / TERMINAL — why this Application exists (37:30–39:30)

Briefly show production labels in ACM fleet, then inspect the exact chain:

```bash
oc_hub get placementdecisions -n "$CENTRAL_NS" \
  -l "cluster.open-cluster-management.io/placement=$PUSH_RELEASE" -o json |
  jq -r '.items[].status.decisions[] | .clusterName'
oc_hub get gitopscluster "$PUSH_RELEASE" -n "$CENTRAL_NS" -o json |
  jq '{argo:.spec.argoServer,placement:.spec.placementRef}'
oc_hub get applicationset "$PUSH_RELEASE" -n "$CENTRAL_NS" -o json |
  jq '{generator:.spec.generators,chartPath:.spec.template.spec.source.path,
       destination:.spec.template.spec.destination}'
```

**Say:** “Placement decides, GitOpsCluster integrates registration, ApplicationSet generates an
Application.” Do not expose registration Secrets. Name-based destinations occur in push and agent
examples; they do not prove agent mode. Controller location is the distinction.

## 3. ADVANCE / ARGO — request v2 (39:30–41:30)

For the authorized CLI Helm owner:

```bash
"${HELM_HUB[@]}" upgrade "$PUSH_RELEASE" "$DEMO_ROOT/charts/delivery" -n "$CENTRAL_NS" \
  -f "$DEMO_VALUES_DIR/push.local.yaml" \
  --set-string "application.version=$DEMO_V2_VERSION" --wait --timeout 2m
```

Use the prepared Git-owner change instead if configured. Show the non-secret source-values diff
and Application's v2 Helm input; then its sync history/tree. **Say:** “Same chart, new desired
content. The central controller reconciles it remotely.” If it syncs too fast to catch OutOfSync,
show completed history; do not force another change for the animation.

## 4. TERMINAL — prove remote rollout (41:30–43:00)

```bash
oc_prod rollout status "deployment/$APP_RELEASE" -n "$PUSH_NS" --timeout=90s
oc_prod get deployment "$APP_RELEASE" -n "$PUSH_NS" -o json |
  jq '{ready:.status.readyReplicas,updated:.status.updatedReplicas,
       checksum:.spec.template.metadata.annotations["checksum/content"]}'
oc_hub get applications.argoproj.io "$PUSH_APP" -n "$CENTRAL_NS" -o json |
  jq '{destination:.spec.destination,sync:.status.sync.status,health:.status.health.status}'
```

Point to the explicit production target, not hub workload state. Explain the content checksum:
ConfigMap changes alter the pod template, so the served content is rolled out, not merely stored.

## 5. APP — close the loop (43:00–44:15)

```bash
oc_prod get route "$APP_RELEASE" -n "$PUSH_NS" -o jsonpath='https://{.spec.host}{"\n"}'
```

Hard-refresh the actual HTTPS page: v2, production environment, central push model. **Say:**
“The central Application, remote rollout, and actual response agree.” Keep it visible briefly.

## 6. LAND — move reconciliation (44:15–45:00)

“What if we keep central intent, but want local application reconciliation?” Switch to the
separate principal tab. On lag, name the boundary still converging and use one bounded read-only
check; no controller restart, live RBAC repair, secret inspection or resource deletion.
