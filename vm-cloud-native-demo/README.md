# From VM to cloud-native

A developer-day presentation and demo about modernizing an application in stages on OpenShift. The **target application** has a Node.js single-page frontend, a Go API, and MariaDB. It starts with each tier on its own VM. The intended end state runs the frontend and API in containers, with MariaDB on a VM built using image mode for RHEL and bootc.

**Scaffold status:** the target baseline is three **pre-deployed RHEL 10 VMs configured with Ansible**. The existing implementation still provisions CentOS VMs and configures guests with cloud-init; it must be replaced by the RHEL 10 and Ansible workflow planned below. The application (Rocket Ramen) is implemented and verified locally, including a Playwright suite against a real MariaDB; nothing has been validated end to end on a cluster yet. The MariaDB bootc image build, VM import, persistent-data migration, cutover, and bootc updates are not implemented. No existing VM migration is performed.

## The application journey

| Stage | Frontend | API | Database |
| --- | --- | --- | --- |
| Starting point | Node.js SPA on a RHEL 10 VM | Go API on a RHEL 10 VM | MariaDB on a conventional RHEL 10 VM |
| Operational modernization | Declarative VM definitions and Tekton/Ansible provisioning; VM workloads remain VMs | Same | Same |
| Application modernization | Container Deployment | Container Deployment | MariaDB stays on its VM |
| Image-mode target | Container | Container | MariaDB on a replacement RHEL bootc VM with a separately planned data migration |

The application is **Rocket Ramen**, a zero-gravity noodle bar. A PatternFly 6 SPA (React 19 + TypeScript) shows the galley menu with search and a tray, the live **Mission Control** order board, an operations strip, and a stack panel. The Go API does the real work: it locks stock with `SELECT … FOR UPDATE`, prices the basket, derives an ETA from current queue depth, writes `orders`, `order_items` and `order_events`, and streams every change back over SSE. MariaDB holds all of it.

A thin Node server (`frontend/server.js`) serves the built SPA and proxies `/api/`, including the SSE stream, to the API. It also answers `/api/webinfo` so the UI can say which tier is answering. The masthead always shows three badges — web runtime, API runtime, MariaDB version — which is what makes the cutover visible: they flip from `VM` to `container` while the order history in MariaDB is unchanged.

The same Go sources run on the app VM and in the API image. The same `frontend/dist` bundle is unpacked by the web VM's cloud-init and copied into the web image, so the container cutover changes the runtime, not the application.

## The application

Rocket Ramen is deliberately small enough to read on a projector, but it does real work rather than returning a fixture.

| Screen | What it shows | Which tier it proves |
| --- | --- | --- |
| Galley menu | Eight dishes from MariaDB, live stock, `FULLTEXT` search (`spicy`, `vegan`, …) | `MATCH … AGAINST` on MariaDB |
| Tray | Basket, crew name, checkout with a `409` alert naming the dish that sold out | transactional stock, rollback |
| Mission Control | Live order board with per-station actions (`queued → cooking → plating → served`) and an ETA derived from queue depth | SSE through the Node proxy, `FOR UPDATE` |
| Ops strip | Revenue, orders, average ticket, busiest hour, orders-per-hour, best sellers | SQL aggregation (`GROUP BY`, `HOUR()`) |
| Stack panel | Web runtime, API runtime, MariaDB version, uptime, query latency, connections | the three tiers themselves |

### Data model

`db/schema.sql` is idempotent and is the single source of the schema for both the VM and any containerized database:

- `menu_items` — dish, price, prep time, stock, spice, tags, `FULLTEXT (name, description, tags)`, plus `restock_to` for a repeatable reset.
- `orders` — `code` (`M-0001`), customer, status, totals, `eta_minutes`, timestamps.
- `order_items` — priced line items with the dish name snapshot.
- `order_events` — per-order status history.

The script also drops the pre-Rocket-Ramen `orders` table (`item`, `delivery_days`) so an existing demo namespace can be reseeded instead of recreated.

