# Demo runbook: From VMs to cloud-native

**Audience:** developers and DevOps engineers. **Session:** 40 minutes, including slides and questions. The live application is Rocket Ramen: a React/Node.js frontend, a Go API, and MariaDB.

**Presenter message:** we can modernize how we operate a VM before changing its application. Then we can move application components independently, keeping the database on a VM when that is the right choice.

| Act | Frontend | API | Database | Audience sees |
| --- | --- | --- | --- | --- |
| Start | RHEL VM | RHEL VM | RHEL VM | Familiar application and Ansible-based operations |
| Containers | Container and VM during Route split | Container, with VM retained | Original VM | Dev Spaces, builds, coexistence and progressive traffic |
| Target | Container | Container | RHEL bootc VM | Image-managed OS with separate database data |

**Implementation status:** the baseline, container cutover, bootc migration and data-preserving reset were rehearsed before the placement display and live Tekton build were added. Rehearse those additions on the restarted cluster. The single setup script prepares container workloads and the bootc target; its fresh build stages and a subsequent uninterrupted repeat setup were tested in an isolated namespace. Guest image update authentication still needs configuration. Legacy VM objects and their disposable root disks are removed after cutover; the separate database disk and snapshots are retained.

## Timing and stage setup

| Minutes | Presenter action |
| --- | --- |
| 0–4 | Personal VM-to-cloud-native story. Modernization does not start with a rewrite. |
| 4–10 | OpenShift Virtualization overview and slides: platform, operational and application modernization. |
| 10–15 | Show Rocket Ramen, three VMs and the Tekton/Ansible baseline. |
| 15–25 | Dev Spaces: inspect source and Containerfiles, build and deploy the app tiers. |
| 25–31 | Route traffic to containers with VM rollback available; introduce Argo Rollouts for subsequent container revisions. |
| 31–36 | Migrate MariaDB to the prepared bootc VM and stop the legacy VMs. |
| 36–40 | Recap and questions. |

Before the audience arrives:

1. From this directory, run `./scripts/setup.sh` and check the printed application URL. Keep the generated private setup directory. See [README.md](README.md) for prerequisites, including the RHEL subscription setting.
2. The setup script runs `./modernization/prepare.sh` to install the namespace-scoped RolloutManager, image streams, build configurations and the live container-build Tekton Pipeline, build both application images, and stage the container workloads. It also sets the GitOps Operator Subscription to namespace-scoped Rollouts mode, a cluster-wide operator setting; it refuses the change if a cluster-scoped RolloutManager exists. This does not change the application Route or the API Service. It allows a slow initial image pull/build to happen before the presentation. Use `NAMESPACE=...` if different from `rocket-ramen`.
3. If updating an existing baseline, restart the web and API VMs during preparation so the new firmware serial takes effect, then verify `/api/webinfo` and `/api/stats`. A running VM does not acquire a changed firmware serial until restarted. Confirm `oc get vm,deploy,rollout,build -n rocket-ramen`. The three VMs and the container API must be ready; the frontend Rollout must have ready replicas. `oc get rolloutmanager -n rocket-ramen` shows the Rollouts controller resource. If it is not ready, inspect `oc get pods -n rocket-ramen` and the operator before presenting.
4. The Dev Spaces workspace is prepared through Argo CD: the `vm-cloud-native-devspace` Application applies `prereqs/devspace/devworkspace.yaml` into your Dev Spaces namespace and starts it. Run `./prereqs/scripts/prereqs.sh --apply` as the presenting user and open the printed IDE URL. If the namespace does not exist yet, log in to the Dev Spaces dashboard once, then re-run. The devfile clones the repository branch named by `DEVSPACE_GIT_REF` (default `main`) into `/projects/rh-demos`, so publish presentation changes to that branch first. Open `vm-cloud-native-demo` in the editor and use the `node` and `openshift-cli` terminals; `npm run dev` is served at the workspace's `/vite/` endpoint. Fallback if the Application is unavailable: create a workspace from the [raw devfile on main](https://raw.githubusercontent.com/cldmnky/rh-demos/main/vm-cloud-native-demo/devfile.yaml).
5. In the `openshift-cli` terminal, authenticate `oc` to the demo cluster as a user who can start builds and apply Deployments and Rollouts in the demo namespace. Confirm with `oc whoami` and set `NAMESPACE` if it differs from `rocket-ramen`. Do not show login tokens. The live Tekton Pipeline builds the frontend bundle and starts the OpenShift image builds in the cluster. A normal Dev Spaces workspace is not a privileged image builder.
6. Keep a **local presenter terminal** in this directory, logged in to the correct cluster and using the original private setup directory and SSH key. The bootc migration and reset use those local files and `virtctl`; they are not run from the workspace. The presenter script is `./demo/demo.sh`; it **changes live demo traffic** in act 3. The terminal commands below are alternatives for rehearsing individual steps. Do not run the presentation script as an unattended test.

