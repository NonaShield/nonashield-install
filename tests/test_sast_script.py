"""The static-analysis script of this repo exists, parses, and never pushes, deploys or signs in."""

import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/sast_local.sh"


def test_the_script_parses():
    if shutil.which("bash") is None:
        pytest.skip("bash not available")
    assert subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True).returncode == 0


def test_the_script_never_pushes_deploys_or_signs_in():
    code = "\n".join(ln for ln in SCRIPT.read_text("utf-8").splitlines() if not ln.strip().startswith("#"))
    for banned in ("git push", "docker push", "docker login", "ssh ", "scp ", "aws ", "curl "):
        assert banned not in code, banned


def test_every_tool_is_skipped_with_a_message_when_missing_and_there_is_a_pass_line():
    text = SCRIPT.read_text("utf-8")
    assert "skipped:" in text and "SAST OK" in text and "SAST FAILED" in text