### API

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | DB ping, runtime name |
| `GET /api/menu?q=` | menu, with `FULLTEXT` search when the term is at least three characters |
| `GET /api/orders?limit=` | recent orders with their line items |
| `POST /api/orders` | transactional checkout; `409 sold_out` names the dish, `409 unknown_item` rejects a stale tray |
| `POST /api/orders/{id}/advance` | next station; `409 already_served` at the end |
| `GET /api/stats` | revenue, queue depth, top sellers, hourly buckets, MariaDB version/uptime/latency |
| `GET /api/stream` | SSE: `hello`, `order.created`, `order.updated`, `stats`, `menu.updated`, plus a 10s heartbeat |
| `POST /api/restock` | refill stock to `restock_to` |
| `POST /api/reset` | clear the order board for a rehearsal; menu and stock stay |
| `GET /api/webinfo` | answered by `server.js`, not the API: which tier serves the page |

The API has no third-party dependencies beyond `go-sql-driver/mysql`, and `go.mod` stays at `go 1.20` so the guest `golang` package can build it.

### One artifact, two runtimes

The SPA needs a build step (PatternFly 6 + React 19 + TypeScript + Vite), the VM must not run `npm` at boot, and userdata becomes a Kubernetes Secret capped at 1 MiB. The workflow is:

1. `scripts/build-frontend.sh` runs `npm run build`, drops the unused PatternFly italic font faces, packs `frontend/dist` into `chart/files/web.tar.gz`, and fails if the base64 encoding would exceed 900 KB.
2. `scripts/sync-sources.sh` copies `server.js`, the Go sources, and `db/schema.sql` into `chart/files/` and rebuilds the bundle only when it is missing or `REBUILD_WEB=1`.
3. Cloud-init writes the tarball into the web VM (`encoding: b64`) and extracts it to `/opt/orders/web`; `server.js` serves that directory.
4. `frontend/Containerfile` copies the same `dist/`, so the cutover changes the runtime and nothing else.

### Local development and tests

```bash
# MariaDB, the same schema the VMs use
podman run -d --name ramen-db -p 13306:3306   -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=orders   -e MARIADB_USER=orders -e MARIADB_PASSWORD=demo-only-password mariadb:11.4
podman exec -i ramen-db mariadb --default-character-set=utf8mb4   -uorders -pdemo-only-password orders < db/schema.sql

# API (VM parity: APP_RUNTIME=VM, same DSN shape as cloud-init)
cd backend
DB_DSN='orders:demo-only-password@tcp(127.0.0.1:13306)/orders?parseTime=true&charset=utf8mb4' \
  APP_RUNTIME=VM PORT=8080 go run .
go test ./...   # unit tests
ORDERS_TEST_DSN='orders:demo-only-password@tcp(127.0.0.1:13306)/orders?parseTime=true' \
  go test -run Integration ./...   # real SQL: stock locking, rollback, status flow, stats

# Web tier: the Vite dev server proxies /api to the Go API
# (in Dev Spaces the components run in separate pods, so set API_URL to the
#  Route or the API Service instead of 127.0.0.1)
cd ../frontend && npm ci && npm run dev

# Built bundle + Playwright against a local server (or a cluster Route)
npm run build && npm start                    # serves dist/, proxies to :8080
PLAYWRIGHT_BASE_URL=http://127.0.0.1:8080 npx playwright test
```

The Playwright suite covers menu rendering and hijacking-free `FULLTEXT` search, checkout, station advancement, cross-browser SSE updates, the sold-out rollback alert, and the stack badges. Run `npx playwright install chromium` once per workspace.

### Resetting the demo data

```bash
curl -X POST "http://$HOST/api/reset"    # empty the board (menu and stock stay)
curl -X POST "http://$HOST/api/restock"  # refill stock
```

The board also has **Restock galley** and **Clear board** buttons, which is the quickest reset between rehearsals. `/api/reset` is a demo-only endpoint: it deletes the order tables, resets the `M-####` counter, and broadcasts `orders.cleared` so every open browser empties without a reload. It never touches `menu_items`.

To change the schema itself, re-run the guest bootstrap (cloud-init only runs once per guest):

```bash
virsh -c qemu+ssh://... # inside the db VM:
/usr/local/sbin/init-orders-db
```

