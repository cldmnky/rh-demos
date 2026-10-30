# Demo runbook: From VMs to cloud-native

**Audience:** developers and DevOps engineers. **Session:** 40 minutes, including slides and questions. The live application is Rocket Ramen: a React/Node.js frontend, a Go API, and MariaDB.

**Presenter message:** we can modernize how we operate a VM before changing its application. Then we can move application components independently, keeping the database on a VM when that is the right choice.

| Act | Frontend | API | Database | Audience sees |
| --- | --- | --- | --- | --- |
| Start | RHEL VM | RHEL VM | RHEL VM | Familiar application and Ansible-based operations |
| Containers | Container and VM during Route split | Container, with VM retained | Original VM | Dev Spaces, builds, coexistence and progressive traffic |
| Target | Container | Container | RHEL bootc VM | Image-managed OS with separate database data |

**Implementation status:** the baseline, container cutover, bootc migration and data-preserving reset have been rehearsed on the current cluster. The single setup script prepares container workloads and the bootc target; its fresh build stages and a subsequent uninterrupted repeat setup were tested in an isolated namespace. Guest image update authentication still needs configuration. Legacy VM objects and their disposable root disks are removed after cutover; the separate database disk and snapshots are retained.

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
2. The setup script runs `./modernization/prepare.sh` to install the namespace-scoped RolloutManager, image streams and build configurations, build both application images, and stage the container workloads. It also sets the GitOps Operator Subscription to namespace-scoped Rollouts mode, a cluster-wide operator setting; it refuses the change if a cluster-scoped RolloutManager exists. This does not change the application Route or the API Service. It allows a slow initial image pull/build to happen before the presentation. Use `NAMESPACE=...` if different from `rocket-ramen`.
3. Confirm `oc get vm,deploy,rollout,build -n rocket-ramen`. The three VMs and the container API must be ready; the frontend Rollout must have ready replicas. `oc get rolloutmanager -n rocket-ramen` shows the Rollouts controller resource. If it is not ready, inspect `oc get pods -n rocket-ramen` and the operator before presenting.
4. Open the application and create a Dev Spaces workspace from the raw URL of `vm-cloud-native-demo/devfile.yaml` on the published branch. The devfile clones the monorepo into `/projects/rh-demos`; publish the current changes or select a branch that contains them before creating the workspace. The Node and OpenShift CLI components share the workspace source. Authenticate the CLI terminal to the demo cluster as a user with build and namespace edit permissions; do not display access tokens on screen. The Node terminal builds the frontend bundle; the OpenShift CLI terminal submits builds to the cluster. A normal Dev Spaces workspace is not a privileged image builder.
5. Keep the terminal in this directory, logged in to the correct cluster. The presenter script is `./demo/demo.sh`; it **changes live demo traffic** in act 3. The terminal commands below are alternatives for rehearsing individual steps. Do not run the presentation script as an unattended test.

## 1. The application we inherited

**Show:** open the Route, place an order, and point out the web VM, API VM and MariaDB badges. Keep the order visible for the later transition.

```bash
export NAMESPACE=rocket-ramen
oc get vm orders-web orders-app orders-db -n "$NAMESPACE"
oc get pipelineruns -n "$NAMESPACE" | grep orders-bootstrap
```

In Dev Spaces, open `automation/chart/files/ansible/site.yml` and `api.yml`: Tekton provisions the VMs and runs Ansible; Ansible installs packages, configures systemd, and installs the application. The VMs are already on OpenShift: this demonstrates the **post-migration** baseline, not a live hypervisor migration.

**Say:** “We have changed the platform and the operating model. The application itself still looks familiar.”

## 2. Build and deploy application containers

In Dev Spaces, show `frontend/Containerfile`, `backend/Containerfile` and `devfile.yaml`. The application code is the same; the frontend image includes the built SPA, while the API image contains the Go binary.

In the **Node** terminal:

```bash
cd "$PROJECTS_ROOT/rh-demos/vm-cloud-native-demo"
./scripts/build-frontend.sh
```

In the **OpenShift CLI** terminal, from the same project directory, authenticate `oc`, then:

```bash
./modernization/build.sh api
./modernization/build.sh web
./modernization/deploy.sh
oc get builds,deploy,rollout -n "$NAMESPACE"
```

