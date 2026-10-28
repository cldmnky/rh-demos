# ACM demo guide

The repository has one reusable workflow; cluster addresses, credentials, kubeconfig paths,
and environment-specific Helm values live only in ignored local files.

1. **[Setup](setup.md)** — prepare the shell, check/create missing prerequisites, then prepare
   the application/governance scenarios.
2. **[Presenter runbook](presenter-runbook.md)** — checklist, variables, 60-minute running order,
   console/terminal choreography, and the detailed segment runbooks.
3. **[Reset](reset.md)** — restore demo baselines without deleting infrastructure.

## Entry points

From `acm-demos/`, in Bash:

```bash
source scripts/demo-shell.sh --prereqs
scripts/prereqs.sh --check
# Only after reviewing the local inputs and approving infrastructure creation:
scripts/prereqs.sh --apply
```

`--check` performs read-only discovery. `--apply` creates missing resources and can incur cloud
costs; it requires local approval flags and an interactive confirmation. Nothing runs simply
because you source the environment script. After provisioning, source the same script without
`--prereqs` to fill in managed-cluster connections and presentation resource names.

All setup uses ignored `values/*.local.yaml`, not example placeholders. The shell initializer
loads a trusted ignored `config/demo.env` when present, asks for missing inputs, and exports
only its allowlisted connection paths/names. It never writes files or changes global context.
Investigation logs and snapshots are deliberately not part of the reusable demo guide.

Offline checks for this scripts/docs workflow (fixture `oc`, no cluster access):

```bash
ruby scripts/check-local.rb
```

Live prerequisite provisioning and operator/BMC interoperability still require an approved
preparation run; offline checks are not a claim that a new environment has been installed.
