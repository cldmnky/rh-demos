# Prepare the ACM demo

## 1. Prepare the shell once

Prerequisites: an existing ACM hub, Bash, authenticated `oc`, Helm, Ruby, jq, Git, and tar.
Use the same Bash shell for the runbook. From `acm-demos/`:

```bash
source scripts/demo-shell.sh --prereqs
```

This prompts for missing hub context/API, production/QA/ZTP cluster names, the VM name, and
release image-set name. It optionally accepts per-target kubeconfig paths. It uses only local
`oc config` reads—no API requests, cluster changes, file writes, or current-context switches.
Expected API URLs are explicit confirmations, not silently inferred identities.

Keep repeatable inputs in trusted **ignored** `config/demo.env`, or set `DEMO_ENV_FILE` to a
trusted private file before sourcing. The file is shell code: never source an untrusted download.
The initializer exports only allowlisted non-secret variables and connection-file paths; keep
actual tokens, passwords, pull secrets, and private keys out of shell configuration.
`--non-interactive` fails on missing required variables instead of hanging for input. Initial
`--prereqs` mode does not require connections to clusters that have not yet been created.

Useful connection variables: `HUB_CONTEXT/HUB_API`, then `PROD_*`, `AGENT_*`, `ZTP_*`, and
`EXCLUDED_*`. Each can have an optional `*_KUBECONFIG` path. `QA_CLUSTER` identifies the AWS SNO; the agent target can be any of the prepared clusters. Choose the actual agent target and QA cluster in the ignored local environment file. The standard demo names are configurable shell variables,
not hardcoded deployment endpoints. The shell does not persist answers automatically.

## 2. Prepare ignored local values

All configuration consumed by setup is under `$DEMO_VALUES_DIR` (defaults to `values/`).
Do not replace or commit the existing local files. Only example inputs are public. New
inputs must use `*.local.yaml`; credential-bearing inputs must be kept private even though
Git ignores them. Ignore rules do not encrypt files or untrack files previously committed.

The prerequisite coordinator requires:

| Local file | Purpose |
| --- | --- |
| `prereqs.local.yaml` | Approvals, source credential, regions, operator version, ZTP orchestration |
| `assisted-service.local.yaml` | Storage and verified release-matched RHCOS image metadata |
| `kubevirtbmc.local.yaml` | Reviewed settings for the pinned community BMC chart |
| `ztp-target.local.yaml` | VM/storage/network/boot inputs; `name` and `vmName` match shell values |
| `ztp-site.local.yaml` | ClusterInstance network, release, template and secret references; `holdInstallation: false` |
| Additional `ztp-*.local.yaml` files | Only components explicitly listed in `ztp.components` |

### Prerequisite profile

Use this structure in the ignored `prereqs.local.yaml`, replacing all placeholders. No real
credentials are shown here. Existing ACM credentials are reused; `credentials.data` is needed
only when the source Secret does not exist.

```yaml
approvals:
  infrastructure: false       # cloud spend, VM disks, OS installation
  sharedOperators: false      # OLM, HCO and SiteConfig setting changes
  communityBmc: false         # community controller, CRD/webhooks and RBAC
  developerPreview: false     # approved declarative-hotplug integration
  credentialStorage: false    # Secret material persists in Helm release history
credentials:
  name: aws
  namespace: default
  data: {}                   # private input only if creating the missing credential
production:
  region: <approved-production-region>
qa:
  region: <approved-qa-region>
aws:
  instanceType: <approved-control-plane-instance-type>
  workerType: <approved-worker-instance-type>
  clusterSet: default
  demoPlacement: false        # opt in new targets only after placement review
virtualization:
  namespace: openshift-cnv
  channel: <compatible-versioned-channel>
  source: redhat-operators
  startingCSV: <approved-starting-csv>
mch:
  name: multiclusterhub
  namespace: open-cluster-management
releaseImage: <approved-release-image-if-image-set-is-missing>
waitTimeout: 90m
ztp:
  pullSecret: <site-pull-secret-name>
  bmcSecret: <site-bmc-secret-name>
  bmcCredentials: {}          # private username/password only if Secret missing
  bootControllerNamespace: <verified-boot-backend-namespace>
  bootControllerDeployment: <verified-boot-backend-deployment>
  # Optional if that Deployment is absent: use a reviewed, dependency-ready local chart.
  bootControllerChart: <private-path-to-reviewed-backend-chart>
  bootControllerValuesFile: <private-path-to-its-local-values>
  bootControllerRelease: <approved-backend-release-name>
  components:
    - ztp-target
    - ztp-site                # site creation must be last
```

