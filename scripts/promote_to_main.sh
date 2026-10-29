#!/usr/bin/env bash
# The only way main moves: fast-forward it to the demo branch that is already on GitHub. No commit is made here, and nothing is
# ever committed on main directly. Run it after the demo test round passed on that exact commit.
#
#   bash scripts/promote_to_main.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

git fetch -q origin
demo="$(git rev-parse origin/demo)"
if [ "$(git rev-parse demo 2>/dev/null || echo none)" != "$demo" ]; then
  echo "STOP: local demo and origin/demo are different commits. Push or pull demo first." >&2; exit 1
fi
if git rev-parse -q --verify origin/main >/dev/null; then
  if ! git merge-base --is-ancestor origin/main "$demo"; then
    echo "STOP: origin/main has commits that demo does not. On demo run: git merge origin/main, test, push, then promote." >&2; exit 1
  fi
  if [ "$(git rev-parse origin/main)" = "$demo" ]; then
    echo "main already equals demo ($(git rev-parse --short "$demo"))"; exit 0
  fi
  echo "main will move: $(git rev-parse --short origin/main) -> $(git rev-parse --short "$demo")"
  git log --oneline origin/main..origin/demo | head -40
else
  echo "main does not exist on GitHub yet; it will be created at $(git rev-parse --short "$demo")"
fi
read -r -p "Type PROMOTE to move main: " answer
answer="${answer//$'\r'/}"
[ "$answer" = PROMOTE ] || { echo "cancelled"; exit 1; }

git push origin "$demo:refs/heads/main"
git fetch -q origin
if [ "$(git branch --show-current)" = main ]; then git merge --ff-only origin/main; else git branch -f main origin/main; fi
echo "main is now $(git rev-parse --short origin/main) (same commit as demo)"
