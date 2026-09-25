#!/usr/bin/env bash
#
# Experiment: is a queued `/exit` held until the turn ends?
#
# Hypothesis, from the Claude Code docs (Interactive mode › Queue messages
# while Claude works):
#
#   "Commands and shell commands: Claude Code holds them until the turn ends,
#    then runs them one at a time"
#
# If that holds for input arriving on stdin, then
#
#   printf 'execute task from task.md file\n/exit\n' | ~/claude-eng
#
# completes the task first and only then exits — no `tail -f`, no timer, no
# hook, no extra CLI flags. Communication with claude is stdin only.
#
# Falsifiable: the task's whole job is to create a side-effect file. If `/exit`
# were executed eagerly, the run would end before that file exists.
#
# ── Billing guard ────────────────────────────────────────────────────────────
# Claude Code switches to non-interactive mode when stdout is not a TTY, and
# non-interactive runs bill per API token instead of against the subscription.
# This script therefore re-enters itself under a pseudo-terminal and refuses to
# launch claude at all if stdout still is not a TTY.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
LOG_DIR="${REPO_ROOT}/out"
LOG_FILE="${LOG_DIR}/stdin-queued-exit.typescript"

# Re-enter under a pty when stdout is not a TTY. `script` records the whole
# session to LOG_FILE while keeping the child's stdout a terminal.
if [ ! -t 1 ] && [ -z "${STDIN_QUEUED_EXIT_PTY:-}" ]; then
  mkdir -p "${LOG_DIR}"
  # script(1) reads termios from its own stdin and refuses to start when that
  # is a socket, as it is under a tool runner. Hand it clean descriptors; the
  # whole session is recorded in LOG_FILE regardless.
  STDIN_QUEUED_EXIT_PTY=1 exec script -q "${LOG_FILE}" "$0" "$@" </dev/null >/dev/null 2>&1
fi

if [ ! -t 1 ]; then
  echo "REFUSING TO RUN: stdout is not a TTY." >&2
  echo "Claude Code would fall back to non-interactive mode and bill per token." >&2
  exit 78
fi

# A pty minted by script(1) starts at 0x0. Claude Code's TUI cannot lay itself
# out on a zero-width terminal and hangs before it ever reads the prompt, so
# give the pty a real size. Only ever resize a terminal we created ourselves.
if [ -n "${STDIN_QUEUED_EXIT_PTY:-}" ]; then
  stty rows 50 columns 200 2>/dev/null || true
fi

CLAUDE_ENG="${HOME}/claude-eng"
PROMPT='execute task from task.md file'
TASK_FILE="${REPO_ROOT}/task.md"
PROOF_FILE="${REPO_ROOT}/pong.txt"
RUN_TIMEOUT=300
KILL_GRACE=15          # claude ignores SIGTERM; timeout needs -k to follow up

# --foreground is mandatory: without it timeout(1) puts claude in its own
# process group, so its first read of the terminal raises SIGTTIN and the
# process stops dead before it ever renders the TUI or reads the prompt.

[ -x "${CLAUDE_ENG}" ] || { echo "not executable: ${CLAUDE_ENG}" >&2; exit 127; }
command -v timeout >/dev/null || { echo "timeout(1) not found" >&2; exit 127; }

# shellcheck disable=SC2329  # invoked via trap
# shellcheck disable=SC2317  # invoked by the EXIT trap below; older shellcheck misses that
cleanup() { rm -f "${TASK_FILE}" "${PROOF_FILE}"; }
trap cleanup EXIT

cd "${REPO_ROOT}"
rm -f "${TASK_FILE}" "${PROOF_FILE}"

cat > "${TASK_FILE}" <<'TASK'
Create a file named pong.txt in the current directory.

Its entire contents must be the single word:

pong

Do nothing else. Do not create, read or modify any other file. Do not run git.
TASK

echo "── setup ─────────────────────────────────────────────"
echo "cwd        : $(pwd)"
echo "stdout tty : $(tty)  size: $(stty size 2>/dev/null || echo unknown)"
echo "task file  : ${TASK_FILE}"
echo "prompt     : ${PROMPT}"
echo "sent on stdin, in order: the prompt, then /exit"
echo "── run ───────────────────────────────────────────────"

start=${SECONDS}
set +e
printf '%s\n/exit\n' "${PROMPT}" | timeout --foreground -k "${KILL_GRACE}" "${RUN_TIMEOUT}" "${CLAUDE_ENG}"
rc=$?
set -e
elapsed=$(( SECONDS - start ))

echo
echo "── result ────────────────────────────────────────────"
echo "exit code    : ${rc}"
echo "elapsed      : ${elapsed}s"
echo "timed out    : $([ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ] && echo YES || echo no)"

if [ -f "${PROOF_FILE}" ]; then
  contents=$(tr -d '[:space:]' < "${PROOF_FILE}")
  echo "pong.txt     : present, contents='${contents}'"
else
  contents=""
  echo "pong.txt     : MISSING"
fi

echo
if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
  echo "VERDICT: INCONCLUSIVE — the process never exited within ${RUN_TIMEOUT}s."
  echo "         /exit was not honoured; a queued-exit design will not work as-is."
  verdict=2
elif [ "${contents}" = "pong" ] && [ "${rc}" -eq 0 ]; then
  echo "VERDICT: CONFIRMED — the task completed, then the process exited."
  echo "         A queued /exit is held until the turn ends."
  verdict=0
elif [ -z "${contents}" ]; then
  echo "VERDICT: REFUTED — the process exited but the task never ran."
  echo "         /exit is executed eagerly; deferred delivery is required."
  verdict=1
else
  echo "VERDICT: UNCLEAR — task side effect present but exit code ${rc}."
  verdict=3
fi

echo "── log ───────────────────────────────────────────────"
echo "full session transcript: ${LOG_FILE}"
exit "${verdict}"
