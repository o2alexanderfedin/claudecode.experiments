#!/usr/bin/env bash
#
# 02 — Machine-readable single result.
#
# `--output-format json` replaces the plain text with one JSON object
# describing the whole run: the final text, the session id, timing, token
# usage and cost. This is the format to reach for when a script needs to
# branch on the outcome rather than just echo it.
#
# The session id it returns is the handle for `claude --resume <id>`, which
# is how a multi-step pipeline keeps context across separate invocations.
#
# Usage: ./02-json-result.sh [prompt]

# shellcheck source=examples/_lib.sh
source "$(dirname "$0")/_lib.sh"
require_claude
require_jq
prepare_out

PROMPT=${1:-"Name the three primary additive colors, comma-separated, nothing else."}
RESULT_FILE="${OUT_DIR}/02-result.json"

banner "claude -p --output-format json"

claude -p "${PROMPT}" \
  --tools "" \
  --model sonnet \
  --output-format json >"${RESULT_FILE}"

echo "raw result: ${RESULT_FILE}"
echo

jq -r "${JQ_RESULT}"' |
  "text        : \(.result)",
  "session_id  : \(.session_id)",
  "duration_ms : \(.duration_ms)",
  "cost_usd    : \(.total_cost_usd)",
  "is_error    : \(.is_error)"
' "${RESULT_FILE}"
