# Git-Driven VM Lifecycle Demo — VMware Admin Edition

A 20-minute live demo for VMware administrators showing how OpenShift Virtualization uses GitOps, Tekton, and Ansible to fully automate the VM application lifecycle — creation, deployment, blue/green upgrade, and rollback — capabilities that require expensive VMware add-ons or extensive manual effort in vSphere.

---

## Overview

The demo is structured in three acts:

| Act | What you show | Time |
|---|---|---|
| 1 — Create | ArgoCD creates a VM from Git | ~5 min |
| 2 — Deploy | Tekton + Ansible installs the application | ~7 min |
| 3 — Upgrade | Blue/green upgrade, smoke test, cutover, rollback | ~8 min |

### The Core Idea

Both VMs — blue (active) and green (standby) — are defined in Git **before the demo starts**. Green has `runStrategy: Halted`: it is a powered-off standby that consumes zero CPU or RAM. The upgrade is driven entirely by **Tekton writing Git commits** — ArgoCD is the authoritative controller throughout.

> [SPEAKER NOTE: State the challenge]
> Traditional HA setups often require resource reservation for standby nodes. Here, we demonstrate a *truly* zero-cost standby. The VM is defined and ready to go, but consumes no compute until needed. This is GitOps-driven configuration management, not a vCenter HA cluster.

```
Helm values.yaml at rest (in Git):
  blue.runStrategy: "Always"         # active, running
  green.runStrategy: "Halted"        # standby, powered off (zero cost)
  traffic.activeSlot: "blue"         # LoadBalancer → blue

During upgrade (ArgoCD parameter overrides):
  Step 1 - Start green:
    green.runStrategy: "Always"      # ArgoCD starts green VM
    green.diskSnapshot.name: <blue-snapshot>  # Clone from blue's snapshot
    
  Step 2 - Cutover (after smoke test passes):
    traffic.activeSlot: "green"      # LoadBalancer → green
    blue.runStrategy: "Halted"       # ArgoCD halts blue (zero cost)
    
  Step 3 - Rollback (patch ArgoCD parameters):
    blue.runStrategy: "Always"       # Start blue
    green.runStrategy: "Halted"      # Halt green
    traffic.activeSlot: "blue"       # LoadBalancer → blue
    
Then clear parameters → values.yaml defaults take over
```

### The Three "VMware Can't Do This" Moments

| Moment | Why it matters |
|---|---|
| Both VMs defined in Git, green powered off | Standby VM with zero compute cost — vCenter has no concept of "desired off" in code |
| Upgrade and cutover are Git commits | Full audit trail, PR review, `git revert` for rollback — vCenter task history is read-only |
| Rollback is Git-driven | Commit traffic back to blue — no manual LB re-pointing |

> [SPEAKER NOTE: Summary]
> These three points highlight the difference between a declarative, GitOps-driven VM lifecycle and traditional, imperative vCenter operations. We're moving from clicks and task histories to code and immutable audit logs.

---

## Repository Layout

```
gitops-vmware-virt-demo/
├── README.md
├── argocd/
│   ├── application.yaml         # ArgoCD Application (prune: true, selfHeal: true)
│   ├── application-infra.yaml   # ArgoCD Application for pipeline infrastructure
│   ├── appproject.yaml          # ArgoCD AppProject for scoping
│   └── rbac.yaml                # ArgoCD controller permissions in vm-demo
├── chart/                       # Helm chart — ArgoCD sync target
│   ├── Chart.yaml
│   ├── values.yaml              # Default values: blue=Always, green=Halted, traffic=blue
│   └── templates/
│       ├── vm-blue.yaml         # VirtualMachine template
│       ├── vm-green.yaml        # VirtualMachine template
│       ├── service-lb.yaml      # LoadBalancer with MetalLB annotation
│       ├── service-blue-ssh.yaml    # ClusterIP for Ansible SSH to blue
│       ├── service-green-ssh.yaml   # ClusterIP for Ansible SSH to green
│       └── service-green-http.yaml  # ClusterIP for pre-cutover HTTP smoke test
├── pipelines/
│   ├── install-pipeline.yaml    # Tekton Pipeline: install-app
│   ├── upgrade-pipeline.yaml    # Tekton Pipeline: upgrade-app
│   ├── install-pipelinerun.yaml # Manual PipelineRun trigger
│   ├── upgrade-pipelinerun.yaml # Manual PipelineRun trigger for upgrade
│   ├── app-version.yaml         # ConfigMap — bump version to trigger upgrade
│   ├── ansible-configmaps.yaml  # Playbooks as ConfigMaps (reference only — not required)
│   ├── event-listener.yaml      # Tekton EventListener + GitHub webhook trigger
│   └── tasks/
│       ├── ansible-run-playbook.yaml  # Runs Ansible playbook via community-ansible-dev-tools
│       └── smoke-test.yaml            # curl health check with retry
├── ansible/
│   ├── install-app.yaml         # Playbook: install Apache httpd + v1.0
│   └── upgrade-app.yaml         # Playbook: deploy v2.0
└── scripts/
    └── setup-secrets.sh         # Helper to create vm-ssh-key and vm-cloud-init secrets
```

