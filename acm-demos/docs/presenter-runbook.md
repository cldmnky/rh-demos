# Run the ACM demo — console and terminal

**Duration:** 60 minutes; 58 minutes of content plus 2 minutes buffer.
**Story:** understand the prepared fleet → explain how its ZTP site was created → govern a
selected cluster → deliver the same application using three different control loops.

**Use the precreated clusters and existing ignored local values.** Do not run prerequisite
provisioning, install operators, create another cluster, or restart ZTP during this presentation.
Lifecycle and ZTP are an explanation of what was created before the session—not a live install.

## Before the audience arrives

### 1. Initialize the presentation shell

From the repository root, use Bash:

```bash
cd acm-demos
source scripts/demo-shell.sh
scripts/verify.sh
```

The initializer loads trusted ignored `config/demo.env`, prompts for missing variables, and
sets connection/resource names. `verify.sh` checks the existing fleet read-only. Keep this same
shell throughout the presentation; do not change global kubeconfig context.

| Helper | Where its commands run |
| --- | --- |
| `oc_hub` | ACM hub: fleet, policies, SiteConfig, application intent |
| `oc_prod` | Precreated production cluster: baseline and subscription/push workloads |
| `oc_ztp` | Installed precreated ZTP cluster: guest node and operator health |
| `oc_agent` | Precreated agent target: local Application/controller and app workload |
| `oc_excluded` | Prepared negative target: prove production policy did not affect it |

These helpers include the selected context, optional private kubeconfig path, and request timeout.
A variable such as `$ZTP_CLUSTER` identifies the prepared resource; it is not an instruction
to create a new cluster.

### 2. Reuse the precreated values files

`$DEMO_VALUES_DIR` defaults to `values/`. This runbook uses:

| Existing local file | Used for |
| --- | --- |
| `ztp-site.local.yaml`, `ztp-target.local.yaml` | Explain the inputs that created the site and VM; **do not apply** |
| `governance-inform.local.yaml` | Inform baseline and post-demo restoration |
| `governance-enforce.local.yaml` | Change the same policy intent to enforce |
| `subscription.local.yaml` | Subscription delivery intent and v1 baseline |
| `push.local.yaml` | Central Argo delivery intent and v1 baseline |
| `agent.local.yaml` | Agent delivery intent and v1 baseline |
| `app-v2.local.yaml` | The prepared application version for the three updates |

Do not copy examples over these files or create a new environment configuration for the talk.
Do not display entire private values files: show only reviewed non-secret fields/diffs.

Prepare the v2 version and an explicit hub Helm command in this shell:

```bash
DEMO_V2_VERSION=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("version")' \
  "$DEMO_VALUES_DIR/app-v2.local.yaml")
SUB_V2_CHART_VERSION=0.2.0
HELM_HUB=(helm --kube-context "$HUB_CONTEXT")
if [[ -n ${HUB_KUBECONFIG:-} ]]; then
  HELM_HUB+=(--kubeconfig "$HUB_KUBECONFIG")
fi
```

`SUB_V2_CHART_VERSION` must match the **already published** v2 package in the prepared Helm
repository; confirm/change it backstage if your package version differs. Chart package version
and displayed app version are separate fields. The one-field `app-v2.local.yaml` belongs to the
app chart's values shape: do **not** pass it directly as a delivery-chart overlay. The update
commands below map its version to the delivery chart's `application.version` explicitly.

**Ownership rule:** the shown update commands are for the existing **CLI Helm-owned intent
releases**. If Git/Argo owns those intent resources, use that owner's rehearsed values/revision
change instead; do not introduce a second owner. A chart fetched from Git does not mean that
CLI Helm release updates themselves are automatically Git-reconciled.

### 3. Confirm starting states

