#!/usr/bin/env bash
#
# Run one task through the INTERACTIVE claude and return when the task is done.
#
#   ./experiments/run-task.sh            # reads ./task.md
#
# Communication with claude is stdin only — no invented CLI flags. The prompt is
# a single line; the task itself lives in task.md so nothing multi-line ever
# touches stdin.
#
# Why not `/exit`: Claude Code reads piped stdin to EOF and submits the whole
# thing as ONE prompt. A trailing `/exit` therefore arrives as prompt text, not
# as a command, and the session stays open forever after the turn. Termination
# is instead driven by the Stop hook in .claude/settings.json, which fires the
# moment the turn ends and signals this session — see experiments/hooks/.
#
# Billing: Claude Code drops to non-interactive mode when stdout is not a TTY,
# and that path bills per API token instead of the subscription. This script
# re-enters itself under a pty and refuses to launch claude without one.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
LOG_DIR="${REPO_ROOT}/out"
LOG_FILE="${LOG_DIR}/run-task.typescript"

if [ ! -t 1 ] && [ -z "${RUN_TASK_PTY:-}" ]; then
  mkdir -p "${LOG_DIR}"
  # script(1) reads termios from its own stdin and refuses to start when that is
  # a socket, as it is under a tool runner. Hand it clean descriptors; the whole
  # session is recorded in LOG_FILE regardless.
  RUN_TASK_PTY=1 exec script -q "${LOG_FILE}" "$0" "$@" </dev/null >/dev/null 2>&1
fi

if [ ! -t 1 ]; then
  echo "REFUSING TO RUN: stdout is not a TTY." >&2
  echo "Claude Code would fall back to non-interactive mode and bill per token." >&2
  exit 78
fi

# A pty minted by script(1) starts at 0x0 and the TUI cannot lay itself out on
# a zero-width terminal. Only ever resize a terminal we created ourselves.
[ -n "${RUN_TASK_PTY:-}" ] && { stty rows 50 columns 200 2>/dev/null || true; }

CLAUDE_ENG="${HOME}/claude-eng"
TASK_FILE="${REPO_ROOT}/task.md"
PROMPT='execute task from task.md file'
RUN_TIMEOUT=${RUN_TIMEOUT:-900}
KILL_GRACE=20

[ -x "${CLAUDE_ENG}" ] || { echo "not executable: ${CLAUDE_ENG}" >&2; exit 127; }
[ -s "${TASK_FILE}" ]  || { echo "missing or empty: ${TASK_FILE}" >&2; exit 66; }
command -v timeout >/dev/null || { echo "timeout(1) not found" >&2; exit 127; }

cd "${REPO_ROOT}"

# Arms the Stop hook. Without it the hook is a no-op, so ordinary interactive
# sessions in this repository are unaffected.
export CLAUDE_BATCH_EXIT=1

echo "── run-task ──────────────────────────────────────────"
echo "cwd     : $(pwd)"
echo "tty     : $(tty)  size: $(stty size 2>/dev/null || echo unknown)"
echo "task    : ${TASK_FILE}"
echo "prompt  : ${PROMPT}"
echo "timeout : ${RUN_TIMEOUT}s"
echo "──────────────────────────────────────────────────────"

start=${SECONDS}
set +e
# --foreground is mandatory: without it timeout(1) puts claude in its own
# process group, its first terminal read raises SIGTTIN, and the process stops
# dead before it ever renders the TUI or reads the prompt.
printf '%s\n' "${PROMPT}" | timeout --foreground -k "${KILL_GRACE}" "${RUN_TIMEOUT}" "${CLAUDE_ENG}"
rc=$?
set -e
elapsed=$(( SECONDS - start ))

echo
echo "── outcome ───────────────────────────────────────────"
echo "raw exit : ${rc}"
echo "elapsed  : ${elapsed}s"

case "${rc}" in
  143|137)
    # 128+SIGTERM / 128+SIGKILL — the Stop hook ended the session on purpose.
    echo "status   : COMPLETED (terminated by Stop hook after the turn)"
    status=0 ;;
  0)
    echo "status   : COMPLETED (session exited on its own)"
    status=0 ;;
  124)
    echo "status   : TIMED OUT after ${RUN_TIMEOUT}s — the turn never ended"
    status=124 ;;
  *)
    echo "status   : FAILED"
    status="${rc}" ;;
esac

echo "log      : ${LOG_FILE}"
exit "${status}"
