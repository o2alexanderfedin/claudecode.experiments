#!/bin/bash
# Exercises experiments/run-task.sh against fake claude binaries in throwaway
# repositories. Nothing here asserts on elapsed time — only on the verdict.
# Usage: tests/run-task.test.sh   (exit status is the number of failures)
set -u

RUNNER="$(cd "$(dirname "$0")/.." && pwd)/experiments/run-task.sh"
HOOK="$(cd "$(dirname "$0")/.." && pwd)/experiments/hooks/stop-terminate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

# The runner refuses to start without a TTY on stdout. Give it one through
# python's pty module, which behaves the same on macOS and Linux (unlike
# script(1), whose argument syntax differs between the two).
with_pty() {
  python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@"
}

# A repo holding a task.md, and a fake claude that runs $2 as a bash script.
#
# The fake is bash reached through a symlink named `claude`, so `ps` reports it
# the way it reports the real binary and the Stop hook recognises it. The body
# may call the real Stop hook as `stop_hook`, exactly as Claude Code would: as
# a child of the session. The hook never looks above the runner, so it cannot
# reach the Claude Code session that may be running this suite.
new_case() {
  local dir="$WORK/$1"
  git init -q "$dir"
  cd "$dir" || exit 1
  echo "do the thing" > task.md
  ln -s /bin/bash claude
  add_fake fake-claude "$2"
}

# Another fake claude in the current case, named $1, whose body is $2.
add_fake() {
  printf 'stop_hook() { "%s"; }\n%s\n' "$HOOK" "$2" > "$1.body"
  printf '#!/bin/sh\nexec "%s/claude" "%s/%s.body"\n' "$PWD" "$PWD" "$1" > "$1"
  chmod +x "$1"
}

# Runs the runner in the current case; prints "<exit> <status line>".
# $1 is RUN_TIMEOUT: 1 for fakes that hang forever, so the timeout is certain to
# fire; a generous one for fakes that end by themselves, so it never does, no
# matter how slowly a loaded machine starts them. $2 names the fake to run.
run() {
  local out rc
  out=$(CLAUDE_ENG="$PWD/${2:-fake-claude}" RUN_TIMEOUT="$1" KILL_GRACE=1 with_pty "$RUNNER" 2>&1 </dev/null)
  rc=$?
  echo "$rc $(printf '%s\n' "$out" | tr -d '\r' | sed -n 's/^status *: \([A-Z ]*\).*/\1/p' | sed 's/ *$//')"
}

expect() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (wanted '$want', got '$got')"
    failures=$((failures + 1))
  fi
}

# Claude Code has been seen ignoring SIGTERM. A session that hangs past the
# timeout is then SIGKILLed by timeout(1), which exits 137 — the same code the
# Stop hook's own SIGKILL watchdog produces. The hang must not read as done.
new_case hang-ignores-term "trap '' TERM; exec sleep 60"
expect "session that hangs and ignores SIGTERM is a timeout" "124 TIMED OUT" "$(run 1)"

new_case hang-honours-term "exec sleep 60"
expect "session that hangs and honours SIGTERM is a timeout" "124 TIMED OUT" "$(run 1)"

# The Stop hook fired: it leaves the marker, then signals the session.
new_case stop-hook-term "stop_hook 2>/dev/null; exec sleep 60"
expect "Stop hook ends the session with SIGTERM" "0 COMPLETED" "$(run 600)"

new_case stop-hook-kill "trap '' TERM; stop_hook 2>/dev/null; kill -KILL \$\$"
expect "Stop hook ends the session with SIGKILL" "0 COMPLETED" "$(run 600)"

new_case exits-cleanly "exit 0"
expect "session that exits on its own" "0 COMPLETED" "$(run 600)"

new_case crashes "exit 3"
expect "session that fails" "3 FAILED" "$(run 600)"

# SIGTERM that the Stop hook did not send is not a completed turn.
new_case terminated-externally "kill -TERM \$\$"
expect "session terminated by someone else is a failure" "143 FAILED" "$(run 600)"

# The task may start a claude of its own, e.g. one of the examples. That
# session inherits the batch environment and fires the same Stop hook when its
# own turn ends. It must not mark the batch run as done: the batch session can
# still hang afterwards, and then the run must be a timeout.
new_case nested-claude-then-hang "\"\$PWD/claude\" -c 'stop_hook() { \"$HOOK\"; }; stop_hook 2>/dev/null; :'; trap '' TERM; exec sleep 60"
expect "a claude started by the task does not complete the run" "124 TIMED OUT" "$(run 1)"

# Two runs in one checkout at the same time. A's Stop hook fires while B is
# still running; B's session is then ended by a SIGTERM nobody's hook sent.
# B must not take A's hook for its own. The files `b-started`, `a-hooked` and
# `b-done` only order the two runs; nothing waits on the clock.
new_case concurrent-runs ""
add_fake fake-b "touch b-started; until [ -e a-hooked ]; do sleep 0.1; done; kill -TERM \$\$"
add_fake fake-a "trap '' TERM; stop_hook 2>/dev/null; touch a-hooked; until [ -e b-done ]; do sleep 0.1; done; kill -KILL \$\$"
run 600 fake-b > b.result &
b_pid=$!
until [ -e b-started ]; do sleep 0.1; done
run 600 fake-a > a.result &
a_pid=$!
wait "$b_pid"
touch b-done
wait "$a_pid"
expect "concurrent run: a hook in another run does not complete this one" "143 FAILED" "$(cat b.result)"
expect "concurrent run: the run whose hook fired completes" "0 COMPLETED" "$(cat a.result)"
expect "concurrent run: no marker is left behind" "" "$(ls out/*stop-hook-fired* 2>/dev/null)"

echo
echo "$failures failure(s)"
exit "$failures"
