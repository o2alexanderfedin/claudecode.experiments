#!/usr/bin/env bash
#
# 04 — Contract-checked output via JSON Schema.
#
# `--json-schema` constrains the final answer to a shape you declare, and
# validates it before the run is allowed to succeed. This turns Claude Code
# into a typed function call: prompt in, schema-conforming JSON out, no
# prose to parse and no "sometimes it adds a preamble" failure mode.
#
# Combined with `--output-format json`, the validated payload lands in
# `.result` as a JSON string.
#
# Usage: ./04-structured-output.sh [text-to-classify]

# shellcheck source=examples/_lib.sh
source "$(dirname "$0")/_lib.sh"
require_claude
require_jq
prepare_out

INPUT=${1:-"The deploy finished but latency doubled and two pods are crash-looping."}
SCHEMA_FILE="${OUT_DIR}/04-schema.json"
RESULT_FILE="${OUT_DIR}/04-result.json"

cat >"${SCHEMA_FILE}" <<'JSON'
{
  "type": "object",
  "properties": {
    "severity":  { "type": "string", "enum": ["info", "warning", "critical"] },
    "component": { "type": "string" },
    "summary":   { "type": "string" },
    "action_required": { "type": "boolean" }
  },
  "required": ["severity", "component", "summary", "action_required"],
  "additionalProperties": false
}
JSON

banner "claude -p --json-schema"

claude -p "Classify this operations report: ${INPUT}" \
  --tools "" \
  --model sonnet \
  --output-format json \
  --json-schema "$(cat "${SCHEMA_FILE}")" >"${RESULT_FILE}"

jq -r "${JQ_RESULT}"' | .result' "${RESULT_FILE}" | jq .
