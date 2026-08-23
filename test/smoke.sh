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

printf '\n== resolve_path ==\n'
(
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  real=$(cd "$tmp" && pwd -P)

  printf 'hello\n' > "$real/file"
  ln -s "$real/file" "$real/link-abs"
  ( cd "$real" && ln -s file link-rel )
  ln -s "$real/link-abs" "$real/link-chain"

  assert_eq "$real/file" "$(resolve_path "$real/file")"       "plain file"
  assert_eq "$real/file" "$(resolve_path "$real/link-abs")"   "absolute symlink"
  assert_eq "$real/file" "$(resolve_path "$real/link-rel")"   "relative symlink"
  assert_eq "$real/file" "$(resolve_path "$real/link-chain")" "two-hop chain"
  assert_eq "$real/file" "$(cd "$real" && resolve_path file)" "relative input"
  assert_eq "$real/ghost" "$(resolve_path "$real/ghost")"     "missing final component"

  ln -s b "$real/a"
  ln -s a "$real/b"
  if ( resolve_path "$real/a" ) >/dev/null 2>&1; then
    fail "symlink cycle dies"
  else
    pass "symlink cycle dies"
  fi

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n== discovery ==\n'
(
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fix=$(cd "$tmp" && pwd -P)

  mkdir -p "$fix/scripts/nested"
  touch "$fix/scripts/alpha.sh"
  touch "$fix/scripts/beta.py"
  touch "$fix/scripts/gamma.ps1"
  touch "$fix/scripts/README.md"
  touch "$fix/scripts/noext"
  touch "$fix/scripts/nested/delta.sh"

  found=$(discover_scripts "$fix" | sed "s|^$fix/scripts/||" | tr '\n' ' ')
  assert_eq "alpha.sh beta.py nested/delta.sh " "$found" "allowlist keeps .sh and .py, recurses"

  skipped=$(discover_ignored "$fix" | sed "s|^$fix/scripts/||" | tr '\n' ' ')
  assert_eq "README.md gamma.ps1 noext " "$skipped" "everything else is ignored"

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n== link naming ==\n'
(
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fix=$(cd "$tmp" && pwd -P)

  assert_eq "smem-groups" "$(link_name_for /a/b/smem-groups.sh)" "strips .sh"
  assert_eq "sync"        "$(link_name_for /a/b/sync.py)"        "strips .py"
  assert_eq "my.tool"     "$(link_name_for /a/b/my.tool.sh)"     "strips only the last extension"
  assert_eq "plain"       "$(link_name_for /a/b/plain)"          "leaves an extensionless name alone"

  mkdir -p "$fix/scripts"
  touch "$fix/scripts/prune.sh" "$fix/scripts/prune.ps1"
  assert_eq "" "$(detect_collisions "$fix")" "prune.sh and prune.ps1 are different platforms, not a collision"

  touch "$fix/scripts/prune.py"
  assert_eq "prune" "$(detect_collisions "$fix")" "prune.sh and prune.py both install here, so they collide"

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n== install ==\n'
(
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/nested/does/not/exist/yet"

  assert_ok "install into a missing directory" "$INSTALL" --dir "$bin"
  assert_ok "symlink was created"              test -L "$bin/smem-groups"

  target=$(readlink "$bin/smem-groups")
  case $target in
    /*) pass "symlink target is absolute" ;;
    *)  fail "symlink target is absolute (got '$target')" ;;
  esac
  assert_eq "$REPO/scripts/smem-groups.sh" "$target" "symlink points at the source script"

  assert_ok "the link actually runs"    "$bin/smem-groups" --help
  assert_ok "re-running is idempotent"  "$INSTALL" --dir "$bin"
  assert_eq "1" "$(ls -1 "$bin" | wc -l | tr -d ' ')" "re-run created no duplicates"

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n== collisions ==\n'
(
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/bin"
  mkdir -p "$bin"

  printf 'not ours\n' > "$bin/smem-groups"
  assert_fail 2 "a regular file blocks the install" "$INSTALL" --dir "$bin"
  assert_eq "not ours" "$(cat "$bin/smem-groups")" "the regular file was left intact"

  assert_ok "--force overwrites the regular file" "$INSTALL" --dir "$bin" --force
  assert_ok "it is a symlink now"                 test -L "$bin/smem-groups"

  rm -f "$bin/smem-groups"
  printf 'someone elses tool\n' > "$work/foreign"
  ln -s "$work/foreign" "$bin/smem-groups"
  assert_fail 2 "a foreign symlink blocks the install" "$INSTALL" --dir "$bin"
  assert_eq "$work/foreign" "$(readlink "$bin/smem-groups")" "the foreign symlink still points where it did"

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n== uninstall ==\n'
(
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/bin"

  "$INSTALL" --dir "$bin" >/dev/null
  assert_ok "installed before uninstalling" test -L "$bin/smem-groups"

  assert_ok "uninstall exits 0"      "$INSTALL" --dir "$bin" --uninstall
  assert_eq "0" "$(ls -1 "$bin" | wc -l | tr -d ' ')" "target directory is empty"

  # A link with our name that is not ours must survive.
  printf 'someone elses tool\n' > "$work/foreign"
  ln -s "$work/foreign" "$bin/smem-groups"
  assert_ok "uninstall exits 0 with a foreign link present" "$INSTALL" --dir "$bin" --uninstall
  assert_ok "the foreign link survived"                     test -L "$bin/smem-groups"

  # So must a regular file.
  rm -f "$bin/smem-groups"
  printf 'not ours\n' > "$bin/smem-groups"
  "$INSTALL" --dir "$bin" --uninstall >/dev/null
  assert_eq "not ours" "$(cat "$bin/smem-groups")" "the regular file survived"

  assert_ok "uninstall on a missing directory exits 0" "$INSTALL" --dir "$work/never" --uninstall

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n== dry run and PATH ==\n'
(
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/bin"

  assert_ok "dry run exits 0"           "$INSTALL" --dir "$bin" --dry-run
  assert_fail 1 "dry run created nothing" test -e "$bin"

  out=$("$INSTALL" --dir "$bin" --dry-run 2>&1)
  case $out in
    *smem-groups*) pass "dry run names the link it would create" ;;
    *)             fail "dry run names the link it would create" ;;
  esac

  out=$(PATH="/usr/bin:/bin" "$INSTALL" --dir "$bin" 2>&1)
  case $out in
    *"not in your PATH"*) pass "warns when the directory is off PATH" ;;
    *)                    fail "warns when the directory is off PATH" ;;
  esac

  rm -rf "$bin"
  out=$(PATH="$bin:/usr/bin:/bin" "$INSTALL" --dir "$bin" 2>&1)
  case $out in
    *"not in your PATH"*) fail "stays quiet when the directory is on PATH" ;;
    *)                    pass "stays quiet when the directory is on PATH" ;;
  esac

  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
) || FAIL=$((FAIL + 1))

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