`init-orders-db` is idempotent: it recreates missing tables, applies `db/schema.sql`, and keeps existing orders.

## Presentation narrative

### Opening — a personal journey from VMs to cloud-native

Magnus starts with a short personal story about working with VMs and how he became interested in cloud-native ways of building and operating software. Use his own experience and a specific turning point. Connect that journey to developers and DevOps teams who maintain useful VM-based applications while adopting containers and new delivery practices.

> “What if the practices that made cloud-native applications easier to deliver could also help us operate the VMs we already depend on?”

Introduce OpenShift Virtualization from the VM's perspective: a VM still has a guest operating system, applications, storage, and networking. On OpenShift, teams can use platform APIs and workflows such as declarative definitions, automation, and access control around it. These practices need to be configured and adopted; moving a VM does not automatically implement them.

### The premise

The team owns an order application that works. The business wants to deliver changes more frequently, and the team wants a more repeatable way to maintain the application and its infrastructure. It cannot stop feature delivery for a wholesale rewrite, and its order data must survive each transition.

> “We have an application that works. How can we make it easier to change and operate while it continues to serve the business?”

**The message:** platform, operational, and application modernization are distinct choices. First bring cloud-native practices to the VMs. Then move the application tiers to containers where it makes sense. Keep MariaDB in a VM, while exploring an image-based way to manage that VM.

### Presentation surfaces

- **Slides** tell the story, introduce OpenShift Virtualization and the three modernization outcomes, and explain the architecture and trade-offs.
- **Dev Spaces** is the developer workbench for the SPA, Go API, tests, Containerfiles, and VM definitions.
- **The demo-magic terminal script** provides the repeatable platform-facing portion of the demonstration. The browser shows the same order before and after each change.

Prepare the workspace, browser tabs, images, VM state, and pipeline runs before the session. The live story should show the meaningful cutovers and verification rather than waiting for package installation or image creation.

### 40-minute run of show

This is the **target** presentation. Until the cluster workflow and bootc transition are implemented and rehearsed, use the relevant sections as a design walkthrough and label them accordingly.

| Time | Segment | Surface | Presenter cue |
| --- | --- | --- | --- |
| 0–3 min | Personal story | Slides | Connect Magnus's VM experience to his cloud-native journey. |
| 3–7 min | Virtualization from the VM perspective | Slides | Explain the familiar VM and the platform workflows available around it. |
| 7–10 min | Three modernization outcomes | Reference slide 1 | Distinguish platform, operational, and application modernization. |
| 10–14 min | Operational modernization | Reference slide 2 → terminal | Show declarative VM definitions, the Tekton setup, three VMs, and the working order application. |
| 14–18 min | Developer workflow | Dev Spaces | Show the Node.js SPA, Go API, devfile, and tests. |
| 18–20 min | From operations to applications | Reference slide 3 | Explain that VMs and containers can run side by side on OpenShift. |
| 20–27 min | Move frontend and API | Dev Spaces → terminal → browser | Build or show prepared container images; prepare and cut over each tier. Verify the same order. |
| 27–32 min | Modernize the MariaDB VM | Dev Spaces → terminal | **Planned:** show the bootc build and replacement VM, then explain or demonstrate a validated data cutover. |
| 32–36 min | Decisions and trade-offs | Slides | Discuss database state, cutover, rollback, failure handling, and team ownership. |
| 36–40 min | Questions and buffer | Slides | Recap the outcomes and take questions. |

### Slide outline

1. **Personal story:** Magnus's journey from VMs to cloud-native.
2. **OpenShift Virtualization:** the VM remains familiar; OpenShift adds platform APIs and operational workflows.
3. **Three modernization outcomes** — reference image 1: platform, operational, and application modernization. The demo starts with newly provisioned VMs, not an actual migration.
4. **Operational modernization** — reference image 2: connect declarative infrastructure, automation, CI/CD, and GitOps to VMs. Show only capabilities actually present in the demo.
5. **The application and demo map:** Node.js SPA → Go API → MariaDB, initially on three VMs; introduce Dev Spaces and the scripted terminal.
6. **Maintain, migrate, modernize** — reference image 3: bridge operational modernization to application modernization and mixed VM/container workloads. Confirm the appropriate OpenShift edition and entitlement for the demo environment.
7. **Before and after:** frontend and API on VMs → containers; MariaDB VM → planned bootc VM.
8. **Engineering decisions and takeaways:** contracts, availability, data migration, security, rollback, and ownership.

