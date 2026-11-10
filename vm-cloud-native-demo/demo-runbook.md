# Demo runbook: From VMs to cloud-native

**Audience:** developers and DevOps engineers. **Application:** Rocket Ramen, a Node.js SPA, a Go API and MariaDB. The live demo starts with all three tiers serving from RHEL VMs and ends with the frontend and API in containers and MariaDB on its original VM.

**Message:** Modernize the way you operate VMs first; then move application components individually while VMs and containers share the same platform.

| Part | Surface | Show |
| --- | --- | --- |
| Operational modernization | OpenShift console and browser | VM application, Lightspeed context, Tekton and Ansible automation |
| Application modernization | Dev Spaces and OpenShift console | Code, container builds, deployment, Route traffic splitting and Argo Rollouts |

## Before the audience arrives

1. Run `./scripts/setup.sh` as described in [README.md](README.md). This also prepares bootc infrastructure, but the live demo does not use it. Allow time for builds and VM provisioning.
2. Check the `rocket-ramen` project: `orders-web`, `orders-app` and `orders-db` are running; the Route sends all traffic to the web VM; `orders-app` and `orders-db` Services select their respective VMs. The `orders-bootstrap` PipelineRun has succeeded.
3. Confirm the `orders-build-containers` Pipeline and BuildConfigs exist, the API container Deployment is ready, and the frontend Rollout has two ready replicas. **The containers are pre-staged and running but receive no application traffic at the start.** This keeps a fallback available if the live build takes too long.
4. Open the application, OpenShift console and [Dev Spaces workspace](prereqs/README.md). Start the workspace in advance and open `vm-cloud-native-demo`. It clones the configured repository revision, so publish the demo changes to that revision before starting it.
5. Check that OpenShift Lightspeed is available in the console and can answer a read-only question about the `rocket-ramen` project. Its answer depends on configured cluster access and user permissions. See [Lightspeed prerequisites](prereqs/agentic/README.md). Rehearse the question; keep the VM page as a fallback.
6. In Dev Spaces, open **Terminal: Create New Terminal (Select a Container)** and choose `openshift-cli`. Authenticate to the demo cluster as a user who can start builds, apply workloads and update Services and Routes. Do not display login tokens. The workspace components share source files. Keep the following commands in this terminal for part 2.
7. Rehearse the live source build and rollout on the target cluster. The VM baseline and earlier cutover were rehearsed, but the newer workspace-source Tekton build needs an end-to-end rehearsal on the current cluster.

## Part 1 — Operational modernization: console only

### 1. The starting application

**Show:** Open the Rocket Ramen Route in the browser. Place an order and leave it visible. Point out the web and API VM badges, the MariaDB version, and the **Where this page runs** card. The VM names and namespace come from provisioning metadata; a readable VM serial comes from KubeVirt SMBIOS. A guest cannot see its OpenShift node through this mechanism, so the node is shown as `—`.

**In the OpenShift console:** Select project `rocket-ramen` and open **Virtualization → VirtualMachines**. Show `orders-web`, `orders-app` and `orders-db`; the builder, bootc target and separate GitOps showcase VM are infrastructure, not application tiers. Show the `orders` Route and its VM-backed frontend Service.

**Say:** “The application has already moved onto OpenShift Virtualization. It still runs as three VMs, and we have not rewritten it.”

### 2. OpenShift Lightspeed understands cluster context

Open the **OpenShift Lightspeed** console panel while viewing the `rocket-ramen` project. Ask:

> What virtual machines are running in the rocket-ramen namespace? Identify the three application VMs and describe their current state.

Review the answer against the VM list. If available, use a follow-up:

> How is the Rocket Ramen application currently exposed, and which Service does its Route send traffic to?

**Say:** “Lightspeed can use the cluster context available to my identity. I can check its answer against the live resources in the console.” If Lightspeed is unavailable or does not retrieve the resources, show the VM and Route pages and continue; do not imply a successful live query.

### 3. Show the VM bootstrap pipeline

In the console, open **Pipelines → Pipelines** in `rocket-ramen`, select **orders-bootstrap**, and show its successful PipelineRun. Follow the tasks:

1. **Provision:** apply the web, API and database VM definitions and wait for VM readiness. The root disks use the RHEL DataSource; the database has a separate data disk.
2. **Configure:** run the chart-packaged Ansible playbooks over SSH. Ansible configures MariaDB, the Go API and the Node.js frontend, including their systemd services.
3. **Verify:** check the application path and the Route.

