# Act 3 — ACM subscription delivery

**29:00–36:00 · 7 minutes.** APP → ACM topology → API evidence → APP.
Prepared inputs: the existing `subscription.local.yaml` delivery values and application version
from `app-v2.local.yaml`. Initialize `HELM_HUB`, `DEMO_V2_VERSION`, and `SUB_V2_CHART_VERSION`
as shown in the [master runbook](../presenter-runbook.md). Packages are already published; `$SUB_DEPLOYMENT` / `$SUB_ROUTE` are the
actual generated names, supplied to the initializer. No package publication during the talk.

## 1. APP — establish v1 (29:00–29:45)

Open the actual subscription HTTPS app. Point to version, environment and delivery model.
**Say:** “Same simple application; this instance is delivered by ACM subscription.” Position it
once as legacy/deprecated in ACM 2.17, not OLM Subscription and not the default for new projects.

## 2. ADVANCE — request the prepared v2 early (29:45–30:15)

The authorized Helm owner can use:

```bash
"${HELM_HUB[@]}" upgrade "$SUB_RELEASE" "$DEMO_ROOT/charts/delivery" -n "$SUB_NS" \
  -f "$DEMO_VALUES_DIR/subscription.local.yaml" \
  --set-string "subscription.chartVersion=$SUB_V2_CHART_VERSION" \
  --set-string "application.version=$DEMO_V2_VERSION" --wait --timeout 2m
```

In the current lab, changing the existing managed Subscription did not refresh its Helm
release. The tested v2 workaround recreates the **production-target demo Subscription** from ACM's
ManifestWork after it contains the new package version. This briefly removes that demo workload
and changes its generated Deployment and Route names. Use the procedure in [setup](../setup.md#subscription-update-workaround) or present the working v1 path only; do not claim an automatic v2 rollout.

Use the existing Git owner instead when applicable. **Say:** “While reconciliation runs, let's
trace how a versioned package reaches a selected cluster.” Do not describe an operator-driven
Helm update as automatic Git reconciliation. Subscription updates may exceed two minutes;
allow the remaining explanation time rather than repeatedly requesting the update.

## 3. CONSOLE — source, selection, destination (30:15–32:15)

All Clusters → Applications → `$SUB_RELEASE` in `$SUB_NS` → Topology.
Point to Channel, Subscription, Placement/target, and delivered workload. **Say:** “Channel is
where; Subscription is what; Placement is which clusters. The Application groups the view.”
Open non-secret source/version details, not credentials. Topology grouping varies by plugin;
explain relationships rather than promising a particular arrangement of icons.

## 4. TERMINAL — prove the topology (32:15–33:30)

```bash
oc_hub get channels.apps.open-cluster-management.io "$SUB_RELEASE" -n "$SUB_NS" -o json |
  jq '{name:.metadata.name,type:.spec.type,source:.spec.pathname}'
oc_hub get subscriptions.apps.open-cluster-management.io "$SUB_RELEASE" -n "$SUB_NS" -o json |
  jq '{chart:.spec.name,chartVersion:.spec.packageFilter.version,
       placement:.spec.placement.placementRef,phase:.status.phase}'
oc_prod get deployment "$SUB_DEPLOYMENT" -n "$SUB_NS" \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas'
```

Point out chart package version versus displayed application version; they are different fields.
The hub's phase is not an end-to-end acceptance test.

## 5. APP — inspect the real v2 response (33:30–35:15)

```bash
oc_prod get route "$SUB_ROUTE" -n "$SUB_NS" -o jsonpath='https://{.spec.host}{"\n"}'
```

Hard-refresh the real HTTPS page. Expect v2, unchanged environment, subscription model.
**Say:** “We have moved from requested package version to an actual application response.”
No invented fallback URL or TLS verification bypass. If still converging, identify the requested
version and revisit the actual response after the push segment; never claim v2 while serving v1.

## 6. LAND — central Argo (35:15–36:00)

“Now keep the same app and fleet selection, but let central Argo reconcile it.” Switch to the
central Argo tab. Retain the prior package/values for offstage rollback through the same owner.