The three supplied images are presentation references; they are not yet in a slide deck in this repository. The before/after slide should distinguish implemented steps from the target when the bootc work is still a design preview.

### Act 1 — A working three-tier application

Show the pre-deployed application in the browser, then show the three RHEL 10 VMs and the declarative definitions that Tekton applies. Explain how Ansible installed and configured the guests before the session. A request goes from the PatternFly SPA to the Go API and then to MariaDB, and every order status change streams back to every open browser over SSE. The masthead badges (`web`, `api`, `db`) are visible for the whole session; they are how the audience follows which tier runs where.

> “The application works. We can start by improving how we define and operate its VMs, without asking the development team to rewrite it first.”

The **planned** workflow creates fresh RHEL 10 VMs on OpenShift; it does not migrate existing ones. Tekton orchestrates VM creation and Ansible configures the guests. The existing scaffold does not yet implement the RHEL 10/Ansible portion. VM readiness, guest configuration, and application readiness need separate verification.

### Act 2 — Operational modernization and Dev Spaces

Show the VM resources and planned provisioning pipeline, including the Ansible roles, then open the repository in the prepared Dev Spaces workspace. Show the SPA sources, the Go API, the Playwright suite, the Containerfiles, and the devfile. Run `npm run dev` in the `node` component to show the Vite dev server talking to the Go API. The devfile describes the development environment; Helm and OpenShift Virtualization describe the VMs.

> “The team can use a consistent development workspace and declarative platform resources while the application is still running on VMs.”

GitOps and more complete CI/CD are possible next steps, not implemented by this scaffold. The current Dev Spaces workspace does not install `oc` or provide cluster credentials; use an authenticated terminal for cluster actions.

### Act 3 — Move the application tiers to containers

Show the frontend and API Containerfiles in Dev Spaces. Prepare the API container, verify its readiness against MariaDB, and switch the API Service to it. The masthead's `api` badge flips from `VM` to `container` while the board keeps its orders. Then prepare and switch the frontend container; the `web` badge flips too. The same Playwright stack spec can prove the flip: run it with `EXPECTED_API_RUNTIME=container`, then with both expectations set to `container`. The VM-backed tiers remain available for a deliberate rollback.

> “We changed where the API and frontend run while keeping their contract and the data they depend on. The VM and container tiers can coexist during the transition.”

The scaffold supplies separate prepare, activate, and revert commands. Images must be built and published separately. Service-selector cutover and readiness do not prove uninterrupted requests or database compatibility; rehearse the flow before the event. No automated build pipeline is implemented yet.

### Act 4 — Keep MariaDB in a VM, modernize its lifecycle

**Planned:** show the RHEL bootc Containerfile, build and publish the bootable image, prepare a replacement VM, and validate MariaDB. Move data to the new VM using a tested, explicit database migration plan and switch the database endpoint only after validation. Verify the same order from the containerized frontend and API.

> “We chose to keep the database in a VM. Image mode gives us a path to build and update the operating system from a versioned image; the database and its state still need their own lifecycle.”

The bootc image is not an application container. A bootc OS rollback does not undo database transactions or reverse a schema migration. Data storage, consistency, backup, credentials, cutover, and recovery are outstanding design work. Until implemented, show the Containerfile as a preview and explain the target rather than claiming a live database migration.

### Close

> “We started with three VMs. We introduced cloud-native operational practices, moved the frontend and API to containers, and chose to keep the database in a VM with an image-based lifecycle. The right next step depends on the application and its data.”

Use future tense for any steps not actually demonstrated. Discuss service contracts, network failures, data ownership, security, observability, and release responsibilities.

## Planned pre-presentation automation

The starting application must already be working when Magnus begins the demo. Run this workflow during preparation, not during the presentation. It deliberately uses Ansible to model how a team might install and maintain an existing VM-based application; later, the demo shows the team adopting container and image-based workflows.

