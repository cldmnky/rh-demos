# RHEL 10 VM bootstrap with Tekton and Ansible

This independent automation package prepares the **pre-presentation baseline**: three RHEL 10 VMs for the Node.js frontend, Go API, and MariaDB. Tekton creates the VM resources and runs Ansible to configure the guests. Cloud-init only creates the SSH automation user. Setup is intended to complete before the presentation.

**Status:** the RHEL 10 VM baseline has been exercised on OpenShift 4.22 with the current Rocket Ramen artifacts, including a repeat Ansible run that preserved the database. Revalidate the artifact and API contracts whenever the application changes. This package does not implement the later container or bootc database migration.

## What runs

1. `orders-provision` applies three OpenShift Virtualization VM resources and waits for VM readiness. MariaDB has a separately provisioned, persistent data disk.
2. `orders-configure` connects through namespace-local Services and runs Ansible. It waits for SSH and cloud-init, verifies RHEL 10, configures MariaDB, the API, then the frontend, and checks the frontend → API → MariaDB path. A final task checks the application Route.
3. `orders-bootstrap` performs both phases in sequence, suitable when SSH host trust is already provisioned.

A VM reporting Ready does not mean its guest or application is ready. Every pipeline task has a timeout. A failed schema initialization is not retried against an existing database automatically: inspect the database and recover deliberately.

## Prerequisites and interfaces

- OpenShift 4.21/4.22 with OpenShift Virtualization and OpenShift Pipelines, a dedicated namespace, working default pod networking and ingress, and permission to create the chart's resources. The CLI image must contain `oc`, `bash`, and `curl`.
- A ready, authorized RHEL 10 DataSource supporting cloning, RHEL 10 guest images with cloud-init, Python 3 and SSH, and appropriate storage. Configure DataSource access and any required clone authorization. Choose a supported storage class and verify that VM disks and the separate RWO data disk work with it.
- RHEL entitlement and repositories or a suitable internal mirror accessible from each VM before Ansible installs packages. Optionally, provide an `orders-rhsm` Secret containing both `RHSM_ORG` and `RHSM_ACTIVATION_KEY`; Ansible registers guests that are not already registered. Alternatively, configure a trusted mirror in the guest image. Confirm the configured Node.js and MariaDB package names exist in the chosen repositories.
- A pullable Ansible task image with `ansible-playbook`, Python 3, Bash, and OpenSSH. `images/ansible.Containerfile` is an example build recipe, not a verified or supported image; build, pin, and validate an image appropriate for the cluster. The task runs under the cluster's normal security context.
- Artifact URLs reachable by the VMs, with SHA-256 digests for each **specific artifact**: a Linux executable for the Go API matching VM architecture, a tar.gz frontend archive containing the Node.js server and assets at its root, and a MariaDB initialization SQL file. HTTPS URLs and the namespace-local `orders-artifacts` HTTP Service are accepted. The frontend entrypoint defaults to `server.js`. The API must support `DB_DSN`, `APP_RUNTIME`, `PORT`, `/health`, and a JSON menu endpoint (default `/api/menu` with a nonempty `items` array); the frontend must serve `/` and proxy `/api/` to `API_URL`.
- Per-VM cloud-init Secrets containing an automation public key and the corresponding trusted VM host keys, plus a Kubernetes SSH Secret with `id_rsa` and `known_hosts` keys. `scripts/prepare-secrets.sh` generates distinct VM host keys and installs these Secrets from private local files. Host-key checking is enabled. An optional `vm.presenterPublicKey` is added by Ansible alongside the automation key; its private key is never needed by the automation.
- A Kubernetes database Secret with key `password`: 16–128 alphanumeric characters, no newline. The account and schema are created on the **first initialization of a new database only**. This constraint avoids embedding arbitrary SQL syntax or invalid DSN characters in generated configuration. Use a private file for the secret; never commit it.

The data disk is formatted as XFS only if it has no detected signatures and `artifacts.dataFormatApproved: true`. The playbook refuses unknown existing filesystems and refuses to hide files already present at the MariaDB mountpoint. Existing databases and order data are never re-seeded; a missing/empty expected menu fails verification. To recover a failed first initialization, an operator can inspect the database and explicitly set `artifacts.allowEmptySchemaRecovery: true`; recovery runs only when the database contains zero tables. Remove the override after recovery. Re-running is intended to preserve data, but this is not a backup or database migration strategy. Do not run overlapping bootstrap PipelineRuns in one namespace.

## Configure RHEL subscriptions

Before preparing the demo, a cluster administrator configures the RHEL subscription in the OpenShift console:

1. Open **Virtualization → Overview → Settings → Cluster → Guest management**.
2. Expand **Automatic subscription of RHEL VirtualMachines**, enable it, select **Monitor and manage subscriptions in the Virtualization settings**, and enter the Red Hat activation key and organization ID. Apply the settings.
3. Ensure the activation key grants the RHEL 10 BaseOS and AppStream repositories, and the guests can reach the subscription and content services. An internal mirror is an alternative.

The console setting is used when the console creates and initializes new VMs; it did not retroactively register the existing demo VMs created by Tekton. This automation uses the same configured activation settings separately: the top-level setup script invokes `./scripts/prepare-rhsm-secret.sh` to copy them into the `orders-rhsm` Secret without displaying them. The Ansible run registers each unregistered guest. The helper retains an existing Secret rather than silently changing it when settings are updated.

