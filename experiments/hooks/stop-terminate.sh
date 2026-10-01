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
# "The correct process": the session the runner launched, and only that one.
# It is the NEAREST `claude` ancestor of this hook, and the walk up from there
# must reach the runner (CLAUDE_BATCH_RUNNER_PID) without meeting another
# `claude`. Everything the session starts inherits the batch environment, so a
# `claude` the task itself runs fires this hook too; that one is not ours. Nor
# is any session above the runner, such as one that launched it.

set -uo pipefail

[ "${CLAUDE_BATCH_EXIT:-}" = "1" ] || exit 0
[ -n "${CLAUDE_BATCH_RUNNER_PID:-}" ] || exit 0

# Prints the batch session's pid and returns 0; returns 1 for a turn that is
# not the batch session's. Returns 2 when the walk reaches the runner without
# passing any `claude`: then it prints the runner's own child (timeout(1)),
# the one process left that can still end the run.
find_batch_session() {
  local pid=$$ parent comm target=""
  while :; do
    parent=$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')
    [ -n "${parent}" ] || return 1
    [ "${parent}" -gt 1 ] 2>/dev/null || return 1
    if [ "${parent}" = "${CLAUDE_BATCH_RUNNER_PID}" ]; then
      if [ -z "${target}" ]; then
        echo "${pid}"
        return 2
      fi
      echo "${target}"
      return 0
    fi
    comm=$(ps -o comm= -p "${parent}" 2>/dev/null | tr -d ' ')
    case "${comm}" in
      claude|*/claude)
        # A second claude below the runner: this hook belongs to a session
        # the batch session started, not to the batch session itself.
        [ -z "${target}" ] || return 1
        target=${parent} ;;
    esac
    pid=${parent}
  done
}

target=$(find_batch_session)
case $? in
  0) ;;
  2)
    # The hook runs under the runner, yet no process on the way is named
    # `claude` (CLAUDE_ENG starts the CLI under another name, for example).
    # Nothing can tell which process is the session, so say so and end the
    # run now instead of letting it sit out the whole timeout.
    [ -n "${CLAUDE_BATCH_NO_SESSION_MARKER:-}" ] && : > "${CLAUDE_BATCH_NO_SESSION_MARKER}"
    echo "stop-terminate: no claude process between this hook and the runner; ending the run through pid ${target}" >&2
    kill -TERM "${target}" 2>/dev/null || true
    exit 0 ;;
  *)
    echo "stop-terminate: not the batch session's own turn; leaving it alone" >&2
    exit 0 ;;
esac

# Tell the runner this ending is ours. Without the marker it cannot tell our
# SIGKILL apart from the one timeout(1) sends a hung session. Written only now,
# once the target is known: a marker from any other turn would let a session
# that hangs later be reported as COMPLETED.
[ -n "${CLAUDE_BATCH_EXIT_MARKER:-}" ] && : > "${CLAUDE_BATCH_EXIT_MARKER}"

echo "stop-terminate: turn finished, terminating claude pid ${target}" >&2

# SIGTERM first so the session gets a chance to flush; Claude Code has been
# observed to ignore it, hence the SIGKILL follow-up from a detached watchdog.
kill -TERM "${target}" 2>/dev/null || true
( sleep 5; kill -KILL "${target}" 2>/dev/null || true ) >/dev/null 2>&1 &

exit 0