### Responsibilities and sequence

| Phase | Owner | Work and completion evidence |
| --- | --- | --- |
| 1. Check inputs | Setup entrypoint | Confirm the selected cluster and namespace, RHEL 10 boot source and entitlement, storage, repository access, registry access, SSH credentials, and sufficient capacity. Fail before provisioning if inputs are missing. |
| 2. Provision | Tekton + OpenShift Virtualization | Create the frontend, API, and database VMs from an approved RHEL 10 DataSource. Wait for VM readiness, then independently wait for SSH and guest initialization. |
| 3. Establish access | Minimal cloud-init + Ansible | Cloud-init creates a dedicated automation user and injects its SSH public key; Ansible connects using a private key from a Kubernetes Secret and verifies host identity. Application installation belongs to Ansible. |
| 4. Configure database | Ansible database role | Install and configure MariaDB, its service, database, scoped application account, and seed data. Wait for a successful database query before moving on. |
| 5. Configure API | Ansible API role | Install the approved Go application artifact and its configuration, set up a systemd service, and verify that the API can read the expected order from MariaDB. |
| 6. Configure frontend | Ansible frontend role | Install the Node.js runtime and prepared SPA/server artifact, configure the API endpoint, enable its systemd service, and verify frontend and proxy responses. |
| 7. Verify baseline | Tekton + verification playbook | Check all services and the browser-facing Route; verify the same known order is returned through the complete request path. Publish a concise result and fail the PipelineRun on errors. |

The frontend, API, and database may be provisioned in parallel; guest configuration follows database → API → frontend because each layer depends on the previous one. Each wait needs a timeout and useful diagnostics. VM `Ready` is not equivalent to SSH, cloud-init, service, or application readiness.

### Proposed implementation

- **Declarative VM inputs:** keep namespace-scoped VM, storage, networking, and Service definitions in the chart. Make the RHEL 10 DataSource name and namespace, storage class, CPU, memory, and disk sizes configurable. Use a distinct persistent data disk for MariaDB so its data lifecycle is explicit; the later bootc data migration still requires a separately tested plan.
- **Tekton orchestration:** use one pipeline with bounded tasks for preflight, VM provisioning, Ansible configuration, and end-to-end verification. Run `oc` and Ansible in suitable prebuilt task images; make the image references configurable. Limit service-account permissions to the required resources in the demo namespace.
- **Ansible structure:** introduce an inventory and separate `common`, `mariadb`, `api`, and `frontend` roles, plus a verification playbook. Inventory can target per-VM internal Services with SSH ports, provided this network path is verified in the actual cluster. Keep application ports and endpoints explicit. Do not assume that a VM's guest IP or SSH availability follows from the VM resource being ready.
- **Application artifacts:** coordinate the install paths, build outputs, service configuration, and health checks with the agent implementing the applications. Fetch pinned, prebuilt artifacts from a configured source or provide them to the pipeline through an agreed workspace. Do not build application artifacts by pulling arbitrary latest source during guest boot.
- **Secrets and trust:** reference separately provisioned Kubernetes Secrets for the automation SSH private key, database credentials, and any RHEL or registry credentials. Supply and verify trusted SSH host keys or a host CA; do not silently disable host-key checking. Do not embed secrets in Git, task logs, VM definitions, or application images.
- **RHEL prerequisites:** use an approved RHEL 10 guest image with cloud-init and guest integration as required, and ensure each VM can access the appropriate entitled repositories or an approved internal mirror. Validate Node.js, MariaDB, and application-artifact compatibility with the chosen RHEL 10 image before fixing versions in the roles.
- **Repeatability:** make roles idempotent and make repeat setup preserve existing MariaDB data. Seed the example order only if absent; fail on incompatible pre-existing state rather than overwriting data. Avoid concurrent setup runs against the same demo namespace. Provide a separately documented, explicit reset for disposable data.
- **Presenter handoff:** preparation ends with a read-only readiness report containing the Route, VM and service state, application version, and end-to-end result. Start the demo only after this report passes; keep logs and failed PipelineRuns available for troubleshooting.

