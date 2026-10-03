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
# It is found by where it sits, never by its name. The runner starts
# timeout(1), and timeout(1) starts CLAUDE_ENG; that process is the session,
# or, when CLAUDE_ENG is a wrapper that starts the CLI without exec, its child.
# The hook acts only when the process that ran it is that session. Everything
# the session starts inherits the batch environment, so a `claude` the task
# itself runs fires this hook too; that one is not ours. Nor is any session
# above the runner, such as one that launched it.

set -uo pipefail

[ "${CLAUDE_BATCH_EXIT:-}" = "1" ] || exit 0
[ -n "${CLAUDE_BATCH_RUNNER_PID:-}" ] || exit 0

[ -n "${CLAUDE_BATCH_ENG:-}" ] || exit 0

parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
args_of() { ps -o args= -p "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }
not_ours() {
  echo "stop-terminate: not the batch session's own turn; leaving it alone" >&2
  exit 0
}

# The ancestors of this hook, nearest first, up to the runner's own child.
chain=()
pid=$$
while :; do
  parent=$(parent_of "${pid}")
  [ -n "${parent}" ] || not_ours
  [ "${parent}" -gt 1 ] 2>/dev/null || not_ours
  [ "${parent}" = "${CLAUDE_BATCH_RUNNER_PID}" ] && break
  chain+=("${parent}")
  pid=${parent}
done

# chain[n-1] is timeout(1); chain[n-2] is the process it started.
n=${#chain[@]}
[ "${n}" -ge 2 ] || not_ours
launched=${chain[n-2]}

# The process that ran this hook. Claude Code may start a hook through a shell
# that only runs this script; that shell is not the session.
i=0
case "$(args_of "${chain[0]}")" in
  "${0##*/}"|*"/${0##*/}") i=1 ;;
esac
[ "${i}" -lt $((n - 1)) ] || not_ours
fired_by=${chain[i]}

if [ "${fired_by}" = "${launched}" ]; then
  target=${fired_by}
elif [ $((i + 1)) = $((n - 2)) ]; then
  # The hook's session is a direct child of the launched process. That is the
  # CLI only when the launched process is still CLAUDE_ENG run as a script, a
  # wrapper that did not exec; otherwise it is a claude the task started.
  case "$(args_of "${launched}")" in
    *" ${CLAUDE_BATCH_ENG}") target=${fired_by} ;;
    *) not_ours ;;
  esac
else
  not_ours
fi

# Tell the runner this ending is ours. Without the marker it cannot tell our
# SIGKILL apart from the one timeout(1) sends a hung session. Written only now,
# once the target is known: a marker from any other turn would let a session
# that hangs later be reported as COMPLETED.
[ -n "${CLAUDE_BATCH_EXIT_MARKER:-}" ] && : > "${CLAUDE_BATCH_EXIT_MARKER}"

echo "stop-terminate: turn finished, terminating claude pid ${target}" >&2

# SIGTERM first so the session gets a chance to flush; Claude Code has been
# observed to ignore it, hence a SIGKILL follow-up from a detached watchdog.
# The watchdog must never hit another process that later gets the same pid:
# it remembers the target's start time and command line, stops as soon as
# they no longer match (the session is gone), and checks them again right
# before the SIGKILL.
identity_of() { ps -o lstart=,args= -p "$1" 2>/dev/null; }
identity=$(identity_of "${target}")
kill -TERM "${target}" 2>/dev/null || true
if [ -n "${identity}" ]; then
  (
    for _ in $(seq 50); do
      [ "$(identity_of "${target}")" = "${identity}" ] || exit 0
      sleep 0.1
    done
    [ "$(identity_of "${target}")" = "${identity}" ] || exit 0
    kill -KILL "${target}" 2>/dev/null || true
  ) >/dev/null 2>&1 &
fi

exit 0
