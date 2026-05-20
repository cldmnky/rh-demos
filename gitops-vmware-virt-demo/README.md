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

```
Git repo state at rest:
  base/vm-blue.yaml       → runStrategy: Always    (active, running)
  base/vm-green.yaml      → runStrategy: Halted    (standby, powered off)
  base/service-lb.yaml    → selector: demo-vm-blue (traffic → blue)

After Tekton Commit 1 ("start green for upgrade"):
  base/vm-green.yaml      → runStrategy: Always    (ArgoCD starts green)

After Tekton Commit 2 ("cutover" — only if smoke test passed):
  base/service-lb.yaml    → selector: demo-vm-green (traffic → green)
  base/vm-blue.yaml       → runStrategy: Halted    (ArgoCD halts blue)

Rollback: git revert Commit 2 → ArgoCD restores instantly
```

### The Three "VMware Can't Do This" Moments

| Moment | Why it matters |
|---|---|
| Both VMs defined in Git, green powered off | Standby VM with zero compute cost — vCenter has no concept of "desired off" in code |
| Upgrade and cutover are Git commits | Full audit trail, PR review, `git revert` for rollback — vCenter task history is read-only |
| Rollback is Git-driven | Commit traffic back to blue — no manual LB re-pointing |

---

## Repository Layout

```
gitops-vmware-virt-demo/
├── README.md
├── argocd/
│   ├── application.yaml         # ArgoCD Application (prune: true, selfHeal: true)
│   └── rbac.yaml                # ArgoCD controller permissions in vm-demo
├── base/                        # ArgoCD sync target
│   ├── vm-blue.yaml             # VirtualMachine — runStrategy: Always
│   ├── vm-green.yaml            # VirtualMachine — runStrategy: Halted (standby)
│   ├── service-lb.yaml          # MetalLB LoadBalancer (selector: demo-vm-blue)
│   ├── service-blue-ssh.yaml    # ClusterIP for Ansible SSH to blue
│   ├── service-green-ssh.yaml   # ClusterIP for Ansible SSH to green
│   └── service-green-http.yaml  # ClusterIP for pre-cutover HTTP smoke test
├── metallb/
│   ├── ipaddresspool.yaml       # L2 address pool
│   └── l2advertisement.yaml     # L2Advertisement
├── pipelines/
│   ├── install-pipeline.yaml    # Tekton Pipeline: install-app
│   ├── upgrade-pipeline.yaml    # Tekton Pipeline: upgrade-app
│   ├── install-pipelinerun.yaml # Manual PipelineRun trigger
│   ├── app-version.yaml         # ConfigMap — bump version to trigger upgrade
│   ├── ansible-configmaps.yaml  # Playbooks as ConfigMaps (reference only — not required)
│   ├── event-listener.yaml      # Tekton EventListener + GitHub webhook trigger
│   └── tasks/
│       ├── git-commit-vm-state.yaml   # Patches runStrategy and commits to Git
│       ├── git-commit-cutover.yaml    # Commits service selector + halts outgoing VM
│       ├── ansible-run-playbook.yaml  # Runs Ansible playbook via community-ansible-dev-tools
│       └── smoke-test.yaml            # curl health check with retry
└── ansible/
    ├── install-app.yaml         # Playbook: install nginx + v1.0
    └── upgrade-app.yaml         # Playbook: deploy v2.0
```

---

## Prerequisites

### Required Operators

Install from OperatorHub or apply pre-staged `Subscription` YAMLs:

| Operator | Namespace | Notes |
|---|---|---|
| OpenShift Virtualization (HCO) | `openshift-cnv` | Installs KubeVirt, CDI, SSP, CNAO |
| MetalLB Operator | `metallb-system` | L2 or BGP address pool required |
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

### RHEL 9 Golden Image

The SSP operator imports RHEL 9 golden images via `DataImportCron`. Verify before the demo:

```bash
oc get datasource rhel9 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Must return: True
```

In a disconnected environment, mirror the image manually:

```bash
virtctl image-upload dv rhel9-golden \
  --size=30Gi \
  --image-path=/path/to/rhel9.qcow2 \
  --storage-class=<your-rwx-sc> \
  -n openshift-virtualization-os-images
```

---

## Setup

### 1 — MetalLB

Edit `metallb/ipaddresspool.yaml` to match your demo network, then apply:

```bash
oc apply -f metallb/ipaddresspool.yaml
oc apply -f metallb/l2advertisement.yaml
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

ArgoCD syncs `base/` to the `vm-demo` namespace. Within ~30 seconds:
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

### Act 1 — GitOps VM Creation (~5 min)

**Talking point:** *"In VMware, creating a VM means clicking through vCenter wizards and it lives only in vCenter. Here, every VM is a YAML file in Git — including the standby VM we'll use for upgrades later."*

1. Open the GitHub repo. Show `base/vm-blue.yaml` (`runStrategy: Always`), `base/vm-green.yaml` (`runStrategy: Halted`), and `base/service-lb.yaml`.
2. Open the ArgoCD console. Show the `vm-demo` Application synced, with both VMs and the LB service in the resource tree.
3. Show the VM states and MetalLB IP:

```bash
oc get vm -n vm-demo
# NAME            STATUS    READY
# demo-vm-blue    Running   True
# demo-vm-green   Stopped   False

