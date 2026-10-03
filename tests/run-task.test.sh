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
# Extra NAME=value pairs for the runner's environment go in PTY_ENV.
PTY_ENV=()
with_pty() {
  env ${PTY_ENV[@]+"${PTY_ENV[@]}"} python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@"
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
  printf '%s\n' "$out" | tr -d '\r' > run.out
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

# A session that exits on its own without reading the prompt. The prompt
# writer is then left with a pipe nobody reads and dies of SIGPIPE (or gets
# EPIPE). The run's verdict must follow the session, not the writer. The
# runner's printf is replaced, through an exported bash function, by one that
# keeps writing, so the writer is certain to be still writing when the
# session is gone — as a slow writer or a long prompt would be.
new_case exits-without-reading "exit 0"
PTY_ENV=('BASH_FUNC_printf%%=() { while :; do builtin printf "$@" || return; done; }')
expect "session that exits without reading the prompt" "0 COMPLETED" "$(run 600)"
PTY_ENV=()

# The session is recognised by where it sits, not by its name: it is the
# process timeout(1) started. The CLI may run under any name -- a CLI started
# by an interpreter shows the interpreter's name. Its Stop hook must still end
# the run.
new_case cli-under-another-name ""
ln -s /bin/bash not-claude
printf '#!/bin/sh\nexec "%s/not-claude" "%s/fake-claude.body"\n' "$PWD" "$PWD" > fake-claude
printf 'stop_hook() { "%s"; }\n%s\n' "$HOOK" "stop_hook 2>/dev/null; exec sleep 600" > fake-claude.body
expect "a CLI under another name is ended by its Stop hook" "0 COMPLETED" "$(run 900)"

# The same session under another name, and a `claude` the task starts. That
# claude's Stop hook used to be taken for the batch session's, because it was
# the only process named `claude` on the way to the runner: the run was marked
# done, and a session that then hung read as COMPLETED.
new_case nested-claude-under-another-name ""
ln -s /bin/bash not-claude
printf '#!/bin/sh\nexec "%s/not-claude" "%s/fake-claude.body"\n' "$PWD" "$PWD" > fake-claude
printf 'stop_hook() { "%s"; }\n%s\n' "$HOOK" "\"\$PWD/claude\" -c 'stop_hook() { \"$HOOK\"; }; stop_hook 2>/dev/null; :'; trap '' TERM; exec sleep 60" > fake-claude.body
expect "a claude started by a session under another name does not complete the run" "124 TIMED OUT" "$(run 1)"

# CLAUDE_ENG may be a wrapper that starts the CLI without exec, so the session
# is the wrapper's child, not the process timeout(1) started.
new_case wrapper-without-exec ""
ln -s /bin/bash not-claude
printf '#!/bin/sh\n"%s/not-claude" "%s/fake-claude.body"\nexit $?\n' "$PWD" "$PWD" > fake-claude
printf 'stop_hook() { "%s"; }\n%s\n' "$HOOK" "stop_hook 2>/dev/null; exec sleep 600" > fake-claude.body
expect "a session started by a wrapper without exec is ended by its Stop hook" "0 COMPLETED" "$(run 900)"
expect "a session started by a wrapper without exec is ended at once" "143" "$(sed -n 's/^raw exit : //p' run.out)"

# Claude Code may start a hook through a shell that does nothing but run it.
# That shell sits between the hook and the session and must be passed over.
# `hookshell` is such a shell. If the hook stopped there, it would leave the
# session alone and the body would go on to `exit 5`.
new_case hook-run-through-a-shell "\"\$PWD/hookshell\" \"$HOOK\" 2>/dev/null; exit 5"
# shellcheck disable=SC2016  # the shim expands its own "$1" when it runs
printf '#!/bin/sh\n"$1"\nexit $?\n' > hookshell
chmod +x hookshell
expect "a Stop hook started through a shell ends the session" "0 COMPLETED" "$(run 600)"

# The Stop hook's SIGKILL follow-up must reach only the process it signalled.
# Here the session reacts to SIGTERM by turning, under the same pid, into a
# different program -- the same thing the follow-up would meet if the session
# died and its pid went to a new process. That program, `waiter`, waits until
# no Stop hook process is left in its own process group (the run's terminal),
# then exits 7. A follow-up that kills it anyway turns the run into
# "0 COMPLETED". Only its own group is searched: other processes on the
# machine may mention the hook's name. The pattern `stop-termina[t]e` matches
# the hook and its follow-up but not the waiter's own text.
new_case watchdog-spares-a-new-program "trap 'exec /bin/bash \"\$PWD/waiter\"' TERM; stop_hook 2>/dev/null; while :; do sleep 0.1; done"
cat > waiter <<'WAITER'
group=$(ps -o pgid= -p $$ | tr -d ' ')
while ps -axo pgid=,args= | awk -v g="$group" '$1 == g' | grep -q 'stop-termina[t]e'; do
  sleep 0.1
done
exit 7
WAITER
expect "the SIGKILL follow-up spares a process that is no longer the session" "7 FAILED" "$(run 600)"

# A session that ignores SIGTERM is still ended by the follow-up SIGKILL, not
# by timeout(1): both end in SIGKILL and exit 137, so the session counts the
# SIGTERMs it gets. The hook sends one; timeout(1) would send a second, and
# the session then leaves `second-term`. The session also records its process
# group, which is the run's own: once the runner has returned, nothing in that
# group -- the session, the hook, the watchdog -- may still be running.
new_case watchdog-kills-a-hung-session "ps -o pgid= -p \$\$ | tr -d ' ' > group; terms=0; trap 'terms=\$((terms + 1)); [ \$terms -lt 2 ] || touch second-term' TERM; stop_hook 2>/dev/null; while :; do sleep 0.1; done"
expect "the SIGKILL follow-up ends a session that ignores SIGTERM" "0 COMPLETED" "$(run 600)"
expect "the session got no SIGTERM from timeout(1)" "absent" "$([ -e second-term ] && echo present || echo absent)"
expect "nothing of the run is left running" "0" "$(if [ -s group ]; then ps -axo pgid= | tr -d ' ' | grep -c -x "$(cat group)"; else echo no-group-recorded; fi)"

# The same for a session that obeys the hook's SIGTERM at once: the watchdog
# then has nobody left to kill and must not stay behind after the run.
new_case watchdog-leaves-with-the-session "ps -o pgid= -p \$\$ | tr -d ' ' > group; stop_hook 2>/dev/null; exec sleep 60"
expect "a session that obeys SIGTERM completes" "0 COMPLETED" "$(run 600)"
expect "nothing of that run is left running" "0" "$(if [ -s group ]; then ps -axo pgid= | tr -d ' ' | grep -c -x "$(cat group)"; else echo no-group-recorded; fi)"

echo
echo "$failures failure(s)"
exit "$failures"
