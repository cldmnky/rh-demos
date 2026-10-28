# Act 1 — explain the precreated ZTP site

**04:00–16:00 · 12 minutes.** CONSOLE → source → TERMINAL → Virtualization → ACM.
Use the initialized shell; site/VM names are `$ZTP_CLUSTER` / `$ZTP_VM`. Local creation inputs
are `ztp-target.local.yaml`, `ztp-site.local.yaml`, and the selected helper values from
`prereqs.local.yaml`. [Setup](../setup.md) completes the site before showtime.

## 1. CONSOLE — start with the result (04:00–05:30)

All Clusters → Infrastructure → Clusters → the ZTP site → Overview. Point to Available, release,
node count, identity. **Say:** “We created this site before the session. Instead of waiting for
an installation, let's trace how the definition produced this healthy managed cluster.”

## 2. SOURCE / TERMINAL — show the contract (05:30–07:30)

Open the chart and reviewed **non-secret** local site values. Helm renders ClusterInstance;
SiteConfig renders installation resources. If Argo owned that creation, show its actual source
revision/sync history; otherwise identify the Helm-driven path honestly.

```bash
oc_hub get clusterinstance "$ZTP_CLUSTER" -n "$ZTP_CLUSTER" -o json |
  jq '{site:.spec.clusterName,release:.spec.clusterImageSetNameRef,templates:.spec.templateRefs,
       nodes:[.spec.nodes[]|{hostName,role,bootMode,templateRefs}]}'
```

Point to release selection and cluster/node templates. Explain BMC/pull credentials as references;
do not display credentials or reapply the chart. One master is the SNO footprint.

## 3. TERMINAL — inspect what SiteConfig generated (07:30–09:30)

```bash
oc_hub get clusterinstance "$ZTP_CLUSTER" -n "$ZTP_CLUSTER" -o json |
  jq -r '.status.conditions[] | [.type,.status,.reason] | @tsv'
oc_hub get agentclusterinstalls,infraenvs,baremetalhosts -n "$ZTP_CLUSTER"
```

**Say:** “Rendered and applied is not the same as installed. ClusterInstance tracks intent;
AgentClusterInstall tracks installation; InfraEnv supplied discovery; BareMetalHost connected
host inventory and boot control.” Read actual generated names/conditions rather than assuming
all child objects use the cluster name. Explain SiteConfig ordering separately from Argo sync waves.

## 4. CONSOLE / TERMINAL — explain the host boot path (09:30–12:00)

Hub → Virtualization → VirtualMachines → project `$ZTP_CLUSTER` → `$ZTP_VM` → Overview/Details.
Point to running VM, root disk, allocated resources and current network. The VM now runs
installed OpenShift, not the installer.

```bash
oc_hub get virtualmachinebmcs -n "$ZTP_CLUSTER"
oc_hub get agents -n "$ZTP_CLUSTER"
```

**Say:** “A VM substitutes for a physical host. The lab BMC exposes Redfish power/media control.
Discovery reported host inventory; Assisted Installer installed the selected release to disk.”
Explain the actual prepared boot history. Disclose any manual step rather than describing an
unverified fully unattended run. Transient ISO imports/events may be gone; genuine preparation
captures can illustrate them if labeled. Never recreate media, restart, or replay provisioning.

## 5. CONSOLE / TERMINAL — prove all three health layers (12:00–15:00)

Return to ACM site Overview / Nodes. VM health, guest-cluster health, and ACM availability are
separate checks:

```bash
oc_hub get managedcluster "$ZTP_CLUSTER" -o json |
  jq -r '.status.conditions[] | select(.type=="HubAcceptedManagedCluster" or
       .type=="ManagedClusterJoined" or .type=="ManagedClusterConditionAvailable") |
       [.type,.status,.reason] | @tsv'
oc_ztp get nodes
oc_ztp get clusteroperators
```

Expect accepted/joined/available, one Ready guest node, healthy guest operators. **Say:** “The
outcome isn't just a booted machine. It is a healthy cluster with a managed identity that
placement and policy can select.” No installation waits or later-progress promises.

## 6. LAND — governance (15:00–16:00)

Return to fleet, then Governance. “That is the lifecycle behind the precreated site. Once a
cluster is available, how do we keep its configuration aligned with our baseline?”

If health is unexpectedly degraded, state that and continue explaining the retained resources;
do not reinstall or change boot state. No Secrets, ignition, signed ISO URLs, or unfiltered logs.
