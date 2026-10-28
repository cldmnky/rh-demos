# ACM technical deep dive demo

A 60-minute console-and-terminal demonstration of Red Hat Advanced Cluster Management:

**Declare a site → explain its provisioned cluster → establish compliance → deliver the same application three ways.**

Application delivery compares legacy ACM subscriptions, central Argo CD push, and Argo CD
Agent managed mode. Helm provides the resource definitions and rendering throughout the pack.

**ZTP is a walkthrough of a precreated, completed site.** Provisioning, operator installation,
networking, and application bootstrap happen before the presentation—not while the audience waits.

## Requirements

- An existing ACM hub and permission to use the intended managed clusters.
- Bash, `oc`, Helm, Ruby, jq, Git, and tar on the presenter workstation.
- Approved AWS account/regions/quotas for any new production or QA cluster creation.
- Reviewed Virtualization, storage, networking, Assisted Installer, and boot-backend inputs for ZTP.
- Private environment configuration and local values prepared as described in [setup](docs/setup.md).

No environment-specific endpoints, kubeconfigs, or credentials are supplied by this README.
Validate component compatibility and the chosen infrastructure before an approved setup run.

## 1. Prepare your terminal

From the repository root, enter the demo directory and initialize the same Bash shell you
will use for setup and presentation:

```bash
cd acm-demos
source scripts/demo-shell.sh --prereqs
```

The sourceable initializer prompts for missing variables and exports them into your current
shell. Initial `--prereqs` mode needs only the hub connection and desired fleet names/release;
it does not require connections to clusters that have not been created yet.

For repeatable sessions, keep non-secret inputs and private kubeconfig **paths** in ignored
`config/demo.env`, or set `DEMO_ENV_FILE` to another trusted private shell file. The initializer
loads that file when present; answers are not automatically saved. It does not change the
global kubeconfig context, write files, or contact the cluster API. Use `--non-interactive`
to fail rather than prompt when required inputs are missing.

## 2. Configure the ignored local values

Setup consumes `$DEMO_VALUES_DIR` (defaults to `values/`). Use `*.local.yaml` files, not the
placeholder example files, for your actual environment.

| Input | Purpose |
| --- | --- |
| `prereqs.local.yaml` | Approvals, source ACM credential, AWS regions, operator configuration, and ZTP orchestration |
| `assisted-service.local.yaml`, `kubevirtbmc.local.yaml` | Installation services and BMC controller configuration |
| `ztp-target.local.yaml`, `ztp-site.local.yaml`, selected helper files | VM, network, DNS, boot path, and completed-site intent |
| `governance-inform.local.yaml`, `governance-enforce.local.yaml` | Policy starting state and remediation transition |
| `subscription.local.yaml`, `push.local.yaml`, `agent.local.yaml` | Application delivery starting states |
| `subscription-v2.local.yaml`, `push-v2.local.yaml`, `agent-v2.local.yaml` | Prepared v2 transitions through the same releases |
| `gitops-operator.local.yaml`, `agent-principal.local.yaml` | GitOps platform preparation when required |
| `demo-source.local.yaml` | Optional in-cluster lab Git/Helm source |

See [the setup guide](docs/setup.md) for the prerequisite profile, credential fields, component
ordering, and ownership requirements. Local values must contain complete reviewed inputs;
ignore rules are not encryption. Keep kubeconfigs under ignored `private/` or outside the repo.
Never commit credentials, private keys, resolved Secrets, or generated ignition.

## 3. Check and prepare the starting fleet

Read-only checks:

```bash
scripts/preflight.sh
scripts/prereqs.sh --check
```

`--check` reports missing prerequisites and returns nonzero for an incomplete starting fleet.
API/access failures stop the operation; they are not interpreted as permission to create replacements.

For a separately authorized preparation run:

```bash
# MUTATION: may create billable AWS resources, operators, storage, and a ZTP cluster.
scripts/prereqs.sh --apply
```

Apply requires reviewed approval flags in `prereqs.local.yaml` and interactive confirmation.
It coordinates:

1. Reusing the ACM credential in `default`, or creating it from private input if missing.
2. Reusing or provisioning production and QA/SNO clusters.
3. Installing missing OpenShift Virtualization prerequisites.
4. Preparing the approved SiteConfig, Assisted Installer, BMC, and boot-backend integration.
5. Deploying the ZTP site and waiting for installation and hub-side availability.

