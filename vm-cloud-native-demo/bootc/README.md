# MariaDB on an image-mode VM: planned extension

`Containerfile` is an unvalidated starting point for a MariaDB VM based on image mode for RHEL. It installs MariaDB and guest integration tools; it does not provision or migrate database state. Use an authorized RHEL registry and validate the base image tag, package versions, and entitlement.

Implementation still needs an OCI build and publish workflow, a bootc-image-builder QCOW2 build, image import, a replacement VM, networking, credentials, and guest initialization. A separate, tested MariaDB data migration must address persistent storage, data consistency, backups, schema compatibility, cutover, and recovery. Keep the original VM available until the new database has been validated. A bootc OS rollback is not a database rollback.

The bootc image-builder local workflow requires rootful privileged execution; do not assume it can run in a normal Dev Spaces workspace. The deployed image is a VM, not an application container. The original application VM example has been replaced by this MariaDB target.

See [RHEL image mode](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/introducing-image-mode-for-rhel) and [bootc image builder](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems).
