#!/usr/bin/env python3
"""
Regenerate the eight install/docker-compose.{tier}.{platform}.yml files from
their origin in payshield-backend, so the copies can never hand-diverge.

Each copy = its own leading comment header (platform notes, kept as-is)
          + the origin's service definitions, with two transforms:
  1. Paths relative to payshield-backend/ ("./config/...", "context: .")
     are rewritten to "../payshield-backend/...", because the copies are run
     from install/. Paths already relative to a sibling ("../nginx/...") are
     left alone.
  2. EDGE_INTERNAL_SECRET is mandatory in customer installs (every installer
     generates it, and nginx and the backend must share it); the origin keeps
     it optional only so the demo stack starts without it. CSRF_SECRET stays
     as the origin has it: install-windows.ps1 leaves it empty for its
     APP_ENV=development default, and that installer is never modified.

Usage (from the workspace root or anywhere):
  python install/tools/sync_compose.py          # rewrite the copies
  python install/tools/sync_compose.py --check  # exit 1 if any copy is stale
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

INSTALL_DIR = Path(__file__).resolve().parents[1]
BACKEND_DIR = INSTALL_DIR.parent / "payshield-backend"

ORIGINS = {
    "full": BACKEND_DIR / "docker-compose.yml",
    "minimal": BACKEND_DIR / "docker-compose.minimal.yml",
}
PLATFORMS = ("aws-ubuntu", "linux", "ubuntu", "windows")

_RELATIVE_PATH = re.compile(r"(?<![\w./])\./")
_CONTEXT_DOT = re.compile(r"^(\s*context:\s*)\.(\s*(?:#.*)?)$")
_OPTIONAL_SECRET = re.compile(
    r'^(\s*)(EDGE_INTERNAL_SECRET):(\s*)"\$\{\2:-\}"\s*$'
)


def _split_header(text: str) -> tuple[list[str], list[str]]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return lines[:index], lines[index:]
    return lines, []


def _transform(line: str) -> str:
    secret = _OPTIONAL_SECRET.match(line)
    if secret:
        indent, name, gap = secret.groups()
        return f'{indent}{name}:{gap}"${{{name}:?{name} must be set (openssl rand -hex 32)}}"'
    context = _CONTEXT_DOT.match(line)
    if context:
        return f"{context.group(1)}../payshield-backend{context.group(2)}"
    if line.lstrip().startswith("#"):
        return line
    return _RELATIVE_PATH.sub("../payshield-backend/", line)


def render(tier: str, copy_path: Path) -> str:
    _, origin_body = _split_header(ORIGINS[tier].read_text(encoding="utf-8"))
    copy_header, _ = _split_header(copy_path.read_text(encoding="utf-8"))
    body = [_transform(line) for line in origin_body]
    return "\n".join(copy_header + body) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("--check", action="store_true", help="report stale copies, write nothing")
    args = parser.parse_args()

    stale = []
    for tier in ORIGINS:
        for platform in PLATFORMS:
            copy_path = INSTALL_DIR / f"docker-compose.{tier}.{platform}.yml"
            rendered = render(tier, copy_path)
            current = copy_path.read_text(encoding="utf-8").replace("\r\n", "\n")
            if rendered == current:
                continue
            stale.append(copy_path.name)
            if not args.check:
                copy_path.write_text(rendered, encoding="utf-8", newline="\n")

    if args.check and stale:
        print("Out of sync with payshield-backend: " + ", ".join(stale))
        print("Run: python install/tools/sync_compose.py")
        return 1
    print(("Rewrote: " + ", ".join(stale)) if stale else "All 8 compose copies are in sync.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
