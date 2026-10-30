# RHEL 10 VM bootstrap with Tekton and Ansible

This independent automation package prepares the **pre-presentation baseline**: three RHEL 10 VMs for the Node.js frontend, Go API, and MariaDB. Tekton creates the VM resources and runs Ansible to configure the guests. Cloud-init only creates the SSH automation user. Setup is intended to complete before the presentation.

**Status:** implemented as a scaffold and checked offline; it has not been run on a cluster or validated against the application agent's final artifacts. Its artifact and API contracts must be checked with that agent before an end-to-end rehearsal. The existing `../chart` and `../scripts` are a separate prototype; do not install both releases into the same namespace because they use the same VM and Service names. This package does not implement the later container or bootc database migration.

## What runs

1. `orders-provision` applies three OpenShift Virtualization VM resources and waits for VM readiness. MariaDB has a separately provisioned, persistent data disk.
2. `orders-configure` connects through namespace-local Services and runs Ansible. It waits for SSH and cloud-init, verifies RHEL 10, configures MariaDB, the API, then the frontend, and checks the frontend → API → MariaDB path. A final task checks the application Route.
3. `orders-bootstrap` performs both phases in sequence, suitable when SSH host trust is already provisioned.

A VM reporting Ready does not mean its guest or application is ready. Every pipeline task has a timeout. A failed schema initialization is not retried against an existing database automatically: inspect the database and recover deliberately.

## Prerequisites and interfaces

- OpenShift 4.21/4.22 with OpenShift Virtualization and OpenShift Pipelines, a dedicated namespace, working default pod networking and ingress, and permission to create the chart's resources. The CLI image must contain `oc`, `bash`, and `curl`.
- A ready, authorized RHEL 10 DataSource supporting cloning, RHEL 10 guest images with cloud-init, Python 3 and SSH, and appropriate storage. Configure DataSource access and any required clone authorization. Choose a supported storage class and verify that VM disks and the separate RWO data disk work with it.
- RHEL entitlement and repositories or a suitable internal mirror accessible from each VM before Ansible installs packages. This package does **not** register guests or configure subscriptions. Confirm the configured Node.js and MariaDB package names exist in the chosen repositories.
- A pullable Ansible task image with `ansible-playbook`, Python 3, Bash, and OpenSSH. `images/ansible.Containerfile` is an example build recipe, not a verified or supported image; build, pin, and validate an image appropriate for the cluster. The task runs under the cluster's normal security context.
- HTTPS artifact URLs reachable by the VMs, with SHA-256 digests for each **specific artifact**: a Linux executable for the Go API matching VM architecture, a tar.gz frontend archive containing the Node.js server and assets at its root, and a MariaDB initialization SQL file. The frontend entrypoint defaults to `server.js`. The API must support `DB_DSN`, `APP_RUNTIME`, `PORT`, `/health`, and a JSON menu endpoint (default `/api/menu` with a nonempty `items` array); the frontend must serve `/` and proxy `/api/` to `API_URL`. Coordinate these contracts and the database schema with the application agent. No source files are copied from that agent's working directory.
- A Kubernetes SSH Secret with `id_rsa` and `known_hosts` keys. The private key must match `vm.sshPublicKey`. The known-hosts entries must authenticate `orders-db`, `orders-app`, and `orders-web` as reached from the Ansible task. Use a trusted SSH host CA or independently verify fingerprints via the VM console; blindly trusting `ssh-keyscan` alone is not verification. Host-key checking is enabled.
- A Kubernetes database Secret with key `password`: 16–128 alphanumeric characters, no newline. The account and schema are created on the **first initialization of a new database only**. This constraint avoids embedding arbitrary SQL syntax or invalid DSN characters in generated configuration. Use a private file for the secret; never commit it.

The data disk is formatted as XFS only if it has no detected signatures and `artifacts.dataFormatApproved: true`. The playbook refuses unknown existing filesystems and refuses to hide files already present at the MariaDB mountpoint. Existing databases and order data are never re-seeded; a missing/empty expected menu fails verification. Re-running is intended to preserve data, but this is not a backup or database migration strategy. Do not run overlapping bootstrap PipelineRuns in one namespace.

## Configure and install

Create a private values file outside Git, for example:

```yaml
vm:
  sourceNamespace: openshift-virtualization-os-images
  sourceName: rhel10  # replace with the actual ready DataSource
  storageClass: my-vm-storage-class
  sshPublicKey: 'ssh-ed25519 AAAA... demo-automation'
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
export NAMESPACE=orders-rhel-demo
cd vm-cloud-native-demo/automation
./scripts/install.sh -f /private/path/orders-values.yaml
./scripts/run.sh provision
```

The installation creates the namespace if needed, a scoped service account and role, bootstrap resources, Services, and the persistent data PVC. It does not create the VMs until the provision PipelineRun. If you have not preconfigured host certificates, inspect the three VMs via a trusted console and independently record the verified SSH host keys using the Service names in `known_hosts`. Then create the Secrets in the namespace, for example from private files:

```bash
oc create secret generic orders-automation-ssh -n "$NAMESPACE" \
  --from-file=id_rsa=/private/path/demo-ssh-key \
  --from-file=known_hosts=/private/path/demo-known-hosts
oc create secret generic orders-database-credentials -n "$NAMESPACE" \
  --from-file=password=/private/path/db-password
./scripts/run.sh configure
```

Secret names are configurable via `secrets.ssh` and `secrets.database`. If a trusted host CA and both Secrets are already available, `./scripts/run.sh bootstrap` provisions and configures in one PipelineRun. `run.sh` reports an explicit failure or a timeout; inspect the failed PipelineRun and TaskRun logs rather than rerunning blindly.

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

This checks Helm rendering, embedded VM and cloud-init YAML, Ansible syntax, and shell syntax only. It cannot validate cluster CRDs, SSH trust, guest boot, artifacts, package repositories, storage, SELinux, networking, database initialization, or application behavior.
