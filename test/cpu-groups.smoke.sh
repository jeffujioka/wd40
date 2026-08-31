#!/usr/bin/env bash
#
# cpu-groups.smoke.sh - smoke tests for scripts/cpu-groups.sh.
#
# Spawns a small known process tree (a parent shell with two busy-loop
# children) and checks that cpu-groups.sh groups the children under the
# parent, and that --depth 0 keeps them separate.
#
# Usage: ./test/cpu-groups.smoke.sh

set -eu

TEST_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$TEST_DIR/.." && pwd -P)
SCRIPT="$REPO/scripts/cpu-groups.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_contains() {
  # assert_contains NEEDLE HAYSTACK LABEL
  case "$2" in
    *"$1"*) pass "$3" ;;
    *) fail "$3 (expected to find '$1')" ;;
  esac
}

# --- spawn a known tree: this shell -> two child shells busy-looping -----
# Each child burns CPU for a few seconds so it shows up in a `ps` snapshot
# taken while they're alive. $$ is the parent PID cpu-groups.sh should
# report as the group's root once it climbs from either child.
( : ) & # warm up job control in case it's not already active
CHILD1_CMD="cpu_groups_smoke_child_a"
CHILD2_CMD="cpu_groups_smoke_child_b"
bash -c "exec -a $CHILD1_CMD bash -c 'end=\$((SECONDS+5)); while [ \$SECONDS -lt \$end ]; do :; done'" &
CHILD1_PID=$!
bash -c "exec -a $CHILD2_CMD bash -c 'end=\$((SECONDS+5)); while [ \$SECONDS -lt \$end ]; do :; done'" &
CHILD2_PID=$!

sleep 1 # let both children accumulate measurable %CPU before snapshotting

OUTPUT="$("$SCRIPT" -u "$USER" -n 20)"

assert_contains "$CHILD1_PID" "$OUTPUT" "child A's PID appears somewhere in the output"
assert_contains "$CHILD2_PID" "$OUTPUT" "child B's PID appears somewhere in the output"

# Both children share this test script's PID ($$) as their direct parent,
# so with unlimited depth they should land in the same group - meaning a
# single output line lists both PIDs in its PIDS column together.
GROUPED_LINE="$(printf '%s\n' "$OUTPUT" | grep -F "$CHILD1_PID" | grep -F "$CHILD2_PID" || true)"
if [ -n "$GROUPED_LINE" ]; then
  pass "both children rolled up into the same group"
else
  fail "expected both children in the same group's PIDS column"
fi

DEPTH0_OUTPUT="$("$SCRIPT" -u "$USER" -n 20 -d 0)"
CHILD1_LINE="$(printf '%s\n' "$DEPTH0_OUTPUT" | grep -F "$CHILD1_PID" || true)"
CHILD2_LINE="$(printf '%s\n' "$DEPTH0_OUTPUT" | grep -F "$CHILD2_PID" || true)"
if [ -n "$CHILD1_LINE" ] && [ -n "$CHILD2_LINE" ] && [ "$CHILD1_LINE" != "$CHILD2_LINE" ]; then
  pass "--depth 0 keeps the two children in separate groups"
else
  fail "--depth 0 should have kept the two children in separate groups"
fi

kill "$CHILD1_PID" "$CHILD2_PID" 2>/dev/null || true
wait 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
