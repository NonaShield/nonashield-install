#!/usr/bin/env bash
# Turn on the repository's git hooks (once per clone): no commit on main, and main can only be pushed to a commit that is on origin/demo.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/* scripts/*.sh 2>/dev/null || true
echo "git hooks on: commits on main are refused; main moves only with: bash scripts/promote_to_main.sh"
