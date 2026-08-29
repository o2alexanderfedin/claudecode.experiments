#!/usr/bin/env bash
#
# 06 — A headless run with hard guard rails.
#
# An unattended agent needs bounds, not trust. Four of them, all enforced by
# the CLI rather than by the prompt:
#
#   --max-budget-usd    stop when the run has spent this much
#   --tools             the only tools that exist for this session
#   --allowed-tools     the only invocations that auto-approve
#   --permission-mode   dontAsk: never block waiting for a human
#
# `--no-session-persistence` keeps the transcript off disk, which matters
# when the input is sensitive or the runner is ephemeral.
#
# Usage: ./06-budgeted-agent.sh [prompt]

# shellcheck source=examples/_lib.sh
source "$(dirname "$0")/_lib.sh"
require_claude
require_jq
prepare_out

PROMPT=${1:-"Count the shell scripts under examples/ and report just the number."}
RESULT_FILE="${OUT_DIR}/06-result.json"

banner "budgeted, tool-restricted, non-blocking run"

claude -p "${PROMPT}" \
  --model sonnet \
  --max-budget-usd 0.50 \
  --tools "Bash,Glob,Read" \
  --allowed-tools "Bash(ls:*)" "Bash(find:*)" "Glob" "Read" \
  --permission-mode dontAsk \
  --no-session-persistence \
  --output-format json >"${RESULT_FILE}"

jq -r "${JQ_RESULT}"' |
  "answer   : \(.result)",
  "cost_usd : \(.total_cost_usd)",
  "turns    : \(.num_turns)",
  "is_error : \(.is_error)"
' "${RESULT_FILE}"