The Helm chart installs the pipeline, supporting resources, VM definitions and Ansible playbooks; the PipelineRun creates and configures the VMs. VM readiness is followed by guest and application checks. The separate `rocket-ramen-gitops-demo` VM is reconciled by Argo CD and is not one of these three application VMs.

**Transition:** “Now that the VMs are operating on OpenShift, let's modernize the application itself.”

## Part 2 — Application modernization: Dev Spaces and console

All commands below run in the **Dev Spaces `openshift-cli` terminal**. Use the OpenShift console alongside it to visualize builds, workloads and traffic. No presenter script is needed.

### 4. Inspect and change the application

In Dev Spaces, open:

- `frontend/Containerfile`: packages the Node server and built SPA.
- `backend/Containerfile`: builds and packages the Go API.
- `modernization/workloads.yaml`: the API Deployment and the frontend Argo Rollout.
- `modernization/pipeline.yaml`: the Tekton task that builds the frontend bundle and starts the two image builds.

Make two small edits and save them:

1. In `frontend/src/App.tsx`, change `zero-gravity noodle bar · PatternFly 6` to `zero-gravity noodle bar · Mission Control v2`.
2. In `backend/main.go`, inside `logRequests`, immediately before `start := time.Now()`, add:

   ```go
   w.Header().Set("X-Rocket-Ramen-Release", "container-v2")
   ```

Show the diff in the editor. These saved workspace edits do not need to be committed for this demo. The running VMs keep their original application artifacts.

### 5. Build with Tekton

In the Dev Spaces CLI terminal:

```bash
cd /projects/rh-demos/vm-cloud-native-demo
export NAMESPACE=rocket-ramen
oc whoami
oc -n "$NAMESPACE" get pipeline orders-build-containers
```

Start the build with the non-interactive helper:

```bash
./modernization/run-pipeline.sh
```

The helper uploads an allowlisted archive of the **current saved workspace source**, including uncommitted edits, to the namespace-local artifact service and creates a PipelineRun. Tekton verifies the archive checksum, builds the SPA, and starts the backend and frontend OpenShift binary builds. The helper waits for completion; a build can take several minutes.

**In the console:** open **Pipelines → PipelineRuns**, select the new `orders-build-containers` run and show its task and logs. The VM bootstrap PipelineRun is a separate pipeline.

```bash
oc -n "$NAMESPACE" get pipelineruns
oc -n "$NAMESPACE" get builds
```

If the live build fails or runs too long, use the pre-staged images and skip claims that the new text or header has been deployed. Inspect the failed PipelineRun separately; do not start overlapping builds using the same image tags.

### 6. Deploy next to the VMs

After the build succeeds, resolve the two built image digests and apply the workload manifest:

```bash
API_IMAGE=$(oc -n "$NAMESPACE" get istag/orders-api-container:demo -o jsonpath='{.image.dockerImageReference}')
WEB_IMAGE=$(oc -n "$NAMESPACE" get istag/orders-web-container:demo -o jsonpath='{.image.dockerImageReference}')
printf 'API: %s\nWeb: %s\n' "$API_IMAGE" "$WEB_IMAGE"
```

Check both values end in an `@sha256:` digest, then apply:

```bash
sed -e "s|DEMO_API_IMAGE|$API_IMAGE|g" -e "s|DEMO_WEB_IMAGE|$WEB_IMAGE|g" modernization/workloads.yaml | oc -n "$NAMESPACE" apply -f -
oc -n "$NAMESPACE" rollout status deployment/orders-api-container --timeout=5m
oc -n "$NAMESPACE" get rollout orders-web-container
oc -n "$NAMESPACE" get pods -l app=orders-web-container
```

**In the console:** show the API Deployment and frontend Rollout beside the VM resources. Both workloads were staged during setup, so this apply **updates** their images. The web image update itself can initiate the configured 60-second Argo canary; wait until the Rollout is Healthy and both frontend replicas are available before continuing. The API reads the existing database Secret. Applying the workloads does not switch the Route or API Service.

**Say:** “The new container workloads and the existing VMs are running on the same platform. We can now choose when to move traffic.”

### 7. Move traffic and show coexistence

First confirm the VM-backed application and the ready container endpoints:

