#!/usr/bin/env bash
#
# Stop hook: end a batch run the moment the turn finishes.
#
# Claude Code reads piped stdin to EOF and submits it as ONE prompt, so a
# trailing `/exit` is swallowed into the prompt text rather than executed, and
# the process stays alive forever once the turn is done. The only reliable
# terminator is a signal — sent at exactly the right moment by the one party
# that knows the turn ended: Claude Code itself, through this hook.
#
# Firing rule: only when CLAUDE_BATCH_EXIT=1 is in the environment. The batch
# runner exports it; ordinary interactive sessions never do, so this hook is
# inert for them.
#
# "The correct process": the NEAREST `claude` ancestor of this hook. Walking up
# from the hook's own pid stops at the batch session — never at the outer
# session that may have launched the runner in the first place.

set -uo pipefail

[ "${CLAUDE_BATCH_EXIT:-}" = "1" ] || exit 0

find_claude_ancestor() {
  local pid=$$ parent comm
  while :; do
    parent=$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')
    [ -n "${parent}" ] || return 1
    [ "${parent}" -gt 1 ] 2>/dev/null || return 1
    comm=$(ps -o comm= -p "${parent}" 2>/dev/null | tr -d ' ')
    case "${comm}" in
      claude|*/claude) echo "${parent}"; return 0 ;;
    esac
    pid=${parent}
  done
}

target=$(find_claude_ancestor) || {
  echo "stop-terminate: no claude ancestor found" >&2
  exit 0
}

echo "stop-terminate: turn finished, terminating claude pid ${target}" >&2

# SIGTERM first so the session gets a chance to flush; Claude Code has been
# observed to ignore it, hence the SIGKILL follow-up from a detached watchdog.
kill -TERM "${target}" 2>/dev/null || true
( sleep 5; kill -KILL "${target}" 2>/dev/null || true ) >/dev/null 2>&1 &

exit 0