- [ ] Existing production, QA, and ZTP clusters are available; guest node/operator checks pass.
- [ ] The ZTP site is already installed. Site values and retained generated resources are available.
- [ ] Governance starts inform / NonCompliant, with an absent or incorrect harmless baseline.
- [ ] Subscription, push, and agent apps are at v1 and their actual HTTPS pages work.
- [ ] v2 chart package is published; local version input is prepared; no publishing during the talk.
- [ ] Principal/agent connection, local-controller permissions, and isolated instances are ready.
- [ ] Actual Subscription Deployment/Route names and local/principal Application names are set.
- [ ] Policy/drift/app updates are authorized; v1/inform restoration is agreed for afterward.

If those states need restoring, do it before starting the clock using [setup](setup.md) and
[reset](reset.md), not by creating clusters during the presentation.

### 4. Open the browser tabs

1. **ACM:** All Clusters → Infrastructure → Clusters.
2. **Virtualization:** hub cluster → VirtualMachines, project `$ZTP_CLUSTER`, VM `$ZTP_VM`.
3. **Governance:** Policies, namespace `$POLICY_NS`, policy `$GOVERNANCE_RELEASE`.
4. **Subscription:** ACM Applications, `$SUB_RELEASE` in `$SUB_NS`, topology view.
5. **Central Argo CD:** Application `$PUSH_APP` in the central instance.
6. **Agent principal Argo CD:** Application `$AGENT_APP` in the separate principal instance.
7. The three real application pages; optional reviewed source/values comparison in Git.

Authenticate before sharing the screen. If the application routes use a default ingress certificate, configure the presenter browser to trust that cluster CA before the talk. Application screenshots were captured with certificate verification disabled for this lab. Menu names vary slightly by installed console version.
Never show Secret pages, kubeconfigs, BMC passwords, signed ISO URLs, ignition, or unfiltered
authentication/installer logs.

## Presentation running order

| Time | What we show | What we explain |
| --- | --- | --- |
| 00–04 | Console fleet + short CLI inventory | Hub, targets, labels, controller responsibilities |
| 04–16 | Precreated ZTP cluster, its definition and generated resources | How the existing site was built; no provisioning |
| 16–29 | Policy UI + production/excluded target evidence | Inform, enforce, continuous drift correction, placement scope |
| 29–36 | Subscription topology + actual app | Legacy delivery via versioned Helm package |
| 36–45 | Central Argo tree + remote rollout | Placement and registration generate centrally reconciled Applications |
| 45–55 | Principal + local Application/controller + app | Central intent, local reconciliation, returned status |
| 55–58 | Fleet recap + comparison | Which control loop runs where, and why that matters |
| 58–60 | Buffer / one short question | No new segment, provisioning, or cleanup |

**Surface cues:** CONSOLE = navigate/highlight; TERMINAL = precise read-only proof; APP = real
HTTPS result; ADVANCE = an explicitly authorized policy/app transition on the prepared fleet.
The assistant authoring this runbook does not execute those transitions.

## Act 0 — orient the audience · 00:00–04:00

### Step 1 — CONSOLE: show the prepared fleet

![Fleet view showing all three prepared managed clusters Ready](screenshots/01-fleet.png)

**Show:** Fleet management → Infrastructure → Clusters; point to the three precreated Ready managed clusters.

All Clusters → Infrastructure → Clusters. Point to the hub/local cluster, production target,
agent target, and precreated ZTP site. Open production Overview: availability, version, labels.

**Explain:** “These clusters were created before the session. We will inspect the lifecycle
resources, then demonstrate policy and application changes on the existing targets. Watch
where intent lives and which controller makes each change.”

### Step 2 — TERMINAL: anchor the UI in actual APIs

```bash
oc_hub get clusterversion version
oc_hub get multiclusterhub -A
oc_hub get managedclusters
```

**Point:** hub version/ACM and accepted/available remote clusters. The local-cluster registration
is the hub itself, not another remote target. Helm is the shared rendering/definition format;
SiteConfig, policy controllers, subscription machinery, and Argo have different responsibilities.

**Transition:** “Start with the completed site and trace how it became a managed cluster.”

## Act 1 — explain the precreated lifecycle and ZTP · 04:00–16:00

### Step 3 — CONSOLE: start at the completed result · 04:00–05:30

![The precreated ZTP site and its installed node](screenshots/02-ztp-cluster.png)

