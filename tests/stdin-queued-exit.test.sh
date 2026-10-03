#!/bin/bash
# Exercises experiments/stdin-queued-exit.sh against a fake claude in throwaway
# repositories. The experiment writes its own task.md and pong.txt at the
# repository root -- the same task.md that run-task.sh reads. A file the user
# had there must be back, unchanged, when the experiment ends.
# Usage: tests/stdin-queued-exit.test.sh   (exit status is the number of failures)
set -u

EXPERIMENT="$(cd "$(dirname "$0")/.." && pwd)/experiments/stdin-queued-exit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

# The experiment refuses to start without a TTY on stdout; give it one.
with_pty() {
  python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@"
}

# A repo, and a HOME whose claude-eng (the path the experiment hard-codes)
# runs $2 as a bash script.
new_case() {
  local dir="$WORK/$1"
  git init -q "$dir"
  cd "$dir" || exit 1
  mkdir home
  printf '#!/bin/bash\n%s\n' "$2" > home/claude-eng
  chmod +x home/claude-eng
}

# Prints the experiment's exit status; its output is kept in run.out.
run() {
  HOME="$PWD/home" with_pty "$EXPERIMENT" > run.out 2>&1 </dev/null
  echo $?
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

# The user has a task prepared for run-task.sh, and a pong.txt of their own.
new_case keeps-user-files "echo pong > pong.txt; exit 0"
printf 'the real task\nsecond line\n' > task.md
printf 'mine\n' > pong.txt
cp task.md task.md.before
cp pong.txt pong.txt.before
expect "the experiment runs to its verdict" "0" "$(run)"
expect "the user's task.md is back unchanged" "same" "$(cmp -s task.md task.md.before && echo same || echo changed-or-missing)"
expect "the user's pong.txt is back unchanged" "same" "$(cmp -s pong.txt pong.txt.before && echo same || echo changed-or-missing)"
expect "no saved copy is left behind" "" "$(find . -path ./.git -prune -o -path ./home -prune -o ! -name . ! -name task.md ! -name pong.txt ! -name '*.before' ! -name out ! -name stdin-queued-exit.typescript ! -name run.out -print)"

# Nothing there before: the experiment leaves nothing behind, as it always did.
new_case leaves-nothing "echo pong > pong.txt; exit 0"
expect "the experiment runs to its verdict without user files" "0" "$(run)"
expect "no task.md is left behind" "absent" "$([ -e task.md ] && echo present || echo absent)"
expect "no pong.txt is left behind" "absent" "$([ -e pong.txt ] && echo present || echo absent)"

# The user's task.md cannot be put back: the session left a directory of the
# same name in its place. The experiment must still exit with its own verdict
# (here CONFIRMED, 0), keep the user's file in the saved folder, and say
# where that folder is.
new_case restore-fails "echo pong > pong.txt; rm -f task.md; mkdir -p task.md/blocker; exit 0"
printf 'the real task\n' > task.md
cp task.md task.md.before
expect "a failed restore keeps the experiment's verdict" "0" "$(run)"
saved=$(find out -maxdepth 1 -name 'stdin-queued-exit.saved.*' | head -n 1)
expect "the user's task.md is kept in the saved folder" "same" "$(cmp -s "${saved:-none}/task.md" task.md.before && echo same || echo changed-or-missing)"
expect "the warning names the saved folder" "named" "$(if [ -n "$saved" ] && tr -d '\r' < run.out | grep 'WARNING' | grep -q -F "${saved#out/}"; then echo named; else echo not-named; fi)"

echo
echo "$failures failure(s)"
exit "$failures"
