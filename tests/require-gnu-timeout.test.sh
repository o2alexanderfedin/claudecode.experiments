#!/bin/bash
# Exercises scripts/require-gnu-timeout.sh with fake `timeout` binaries on PATH.
# Usage: tests/require-gnu-timeout.test.sh   (exit status is the number of failures)
set -u

CHECK="$(cd "$(dirname "$0")/.." && pwd)/scripts/require-gnu-timeout.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

expect() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (wanted '$want', got '$got')"
    failures=$((failures + 1))
  fi
}

# Runs the check with a fake timeout whose --version prints $1.
check_with() {
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$WORK/bin/timeout"
  chmod +x "$WORK/bin/timeout"
  if PATH="$WORK/bin:$PATH" bash "$CHECK" >/dev/null 2>&1; then echo accepted; else echo rejected; fi
}

expect "GNU coreutils timeout is accepted" accepted "$(check_with 'timeout (GNU coreutils) 9.4')"
expect "uutils timeout is rejected" rejected "$(check_with 'timeout (uutils coreutils) 0.10.0')"
expect "busybox timeout is rejected" rejected "$(check_with 'BusyBox v1.36.1 (2023-01-01) multi-call binary.')"

rm -f "$WORK/bin/timeout"
expect "no timeout at all is rejected" rejected "$(if PATH="$WORK/bin:/nonexistent" /bin/bash "$CHECK" >/dev/null 2>&1; then echo accepted; else echo rejected; fi)"

echo
echo "$failures failure(s)"
exit "$failures"
