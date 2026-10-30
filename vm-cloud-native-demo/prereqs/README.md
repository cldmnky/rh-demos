# Cluster prerequisites through Argo CD

The prerequisite Application installs the Red Hat OpenShift Pipelines operator from the `pipelines-1.24` catalog channel in `openshift-operators`. The operator manages its own operands in `openshift-pipelines`. The Application uses automatic synchronization and self-healing; it does not prune resources when files are removed.

Prerequisites: authenticated `oc`, Ruby, an available OpenShift GitOps instance named `openshift-gitops`, a controller with permission to manage Subscriptions, the `redhat-operators` catalog, and network access from Argo CD to the Git repository. The script does not install Argo CD, Dev Spaces, or a RHEL boot image.

```bash
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --check
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --apply
```

The script captures the current kubeconfig context, checks for conflicting Pipelines Subscriptions, applies an Argo CD Application and waits for Argo synchronization, a successful operator CSV and the Tekton Pipeline CRD. Inspect the TektonConfig and controller pods separately to confirm operands are ready. It does not adopt a differently named Pipelines Subscription.

By default the Application points at `https://github.com/cldmnky/rh-demos.git`, branch `vm-cloud-native-prereqs`, and `vm-cloud-native-demo/prereqs/pipelines`. Override `PREREQ_GIT_URL`, `PREREQ_GIT_REF`, or `PREREQ_GIT_PATH` when using a different published source. The referenced files must exist in that Git revision; uncommitted local files cannot be read by Argo CD. After merging the manifests into the main branch, set `PREREQ_GIT_REF=main` and reapply the Application if desired. See the [Red Hat installation guide](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/installing_and_configuring/installing-pipelines) for the operator's subscription model.
