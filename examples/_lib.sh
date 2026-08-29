#!/usr/bin/env bash
# Shared helpers for the non-interactive Claude Code experiments.
# Source this from an example script; do not run it directly.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
OUT_DIR="${REPO_ROOT}/out"

require_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "error: 'claude' CLI not found on PATH." >&2
    echo "       install it from https://claude.com/claude-code" >&2
    exit 127
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: 'jq' not found on PATH (brew install jq)." >&2
    exit 127
  fi
}

# Every example writes its artifacts here; out/ is git-ignored.
prepare_out() {
  mkdir -p "${OUT_DIR}"
}

banner() {
  printf '\n\033[1m== %s ==\033[0m\n' "$*"
}

# `--output-format json` shape differs across CLI versions: current versions
# emit the whole message array with the terminal `result` event last, older
# ones emit that single object on its own. This filter normalizes both to the
# `result` event, so downstream jq can just read `.result`, `.session_id`, etc.
# shellcheck disable=SC2034  # consumed by scripts that source this file
JQ_RESULT='if type == "array" then (map(select(.type == "result")) | last) else . end'