oc get svc demo-app-lb -n vm-demo
# NAME           TYPE           EXTERNAL-IP     PORT(S)
# demo-app-lb    LoadBalancer   192.168.10.50   80:xxxxx/TCP
```

*"The VM already has a real external IP. MetalLB assigned it automatically — no IPAM ticket, no NSX config."*

### Act 2 — Tekton + Ansible Application Deployment (~7 min)

**Talking point:** *"Now let's install an application on the VM. In VMware, you'd SSH in manually or use a configuration management tool you'd have to integrate yourself. Here, Tekton pipelines handle that — with Ansible as the task runner."*

1. Open the Pipelines console. Walk through the `install-app` pipeline graph.
2. Trigger the pipeline:

```bash
oc create -f pipelines/install-pipelinerun.yaml -n vm-demo
```

3. Show the Ansible task logs in the Tekton console.
4. Show the running application:

```bash
LB_IP=$(oc get svc demo-app-lb -n vm-demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$LB_IP/
# <h1>Demo App v1.0 — served by demo-vm-blue</h1>
```

### Act 3 — Blue/Green Upgrade with Rollback (~8 min)

**Talking point:** *"Now the interesting part. We need to deploy v2.0. Watch what happens when I commit to Git."*

The upgrade pipeline flow:

```
[1] snapshot-blue     → VirtualMachineSnapshot safety net
[2] git-start-green   → Commit: vm-green.yaml runStrategy: Always → ArgoCD starts green
[3] wait-for-green    → Poll VMI until Running
[4] ansible-upgrade   → Ansible installs v2.0 on green
[5] smoke-test        → curl http://demo-vm-green-http/health

PASS → [6] git-cutover  → Commit: service selector → green, vm-blue → Halted
FAIL → [6] git-stop-green → Commit: vm-green → Halted (blue unchanged)
```

**Trigger the upgrade** by bumping the version in `gitops-vmware-virt-demo/pipelines/app-version.yaml` and pushing (GitHub webhook fires the EventListener), or manually:

```bash
# Edit gitops-vmware-virt-demo/pipelines/app-version.yaml: version: "v2.0"
git add gitops-vmware-virt-demo/pipelines/app-version.yaml
git commit -m "bump app version to v2.0"
git push origin main
```

**Watch in real time:**

```bash
# VM state transitions
oc get vm -n vm-demo -w

# ArgoCD sync events
oc get events -n vm-demo --field-selector reason=ResourceUpdated -w
```

**After cutover:**

```bash
curl http://$LB_IP/
# <h1>Demo App v2.0 — served by demo-vm-green</h1>

oc get vm -n vm-demo
# NAME            STATUS    READY
# demo-vm-blue    Stopped   False   ← halted, still in Git, zero compute
# demo-vm-green   Running   True    ← now active
```

*"Same IP. Zero downtime. Blue is halted — still in Git, and can be restarted for rollback."*

**Rollback (optional, high impact):**

```bash
# Step 1: start blue while traffic still flows to green
yq e '.spec.runStrategy = "Always"' -i base/vm-blue.yaml
git add base/vm-blue.yaml
git commit -m "rollback: start blue standby"
git push origin main

# Wait until blue is Running, smoke-test it...

# Step 2: revert cutover commit and halt green
git revert <cutover-commit-sha> --no-commit
yq e '.spec.runStrategy = "Halted"' -i base/vm-green.yaml
git add base/
git commit -m "rollback: route traffic back to blue"
git push origin main

curl http://$LB_IP/
# <h1>Demo App v1.0 — served by demo-vm-blue</h1>
```

*"In VMware: find the snapshot, revert, wait for boot, re-point the load balancer manually. Here: Git commits, ArgoCD reconciliation."*

---

## Pre-Demo Checklist

Run through this before the audience arrives:

```bash
# 1. Operators all running
oc get csv -n openshift-cnv | grep -E "Succeeded|Failed"
oc get csv -n openshift-gitops | grep -E "Succeeded|Failed"
oc get csv -n openshift-pipelines | grep -E "Succeeded|Failed"

# 2. MetalLB pool configured
oc get ipaddresspool -n metallb-system

# 3. RHEL9 boot source ready
oc get datasource rhel9 -n openshift-virtualization-os-images \
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

### Reset Between Runs

```bash
yq e '.spec.runStrategy = "Always"' -i base/vm-blue.yaml
yq e '.spec.runStrategy = "Halted"' -i base/vm-green.yaml
yq e '.spec.selector["kubevirt.io/domain"] = "demo-vm-blue"' -i base/service-lb.yaml
git add base/ && git commit -m "reset demo state" && git push origin main
# ArgoCD syncs → cluster matches initial state in ~30 seconds
```

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
