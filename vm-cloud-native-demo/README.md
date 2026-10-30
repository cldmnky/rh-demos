# From VM to Cloud-Native: Rocket Ramen

A developer-day demo that starts with a three-tier application on RHEL 10 VMs: a Node.js SPA, a Go API, and MariaDB. Tekton provisions the VMs on OpenShift Virtualization and Ansible installs and configures the application, as in a traditional VM environment.

The presentation moves from operational modernization of VMs to application modernization. The intended end state is a containerized frontend and API alongside MariaDB on an image-mode RHEL (bootc) VM. **The VM baseline, container cutover, bootc database migration and data-preserving reset have been rehearsed on OpenShift 4.22.**

## Prepare the demo

Prerequisites:

- An authenticated `oc` session with cluster-admin permissions, OpenShift Virtualization, OpenShift GitOps/Argo CD, a default storage class suitable for VMs, and access to Red Hat registries. The script installs OpenShift Pipelines and Dev Spaces through Argo CD.
- `oc`, `helm`, Ruby, Go, Node.js/npm, `tar`, `ssh-keygen`, `curl`, Python 3, SSH and `virtctl` on the machine running setup.
- Configure **Virtualization → Overview → Settings → Cluster → Guest management → Automatic subscription of RHEL VirtualMachines**. Enable it, select **Monitor and manage subscriptions in the Virtualization settings**, and provide an activation key and organization ID with RHEL 10 BaseOS and AppStream access. VMs also need access to subscription and content services. Treat those settings as sensitive.

From this directory, run:

```bash
./scripts/setup.sh
```

The script applies the prerequisite Argo CD applications, prepares a RHEL 10 boot source if needed, builds and stages the application, creates private credentials, runs Tekton and Ansible, stages the container workloads, and prepares the bootc builder and target VM. It waits for the three VMs and checks the application; the final line prints its URL. Allow time for operator installation, image import, VM boot, and package installation.

The default namespace is `rocket-ramen`. Private setup files are kept outside the repository in `${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo`; **keep this directory** for repeat runs. Existing VM disks, database contents, and credentials are retained. The script uses `~/.ssh/rh-demos` for automation if it exists, otherwise it generates a separate key in the private directory. To authorize a presenter SSH public key as well, or reuse an earlier private directory:

```bash
PRESENTER_PUBLIC_KEY_FILE=~/.ssh/presenter.pub PRIVATE_DIR=/path/to/existing/private-dir ./scripts/setup.sh
```

`NAMESPACE`, `SSH_KEY`, `PRIVATE_DIR`, `ANSIBLE_IMAGE`, and `VM_ARCH` can be overridden as environment variables. `RHEL_SOURCE_NAMESPACE` and `RHEL_SOURCE_NAME` select an existing ready RHEL 10 DataSource on the first run. The default pinned Ansible execution image requires registry access. Never commit private files, subscription details, or credentials.

For the presenter, `./demo/demo.sh` uses demo-magic and the Dev Spaces workspace is described in `devfile.yaml`. The demo script creates an order; setup verification is read-only. See [automation/README.md](automation/README.md) for pipeline details and troubleshooting.

Follow the [demo runbook](demo-runbook.md) for the presentation flow, Dev Spaces steps, traffic cutover, database migration and reset.
