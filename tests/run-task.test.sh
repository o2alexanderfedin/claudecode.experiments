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

# A repo holding a task.md, and a fake claude whose body is $2.
#
# The fake may call the real Stop hook as `stop_hook`. The hook walks up the
# process tree to the nearest `claude` and kills it; from inside a test that
# could be the Claude Code session running the suite. So the hook always runs
# with a `ps` that reports no parent, which makes it find nothing to kill.
new_case() {
  local dir="$WORK/$1"
  git init -q "$dir"
  cd "$dir" || exit 1
  echo "do the thing" > task.md
  mkdir shim
  printf '#!/bin/sh\nexit 0\n' > shim/ps
  chmod +x shim/ps
  # shellcheck disable=SC2016  # $PATH is meant to expand inside the fake
  printf '#!/bin/bash\nstop_hook() { PATH="%s:$PATH" "%s"; }\n%s\n' "$dir/shim" "$HOOK" "$2" > fake-claude
  chmod +x fake-claude
}

# Runs the runner in the current case; prints "<exit> <status line>".
# $1 is RUN_TIMEOUT: 1 for fakes that hang forever, so the timeout is certain to
# fire; a generous one for fakes that end by themselves, so it never does, no
# matter how slowly a loaded machine starts them.
run() {
  local out rc
  out=$(CLAUDE_ENG="$PWD/fake-claude" RUN_TIMEOUT="$1" KILL_GRACE=1 with_pty "$RUNNER" 2>&1 </dev/null)
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
new_case stop-hook-term "stop_hook 2>/dev/null; kill -TERM \$\$"
expect "Stop hook ends the session with SIGTERM" "0 COMPLETED" "$(run 600)"

new_case stop-hook-kill "stop_hook 2>/dev/null; kill -KILL \$\$"
expect "Stop hook ends the session with SIGKILL" "0 COMPLETED" "$(run 600)"

new_case exits-cleanly "exit 0"
expect "session that exits on its own" "0 COMPLETED" "$(run 600)"

new_case crashes "exit 3"
expect "session that fails" "3 FAILED" "$(run 600)"

# SIGTERM that the Stop hook did not send is not a completed turn.
new_case terminated-externally "kill -TERM \$\$"
expect "session terminated by someone else is a failure" "143 FAILED" "$(run 600)"

echo
echo "$failures failure(s)"
exit "$failures"