Set `NAMESPACE` in each terminal if it differs from the default. The scripts upload source/build context to OpenShift BuildConfigs and push images to the internal registry. Deployment resolves the built ImageStream tags to immutable image digests, so rebuilding produces a new revision. The frontend context contains the bundle, not `node_modules`. The API Deployment reads the existing database password from a Kubernetes Secret and still connects to the VM database. The frontend Rollout initially connects to the original API Service. Builds can take several minutes: start them live and discuss the manifest, or show the prepared builds if time is short. `deploy.sh` creates workloads but does not change user traffic.

**Say:** “We can build from the same workspace and run the new workloads beside the old ones.”

## 3. Shift traffic with a way back

The API Service has one active backend selection at a time. The frontend Route can split incoming connections between the VM Service and container Service. This is the VM-to-container canary; it is independent of Argo Rollouts.

```bash
./modernization/traffic.sh api container
./modernization/traffic.sh web 50
oc set route-backends orders -n "$NAMESPACE"
```

Refresh or make new requests to see both frontend runtimes. The Route uses round-robin with router cookies disabled. The weights are relative, apply to new traffic, and are not an exact 50/50 guarantee for a small sample; existing connections, including SSE streams, can stay on their prior backend.

```bash
./modernization/traffic.sh web 100
```

The app now uses the container frontend and API and the original VM database. The legacy frontend and API VMs still run. If either cutover fails, restore in this order:

```bash
./modernization/traffic.sh web 0
./modernization/traffic.sh api vm
```

**Argo Rollouts:** the frontend container is an Argo `Rollout`. Its first deployment is the initial stable revision; it does not canary the VM. To show a later container-to-container revision, change the pod-template annotation and watch its ReplicaSets during the 60-second pause:

```bash
oc -n "$NAMESPACE" patch rollout orders-web-container --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"demo.revision":"2"}}}}}'
oc -n "$NAMESPACE" get rollout,replicasets,pods -l app=orders-web-container -w
```

Stop watching with Ctrl-C. The example changes an annotation so it demonstrates rollout mechanics without claiming a new application feature. Without a traffic-routing integration, the rollout approximates the canary ratio using replica counts; it does not control the VM-to-container Route split. A repeated demo needs a different annotation value to create a new revision.

## 4. Move MariaDB to a bootc VM

Before the demo, prepare and validate the target as described in [bootc/README.md](bootc/README.md). On this cluster, `orders-db-bootc` is already prepared. The builder VM is an additional operational VM, not one of the application tiers. The snapshot class is detected from the database storage class when there is one matching CSI snapshot class. If multiple exist, set it before starting the presenter script:

```bash
export SNAPSHOT_CLASS=ocs-external-storagecluster-rbdplugin-snapclass
```

Show `bootc/Containerfile`. The image contains the OS and MariaDB; the database files are on a separate disk. Run:

```bash
./bootc/migrate.sh
./bootc/status.sh
./bootc/retire-legacy.sh
```

The migration pauses writes by stopping the API and legacy database, takes an offline CSI snapshot, restores it to a new PVC, attaches it to the target, verifies menu and order counts, and switches the database Service. The frontend and API end on containers. The retirement command removes the three unused legacy VM objects and their VM-owned root disks. The separate database data PVC and snapshots remain available. This has a write outage; it is not a zero-downtime migration.

Show the application and place an order. The old database disk is now stale. Use `./bootc/reset.sh` with `SNAPSHOT_CLASS` set to snapshot the current bootc disk and restore it to a new PVC for the original DB VM, preserving new orders. Each run retains snapshots and old PVCs; inspect and clean them up separately after rehearsals. If any command fails, inspect its output and current VM, Service and PVC state before restarting it. A bootc OS rollback is not a database rollback.

The [image-mode documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems) describes bootc and image building.

## 5. Final state and reset

Show `oc get vm,pods,svc`, the browser's container/container/MariaDB stack and the orders. The legacy VM objects and VM-owned root disks have been removed. The separate database data PVC and snapshots are retained. After the presentation:

```bash
./bootc/reset.sh
```

The reset copies current database data to a new disk, recreates the three legacy VMs, runs Ansible, and restores VM traffic. A full reset was validated with orders created before and after migration. It does not delete old snapshots or PVCs.
