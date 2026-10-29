"""Branch and CI policy: every workflow starts only by hand and nothing pushes or deploys main."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_the_policy_checker_passes_on_this_repository():
    out = subprocess.run([sys.executable, str(ROOT / "scripts/check_branch_policy.py")], capture_output=True, text=True)
    assert out.returncode == 0, out.stdout + out.stderr


def test_the_installer_ci_is_manual_only():
    text = (ROOT / ".github/workflows/installer-ci.yml").read_text("utf-8")
    head = text.split("\njobs:")[0]
    for banned in ("\n  push:", "\n  pull_request:", "\n  schedule:"):
        assert banned not in head
    assert "workflow_dispatch:" in head