If the source `default/aws` Secret is absent, privately supply `credentials.data` keys
`aws_access_key_id`, `aws_secret_access_key`, `baseDomain`, `pullSecret`, `ssh-publickey`, and
`ssh-privatekey`; optional proxy/trust fields use the ACM credential's normal names. Do not
pass these through CLI `--set`, terminal recordings, or chat. Prefer an approved secret manager
when available. Copying them to target Secrets and Helm release history needs explicit acceptance.

ZTP components can include `ztp-network`, `ztp-dns-guest`, `ztp-dns-hub`, `ztp-endpoints`, and
the rehearsed `ztp-boot-transition` Job **before** `ztp-site`. List only the network/boot path
actually validated for your environment; the presence of an old local file does not enable it.
A functioning unattended boot backend is required. The script reuses the specified Deployment;
if absent, it can install the explicitly supplied reviewed local backend chart/values/release.
Without either an existing backend or those inputs, apply stops **before cloud creation**.
It does not invent Metal3 configuration or silently substitute manual ISO boot. Keep any
backend-specific network, images and RBAC in that chart's ignored private inputs.

## 3. Check the starting fleet (read-only)

```bash
scripts/preflight.sh
scripts/prereqs.sh --check
```

The check reports missing resources and exits nonzero when the starting fleet is incomplete.
An API/RBAC failure stops execution; it is never treated as absence. Credential values are not
displayed. Existence does not prove readiness: final guest health is checked separately.

## 4. Create missing prerequisites (approved preparation, not live presentation)

```bash
scripts/prereqs.sh --apply
```

Review the profile, change the explicit approvals to true, and confirm the operation at the
prompt. The coordinator:

1. Reuses the ACM AWS credential or creates the missing source Secret through Helm.
2. Reuses or creates the requested ClusterImageSet.
3. Reuses production and QA clusters; otherwise starts Hive AWS installation: production is
   three control planes plus three workers; QA SNO is one control plane and zero workers.
4. Installs missing OpenShift Virtualization OLM/HCO resources. Existing operator configuration
   is not adopted into a new Helm release. Automatic OLM approval for a new install is explicit
   preparation behavior, not permission to change an existing Subscription.
5. Enables only the approved HCO hotplug and MCH SiteConfig keys with resource-version guarded
   patches, preserving unrelated settings. Unsupported HCO schemas fail closed.
6. Creates a missing AgentServiceConfig and installs the pinned BMC controller when its API
   is absent. Release/image/storage inputs must already be verified for the hub.
7. Reuses or installs the explicitly configured boot backend, creates missing ZTP credential
   copies, prepares the selected substrate/helper charts, and
   creates site intent. Existing ClusterInstance/VM boot state is not reapplied on rerun.
8. Uses bounded waits for cluster join/availability and ZTP installation completion.

This is a staged operation, **not a transaction**. Failure leaves useful resources for diagnosis;
there is no automatic rollback, namespace deletion, AWS teardown, or retry of Redfish actions.
Cloud quotas, DNS, image accessibility, capacity, boot-controller interoperability, SCC/RBAC,
and supported feature configuration must be reviewed first. Real credentials and cloud/backend
installation cannot be validated by offline rendering. Do not assume this script has completed
an environment until its explicit checks pass.

Existing imported/console-created clusters are not replaced, Helm-adopted, relabeled, or given
new cluster-set membership. A namespace collision without a recognized cluster stops creation.
The prerequisite-only AWS chart is under `scripts/charts/prereqs`; it supports missing production
clusters without changing the standalone AWS SNO chart's protection against adopting them.

## 5. Connect to the completed targets

Securely obtain managed kubeconfigs through the approved workflow; keep them under ignored
`private/` or outside the repository. Do not print kubeconfig Secrets. Then source the **same**
initializer in full mode:

```bash
source scripts/demo-shell.sh
scripts/verify.sh
```

Fill missing target contexts/APIs, actual generated app names, and presentation variables.
The initializer exposes `oc_hub`, `oc_prod`, `oc_ztp`, `oc_agent`, and `oc_excluded`, each carrying
its explicit context, optional kubeconfig path, and request timeout. `verify.sh` checks hub-side
acceptance/join/availability and guest node/operator health, without changing anything.

ZTP must already be completed before the presentation. No provisioning watches, BMC actions,
hold toggles, or reinstall attempts are part of the demo runbook.

## 6. Prepare application and governance scenarios

Use `scripts/setup-demo.sh COMPONENT` to render a **metadata-only resource summary** from
`$DEMO_VALUES_DIR/COMPONENT.local.yaml`. Add `--apply` only for an authorized installation or
transition; it checks hub identity and requires confirmation. No all-components bulk apply.

```bash
scripts/setup-demo.sh governance-inform
scripts/setup-demo.sh push
# Approved example (changes hub intent and selected managed workloads):
scripts/setup-demo.sh governance-inform --apply
```

