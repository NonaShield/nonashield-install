#!/usr/bin/env bash
# Builds and deploys come from the demo branch. A release build may also run from an exact release tag (a commit that carries a v* tag).
# Run from a build script after it has changed into the repository: bash scripts/require_demo_branch.sh || exit 1
# A GitHub Actions run is started by hand by an approver on demo or main, so the branch is their choice there.
[ "${GITHUB_ACTIONS:-}" = true ] && exit 0
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$branch" = demo ]; then exit 0; fi
if git describe --exact-match --tags --match 'v[0-9]*' HEAD >/dev/null 2>&1; then exit 0; fi
echo "STOP: builds come from the demo branch, and you are on '$branch'." >&2
echo "      git checkout demo && git pull --ff-only     (a release build runs from a commit that carries a v* tag)" >&2
exit 1
