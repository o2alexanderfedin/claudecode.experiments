#!/usr/bin/env bash
# Lint every shell script in the repository.
#
#   ./scripts/lint.sh
#
# Runs `bash -n` (syntax) followed by shellcheck (semantics) and exits
# non-zero on the first failure, so it drops straight into CI.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Tracked and untracked-but-not-ignored files, so the lint works on a
# work-in-progress tree as well as on a clean checkout.
scripts=()
while IFS= read -r script; do
  [ -n "${script}" ] && scripts+=("${script}")
done < <(git ls-files --cached --others --exclude-standard -- '*.sh' '.githooks/*' | sort -u)

if [ ${#scripts[@]} -eq 0 ]; then
  echo "no shell scripts found"
  exit 0
fi

echo "== bash -n =="
for script in "${scripts[@]}"; do
  bash -n "${script}"
  echo "  ok  ${script}"
done

echo
echo "== shellcheck =="
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "  shellcheck not installed (brew install shellcheck) — skipped" >&2
  exit 0
fi
shellcheck -x "${scripts[@]}"
echo "  ok  ${#scripts[@]} script(s) clean"
