#!/usr/bin/env python3
"""Branch and CI policy check (same file in every NonaShield repository). Exit 1 on any violation.

  1. Every workflow starts only by hand: the `on:` block holds `workflow_dispatch` and nothing else.
  2. Nothing resets, checks out or pushes `main` (builds, deploys and bots use `demo`; main moves only with scripts/promote_to_main.sh).
  3. The branch tools exist: the git hooks, the promote script, the demo-branch guard.

    python scripts/check_branch_policy.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "build", ".gradle", ".claude", "__pycache__", "worktrees", "dist", "tests", "docs"}
OWN = {
    "check_branch_policy.py", "promote_to_main.sh", "install_git_hooks.sh", "require_demo_branch.sh",
    "pre-commit", "pre-push", "pre-merge-commit",
}
FORBIDDEN = [
    (re.compile(r"origin/main\b"), "refers to origin/main"),
    (re.compile(r"git\s+push\s+origin\s+main\b"), "pushes main"),
    (re.compile(r"checkout\s+(-B\s+)?main\b"), "checks out main"),
    (re.compile(r"^\s*ref:\s*main\s*$", re.M), "checks out ref main"),
    (re.compile(r"branches:\s*\[[^\]]*\bmain\b"), "triggers on main"),
]
REQUIRED = [
    "scripts/check_branch_policy.py", "scripts/promote_to_main.sh", "scripts/install_git_hooks.sh",
    "scripts/require_demo_branch.sh", "scripts/git-hooks/pre-commit", "scripts/git-hooks/pre-push", "scripts/git-hooks/pre-merge-commit",
]


def workflow_triggers(text: str) -> list[str]:
    lines = text.lstrip("﻿").splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^on:\s*$", line):
            keys = []
            for nxt in lines[i + 1:]:
                if nxt.strip() == "" or nxt.lstrip().startswith("#"):
                    continue
                if not nxt.startswith(" "):
                    break
                m = re.match(r"^  ([A-Za-z_][\w-]*):", nxt)
                if m:
                    keys.append(m.group(1))
            return keys
        if re.match(r"^on:\s*\S", line):
            return [line]  # inline form such as `on: [push]`: always a violation
    return ["(no on: block)"]


def candidate_files():
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.name in OWN:
            continue
        parts = set(path.relative_to(ROOT).parts[:-1])
        if parts & SKIP_DIRS:
            continue
        if path.suffix in {".sh", ".ps1", ".yml", ".yaml", ".py", ".mk"} or path.name in {"Makefile"}:
            yield path


def main() -> int:
    problems = []
    for rel in REQUIRED:
        if not (ROOT / rel).is_file():
            problems.append(f"missing {rel}")
    workflows = list((ROOT / ".github" / "workflows").glob("*.y*ml")) if (ROOT / ".github" / "workflows").is_dir() else []
    templates = list((ROOT / "ci-templates").glob("*.y*ml")) if (ROOT / "ci-templates").is_dir() else []
    for wf in workflows + templates:
        triggers = workflow_triggers(wf.read_text(encoding="utf-8", errors="replace"))
        if triggers != ["workflow_dispatch"]:
            problems.append(f"{wf.relative_to(ROOT)}: triggers are {triggers}, only workflow_dispatch is allowed")
    for path in candidate_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern, why in FORBIDDEN:
            if pattern.search(text):
                problems.append(f"{path.relative_to(ROOT)}: {why}")
    if problems:
        print("BRANCH POLICY FAILED:")
        for p in problems:
            print("  -", p)
        return 1
    print(f"branch policy OK ({len(workflows) + len(templates)} workflow file(s), all manual-only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