## 1. The application we inherited

**Show:** open the Route, place an order, and point out the web VM, API VM and MariaDB badges and the placement details. The VM names and namespace come from Ansible provisioning metadata; when readable, the serial comes from KubeVirt SMBIOS. The guest does not report its OpenShift node, so it is shown as —. Keep the order visible for the later transition.

```bash
export NAMESPACE=rocket-ramen
oc get vm orders-web orders-app orders-db -n "$NAMESPACE"
oc get pipelineruns -n "$NAMESPACE" | grep orders-bootstrap
```

In Dev Spaces, open `automation/chart/files/ansible/site.yml` and `api.yml`: Tekton provisions the VMs and runs Ansible; Ansible installs packages, configures systemd, and installs the application. The VMs are already on OpenShift: this demonstrates the **post-migration** baseline, not a live hypervisor migration.

**Say:** “We have changed the platform and the operating model. The application itself still looks familiar.”

## 2. Build and apply from Dev Spaces

**Switch to the Dev Spaces editor.** Show `frontend/Containerfile`, `backend/Containerfile`, `devfile.yaml` and `modernization/workloads.yaml`. The frontend image includes the built SPA, and the API image contains the Go binary.

Make two small changes and save both files:

1. In `frontend/src/App.tsx`, change `zero-gravity noodle bar · PatternFly 6` to `zero-gravity noodle bar · Mission Control v2`.
2. In `backend/main.go`, inside `logRequests`, immediately before `start := time.Now()`, add `w.Header().Set("X-Rocket-Ramen-Release", "container-v2")`.

Show the diff in Dev Spaces. These are workspace edits; a Git commit is not required. The running VMs keep the original code. The build packages the current saved source, including these uncommitted edits, using an explicit application-file allowlist.

In the **`openshift-cli` terminal** in Dev Spaces, use the authenticated session prepared above:

```bash
cd "$PROJECTS_ROOT/rh-demos/vm-cloud-native-demo"
export NAMESPACE=rocket-ramen
./demo/devspaces.sh
```

The demo-magic segment uploads the saved workspace source to the namespace-local artifact service and starts a Tekton PipelineRun. Tekton verifies its SHA-256, builds the SPA, and starts the API and frontend OpenShift binary builds. The segment displays the workload manifest, resolves the new image digests and visibly runs `oc apply` for the Deployment and frontend Rollout. It then invokes `modernization/deploy.sh` to repeat the idempotent apply and wait for readiness. The API reads the existing database Secret; both containers initially use the existing VM-backed Services. No Route or Service traffic is switched by this apply.

Watch the PipelineRun in the OpenShift Pipelines view or with `oc get pipelineruns -n "$NAMESPACE"`. Builds may take several minutes. Setup has already staged working images and workloads, so if a live build is slow, show the prepared resources and return to the local terminal. The exact workspace code and the presenter segment must be published on the branch cloned by Dev Spaces.

**Say:** “From the development workspace, we build images and apply workloads next to the existing VM application.”

**Return to the local presenter terminal** and continue `./demo/demo.sh` with act 3.

## 3. Shift traffic with a way back

**Local presenter terminal:** continue the demo-magic script. The commands below describe what it executes.

The API Service has one active backend selection at a time. The frontend Route can split incoming connections between the VM Service and container Service. This is the VM-to-container canary; it is independent of Argo Rollouts.

```bash
./modernization/traffic.sh api container
./modernization/traffic.sh web 50
oc set route-backends orders -n "$NAMESPACE"
```