**Implementation boundary:** a separate [RHEL 10 Tekton and Ansible automation package](automation/README.md) now implements this workflow as an unvalidated scaffold. It requires integration with the independently developed application artifacts and an end-to-end cluster rehearsal. The original chart's CentOS/cloud-init guest installation and hard-coded lab credentials remain a separate prototype and do not satisfy this plan; do not install both packages into the same namespace.

## Current scaffold: prerequisites

- A disposable, appropriately entitled OpenShift 4.21 or 4.22 cluster with OpenShift Virtualization and OpenShift Pipelines; `tekton.dev/v1` must be available. Dev Spaces is needed for its presentation segment.
- Authenticated `oc`, Helm 3, curl, Python 3, and permission to create a namespace, Roles, Secrets, VMs, Deployments, and PipelineRuns. The Tekton service account receives namespace-scoped VM access.
- A ready CentOS Stream cloud-image DataSource accessible for cloning, suitable storage, capacity, cluster ingress, and registry access. Override `vm.sourceNamespace`, `vm.sourceName`, and `vm.storageClass` for your environment.
- Guest DNS and outbound access to CentOS repositories and the Go module proxy. Cloud-init installs Node.js, Go, and MariaDB; the Go VM builds the API at first boot. Images and source dependencies must be accessible from the environment.
- **For building the SPA:** Node.js 20.19 or newer with npm, on the workstation or in Dev Spaces. The web VM never runs npm; it receives a packed bundle through cloud-init. Add `npx playwright install chromium` once for the E2E suite.
- **Secret size:** the web tier's cloud-init userdata carries the base64 bundle and becomes a Kubernetes Secret, which is capped at 1 MiB. `scripts/build-frontend.sh` strips unused PatternFly italic fonts and fails above 900 KB encoded. If the bundle grows, split assets before the setup run fails on a rejected Secret.
- A compatible CLI image for Tekton. Override `pipeline.cliImage` if necessary. Build and publish the frontend and API images to a registry that the cluster can pull from.
- `podman` or `docker` for the local MariaDB used by the integration test under `backend/store_integration_test.go`.
- `pv` is optional for the presenter script's typing animation. The script supports demo-magic `-n` and `-w` flags.

This is a **disposable lab**. It contains a fixed example database password, disables guest firewalld, and exposes an unencrypted route. Do not use real data or credentials. MariaDB data is currently on the conventional VM's root disk; deleting it loses the demo data. Cloud-init Secrets contain the example password.

## Current scaffold: set up the baseline

```bash
cd vm-cloud-native-demo
export NAMESPACE=vm-cloud-native
./scripts/build-frontend.sh            # once, or whenever frontend/ changes
./scripts/setup.sh                    # optionally add -f my-values.yaml
./scripts/verify.sh
```

These commands are for the **existing CentOS/cloud-init prototype**, not the planned RHEL 10/Ansible baseline. Setup synchronizes the application source into the chart, installs/upgrades the release, and creates a Tekton PipelineRun. It waits for the VM resources, not guest setup. First boot can take several minutes.

`verify.sh` checks behaviour rather than liveness: the menu and its `FULLTEXT` tags come from MariaDB, a real order is committed through the Route and comes back with an `M-####` code and an ETA, `/api/stats` reports the MariaDB version and the API runtime, and the served `index.html` references the built `assets/app.js`. `scripts/sync-sources.sh` builds the SPA only when `chart/files/web.tar.gz` is missing; set `REBUILD_WEB=1` after any `frontend/` change so the VMs and the image see the same bundle.

```bash
oc whoami --show-context
oc get datasource -n openshift-virtualization-os-images
oc get storageclass
oc get crd virtualmachines.kubevirt.io pipelines.tekton.dev
helm template vm-cloud-native chart
```

Example local overrides:

```yaml
vm:
  sourceNamespace: openshift-virtualization-os-images
  sourceName: centos-stream9
  storageClass: your-vm-storage-class
pipeline:
  cliImage: your-registry/oc-compatible-image:tag
```

The source copies under `chart/files/` are generated from `frontend/` and `backend/`. Run `scripts/sync-sources.sh` after editing source before rendering the chart; setup and container preparation also run it. Changes to cloud-init are applied on first boot, not automatically inside already-created guests.