Existing clusters are not Helm-adopted, replaced, or automatically relabeled. A pre-existing
ZTP site's VM/boot fields are not reapplied on rerun. This is a staged operation, not a transaction:
failures do not trigger automatic cloud teardown or destructive rollback. An unattended boot
backend must exist or be explicitly supplied as a reviewed local Helm chart; the script does
not invent Metal3/network configuration or silently substitute manual boot.

**Complete this phase well before the presentation.** A Helm release existing is not proof
that a cluster installation succeeded.

## 4. Prepare the demo scenarios

Use the same initialized shell. These commands render offline, metadata-only summaries:

```bash
scripts/setup-demo.sh governance-inform
scripts/setup-demo.sh subscription
scripts/setup-demo.sh push
scripts/setup-demo.sh agent-principal
scripts/setup-demo.sh agent
```

After reviewing each component and obtaining authorization, add `--apply` to install/update it:

```bash
# Example: changes policy intent and can affect selected managed clusters.
scripts/setup-demo.sh governance-inform --apply
```

Prepare compatible GitOps instances, certificates, placement consent, and scoped target
permissions before application delivery. Keep agent principal and central push ownership
separate. If Git already owns intent, use that owner instead of creating a second CLI Helm owner.

An optional lab source is available:

```bash
scripts/prepare-demo-source.sh          # offline preparation/summary
scripts/prepare-demo-source.sh --apply  # explicitly approved hub deployment/update
```

This uses a disposable temporary Git repository; it never commits or pushes the real repository.
Configure the real source URLs in the ignored delivery values. Publish/prepare both versions
before showtime, not during an application update segment.

## 5. Connect to the targets and verify readiness

Securely obtain the managed-cluster kubeconfigs and observe actual generated application/resource
names. Then complete the presentation shell configuration:

```bash
source scripts/demo-shell.sh
scripts/verify.sh
```

Full mode prompts for missing managed-cluster connections and presentation names. It provides
explicit-target helpers: `oc_hub`, `oc_prod`, `oc_ztp`, `oc_agent`, and `oc_excluded`.
`verify.sh` checks hub acceptance/join/availability and guest node/operator health read-only.

Before presenting, confirm:

- The ZTP site is already installed, healthy, and available in ACM.
- Governance starts in inform with an absent/incorrect harmless baseline; the excluded target is unchanged.
- Subscription, push, and agent v1 are healthy and their actual HTTPS pages work.
- Prepared v2 local files and retained v1 inputs are ready.
- The operator responsible for state transitions and the baseline restoration plan are agreed.

## 6. Run the presentation

Follow **[the presenter runbook](docs/presenter-runbook.md)** for narration, browser tabs, terminal
commands, expected results, and handoffs.

| Time | Segment | Detailed runbook |
| --- | --- | --- |
| 00–04 | Fleet, versions, and controller responsibilities | [Opening](docs/presenter-runbook.md) |
| 04–16 | Inspect and explain the precreated ZTP site | [Lifecycle](docs/runbooks/01-lifecycle-ztp.md) |
| 16–29 | Inform → enforce → drift correction → exclusion | [Governance](docs/runbooks/02-governance.md) |
| 29–36 | ACM subscription delivery and v2 | [Subscriptions](docs/runbooks/03-app-subscriptions.md) |
| 36–45 | Central Argo CD push and remote rollout | [Push](docs/runbooks/04-app-argocd-push.md) |
| 45–55 | Central intent, local agent reconciliation, returned status | [Agent](docs/runbooks/05-app-argocd-agent.md) |
| 55–58 | Compare the models and close | [Presenter runbook](docs/presenter-runbook.md) |
| 58–60 | Buffer / short question | No new demo or cleanup |

Inspection commands are read-only. Deliberate policy/drift/v2 transitions are separately approved
mutations through the existing owner. The scripts default to check/render; `--apply` is explicit
and confirmed. Do not present a Helm-driven intent update as automatic Git reconciliation.

## After the presentation

Use [baseline restoration guidance](docs/reset.md). Routine reset restores inform/v1 values;
it does not uninstall provisioning releases, destroy clusters, remove namespaces, or modify
shared infrastructure. `scripts/reset.sh` is preview-only.

## Offline checks and documentation

```bash
ruby scripts/check-local.rb
```

This checks script syntax, documentation links/shell blocks, prerequisite Helm phase rendering,
fixture-based shell initialization/failure paths, and ignore rules. It does not access the cluster
or prove cloud installation, operator/BMC interoperability, or application runtime outcomes.

- [Documentation index](docs/README.md)
- [Full setup instructions](docs/setup.md)
- [Presenter runbook](docs/presenter-runbook.md)
- [Baseline restoration](docs/reset.md)
