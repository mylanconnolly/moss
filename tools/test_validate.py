"""Integration checks for validation failure propagation and retained evidence."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import validate


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        (self.root / "mise.toml").write_text('[tools]\nzig = "0.16.0"\n')
        self.program("git", '#!/bin/sh\n[ "$1" != rev-parse ] || echo fixture-revision\n')
        self.program("zig", '''#!/bin/sh
if [ "$1" = version ]; then echo 0.16.0; exit 0; fi
echo "executed $*"
case "$*" in *ReleaseSafe*) exit 0;; *) exit 7;; esac
''')

    def program(self, name, body):
        path = self.root / "bin" / name
        path.write_text(body)
        path.chmod(0o755)

    def invoke(self, mode="host"):
        with patch.object(validate, "ROOT", self.root), \
                patch("sys.argv", ["validate.py", mode]), \
                patch.dict(os.environ, {"PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"]}), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            code = validate.main()
        report_path, = self.root.glob("zig-out/validation/*/result.json")
        return code, report_path, json.loads(report_path.read_text())

    def test_failure_stays_red_and_later_phase_still_runs(self):
        code, report_path, report = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(report["runs"]["host-debug"]["exit_code"], 7)
        self.assertEqual(report["runs"]["host-release-safe"]["exit_code"], 0)
        self.assertEqual(report["revision"], "fixture-revision")
        for label in report["runs"]:
            self.assertIn("executed build test", (report_path.parent / label / "build.log").read_text())

    def test_toolchain_mismatch_is_recorded_before_any_test(self):
        self.program("zig", '#!/bin/sh\necho wrong-version\n')
        code, _, report = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(report["runs"], {})
        self.assertIn("Zig 0.16.0 required", report["error"])

    def test_full_requires_kvm_only_on_amd64_and_runs_both_after_failure(self):
        with patch.object(validate, "preflight", return_value=({"revision": "fixture"}, [])):
            code, _, report = self.invoke("full")
        self.assertEqual(code, 1)
        self.assertEqual(set(report["runs"]), {"amd64-kvm", "aarch64-tcg"})
        amd = report["runs"]["amd64-kvm"]["command"]
        arm = report["runs"]["aarch64-tcg"]["command"]
        self.assertIn("-Drequire-kvm", amd)
        self.assertNotIn("-Dtcg", amd)
        self.assertNotIn("-Drequire-kvm", arm)

    def test_smoke_forces_tcg_and_the_same_drills_on_both_ports(self):
        with patch.object(validate, "preflight", return_value=({}, [])):
            _, _, report = self.invoke("smoke")
        amd = report["runs"]["amd64-tcg"]["command"]
        arm = report["runs"]["aarch64-tcg"]["command"]
        self.assertIn("-Dtcg", amd)
        for command in (amd, arm):
            self.assertNotIn("-Drequire-kvm", command)
            self.assertIn(f"-Donly={validate.SMOKE}", command)

    def test_archive_excludes_stale_logs_and_disk_images(self):
        check = self.root / "zig-out/check"
        check.mkdir(parents=True)
        dest = self.root / "evidence"
        dest.mkdir()
        for name in ("stale-failed.log", "current.log", "current.ppm", "disk.img"):
            (check / name).write_text(name)
        os.utime(check / "stale-failed.log", ns=(0, 0))
        with patch.object(validate, "ROOT", self.root):
            validate.save_evidence(dest, 1)
        self.assertEqual({p.name for p in dest.iterdir()}, {"current.log", "current.ppm"})


if __name__ == "__main__":
    unittest.main()