Supported scenario components: `gitops-operator`, `governance`, `governance-inform`,
`governance-enforce`, `subscription`, `push`, `agent-principal`, and `agent`. Prepared v2 commands
`subscription-v2`, `push-v2`, and `agent-v2` read the correspondingly named ignored local files
but upgrade the **same** intent releases. Supply complete desired values in each file; for
subscription, also select a real prepublished v2 package. Local values for
push/subscription/agent point to actual reachable sources and matching namespaces. Prepare
principal/certificates, placement labels, bindings and target permissions before agent intent.
No script broadens RBAC or labels an existing cluster merely to make the demo select it.

Optional in-cluster lab Git/Helm source:

```bash
scripts/prepare-demo-source.sh
# Explicitly approved source deployment/update:
scripts/prepare-demo-source.sh --apply
```

This packages the app in a disposable temporary Git repository, never commits/pushes the real
repository, uses relative Helm package URLs, and uses Helm for both the bundle ConfigMap and
server. `demo-source.local.yaml` must set `bundleConfigMap` equal to `$SOURCE_BUNDLE`. Discover
its real Route and update ignored delivery values; no cluster domain is hardcoded. The lab
source is not an authenticated production Git service. Keep source publication offstage.

If an in-place subscription update retains previous Helm inputs on a particular target,
resolve that during preparation. A controller-aware recreation can briefly remove the workload
and change generated Deployment/Route names; see the tested procedure below.
Do not add automatic subscriber deletion/recreation to the presentation or prerequisite scripts,
and do not claim v2 until the actual target response proves it. Re-source the shell initializer
with the newly observed names after any such repair.

Before showtime: governance inform/noncompliant, all apps v1 healthy, v2 inputs prepared, and
actual generated names confirmed. If Git owns intent, use that owner rather than CLI Helm
upgrades. Run the [presenter checklist](presenter-runbook.md) and restore v1 offstage afterward.

## Current pod-network ZTP access and add-on

The ZTP guest API and ingress are internal to the hub. For workstation API access, keep a
separate terminal open with the hub endpoint port-forward, then use the private ZTP kubeconfig
configured for `https://127.0.0.1:16443` and the guest API TLS server name:

```bash
oc_hub -n "$ZTP_CLUSTER" port-forward service/ztp-endpoint 16443:6443
```

The standard SiteConfig template disables `applicationManager`. The existing ZTP site has that
add-on enabled on its generated KlusterletAddonConfig; it is needed for Subscription delivery and
the central Argo registration path. SiteConfig makes the cluster template reference immutable
after creation, so check that this remains enabled if the site is reconciled or recreated. For a
new site, use a site-specific copy of the cluster template with applicationManager enabled before
creating the ClusterInstance. Keep the in-cluster DNS, endpoint and related ZTP services running.

## Subscription update workaround

In the current ACM lab the Helm subscriber retained old inputs after the root Subscription was
updated. The following tested procedure briefly removes **only the demo Subscription on the selected production target**
and changes its generated workload and Route names. First perform the v2 Helm upgrade in the
[Subscription act](runbooks/03-app-subscriptions.md), then wait until the ManifestWork contains
the requested package version. Recreate the managed copy from that work:

```bash
oc_hub get manifestwork "$SUB_NS-$SUB_RELEASE" -n "$PROD_CLUSTER" -o json |
  jq -r '.spec.workload.manifests[] | select(.kind=="Subscription") | .spec.packageFilter.version'
# Proceed only after the printed version is the requested version.
oc_prod delete subscription.apps.open-cluster-management.io "$SUB_RELEASE" -n "$SUB_NS"
oc_hub get manifestwork "$SUB_NS-$SUB_RELEASE" -n "$PROD_CLUSTER" -o json |
  jq -c '.spec.workload.manifests[] | select(.kind=="Subscription")' | oc_prod apply -f -
oc_prod get deployment,route -n "$SUB_NS"
```

Wait for the new Deployment and check the new Route's application response. Update the ignored
`SUB_DEPLOYMENT` and `SUB_ROUTE` values before sourcing the demo shell again. For v1 restoration,
upgrade with `subscription.local.yaml`, wait for the work to report `0.1.0`, and repeat the
recreation. The root Subscription and Placement remain owned by Helm and ACM.

### Presenter access to Argo

Both central Argo and the agent-principal UI use OpenShift SSO. The current lab grants the
`acm-demo-presenters` OpenShift group read-only Argo access; add the intended presenter to that group in the local environment.
The agent-principal chart enables a separate console Route and Dex, while its agent connection
uses the separate principal Route. Sign in to each UI through OpenShift and approve the normal
user-information consent when prompted. Terminal Helm actions use the hub credentials and are
not granted by this read-only UI role.