**Show:** open the precreated ZTP site from the fleet and point to the installed node and cluster status.

ACM Clusters → `$ZTP_CLUSTER` → Overview. Show availability, release, node count and identity.

**Say:** “A full install takes longer than this segment, so we created this site beforehand.
This is the real completed cluster. We are not starting an installation or waiting for one.”

### Step 4 — SOURCE / TERMINAL: show the intent used to build it · 05:30–07:30

Open the reviewed chart and safe fields from the precreated local site values. Then inspect
selected fields of the actual ClusterInstance:

```bash
oc_hub get clusterinstance "$ZTP_CLUSTER" -n "$ZTP_CLUSTER" -o json |
  jq '{site:.spec.clusterName,release:.spec.clusterImageSetNameRef,templates:.spec.templateRefs,
       nodes:[.spec.nodes[]|{hostName,role,bootMode,templateRefs}]}'
```

**Explain:** Helm rendered ClusterInstance; SiteConfig expanded cluster/node templates. Release
selection is explicit; one master means SNO. Credentials are referenced, not displayed. If the
creation was Helm-driven, say so; show actual Argo sync history only if that was the real owner.

### Step 5 — TERMINAL: follow the generated resources · 07:30–09:30

```bash
oc_hub get clusterinstance "$ZTP_CLUSTER" -n "$ZTP_CLUSTER" -o json |
  jq -r '.status.conditions[] | [.type,.status,.reason] | @tsv'
oc_hub get agentclusterinstalls,infraenvs,baremetalhosts -n "$ZTP_CLUSTER"
```

**Explain:** ClusterInstance validation/rendering is separate from backend installation.
AgentClusterInstall tracks the install, InfraEnv supplied discovery, and BareMetalHost connects
the host to boot control. These are retained results, not live condition transitions.

### Step 6 — CONSOLE: explain the VM/BMC path · 09:30–12:00

Virtualization → VirtualMachines → `$ZTP_VM` in `$ZTP_CLUSTER` → Overview/Details. Point to the
running installed VM, root disk, resources and network. Brief terminal support:

```bash
oc_hub get virtualmachinebmcs -n "$ZTP_CLUSTER"
oc_hub get agents -n "$ZTP_CLUSTER"
```

**Explain:** the VM substituted for hardware; the BMC exposed Redfish power/media control;
discovery reported inventory; Assisted Installer wrote OpenShift to disk. Describe the actual
prepared boot history, including any manual intervention. Transient media/import resources may
already be gone; do not recreate them. Label genuine preparation captures as such.

### Step 7 — CONSOLE / TERMINAL: distinguish the three health layers · 12:00–16:00

Return to ACM site Overview / Nodes, then:

```bash
oc_hub get managedcluster "$ZTP_CLUSTER"
oc_ztp get nodes
oc_ztp get clusteroperators
```

**Point:** VM Running, guest node/operators healthy, ACM accepted/joined/available. Use the
installed site's context for guest checks, not the hub's node view.

**Transition:** “That explains the lifecycle behind our precreated site. Once a cluster is
available, how do we keep it aligned with the baseline?” Switch to Governance.

**No lifecycle mutations:** no `prereqs.sh --apply`, infrastructure Helm updates, hold toggles,
ISO insertion, VM power actions, reinstallation, or progress watches in this act.

## Act 2 — governance on the existing production target · 16:00–29:00

### Step 8 — CONSOLE: inform observes · 16:00–19:00

![Governance policies in the inform starting state](screenshots/03-policy-inform.png)

**Show:** Governance → Policies; identify the baseline policy with three violations and the compliant GitOps installation policy.

Governance → `$GOVERNANCE_RELEASE` → Details / cluster compliance. Read one NonCompliant message.
Explain the harmless required ConfigMap value and show which cluster was selected.

### Step 9 — TERMINAL: prove selection and lack of correction · 19:00–21:00