```bash
oc -n "$NAMESPACE" get vm orders-web orders-app orders-db
oc -n "$NAMESPACE" get endpoints orders-web-container
oc -n "$NAMESPACE" get svc orders-app -o jsonpath='{.spec.selector}{"\n"}'
oc -n "$NAMESPACE" set route-backends orders
```

Switch the API Service to the container. This is a selector switch, not a percentage split; both frontend versions use this same API Service:

```bash
oc -n "$NAMESPACE" patch service orders-app --type=merge -p '{"spec":{"selector":{"vm.kubevirt.io/name":null,"app":"orders-api-container"}}}'
```

Split the frontend Route between the VM and container Services:

```bash
oc -n "$NAMESPACE" annotate route orders --overwrite haproxy.router.openshift.io/balance=roundrobin haproxy.router.openshift.io/disable_cookies=true
oc -n "$NAMESPACE" set route-backends orders orders-web=50 orders-web-container=50
oc -n "$NAMESPACE" set route-backends orders
```

**In the console:** show the `orders` Route's two backends and their weights. Refresh the application and compare web runtime and instance names; the API badge now reports a container. The Route weights apply to new connections and are not an exact 50/50 guarantee for a small sample. Existing connections, including SSE, can remain on their previous backend. `/api/webinfo` and the page itself are separate requests and can reach different web instances.

Send all new frontend traffic to the container:

```bash
oc -n "$NAMESPACE" set route-backends orders orders-web=0 orders-web-container=100
oc -n "$NAMESPACE" set route-backends orders
```

Refresh and show the new **Mission Control v2** text and container pod/node information. The API now serves the new code too:

```bash
HOST=$(oc -n "$NAMESPACE" get route orders -o jsonpath='{.spec.host}')
curl -sS -D - -o /dev/null "http://$HOST/api/menu" | grep -i '^x-rocket-ramen-release:'
```

The expected header is `X-Rocket-Ramen-Release: container-v2`. The original VMs are still running; MariaDB remains on its original VM. The header and edited text are expected only if the live build succeeded and the new images were applied.

### 8. Progressive delivery of a container revision

The Route split above is controlled directly with `oc`; it is independent of Argo Rollouts. The web container is an Argo `Rollout` with two replicas, a 50% canary step and a 60-second pause. To make a **later container-to-container revision** visible, change an annotation in its pod template:

```bash
REVISION="$(date +%s)"
oc -n "$NAMESPACE" patch rollout orders-web-container --type=merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"demo.revision\":\"$REVISION\"}}}}}"
oc -n "$NAMESPACE" get rollout,replicasets,pods -l app=orders-web-container -w
```

**In the console:** inspect the frontend Rollout and its ReplicaSets and pods during the pause. Refresh the application to compare the displayed web pod name with the old and new pods. Different requests can reach different replicas; strict alternation is not guaranteed. Press Ctrl-C to stop the watch.

The annotation changes the pod template to show rollout mechanics; it does not introduce another application feature. Without a configured traffic-routing integration, Argo Rollouts approximates its canary weight using replica counts. It does not control the VM-to-container Route split, and this demo does not configure automated metrics analysis. Workloads here are applied from Dev Spaces; Argo CD is not syncing this Rollout.

## Close and reset

Show the application with container frontend and API, MariaDB on its VM, and the order placed at the beginning. **Say:** “We modernized application components independently, with VMs and containers running side by side. For VM workloads we choose to keep, image mode and bootc offer another way to manage the operating system as an image.” No bootc migration is performed in this demo.

To restore the starting traffic after the presentation, from the Dev Spaces CLI terminal:

```bash
oc -n "$NAMESPACE" set route-backends orders orders-web=100 orders-web-container=0
oc -n "$NAMESPACE" patch service orders-app --type=merge -p '{"spec":{"selector":{"app":null,"vm.kubevirt.io/name":"orders-app"}}}'
oc -n "$NAMESPACE" set route-backends orders
oc -n "$NAMESPACE" get svc orders-app -o jsonpath='{.spec.selector}{"\n"}'
```

Refresh the application and confirm both web and API report VM and the order is still present. The database has not moved or been reset. To repeat the exact code-edit beat, revert the two presenter edits in Dev Spaces when finished; do not discard unrelated workspace changes. The staged container images and running containers remain available for the next session.
