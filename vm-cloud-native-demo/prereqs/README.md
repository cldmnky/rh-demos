# Cluster prerequisites through Argo CD

Two prerequisite Applications install OpenShift Pipelines and OpenShift Dev Spaces. Pipelines uses the `pipelines-1.24` channel and manages its operands in `openshift-pipelines`. Dev Spaces uses the `stable` channel, installs the operator in `openshift-operators`, and creates a `CheCluster` in `openshift-devspaces`. Both Applications synchronize automatically and self-heal without pruning removed resources.

Prerequisites: authenticated `oc`, Ruby, an available OpenShift GitOps instance named `openshift-gitops`, a controller with permission to manage Subscriptions, the `redhat-operators` catalog, and network access from Argo CD to the Git repository. The script does not install Argo CD or a RHEL boot image. Ensure no conflicting Dev Workspace or Dev Spaces installation already exists.

```bash
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --check
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --apply
```

The script captures the current kubeconfig context, checks for conflicting Pipelines Subscriptions, applies both Argo CD Applications and waits for their synchronization, successful operator CSVs, a Ready TektonConfig, and an Active Dev Spaces instance with a dashboard URL. It does not adopt a differently named Pipelines Subscription.

By default the Application points at `https://github.com/cldmnky/rh-demos.git`, branch `vm-cloud-native-prereqs`, and the `vm-cloud-native-demo/prereqs/pipelines` and `vm-cloud-native-demo/prereqs/devspaces` paths. Override `PREREQ_GIT_URL`, `PREREQ_GIT_REF`, `PREREQ_GIT_PATH`, or `DEVSPACES_GIT_PATH` when using a different published source. The referenced files must exist in that Git revision; uncommitted local files cannot be read by Argo CD. After merging the manifests into the main branch, set `PREREQ_GIT_REF=main` and reapply the Application if desired. See the [Red Hat installation guide](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/installing_and_configuring/installing-pipelines) for the operator's subscription model.
