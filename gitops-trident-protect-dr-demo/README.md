# GitOps & Pipeline-Driven Disaster Recovery with NetApp Trident Protect

This demo showcases a production-ready, fully-automated **Disaster Recovery (DR) and Application Mobility** solution for virtualized workloads on Red Hat OpenShift. 

It integrates **OpenShift Virtualization**, **NetApp Trident Protect**, **ArgoCD (using a unified Helm Chart)**, and **OpenShift Pipelines (Tekton)** to illustrate how enterprise organizations can safely backup, migrate, and fail over critical Virtual Machines between namespaces or clusters.

---

## 🏗️ Demo Architecture & Patterns

The demo demonstrates two distinct Disaster Recovery patterns:

### 1. Pattern A: GitOps-Driven SnapMirror Replication (Active-Passive)
*   **Concept**: Real-time block-level replication (SnapMirror) directly at the NetApp ONTAP storage layer.
*   **Flow**:
    1.  The Production VM runs in `vm-prod`.
    2.  An **AppMirrorRelationship (AMR)** is established in `vm-dr-mirror` with `desiredState: Established`. The target PVC remains `ReadOnly` and the target VM is halted.
    3.  **GitOps Failover**: The operator updates the git repository setting `desiredState: Promoted` in the target's values file.
    4.  ArgoCD synchronizes the change, Trident Protect promotes the target volume to `ReadWrite`, reconstructs all Kubernetes metadata (such as VM definitions), and boots up the standby VM automatically in `vm-dr-mirror` within seconds.

### 2. Pattern B: Pipeline-Driven Cloud Backup & Restore (On-Demand / Portable)
*   **Concept**: S3-backed application-consistent cloud backups and on-demand restore orchestration.
*   **Flow**:
    1.  A Tekton pipeline is triggered in `vm-prod`.
    2.  **ExecHook (Application Consistency)**: The pipeline executes a pre-backup script inside the Guest OS to cleanly freeze filesystems or databases.
    3.  **Cloud Backup**: Trident Protect takes a snapshot and copies both volume blocks and Kubernetes metadata to an S3 bucket (represented by the `lab-vault` AppVault).
    4.  **ExecHook (Thaw)**: Filesystem is unfrozen, minimizing Guest OS impact.
    5.  **Target Restore**: The pipeline triggers a `BackupRestore` in `vm-dr-backup`, translating namespaces from `vm-prod` to `vm-dr-backup`.
    6.  Trident Protect provisions the PVC, recovers the blocks from S3, recreates the VM, and transitions it to a `Running` state.

---

## 📦 Directory Structure

```
gitops-trident-protect-dr-demo/
├── README.md                      # This comprehensive guide & narrative
├── chart/                         # Unified Helm Chart for both Prod and DR environments
│   ├── Chart.yaml
│   ├── values.yaml               # Baseline default settings
│   ├── values-prod.yaml          # Value overrides for Active Production (vm-prod)
│   ├── values-dr-mirror.yaml     # Value overrides for SnapMirror standby (vm-dr-mirror)
│   └── templates/
│       ├── vm.yaml               # KubeVirt VirtualMachine template
│       ├── service.yaml          # SSH cluster service
│       ├── trident-app.yaml      # Trident Protect Application CR
│       └── trident-amr.yaml      # AppMirrorRelationship CR (conditional)
├── argocd/                        # ArgoCD Application declarations
│   ├── argocd-prod-app.yaml       # deploys Production environment
│   └── argocd-dr-mirror-app.yaml  # deploys DR SnapMirror environment
├── pipelines/                     # Tekton Pipeline & Task manifests
│   ├── dr-pipeline.yaml           # End-to-End Backup & Restore pipeline
│   └── tasks/
│       ├── trident-protect-backup.yaml   # Creates & monitors an S3 backup
│       └── trident-protect-restore.yaml  # Restores VM into target namespace
├── scripts/
│   └── cleanup.sh                 # Exhaustive cleanup (proactively strips stuck finalizers)
└── demo/
    └── test-flow.sh               # E2E automated validation script
```

---

## 🎬 Presenter Script & Narrative

### Scene 1: Setting the Stage (The Production Environment)
1.  **Deploy Production**: Spin up the production CentOS VirtualMachine (`centos-vm`) in the `vm-prod` namespace using ArgoCD:
    ```bash
    oc apply -f argocd/argocd-prod-app.yaml
    ```
2.  **Add Sample Data**: Access the VM console or spin up a shell, creating a high-value data file:
    ```bash
    echo "Disaster Recovery Verified!" > /root/myfile.txt
    ```
3.  **Explain the Trident Protect Application**: Point out to the audience that Trident Protect is *declarative*. We have defined an `Application` resource (`centos-vm-app`) that tracks the entire namespace `vm-prod` as a single logical unit.

### Scene 2: Pattern B - Automated Pipeline DR Failover
1.  **Introduce the Pipeline**: Explain that you want to back up the VM to an offsite S3-compatible cloud storage target (AWS S3) and restore it in `vm-dr-backup` completely automatically.
2.  **Trigger the Tekton Pipeline**:
    ```bash
    tkn pipeline start trident-dr-pipeline \
      -p application-name=centos-vm-app \
      -p destination-namespace=vm-dr-backup \
      --showlog
    ```
3.  **Live Log Commentary**:
    *   Explain the **ExecHooks**: Under the hood, Trident Protect frozen the guest filesystem, copied the data and metadata to AWS S3, and thawed the VM safely.
    *   Explain the **Restore**: Tekton automatically submitted a `BackupRestore` CR in the target namespace, mapping `vm-prod` to `vm-dr-backup`.
4.  **Show the Recovered VM**: Navigate to the `vm-dr-backup` namespace. Show that the VM has been successfully restored and is running, and that the data in `/root/myfile.txt` is 100% intact!

### Scene 3: Pattern A - GitOps-Driven SnapMirror DR Failover
1.  **Establish the Mirror**: Deploy the standby mirror environment via ArgoCD:
    ```bash
    oc apply -f argocd/argocd-dr-mirror-app.yaml
    ```
2.  **Show Standby State**: Show the audience that in `vm-dr-mirror`, the PVC is `ReadOnly` and the VM is powered down. Storage-level replication is happening in the background every 5 minutes.
3.  **Execute the GitOps Failover**: Edit `chart/values-dr-mirror.yaml` in Git (or patch the ArgoCD Application helm parameters) to set `trident.amr.desiredState` to `"Promoted"`.
4.  **Observe Promotion**: Show ArgoCD synchronizing the change. Trident Protect instantly promotes the storage, recreates the VM, and spins it up. The warm-standby is now fully promoted to active!

---

## 🛠️ E2E Automated Verification

To verify that both patterns are working flawlessly on your cluster, run the headless E2E validation script:

```bash
./demo/test-flow.sh
```

This script will:
1.  Execute `scripts/cleanup.sh` to purge any stale state.
2.  Grant the necessary permissions to ArgoCD and Tekton.
3.  Provision the active CentOS VM in `vm-prod` using ArgoCD.
4.  Run the on-demand Backup & Restore Tekton Pipeline (Pattern B).
5.  Establish, synchronize, and promote the SnapMirror relationship (Pattern A).
6.  Ensure all restored VMs are healthy and running.

---

## 🧹 Cleanup
To clean up all deployed applications, namespaces, and cluster rolebindings, run:

```bash
./scripts/cleanup.sh
```
*(The cleanup script is hardened to proactively remove any finalizers from CSI VolumeSnapshots and VolumeSnapshotContents to avoid namespace termination hangs).*
