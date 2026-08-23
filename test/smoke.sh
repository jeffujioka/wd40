#!/usr/bin/env bash
#
# smoke.sh - end-to-end and unit tests for install.sh.
#
# Written for bash 3.2 and BSD userland so it runs unchanged on macOS and
# Linux. No test framework on purpose: one file does not justify a
# dependency contributors have to install.
#
# Usage: ./test/smoke.sh

set -eu

TEST_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$TEST_DIR/.." && pwd -P)
INSTALL="$REPO/install.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {
  # assert_eq EXPECTED ACTUAL LABEL
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3"
    printf '       expected: %s\n' "$1"
    printf '       actual:   %s\n' "$2"
  fi
}

assert_ok() {
  # assert_ok LABEL CMD...
  label=$1; shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label (exit $?)"
  fi
}

assert_fail() {
  # assert_fail EXPECTED_CODE LABEL CMD...
  expected=$1; label=$2; shift 2
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  assert_eq "$expected" "$actual" "$label"
}

printf '\n== argument handling ==\n'
assert_ok   "--help exits 0"          "$INSTALL" --help
assert_fail 1 "unknown flag exits 1"  "$INSTALL" --nonsense

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
