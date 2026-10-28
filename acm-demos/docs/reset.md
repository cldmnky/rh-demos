# Restore the demo baseline

Routine reset restores demo values, not infrastructure. `scripts/reset.sh` only prints a preview
and refuses execution flags. No cluster, namespace, Secret, operator or cloud teardown is automatic.

After the audience leaves, use the same initialized Bash session and the actual desired-state owner:

```bash
# Authorized CLI Helm owner only; otherwise revert through the existing Git owner.
scripts/setup-demo.sh governance-inform --apply
scripts/setup-demo.sh subscription --apply
scripts/setup-demo.sh push --apply
scripts/setup-demo.sh agent --apply
```

These inputs are the ignored v1/inform local files. Confirm real application rollout/HTTPS and
policy state. Switching a policy back to inform does **not** remove its existing target objects;
restore the agreed missing/incorrect starting fixture separately, after enforce has stopped.
Never delete an object while its controller still owns an enforced desired state.

Do not uninstall the prerequisite releases, delete their namespaces, remove Hive finalizers,
reinstall the ZTP site, eject media, or power-cycle the host VM during ordinary reset. Keep
annotations are only secondary safeguards. Infrastructure deletion can destroy AWS resources,
cluster data, or the installation backend; it requires a separate approved teardown plan.

Helm history may retain copied credentials. Uninstalling does not revoke credentials; logs and
rendered values/manifests must remain private. Existing unrelated/console-owned resources remain
outside the demo's Helm ownership throughout.