---

## Prerequisites

### Required Operators

Install from OperatorHub or apply pre-staged `Subscription` YAMLs:

| Operator | Namespace | Notes |
|---|---|---|
| OpenShift Virtualization (HCO) | `openshift-cnv` | Installs KubeVirt, CDI, SSP, CNAO |
| MetalLB Operator | `metallb-system` | Pre-existing address pool required (demo references it, does not create it) |
| OpenShift GitOps | `openshift-gitops` | ArgoCD instance auto-created |
| OpenShift Pipelines | `openshift-pipelines` | Tekton with ArtifactHub hub resolver (≥ 1.12) |

### Tekton Task Sourcing

The pipelines resolve KubeVirt tasks at runtime via the **ArtifactHub hub resolver** (enabled by default in OpenShift Pipelines ≥ 1.12). No ClusterTask pre-installation is needed:

| Task | Source | Version |
|---|---|---|
| `wait-for-vmi-status` | [`kubevirt-tekton-tasks` on ArtifactHub](https://artifacthub.io/packages/tekton-task/kubevirt-tekton-tasks/wait-for-vmi-status) | v0.25.0 |
| `openshift-client` | Built-in, referenced via **cluster resolver** from `openshift-pipelines` ns | — |

> **Note:** There is no `create-vm-snapshot` task in the kubevirt-tekton-tasks ArtifactHub catalog. The `snapshot-blue` step uses `openshift-client` (fetched via the Tekton cluster resolver) to apply a `VirtualMachineSnapshot` CR and wait for it to be ready. Playbook content is passed inline to `ansible-run-playbook` as a task parameter — no ConfigMap apply step is required.

### Storage

A storage class with **ReadWriteMany (RWX)** and a matching `VolumeSnapshotClass` are required:

```bash
# Verify snapshot support
oc get volumesnapshotclass
```

ODF (OpenShift Data Foundation) or any CSI driver with RWX is suitable.

### CentOS Stream 10 Golden Image

The SSP operator imports CentOS Stream 10 golden images via `DataImportCron`. Verify before the demo:

```bash
oc get datasource centos-stream10 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Must return: True
```

In a disconnected environment, mirror the image manually:

```bash
virtctl image-upload dv centos-stream10-golden \
  --size=30Gi \
  --image-path=/path/to/centos-stream10.qcow2 \
  --storage-class=<your-rwx-sc> \
  -n openshift-virtualization-os-images
```

---

## Setup

### 1 — MetalLB

The demo reuses an existing MetalLB `IPAddressPool` in `metallb-system`. It does **not**
create any MetalLB resources. By default, `chart/templates/service-lb.yaml` requests the pool named `metallb`:

```bash
# Verify the pool exists before running the demo
oc get ipaddresspool metallb -n metallb-system
```

If your cluster uses a different pool name, update the annotation in `chart/templates/service-lb.yaml`:

```yaml
annotations:
  metallb.universe.tf/address-pool: <your-pool-name>
```

### 2 — Deploy Key and Cluster Secrets

The pipelines use the deploy key **`~/.ssh/rh-demos`** for both:
- SSH git push-back from Tekton tasks (GitHub deploy key)
- VM SSH access via Ansible (public key injected through cloud-init)

**Add the public key as a GitHub deploy key (write access):**

```
https://github.com/cldmnky/rh-demos/settings/keys
```

Paste the contents of `~/.ssh/rh-demos.pub` and enable **"Allow write access"**.

**Create the cluster secrets with the setup script:**

```bash
cd gitops-vmware-virt-demo
./scripts/setup-secrets.sh          # targets vm-demo namespace by default
# Override with: NAMESPACE=other-ns ./scripts/setup-secrets.sh
```

This creates:
- `vm-ssh-key` — private key (`~/.ssh/rh-demos`) used by Tekton for git SSH auth
- `vm-cloud-init` — cloud-init userdata with the public key in `authorized_keys`

### 3 — ArgoCD repo access

This demo uses `https://github.com/cldmnky/rh-demos` as the ArgoCD source. For a private fork, add a repository credential in the ArgoCD UI or via secret and update `argocd/appproject.yaml` `sourceRepos`.

### 4 — ArgoCD Applications

```bash
# App 1: VMs and services (what ArgoCD drives during the demo)
oc apply -f argocd/appproject.yaml
oc apply -f argocd/rbac.yaml
oc apply -f argocd/application.yaml -n vm-demo

# App 2: Pipeline infrastructure (tasks, pipelines, event-listener)
oc apply -f argocd/application-infra.yaml -n vm-demo
```

ArgoCD syncs the Helm chart (`chart/`) to the `vm-demo` namespace. Within ~30 seconds:
- `demo-vm-blue` is `Running`
- `demo-vm-green` is `Stopped`
- `demo-app-lb` has an external IP

### 6 — Trigger the Install Pipeline

```bash
oc create -f pipelines/install-pipelinerun.yaml -n vm-demo
```

> **Note:** `install-pipelinerun.yaml` and `ansible-configmaps.yaml` are intentionally excluded from the ArgoCD infra app — PipelineRuns are one-shot triggers, not desired state.

Configure a GitHub webhook pointing to the `upgrade-trigger` Route for webhook-driven upgrades:

```bash
oc get route upgrade-trigger -n vm-demo
```

---

## Running the Demo

The terminal experience is fully automated using [`demo-magic`](https://github.com/paxtonhare/demo-magic). The `demo/demo.sh` script simulates typing commands and pauses for you to speak and explain what is happening.

**Start the demo:**

```bash
cd gitops-vmware-virt-demo
./demo/demo.sh
```

**Controls during the demo:**
- Press `ENTER` or `SPACE` to advance to the next step when the script pauses.
- Use `CTRL+C` to abort the script.

**Optional flags:**
- `-n`: No wait (auto-advance without pausing)
- `-d`: Disable simulated typing (instant output)
- `-w <secs>`: Auto-advance after N seconds

### The Flow

The script automatically executes the setup, the three acts, and the rollback. While the script runs in the terminal, keep browser tabs open to show the visual changes:
- ArgoCD console
- OpenShift Pipelines console
- GitHub repository
- OpenShift Virtualization console

Here is what happens during the run:

### Setup

The script begins by setting up the environment: creating the namespace, secrets, and the ArgoCD applications. It waits for the VMs to reach their initial state (Blue running, Green halted).

### Act 1 — GitOps VM Creation (~5 min)

> [SPEAKER NOTE: Opening]
> In VMware, creating a VM means clicking through vCenter wizards and it lives only in vCenter. Here, every VM is a YAML file in Git — including the standby VM we'll use for upgrades later. This is **declarative infrastructure** for VMs.

- The script shows the `chart/values.yaml` defaults driving the Helm templates.
- **Show in UI:** Open the ArgoCD console to show the `vm-demo` Application synced, with both VMs and the LB service in the resource tree.
- The script queries the VM states and the LoadBalancer IP.

> [SPEAKER NOTE: MetalLB]
> The VM already has a real external IP. MetalLB assigned it automatically — no IPAM ticket, no NSX config. MetalLB is OpenShift's native load balancing solution, replacing complex third-party tools.

### Act 2 — Tekton + Ansible Application Deployment (~7 min)

> [SPEAKER NOTE: Installation]
> Now let's install an application on the VM. In VMware, you'd SSH in manually or use a configuration management tool you'd have to integrate yourself. Here, Tekton pipelines handle that — with Ansible as the task runner. The integration is seamless and automated.

- **Show in UI:** Open the Pipelines console to show the `install-app` pipeline graph.
- The script triggers the pipeline and streams the Ansible task logs in the terminal.
- Finally, it curls the LoadBalancer IP to show the running application v1.0.

### Act 3 — Blue/Green Upgrade with Rollback (~8 min)

> [SPEAKER NOTE: Upgrade Trigger]
> Now the interesting part. We need to deploy v2.0. Watch what happens when I commit to Git. The upgrade is initiated by a simple version bump in Git, which Tekton detects and acts upon.

The upgrade pipeline flow:

```
[1] snapshot-blue     → VirtualMachineSnapshot safety net
[2] git-start-green   → Patch ArgoCD params: green=Always, disk=blue-snapshot
[3] wait-for-green    → Poll VMI until Running
[4] ansible-upgrade   → Ansible installs v2.0 on green
[5] smoke-test        → curl http://demo-vm-green-http/health

PASS → [6] git-cutover  → Patch ArgoCD params: traffic=green, blue=Halted
FAIL → [6] git-stop-green → Patch ArgoCD params: green=Halted
```

- The script updates `app-version.yaml` to `v2.0` and commits it to Git.
- It triggers the upgrade pipeline and streams the logs.
- After cutover, it curls the LoadBalancer IP to show v2.0 is live on `demo-vm-green`.

*"Same IP. Zero downtime. Blue is halted — still in Git, and can be restarted for rollback."*

**Rollback (optional, high impact):**

The script then performs the rollback using ArgoCD Helm parameter patches — no Git commits needed. It restarts blue, cuts traffic back, halts green, and deletes the green resources.

> [SPEAKER NOTE: Rollback Summary]
> In VMware: find the snapshot, revert, wait for boot, re-point the load balancer manually. Here: Git commits, ArgoCD reconciliation. The entire process is auditable and repeatable through Git.

---

## Pre-Demo Checklist

Run through this before the audience arrives:

```bash
# 1. Operators all running
oc get csv -n openshift-cnv | grep -E "Succeeded|Failed"
oc get csv -n openshift-gitops | grep -E "Succeeded|Failed"
oc get csv -n openshift-pipelines | grep -E "Succeeded|Failed"

# 2. Existing MetalLB pool available (not created by demo)
oc get ipaddresspool metallb -n metallb-system

# 3. CentOS Stream 10 boot source ready
oc get datasource centos-stream10 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# 4. VolumeSnapshotClass present
oc get volumesnapshotclass

# 5. ArgoCD application healthy and synced
oc get application vm-demo -n openshift-gitops

# 6. Both VMs in expected state
oc get vm -n vm-demo
# demo-vm-blue    Running   True
# demo-vm-green   Stopped   False

# 7. Service pointing to blue
oc get svc demo-app-lb -n vm-demo -o jsonpath='{.spec.selector}'
# {"kubevirt.io/domain":"demo-vm-blue"}

# 8. App responding
LB_IP=$(oc get svc demo-app-lb -n vm-demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$LB_IP/

# 9. Secrets present
oc get secret vm-ssh-key vm-cloud-init -n vm-demo

# 10. SSH and pre-cutover HTTP services present
oc get svc demo-vm-blue-ssh demo-vm-green-ssh demo-vm-green-http -n vm-demo

# 11. Tekton pipelines present
oc get pipeline install-app upgrade-app -n vm-demo
```

### Automatic Reset Between Runs

The `demo.sh` script includes a pre-flight check that automatically resets the environment to its initial state before starting:
- Reverts `app-version.yaml` to `v1.0` and commits it to Git
- Clears any ArgoCD Helm parameter overrides left over from previous upgrades or rollbacks
- Waits for ArgoCD to sync the cluster back to the `values.yaml` defaults (`blue=Always`, `green=Halted`, `traffic=blue`)

You do not need to manually reset the environment between presentations.

---

## Timing Tips

- Pre-run Acts 1 and 2 before the audience arrives; reset with the script above
- Green VM starts from `Halted` in ~30–60 seconds (DataVolume is pre-provisioned)
- Keep browser tabs open to: ArgoCD console, Tekton console, GitHub commit history, OCP Virtualization console, and a `curl` terminal

---

## Closing Talking Points

1. **Everything in Git** — both VMs and service routing. ArgoCD is authoritative throughout.
2. **Tekton writes Git; Git drives the cluster** — VM power state and service routing move through commits. The audit trail is `git log`.
3. **Rollback is Git-driven** — `git revert`, not vCenter snapshot revert.
4. **No licensing surprises** — MetalLB replaces NSX/F5. NetworkPolicy replaces NSX microsegmentation. Included in OpenShift.
5. **VMs and containers coexist** — same cluster, RBAC, monitoring, network policy. Modernize incrementally.
6. **Operators handle platform upgrades** — OCP Virtualization upgrades live-migrate VMs automatically. No maintenance window required.
