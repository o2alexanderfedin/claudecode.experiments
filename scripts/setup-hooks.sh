#!/usr/bin/env bash
# Install the repository's tracked git hooks into .git/hooks.
#
# .git/hooks is not versioned, so a fresh clone starts without protection.
# Run this once after cloning:
#
#   ./scripts/setup-hooks.sh
#
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
src_dir="${repo_root}/.githooks"
dst_dir="$(git rev-parse --git-path hooks)"

mkdir -p "${dst_dir}"

for hook in "${src_dir}"/*; do
  [ -f "${hook}" ] || continue
  name=$(basename "${hook}")
  install -m 0755 "${hook}" "${dst_dir}/${name}"
  echo "installed: ${dst_dir}/${name}"
done

echo "Git hooks installed. Direct commits to main/develop are now blocked."
