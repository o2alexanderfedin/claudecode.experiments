#!/usr/bin/env bash
#
# 03 — Streaming the run as it happens.
#
# `--output-format stream-json` emits newline-delimited JSON (JSONL): one
# object per event — system init, each assistant message, each tool_use and
# tool_result, then a final `result` event. Consume it line by line to build
# a live progress view or to log what the agent actually did.
#
# `--include-partial-messages` adds token-level deltas on top, for rendering
# text as it is generated.
#
# This example lets the agent use a read-only slice of the toolset so the
# stream contains real tool events worth looking at.
#
# Usage: ./03-stream-json.sh [prompt]

# shellcheck source=examples/_lib.sh
source "$(dirname "$0")/_lib.sh"
require_claude
require_jq
prepare_out

PROMPT=${1:-"List the top-level files in this repository, then say DONE."}
STREAM_FILE="${OUT_DIR}/03-stream.jsonl"

banner "claude -p --output-format stream-json"

claude -p "${PROMPT}" \
  --model sonnet \
  --tools "Bash,Read,Glob" \
  --allowed-tools "Bash(ls:*)" "Read" "Glob" \
  --permission-mode dontAsk \
  --output-format stream-json \
  --verbose >"${STREAM_FILE}"

echo "raw stream: ${STREAM_FILE}"
echo

banner "event timeline"
jq -r '
  if .type == "system"    then "system      : \(.subtype)"
  elif .type == "assistant" then
    "assistant   : " + ([.message.content[] |
      if .type == "text" then "text"
      elif .type == "tool_use" then "tool_use(\(.name))"
      else .type end] | join(", "))
  elif .type == "user"    then "tool_result : (returned to model)"
  elif .type == "result"  then "result      : \(.subtype) in \(.duration_ms)ms"
  else .type end
' "${STREAM_FILE}"
