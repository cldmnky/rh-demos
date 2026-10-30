# Cluster prerequisites through Argo CD

Two prerequisite Applications install OpenShift Pipelines and OpenShift Dev Spaces. Pipelines uses the `pipelines-1.24` channel and manages its operands in `openshift-pipelines`. Dev Spaces uses the `stable` channel, installs the operator in `openshift-operators`, and creates a `CheCluster` in `openshift-devspaces`. Both Applications synchronize automatically and self-heal without pruning removed resources.

Prerequisites: authenticated `oc`, Ruby, an available OpenShift GitOps instance named `openshift-gitops`, a controller with permission to manage Subscriptions, the `redhat-operators` catalog, and network access from Argo CD to the Git repository. The script does not install Argo CD or a RHEL boot image. Ensure no conflicting Dev Workspace or Dev Spaces installation already exists.

```bash
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --check
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --apply
```

The script captures the current kubeconfig context, checks for conflicting Pipelines Subscriptions, applies both Argo CD Applications and waits for their synchronization, successful operator CSVs, a Ready TektonConfig, and an Active Dev Spaces instance with a dashboard URL. It does not adopt a differently named Pipelines Subscription.

By default the Application points at `https://github.com/cldmnky/rh-demos.git`, branch `main`, and the `vm-cloud-native-demo/prereqs/pipelines` and `vm-cloud-native-demo/prereqs/devspaces` paths. Override `PREREQ_GIT_URL`, `PREREQ_GIT_REF`, `PREREQ_GIT_PATH`, or `DEVSPACES_GIT_PATH` when using a different published source. The referenced files must exist in that Git revision; uncommitted local files cannot be read by Argo CD. See the [Red Hat installation guide](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/installing_and_configuring/installing-pipelines) for the operator's subscription model.

## Dev Spaces workspace through Argo CD

A third Application, `vm-cloud-native-devspace`, applies `prereqs/devspace/devworkspace.yaml` into the presenting user's Dev Spaces namespace. The workspace — three tooling components, the devfile commands and the `che-code` editor — is created and started by GitOps instead of a dashboard click.

```bash
DEVSPACE_NAMESPACE="$(oc whoami)-devspaces" ./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --apply
./vm-cloud-native-demo/prereqs/scripts/prereqs.sh --check     # namespace, phase, IDE URL
```

- **Namespace:** Dev Spaces provisions `<username>-devspaces` on a user's first dashboard login. The script derives the name from `oc whoami`; when the identity is a service account it refuses to guess and requires `DEVSPACE_NAMESPACE`. If the namespace does not exist yet, log in to the Dev Spaces dashboard once and re-run `--apply` (or `--check`); the Application then syncs.
- **Generated manifest:** `prereqs/scripts/render-devworkspace.sh` merges `devfile.yaml` with the vendored editor stub, injects `API_URL` (default `http://orders-api.rocket-ramen.svc.cluster.local:8080`) and pins the project revision (`DEVSPACE_GIT_REF`, default `main`). `--check` fails when the committed manifest is stale, so run it before pushing.
- **Vendored editor:** a DevWorkspace must carry the editor inline; the dashboard normally merges it from the cluster's `editors-definitions` ConfigMap. `editor-che-code.yaml` is that definition minus icons, refreshed with `render-devworkspace.sh --refresh-editor` after a Dev Spaces upgrade. `CODE_HOST=0.0.0.0` in the devfile keeps che-code reachable from its Route and health check; with the default `127.0.0.1` the workspace never reaches `Running`.
- **No self-heal:** idling the workspace sets `spec.started: false`. With drift correction Argo CD would restart a workspace the presenter deliberately stopped, so this Application keeps `automated` sync but `selfHeal: false`.
- **Opening it:** use the IDE URL printed by `--check`/`--apply` (`https://devspaces.<domain>/dashboard/#/ide/<namespace>/rocket-ramen`) or `status.mainUrl`. Argo CD creates the object, so `controller.devfile.io/creator` names the Argo service account rather than your user; if the dashboard's personal list filters on that label, open the URL directly. `npm run dev` is exposed at the workspace's `/vite/` endpoint.
