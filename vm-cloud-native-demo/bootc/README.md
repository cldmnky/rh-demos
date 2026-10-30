# MariaDB on an image-mode VM

The target VM runs RHEL 10 image mode and MariaDB on a separate data disk. The `Containerfile` leaves MariaDB disabled until the cloned disk is mounted and checked.

The migration and reset have been exercised on the current cluster. If automatic detection is ambiguous, set `SNAPSHOT_CLASS` to a CSI VolumeSnapshotClass compatible with the database storage, then run `./bootc/migrate.sh` and `./bootc/retire-legacy.sh` from the demo directory. `./bootc/reset.sh` takes a fresh offline snapshot of the bootc database and restores its data to a new PVC for the legacy VM. Each migration and reset creates snapshots and PVCs that are retained for recovery. A bootc OS rollback is not a database rollback.

The setup script calls `./bootc/prepare.sh` to automate target preparation. The fresh-namespace build, disk import and VM boot were tested on OpenShift 4.22. The initial setup run was interrupted during testing and resumed at the bootc step; a subsequent uninterrupted repeat setup passed. Its stages are:

1. `./bootc/prepare-builder.sh` creates a RHEL builder VM and configures Podman with Tekton and Ansible.
2. Build and publish the `Containerfile`, then convert it to a QCOW2 on the builder with Red Hat `bootc-image-builder`. `build-on-builder.sh` requires a writable registry and authenticated rootful Podman. The preparer uses the internal registry with temporary authentication.
3. The preparer forwards builder SSH, stages the QCOW2 and imports it with CDI, then creates the target VM.

The target reports the internal-registry image as its booted source. On the primary demo target the registry service CA is installed; a short-lived pull credential was used to switch from the initial local test tag and then removed. Registry authentication renewal and an automated image-update demonstration are not yet configured.

The documented image-builder workflow uses root and a privileged container on the dedicated builder VM; do not assume those privileges exist in Dev Spaces. See [RHEL image mode](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems).