Refresh or make new requests to see both frontend runtimes and instance names. The web identity is the instance answering `/api/webinfo`; the API identity comes from `/api/stats`, so separate requests can hit different instances. The Route uses round-robin with router cookies disabled. The weights are relative, apply to new traffic, and are not an exact 50/50 guarantee for a small sample; existing connections, including SSE streams, can stay on their prior backend.

```bash
./modernization/traffic.sh web 100
```

The app now uses the container frontend and API and the original VM database. Refresh to show the new `Mission Control v2` text, container pod names and node names. Confirm the API code change:

```bash
HOST=$(oc -n "$NAMESPACE" get route orders -o jsonpath='{.spec.host}')
curl -sS -D - -o /dev/null "http://$HOST/api/menu" | grep -i '^x-rocket-ramen-release:'
```

The expected header is `X-Rocket-Ramen-Release: container-v2`. If the build was skipped, the staged baseline images do not contain either code change. The legacy frontend and API VMs still run. If either cutover fails, restore in this order:

```bash
./modernization/traffic.sh web 0
./modernization/traffic.sh api vm
```

**Argo Rollouts:** the frontend container is an Argo `Rollout`. Its first deployment is the initial stable revision; it does not canary the VM. To show a later container-to-container revision, change the pod-template annotation and watch its ReplicaSets during the 60-second pause:

```bash
oc -n "$NAMESPACE" patch rollout orders-web-container --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"demo.revision":"2"}}}}}'
oc -n "$NAMESPACE" get rollout,replicasets,pods -l app=orders-web-container -w
```

Stop watching with Ctrl-C. Refresh during the rollout and compare the web pod name with the listed old and new pods. With two replicas, repeated requests can reach different pods, but balancing is not guaranteed to alternate. The example changes an annotation so it demonstrates rollout mechanics without claiming a new application feature. Without a traffic-routing integration, the rollout approximates the canary ratio using replica counts; it does not control the VM-to-container Route split. A repeated demo needs a different annotation value to create a new revision.

## 4. Move MariaDB to a bootc VM

Before the demo, prepare and validate the target as described in [bootc/README.md](bootc/README.md). On this cluster, `orders-db-bootc` is already prepared. The builder VM is an additional operational VM, not one of the application tiers. The snapshot class is detected from the database storage class when there is one matching CSI snapshot class. If multiple exist, set it before starting the presenter script:

```bash
export SNAPSHOT_CLASS=ocs-external-storagecluster-rbdplugin-snapclass
```

**Local presenter terminal:** continue the demo-magic script and show `bootc/Containerfile`. The image contains the OS and MariaDB; the database files are on a separate disk. The script runs:

```bash
./bootc/migrate.sh
./bootc/status.sh
./bootc/retire-legacy.sh
```

The migration pauses writes by stopping the API and legacy database, takes an offline CSI snapshot, restores it to a new PVC, attaches it to the target, verifies menu and order counts, and switches the database Service. The frontend and API end on containers. The retirement command removes the three unused legacy VM objects and their VM-owned root disks. The separate database data PVC and snapshots remain available. This has a write outage; it is not a zero-downtime migration.

Show the application and place an order. The old database disk is now stale. Use `./bootc/reset.sh` with `SNAPSHOT_CLASS` set to snapshot the current bootc disk and restore it to a new PVC for the original DB VM, preserving new orders. Each run retains snapshots and old PVCs; inspect and clean them up separately after rehearsals. If any command fails, inspect its output and current VM, Service and PVC state before restarting it. A bootc OS rollback is not a database rollback.

The [image-mode documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems) describes bootc and image building.

## 5. Final state and reset

Show `oc get vm,pods,svc`, the browser's container/container/MariaDB stack and the orders. The legacy VM objects and VM-owned root disks have been removed. The separate database data PVC and snapshots are retained. After the presentation, in the local presenter terminal:

```bash
./bootc/reset.sh
```

If you want to repeat the exact edit, revert the two presenter changes in the Dev Spaces editor after the session. The reset copies current database data to a new disk, recreates the three legacy VMs, runs Ansible, and restores VM traffic. A full reset was validated with orders created before and after migration. It does not delete old snapshots or PVCs.
