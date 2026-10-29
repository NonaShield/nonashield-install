#!/usr/bin/env bash
# Static analysis of the installers from Git Bash. Free tools only; each one is skipped with a message when it is not installed.
#
#   bash scripts/sast_local.sh
#
# Gates (exit 1): shellcheck error-level findings in the installer shell scripts; gitleaks finds a secret.
# Tools: shellcheck https://www.shellcheck.net, gitleaks https://github.com/gitleaks/gitleaks. Neither needs an account.
# The PowerShell installers and the compose files are not covered here (compose is validated by the backend build).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAILED=0
step() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

step "shellcheck (error level is a gate)"
if have shellcheck; then
  shellcheck -S error ./*.sh || { echo "FAILED: shellcheck"; FAILED=1; }
else echo "skipped: shellcheck is not installed"; fi

step "gitleaks"
if have gitleaks; then
  gitleaks detect --source . --redact || { echo "FAILED: gitleaks found a secret"; FAILED=1; }
else echo "skipped: gitleaks is not installed"; fi

echo
step "branch policy (every workflow manual-only, nothing deploys or pushes main)"
"${PY:-python}" scripts/check_branch_policy.py || FAILED=1
if [ "$FAILED" = 0 ]; then echo "SAST OK (tools that were not installed were skipped)"; else echo "SAST FAILED"; exit 1; fi