```bash
oc_hub get placementdecisions -n "$POLICY_NS" \
  -l "cluster.open-cluster-management.io/placement=$GOVERNANCE_RELEASE" -o json |
  jq -r '.items[].status.decisions[] | .clusterName'
oc_prod get configmap demo-security-baseline -n "$BASELINE_NS" --ignore-not-found
```

**Explain:** the three demo-enabled managed clusters are selected; the hub is excluded. Inform reports but does not create/correct the object;
initial absence/NotFound can be expected. Do not claim absence if displaying an existing object.

### Step 10 — ADVANCE / CONSOLE: enforce corrects · 21:00–24:00

![Governance after enforcement on the three targets](screenshots/04-policy-enforce.png)

**Show:** the same policy after its terminal Helm upgrade; wait for the three target results to turn compliant.

Using the existing Helm-owned release and prepared local input:

```bash
scripts/setup-demo.sh governance-enforce --apply
oc_hub wait "policy/$GOVERNANCE_RELEASE" -n "$POLICY_NS" \
  --for=jsonpath='{.status.compliant}'=Compliant --timeout=90s
oc_prod get configmap demo-security-baseline -n "$BASELINE_NS" -o json | jq '.data'
```

**Point:** console becomes Compliant; target contains the required value. The definition lives
on the hub; the managed policy controller corrects the target. Parent/embedded remediation
must not conflict. This changes policy intent, not infrastructure.

### Step 11 — ADVANCE / TERMINAL: demonstrate continuous remediation · 24:00–26:00

```bash
scripts/drift-demo.sh --apply
```

Explain the authorized one-field drift in the demo-owned ConfigMap and the restored baseline.
The script checks production identity, asks for confirmation, and bounds the remediation wait.
Do not promise to catch a transient red UI state or measure latency from an immediate wait.

### Step 12 — CONSOLE / TERMINAL: prove exclusion · 26:00–29:00

Show the selected-cluster list and inspect the prepared negative target:

```bash
oc_excluded get namespace "$BASELINE_NS" --ignore-not-found
```

Expect no baseline namespace, or compare its known initial state if it legitimately pre-existed.
**Transition:** “Fleet-wide doesn't mean every cluster. Now keep governance separate and change
how we deliver an application.”

## Act 3 — legacy subscription delivery · 29:00–36:00

### Step 13 — APP: show v1 and request v2 early · 29:00–30:15

Show version/environment/model on the subscription app's real HTTPS page. Position this as the
legacy model deprecated in ACM 2.17—not an OLM operator Subscription. For approved CLI Helm intent:

```bash
"${HELM_HUB[@]}" upgrade "$SUB_RELEASE" "$DEMO_ROOT/charts/delivery" -n "$SUB_NS" \
  -f "$DEMO_VALUES_DIR/subscription.local.yaml" \
  --set-string "subscription.chartVersion=$SUB_V2_CHART_VERSION" \
  --set-string "application.version=$DEMO_V2_VERSION" --wait --timeout 2m
```

