# Act 5 — central intent, local reconciliation

**45:00–55:00 · 10 minutes.** Principal Argo → managed controller/Application → APP → principal.
Prepared inputs: existing `agent-principal.local.yaml` and `agent.local.yaml`, with the v2
application version read from `app-v2.local.yaml`. Use `HELM_HUB` and `DEMO_V2_VERSION`
initialized in the [master runbook](../presenter-runbook.md). Use isolated `$PRINCIPAL_NS`, target `$AGENT_CLUSTER`, managed instance `$AGENT_GITOPS_NS`, and
app namespace `$AGENT_APP_NS`. Principal/certificates, ApplicationSet permissions and scoped target
RBAC are already configured. The ACM integration is Technology Preview in 2.17; this is not
ACM's separate ManifestWork application-pull model.

## 1. ARGO — show central intent (45:00–46:30)

Separate principal tab → Applications → `$AGENT_APP` → Details / tree. Point to source, destination,
v1 intent/status; briefly show the actual v1 app page. **Say:** “Intent still looks central. The
change is who reconciles it on the target. We'll verify that locally and watch status return.”
Do not use destination-name syntax or an enabled flag alone as connection proof.

## 2. TERMINAL — identify the integration (46:30–48:00)

```bash
oc_hub get gitopscluster "$AGENT_RELEASE" -n "$PRINCIPAL_NS" -o json |
  jq '{principal:.spec.argoServer.argoNamespace,placement:.spec.placementRef,
       addon:.spec.gitopsAddon.enabled,agent:.spec.gitopsAddon.argoCDAgent}'
oc_hub get managedclusteraddons -n "$AGENT_CLUSTER"
oc_agent get deployments -n "$AGENT_GITOPS_NS"
```

Point to managed mode, the selected target add-on, agent and local application-controller.
**Say:** “Ready processes are health signals; delivery of the next version will prove that
intent and status actually cross the connection.” Show the rehearsed connection-status view if
available; do not invent a UI menu or expose certificate/authentication material.

## 3. TERMINAL — the local Application (48:00–50:00)

```bash
oc_agent get applications.argoproj.io -n "$AGENT_GITOPS_NS" \
  -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
oc_agent get applications.argoproj.io "$LOCAL_AGENT_APP" -n "$AGENT_GITOPS_NS" -o json |
  jq '{name:.metadata.name,destination:.spec.destination,
       source:.spec.source.path,sync:.status.sync.status,health:.status.health.status}'
```

**Say:** “There is an Application and application-controller here on the managed cluster.
This is where application reconciliation happens.” Names and namespace routing come from the
rehearsed configuration, not assumed equality with the principal's generated name.

## 4. ADVANCE — request v2 centrally (50:00–51:00)

For the existing authorized Helm owner:

```bash
"${HELM_HUB[@]}" upgrade "$AGENT_RELEASE" "$DEMO_ROOT/charts/delivery" -n "$PRINCIPAL_NS" \
  -f "$DEMO_VALUES_DIR/agent.local.yaml" \
  --set-string "application.version=$DEMO_V2_VERSION" --wait --timeout 2m
```

Use the Git owner instead when applicable. Show the safe desired-values change. **Say:** “The
update starts at the principal; we are not patching a managed Deployment to simulate delivery.”

## 5. TERMINAL / APP — local rollout (51:00–53:00)

```bash
oc_agent rollout status "deployment/$APP_RELEASE" -n "$AGENT_APP_NS" --timeout=90s
oc_agent get applications.argoproj.io "$LOCAL_AGENT_APP" -n "$AGENT_GITOPS_NS" -o json |
  jq '{sync:.status.sync.status,health:.status.health.status}'
oc_agent get route "$APP_RELEASE" -n "$AGENT_APP_NS" -o jsonpath='https://{.spec.host}{"\n"}'
```

Hard-refresh the actual HTTPS page. Expect v2, selected target environment, agent delivery model.
The local controller/Application and the real response together establish the target outcome.

## 6. ARGO — status round trip (53:00–54:15)

Return to the principal tree: v2 desired input, returned Synced/Healthy. Optional precise proof:

```bash
oc_hub get applications.argoproj.io "$AGENT_APP" -n "$PRINCIPAL_NS" -o json |
  jq '{sync:.status.sync.status,health:.status.health.status}'
```

**Say:** “Central intent, local application reconciliation, central visibility. We checked both
sides of the round trip.” No zero-credential, unlimited-scale or disconnected-update promises.

## 7. LAND — compare the control loops (54:15–55:00)

“We kept the application constant; we changed the location of its reconciliation.” Return to
the master's comparison. On lag, identify intent delivery, local reconciliation or returned
status as the incomplete boundary; do not regenerate certificates, broaden RBAC, or reinstall
an add-on on stage. Reset via the same desired-state owner after the presentation.