The Virtualization settings currently store the activation settings in the `openshift-cnv/kubevirt-ui-features` ConfigMap, so treat access to that ConfigMap and to the copied namespace Secret as sensitive. Never commit the activation key or organization ID to Git or print their values. If your organization prefers, create the Secret from private files instead of using this helper.

## Configure and install

Create the dedicated namespace, then prepare the registration and SSH Secrets and build the application artifacts. `PRIVATE_DIR` must be a private persistent directory; `SSH_KEY` can override the automation private key path (default `~/.ssh/rh-demos`).

```bash
export NAMESPACE=orders-rhel-demo
export PRIVATE_DIR=/private/path/orders-private
cd vm-cloud-native-demo/automation
# Create the dedicated namespace first, if it does not already exist.
./scripts/prepare-rhsm-secret.sh
./scripts/prepare-secrets.sh
./scripts/prepare-artifacts.sh
```

`prepare-artifacts.sh` builds the SPA and Linux Go executable, publishes them and the schema to a namespace-internal artifact Service, and prints their URLs and checksums. This Service has no external Route; do not put credentials or sensitive files in the artifact directory. The client needs Node.js/npm, Go, and tar. Set `VM_ARCH` if the VM architecture is not `amd64`. The RHEL boot DataSource must already exist; `scripts/import-rhel10.sh` can import it from a registry using an existing CDI-format registry credentials Secret.

Create a private values file outside Git using the printed artifact details, for example:

```yaml
vm:
  sourceNamespace: openshift-virtualization-os-images
  sourceName: rhel10  # replace with the actual ready DataSource
  storageClass: my-vm-storage-class
  presenterPublicKey: 'ssh-ed25519 AAAA... presenter'  # optional
images:
  oc: registry.example.org/demo/oc-with-curl:4.22
  ansible: registry.example.org/demo/ansible@sha256:REPLACE
artifacts:
  apiUrl: https://artifacts.example.org/orders/api
  apiSha256: REPLACE_WITH_64_HEX_DIGEST
  frontendUrl: https://artifacts.example.org/orders/frontend.tar.gz
  frontendSha256: REPLACE_WITH_64_HEX_DIGEST
  schemaUrl: https://artifacts.example.org/orders/schema.sql
  schemaSha256: REPLACE_WITH_64_HEX_DIGEST
  dataFormatApproved: true  # authorize formatting a new, empty demo data disk
```

Use real values and a controlled, trusted artifact source. The schema SQL is run with database privileges; only publish reviewed SQL. Set `dataFormatApproved` only for a new, disposable data disk. The installer validates URL and checksum formats; it does not prove URL accessibility, image availability, package compatibility, source correctness, storage safety, or entitlements.

```bash
./scripts/install.sh -f /private/path/orders-values.yaml
./scripts/run.sh provision
```

Create the namespace before preparing Secrets. `prepare-secrets.sh` retains existing Secrets and private files rather than rotating them; keep the private directory safe and ensure it corresponds to any existing Secrets. The Helm installation creates the scoped service account and role, bootstrap resources, Services, and persistent data PVC. It does not create VMs until the provision PipelineRun. If using a different key-management approach, provide the expected per-VM cloud-init Secrets and SSH host trust yourself.

```bash
./scripts/run.sh configure
```

Secret names are configurable via `secrets.ssh`, `secrets.database`, and `secrets.rhsm`. If the VM cloud-init, trusted SSH, database, and any required RHSM Secrets are already available, `./scripts/run.sh bootstrap` provisions and configures in one PipelineRun. The RHSM Secret uses keys `RHSM_ORG` and `RHSM_ACTIVATION_KEY`. `run.sh` reports an explicit failure or a timeout; inspect the failed PipelineRun and TaskRun logs rather than rerunning blindly.

Ansible stores API database configuration in a root-owned, mode-0600 file in the API guest. This is a demo setup; guest and cluster access controls, transport encryption, network policies, and secret lifecycle need further design for production. The example Route uses HTTP. The MariaDB Service listens on the internal network, and the roles open the relevant guest port if firewalld is active.

## Verify and troubleshoot

After a successful configure PipelineRun, open the Route printed in its final task and verify the application in a browser. The API test checks that the menu is nonempty; the route task checks that the proxied API returns HTTP 200. Neither substitutes for a functional test of order creation or the later modernization cutovers.

```bash
oc get pipelineruns,taskruns,vms,vmis,dv,pvc,pods -n "$NAMESPACE"
oc describe pipelinerun -n "$NAMESPACE" <name>
oc get route orders -n "$NAMESPACE"
```

Inspect VM console output, cloud-init status, guest networking, repository access, the Automation Secret's verified host keys, systemd services, and task logs if a phase fails. This package does not automatically delete VMs, PVCs, or a database. Helm uninstall is not a safe data reset: understand resource ownership and data consequences before cleanup.

Offline validation requires Helm, Ruby, Bash, and `ansible-playbook`:

```bash
./scripts/check.sh
```

This checks Helm rendering, embedded VM YAML, Ansible syntax, and shell syntax only. It cannot validate cluster CRDs, SSH trust, guest boot, artifacts, package repositories, storage, SELinux, networking, database initialization, or application behavior.