This updates the existing intent release. In this lab the managed Subscription retained its old inputs; the verified v2 workaround recreates the demo Subscription as described in [setup](setup.md#subscription-update-workaround). If the workaround has not been performed, show v1 and do not claim v2 has deployed.

### Step 14 — CONSOLE / TERMINAL: source, selection, destination · 30:15–33:30

![Subscription topology showing placement and workloads on three clusters](screenshots/06-subscription-topology.png)

**Show:** Applications → `acm-subscription` → Topology; trace Subscription → Placement → three clusters → workload.

ACM Applications → `$SUB_RELEASE` in `$SUB_NS` → Topology. Point to Channel, Subscription,
placement/target, delivered workload. Then:

```bash
oc_hub get subscriptions.apps.open-cluster-management.io "$SUB_RELEASE" -n "$SUB_NS" -o json |
  jq '{chart:.spec.name,packageVersion:.spec.packageFilter.version,
       placement:.spec.placement.placementRef,phase:.status.phase}'
oc_prod get deployment "$SUB_DEPLOYMENT" -n "$SUB_NS"
```

**Explain:** Channel says where, Subscription says what, Placement says which clusters.
A package version request or hub phase alone is not proof of the application response.

### Step 15 — APP: prove v2 · 33:30–36:00

![Subscription application serving version 2](screenshots/09-subscription-v2.png)

```bash
oc_prod get route "$SUB_ROUTE" -n "$SUB_NS" -o jsonpath='https://{.spec.host}{"\n"}'
```

Hard-refresh the actual HTTPS page and point to v2, unchanged environment, subscription model. In this lab, the managed Subscription must be recreated after the version change; follow the tested [terminal procedure](setup.md#subscription-update-workaround), then update `$SUB_DEPLOYMENT` and `$SUB_ROUTE` to the newly generated names. This briefly interrupts the demo workload. If it has not completed, show the actual current version and revisit it later.

**Transition:** “Same app and fleet selection; now let central Argo perform reconciliation.”

## Act 4 — central Argo push · 36:00–45:00

### Step 16 — ARGO / TERMINAL: explain the control loop · 36:00–39:30

![Central push application at the initial version](screenshots/05-push-v1.png)

![Central Argo application tree with healthy synced resources](screenshots/10-argocd-push.png)

**Show:** central Argo → `$PUSH_APP`; point to Synced, Healthy, and the Deployment, Service and Route.

Central Argo → `$PUSH_APP` → Details / tree. Show v1 source, registered destination, Synced/Healthy
and actual app page. Trace the target decision and generator:

```bash
oc_hub get placementdecisions -n "$CENTRAL_NS" \
  -l "cluster.open-cluster-management.io/placement=$PUSH_RELEASE" -o json |
  jq -r '.items[].status.decisions[] | .clusterName'
oc_hub get gitopscluster "$PUSH_RELEASE" -n "$CENTRAL_NS"
oc_hub get applicationset "$PUSH_RELEASE" -n "$CENTRAL_NS" -o json |
  jq '{generator:.spec.generators,path:.spec.template.spec.source.path,
       destination:.spec.template.spec.destination}'
```

**Explain:** ACM selects/integrates the cluster, ApplicationSet generates an Application,
and the **central** application-controller reconciles the remote API. Argo renders the Helm
chart; don't install a separate Helm owner on those target objects. No registration Secret dump.

### Step 17 — ADVANCE / ARGO: reuse the local input for v2 · 39:30–41:30

```bash
"${HELM_HUB[@]}" upgrade "$PUSH_RELEASE" "$DEMO_ROOT/charts/delivery" -n "$CENTRAL_NS" \
  -f "$DEMO_VALUES_DIR/push.local.yaml" \
  --set-string "application.version=$DEMO_V2_VERSION" --wait --timeout 2m
```

Show the generated Application's updated Helm input and sync result/history. No manual edits
to its Deployment or generated Application. If sync is fast, use its history instead of forcing
another update to catch OutOfSync on screen.

### Step 18 — TERMINAL / APP: prove remote rollout · 41:30–45:00

![Central push application at version 2](screenshots/07-push-v2.png)

```bash
oc_prod rollout status "deployment/$APP_RELEASE" -n "$PUSH_NS" --timeout=90s
oc_hub get application "$PUSH_APP" -n "$CENTRAL_NS" -o json |
  jq '{sync:.status.sync.status,health:.status.health.status}'
oc_prod get route "$APP_RELEASE" -n "$PUSH_NS" -o jsonpath='https://{.spec.host}{"\n"}'
```

Hard-refresh the push app: v2 / production / central push. Explain that the chart's content
checksum drives a pod-template change, not just a stored ConfigMap update.

**Transition:** “Keep central intent, but move application reconciliation onto the target.”

## Act 5 — Argo CD Agent managed mode · 45:00–55:00

### Step 19 — PRINCIPAL / TERMINAL: show both sides · 45:00–50:00

![Agent principal Argo application tree](screenshots/11-argocd-agent.png)

**Show:** the separate agent-principal Argo console → `$AGENT_APP`; compare its returned status with the managed-cluster objects in the terminal.

Separate principal Argo → `$AGENT_APP`. Show the source and v1 intent, then inspect the prepared
managed target:

```bash
oc_hub get gitopscluster "$AGENT_RELEASE" -n "$PRINCIPAL_NS" -o json |
  jq '{principal:.spec.argoServer,agent:.spec.gitopsAddon.argoCDAgent}'
oc_hub get managedclusteraddons -n "$AGENT_CLUSTER"
oc_agent get deployments -n "$AGENT_GITOPS_NS"
oc_agent get application "$LOCAL_AGENT_APP" -n "$AGENT_GITOPS_NS" -o json |
  jq '{name:.metadata.name,destination:.spec.destination,
       sync:.status.sync.status,health:.status.health.status}'
```

**Explain:** principal holds central intent; managed agent/local application-controller performs
application reconciliation. A Ready Deployment or destination name alone is not connection proof.
Use the actual rehearsed connection-status signal, then demonstrate the v2/status round trip.
The ACM integration is Technology Preview in 2.17, separate from ManifestWork application pull.

### Step 20 — ADVANCE: change principal intent with existing values · 50:00–51:00

```bash
"${HELM_HUB[@]}" upgrade "$AGENT_RELEASE" "$DEMO_ROOT/charts/delivery" -n "$PRINCIPAL_NS" \
  -f "$DEMO_VALUES_DIR/agent.local.yaml" \
  --set-string "application.version=$DEMO_V2_VERSION" --wait --timeout 2m
```

**Say:** “We request the version centrally. We are not patching the remote Deployment to simulate
agent delivery.” Keep push and agent principal instances visibly separate.

### Step 21 — TERMINAL / APP / PRINCIPAL: prove the round trip · 51:00–55:00

![Agent-delivered application serving version 2](screenshots/08-agent-v2.png)

```bash
oc_agent rollout status "deployment/$APP_RELEASE" -n "$AGENT_APP_NS" --timeout=90s
oc_agent get application "$LOCAL_AGENT_APP" -n "$AGENT_GITOPS_NS" -o json |
  jq '{sync:.status.sync.status,health:.status.health.status}'
oc_agent get route "$APP_RELEASE" -n "$AGENT_APP_NS" -o jsonpath='https://{.spec.host}{"\n"}'
oc_hub get application "$AGENT_APP" -n "$PRINCIPAL_NS" -o json |
  jq '{sync:.status.sync.status,health:.status.health.status}'
```

Show the actual v2 HTTPS response, then return to the principal's current status.
**Land:** “Central intent, local reconciliation, central visibility.” Do not imply zero
credentials, no network dependencies, unlimited scale, or new updates working disconnected.

## Close — 55:00–58:00

Return to the precreated site's ACM availability as a recap—not a claim it finished during
the talk. Compare the three control loops:

| Question | Subscription | Central push | Agent managed mode |
| --- | --- | --- | --- |
| Central intent | Channel / Subscription | ApplicationSet / Application | Principal ApplicationSet / Application |
| App reconciliation | Subscription machinery | Central application-controller | Managed-cluster application-controller |
| Source here | Versioned Helm package | Helm chart in Git | Same Helm chart in Git |
| Proof | Target workload and response | Central status + remote rollout/response | Local reconciliation/response + returned principal status |
| Positioning | Legacy / deprecated in ACM 2.17 | Standard integrated push pattern | ACM integration Technology Preview in 2.17 |

**Say:** “We kept the application constant. What changed was controller location, permissions,
network path, and status return. Lifecycle gives us a cluster; governance maintains a baseline;
application delivery is its own control loop.” Leave the comparison visible for the buffer.

## After the audience leaves

Restore v1/inform through the same owner, using the unchanged base local files and
[reset guidance](reset.md). Never uninstall prerequisite releases, delete cluster namespaces,
reinstall the ZTP site, or destroy cloud infrastructure as routine demo reset.

Detailed speaking notes remain available for [lifecycle](runbooks/01-lifecycle-ztp.md),
[governance](runbooks/02-governance.md), [subscription](runbooks/03-app-subscriptions.md),
[push](runbooks/04-app-argocd-push.md), and [agent](runbooks/05-app-argocd-agent.md).
