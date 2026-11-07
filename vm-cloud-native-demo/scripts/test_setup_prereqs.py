#!/usr/bin/env python3
"""Offline regression checks for source sizing and private-state isolation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent


class SetupPrerequisites(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        oc = self.root / "oc"
        oc.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
assert 'get' in args, args  # These helpers must never mutate cluster resources.
resource = args[args.index('get') + 1]
if resource == 'namespace':
    print(os.environ['TEST_CLUSTER_UID'], end='')
else:
    print(json.dumps(json.loads(os.environ['TEST_RESOURCES'])[resource]))
""")
        oc.chmod(0o755)
        self.env = dict(os.environ)
        self.env.pop("PRIVATE_DIR", None)
        self.env.update(PATH=f"{self.root}:{os.environ['PATH']}",
                        XDG_STATE_HOME=str(self.root / "state"),
                        NAMESPACE="rocket-ramen", TEST_CLUSTER_UID="cluster-one")

    def size(self, kind="snapshot", source=None, ready=True):
        datasource = {"metadata": {"namespace": "images"}, "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "source": {kind: {"name": "rhel10-source", "namespace": "images"}}}}
        if source is None:
            source = {"status": {"readyToUse": True, "restoreSize": "30Gi"}}
        resources = {"datasource": datasource,
                     "volumesnapshot" if kind == "snapshot" else "pvc": source}
        self.env["TEST_RESOURCES"] = json.dumps(resources)
        return subprocess.run(["bash", str(SCRIPTS / "source-root-size.sh"), "images", "rhel10"],
                              env=self.env, text=True, capture_output=True)

    def private_dir(self):
        return subprocess.run(["bash", "-ec", 'source "$1"; printf "%s" "$PRIVATE_DIR"',
                               "test", str(SCRIPTS / "private-dir.sh")],
                              env=self.env, text=True, capture_output=True, check=True).stdout

    def test_snapshot_source_without_original_pvc(self):
        result = self.size()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "30Gi")

    def test_pvc_source(self):
        result = self.size("pvc", {"spec": {"resources": {"requests": {"storage": "20Gi"}}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "20Gi")

    def test_snapshot_without_size_is_rejected(self):
        result = self.size(source={"status": {"readyToUse": True}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot determine", result.stderr)

    def test_snapshot_not_ready_is_rejected(self):
        result = self.size(source={"status": {"readyToUse": False, "restoreSize": "30Gi"}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ready to use", result.stderr)

    def test_datasource_not_ready_is_rejected(self):
        result = self.size(ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DataSource is not ready", result.stderr)

    def test_deleting_source_is_rejected(self):
        result = self.size(source={"metadata": {"deletionTimestamp": "2026-11-07T10:00:00Z"},
                                   "status": {"readyToUse": True, "restoreSize": "30Gi"}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("being deleted", result.stderr)

    def test_cluster_and_namespace_have_separate_repeatable_state(self):
        first = self.private_dir()
        self.assertEqual(first, str(self.root / "state/rocket-ramen-demo/cluster-one/rocket-ramen"))
        self.assertEqual(first, self.private_dir())
        self.env["TEST_CLUSTER_UID"] = "cluster-two"
        second = self.private_dir()
        self.assertNotEqual(first, second)
        self.env["NAMESPACE"] = "other-demo"
        self.assertNotEqual(second, self.private_dir())
        self.assertFalse((self.root / "state").exists())

    def test_explicit_legacy_state_is_retained(self):
        self.env["PRIVATE_DIR"] = str(self.root / "legacy")
        self.env.pop("TEST_CLUSTER_UID")  # Must not query cluster identity for an override.
        self.assertEqual(self.private_dir(), self.env["PRIVATE_DIR"])


if __name__ == "__main__":
    unittest.main()
