#!/usr/bin/env bash
# Fail unless `timeout` on PATH is GNU coreutils timeout.
#
#   ./scripts/require-gnu-timeout.sh
#
# experiments/run-task.sh and its tests depend on GNU timeout's behaviour:
# `--foreground`, exit 124 when the time runs out, and 137 when the -k
# follow-up SIGKILL is needed. Other implementations (uutils, busybox) are
# not known to match. CI runs this first, so a runner image that changes
# `timeout` fails here with a clear message instead of as flaky verdicts.
set -euo pipefail

if ! command -v timeout >/dev/null 2>&1; then
  echo "require-gnu-timeout: no timeout(1) on PATH" >&2
  exit 1
fi

version=$(timeout --version 2>/dev/null | head -n 1 || true)
case "${version}" in
  *"(GNU coreutils)"*)
    echo "require-gnu-timeout: ok: ${version}" ;;
  *)
    echo "require-gnu-timeout: timeout(1) is not GNU coreutils: '${version}'" >&2
    exit 1 ;;
esac
