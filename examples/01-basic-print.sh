#!/usr/bin/env bash
#
# 01 — The minimal headless run.
#
# `-p/--print` runs one turn, prints the final assistant text to stdout and
# exits. That is the whole contract: prompt in, text out, exit code 0.
#
# Nothing here needs tools, so we disable them entirely with `--tools ""`.
# A run that cannot touch the filesystem or shell can never block on a
# permission prompt — the single most common reason headless runs hang.
#
# Usage: ./01-basic-print.sh [prompt]

# shellcheck source=examples/_lib.sh
source "$(dirname "$0")/_lib.sh"
require_claude

PROMPT=${1:-"Reply with exactly one word: pong"}

banner "claude -p (text output, no tools)"

claude -p "${PROMPT}" \
  --tools "" \
  --model sonnet