## Prepare the application cutover

Build and publish images from the two Containerfiles using an approved build environment and provide the actual pullable image references below. The frontend image expects `frontend/dist`, so run `./scripts/build-frontend.sh` (or `npm run build`) first; that is the same bundle the web VM already serves. Building and publishing is intentionally separate from the Dev Spaces workspace and is not automated yet.

```bash
./scripts/service.sh prepare app "$API_IMAGE"
./scripts/service.sh activate app
./scripts/verify.sh
./scripts/service.sh prepare web "$FRONTEND_IMAGE"
./scripts/service.sh activate web
./scripts/verify.sh
```

`prepare` creates the Deployment and waits for readiness; `activate` changes the matching Service selector after checking rollout status. Revert in reverse order:

```bash
./scripts/service.sh revert web
./scripts/service.sh revert app
./scripts/verify.sh
```

The original VMs must still be healthy. Revert changes traffic selection but does not remove the container Deployments. Both implementations use the same MariaDB VM and example credentials. Helm owns these changes; when using GitOps, adapt the workflow to change the actual GitOps source of truth. The Route carries `haproxy.router.openshift.io/timeout: 5m` so the SSE stream is not cut by the router's idle timeout; the API sends a heartbeat every 10 seconds regardless.

For the presenter script:

```bash
./demo/demo.sh
```

To perform the container cutover in the scripted presentation, set `RUN_CUTOVER=true`, `API_IMAGE`, and `FRONTEND_IMAGE` before running it. The script does not implement the bootc migration. Open Dev Spaces separately and use its `test-api` and `check-frontend` commands. The workspace assumes the monorepository is the project root.

## Troubleshooting and verification

```bash
oc get pipelineruns,taskruns,vms,vmis,dv,pvc,pods -n "$NAMESPACE"
oc describe pipelinerun -n "$NAMESPACE" <pipeline-run-name>
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc get endpointslice -n "$NAMESPACE"
```

Inspect `/var/log/cloud-init-output.log` and `systemctl status orders-web`, `orders-api`, or `mariadb` in the relevant VM. Guest package and Go module access, DataSource clone permissions, DNS, registry access, SELinux, storage, and ingress must work in the target cluster.

Application-specific failures to look for:

- **`web bundle missing: expected /opt/orders/web`** from `server.js`: the tarball was not written or extracted. Check `chart/files/web.tar.gz` exists at render time (Helm fails with an explicit message when it does not) and that `tar -xzf` succeeded in `runcmd`.
- **Board says `reconnecting`**: `/api/stream` is blocked. Check the Route timeout annotation, that the proxy passes `Cache-Control: no-store` and `X-Accel-Buffering: no`, and that the Go API was started without a write timeout.
- **`database unavailable`**: MariaDB is down or the schema was never seeded. Re-run `/usr/local/sbin/init-orders-db` inside the db VM; cloud-init only runs once per guest.
- **Emoji or search failures**: the schema must be loaded with `--default-character-set=utf8mb4`, and every table uses `utf8mb4`.
- **`409 sold out` in the demo unexpectedly**: call `POST /api/restock`; the tray intentionally keeps the basket when a transaction rolls back.

Offline checks:

```bash
(cd frontend && npm ci && npm run build)          # tsc --noEmit runs first
./scripts/build-frontend.sh                       # packs chart/files/web.tar.gz
helm lint chart
helm template vm-cloud-native chart > /tmp/vm-cloud-native-rendered.yaml
(cd backend && go test ./...)
node --check frontend/server.js
bash -n scripts/*.sh demo/*.sh

# Real SQL against a throwaway MariaDB (see "Local development and tests")
ORDERS_TEST_DSN='orders:demo-only-password@tcp(127.0.0.1:13306)/orders?parseTime=true' \
  (cd backend && go test -run Integration ./...)

# The bundle the VMs receive must decode into a real tarball
python3 scripts/check-web-bundle.py /tmp/vm-cloud-native-rendered.yaml
```

These checks do not validate VM boot, disk cloning, guest provisioning, container builds, network connectivity, application cutover, bootc, or database migration. No script deletes the demo namespace or disks.
