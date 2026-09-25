#!/bin/bash
# Exercises .githooks/pre-commit in throwaway repositories.
# Usage: tests/pre-commit.test.sh   (exit status is the number of failures)
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/.githooks/pre-commit"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

# A repo with main and develop, the hook installed, and one commit on each.
new_repo() {
  local dir="$WORK/$1"
  git init -q -b main "$dir"
  cd "$dir" || exit 1
  git config user.email test@example.com
  git config user.name test
  cp "$HOOK" .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  echo base > file
  git add file
  git commit -q --no-verify -m base
  git switch -q -c develop
}

expect() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (wanted $want, got $got)"
    failures=$((failures + 1))
  fi
}

commit_result() {
  if git commit -q "$@" >/dev/null 2>&1; then echo accepted; else echo rejected; fi
}

new_repo direct-develop
echo change > file && git add file
expect "direct commit on develop is rejected" rejected "$(commit_result -m change)"

new_repo direct-main
git switch -q main
echo change > file && git add file
expect "direct commit on main is rejected" rejected "$(commit_result -m change)"

new_repo feature-branch
git switch -q -c feature/x
echo change > file && git add file
expect "commit on feature/x is accepted" accepted "$(commit_result -m change)"

# `git flow feature finish` merges into develop. When that merge conflicts, git
# stops and the resolution is committed with `git commit`, which runs
# pre-commit on develop. That commit is the flow itself, not a direct commit.
new_repo conflict-merge
git switch -q -c feature/x
echo feature > file && git commit -q -am feature
git switch -q develop
echo develop > file && git commit -q --no-verify -am develop
git merge -q --no-ff feature/x -m "Merge branch 'feature/x' into develop" >/dev/null 2>&1
echo resolved > file && git add file
expect "conflict-resolution merge commit on develop is accepted" accepted "$(commit_result --no-edit)"

echo
echo "$failures failure(s)"
exit "$failures"
