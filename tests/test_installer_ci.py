"""E-5: the installer CI covers both tiers on both Ubuntu releases, and the install repo's own rules hold. The workflow itself can only
run in CI on clean VMs; these checks keep it from rotting and enforce the rules that can be checked anywhere."""

import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WF = yaml.safe_load((ROOT / ".github/workflows/installer-ci.yml").read_text(encoding="utf-8"))
RAW = (ROOT / ".github/workflows/installer-ci.yml").read_text(encoding="utf-8")


class InstallerCi(unittest.TestCase):
    def test_minimal_runs_on_every_push_and_full_only_by_hand_on_both_supported_ubuntu_releases(self):
        m = WF["jobs"]["installer"]["strategy"]["matrix"]
        self.assertEqual(sorted(m["os"]), ["ubuntu-22.04", "ubuntu-24.04"])
        expr = m["tier"]
        self.assertIn('["minimal"]', expr)
        self.assertIn('["minimal","full"]', expr)
        self.assertIn("workflow_dispatch", expr)
        self.assertIn("run_full", WF[True]["workflow_dispatch"]["inputs"])

    def test_only_free_hosted_runners_are_used(self):
        self.assertNotIn("FULL_RUNNER", RAW)
        for job in WF["jobs"].values():
            self.assertRegex(job["runs-on"], r"^(ubuntu-\d+\.\d+|\$\{\{ matrix\.os \}\})$")

    def test_the_installer_job_waits_for_the_guard_and_does_not_stop_at_the_first_failing_cell(self):
        j = WF["jobs"]["installer"]
        self.assertEqual(j["needs"], "guard")
        self.assertFalse(j["strategy"]["fail-fast"])

    def test_it_installs_with_the_documented_options_and_skips_the_4gb_model(self):
        env = WF["jobs"]["installer"]["env"]
        self.assertEqual(env["SKIP_OLLAMA"], "1")
        self.assertIn("matrix.tier", env["PAYSHIELD_TIER"])
        self.assertIn("install-ubuntu.sh install", RAW)

    def test_it_checks_health_idempotence_restart_and_uninstall(self):
        names = [s.get("name", "") for s in WF["jobs"]["installer"]["steps"]]
        for needle in ("Install", "Backend is healthy", "never overwrites the secrets", "Stop and start", "Uninstall"):
            self.assertTrue(any(needle in n for n in names), needle)
        self.assertIn("sha256sum", RAW)

    def test_uninstall_runs_even_when_an_earlier_step_fails(self):
        last = WF["jobs"]["installer"]["steps"][-1]
        self.assertEqual(last["if"], "always()")

    def test_the_three_repos_are_laid_out_side_by_side_as_the_installer_expects(self):
        paths = [s["with"]["path"] for s in WF["jobs"]["installer"]["steps"] if "with" in s and "path" in s["with"]]
        self.assertEqual(sorted(paths), ["stack/install", "stack/nginx", "stack/nonashield-backend"])

    def test_the_proven_windows_installer_is_guarded_against_modification(self):
        self.assertIn("git diff --exit-code", RAW)
        self.assertIn("install-windows.ps1", RAW)

    def test_the_workflow_does_not_embed_a_secret(self):
        self.assertEqual(re.findall(r"ghp_[A-Za-z0-9]+|AKIA[0-9A-Z]{12,}", RAW), [])
        self.assertIn("secrets.REPO_PAT", RAW)


class RepoRules(unittest.TestCase):
    def test_the_compose_copies_match_their_origin(self):
        r = subprocess.run([sys.executable, str(ROOT / "tools/sync_compose.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_both_installers_exist_for_both_tiers(self):
        for f in ("install-ubuntu.sh", "install-windows.ps1", "install-windows-minimal.ps1",
                  "docker-compose.minimal.ubuntu.yml", "docker-compose.full.ubuntu.yml"):
            self.assertTrue((ROOT / f).is_file(), f)

    def test_the_ubuntu_installer_parses(self):
        import shutil

        bash = shutil.which("bash")
        if not bash:
            self.skipTest("needs bash")
        r = subprocess.run([bash, "-n", (ROOT / "install-ubuntu.sh").as_posix()], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
