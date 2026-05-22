# Agent Instructions — Red Hat Demos Mono-Repository

These instructions help OpenCode agents navigate this mono-repository, avoid execution hangs, and safely build or test interactive and GitOps-driven demos.

## Repository Architecture

This is a mono-repository designed to host multiple distinct Red Hat demo modules (e.g., `gitops-vmware-virt-demo/` and others).
- **Core Scripts:** Shared utility scripts (like `demo-magic.sh`) live under the root `/scripts` folder.
- **Demo Subdirectories:** Every distinct demo should be self-contained within its own top-level subdirectory and contain a comprehensive `README.md`.

---

## Developer & Verification Commands

- **Interactive Presentation Scripts (Hangs/Blocking):** Live presenter scripts (e.g., `demo.sh` or `demo-rosa.sh` utilizing `demo-magic.sh`) will hang indefinitely waiting for keyboard input during automated verification.
  - **Do NOT** execute these interactively.
  - **For headless testing of demo-magic scripts:** Append `-n` (No Wait) or a max timeout (e.g., `-w 1`) if the script supports it.
  - **For functional verification:** Prefer executing the non-interactive test mirrors (e.g., `test-flow.sh` or `test-flow-rosa.sh`) inside each demo's subdirectory.

- **Available Demo Suites:**
  - **GitOps VMware Virt Demo:**
    - Test VMware: `gitops-vmware-virt-demo/scripts/cleanup.sh && gitops-vmware-virt-demo/demo/test-flow.sh`
    - Test ROSA: `gitops-vmware-virt-demo/scripts/cleanup.sh && gitops-vmware-virt-demo/demo/test-flow-rosa.sh`
    - Cleanup only: `gitops-vmware-virt-demo/scripts/cleanup.sh`

---

## Crucial Side Effects & Conventions

- **Automated Git Commits / GitOps Pushes:** Some validation and demo scripts modify version manifest files (e.g., `app-version.yaml`), run git commits, and directly execute `git push origin main` to trigger webhooks/reconciliations.
  - Prior to running scripts with git side effects, verify you are on a tracking branch, have write permissions to the remote, and have a clean working tree.
  - To prevent GPG prompt hangs during automated pipeline commits, scripts should pass `--no-gpg-sign` to `git commit`.

- **State vs. Git Desired Baseline:**
  - Git changes should only represent immutable application version upgrades or initial boot baselines.
  - Transient runtime changes (e.g., starting/stopping VMs, scaling, routing traffic) should be controlled dynamically via parameter overrides (e.g. patching ArgoCD `spec.source.helm.parameters` with `oc patch`) rather than writing commits back to Git.

---

## Dependencies & Prerequisites

- **CLI Toolchain:**
  - `oc` (OpenShift CLI) authenticated to the correct target cluster.
  - `ruby` is the preferred tool across validation scripts for lightweight, inline YAML processing.
  - `gum` is required for rich text/slide generation in interactive demo scripts.
- **SSH Keys & Access:**
  - Demos using SSH usually expect `~/.ssh/rh-demos` and `~/.ssh/rh-demos.pub` to exist. 
  - The public key must be configured as a GitHub deploy key with write access to this repo for git pushback compatibility.
