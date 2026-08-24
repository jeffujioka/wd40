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
SOURCE_REPO=$(cd "$TEST_DIR/.." && pwd -P)

# One sandbox for the whole run, and one trap to take it away again.
# Everything this file creates lives under it: the copy of the repository
# the tests are aimed at, the file each section's counts come home in, and
# every scratch directory probe_shell makes.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# The installer is run against a copy, never against the working tree.
#
# install_one does `chmod +x` on every source it links, and twenty-eight of
# the runs below are the real install.sh pointed at the real repository, so
# a test run used to edit the tree it was testing. The coupling is the
# worse half of it: those assertions are written against whatever scripts/
# and shell/ happen to hold today, so adding one script would break tests
# that say nothing about it. REPO and INSTALL name the copy, and every call
# site already goes through them.
REPO="$SANDBOX/repo"
cp -a "$SOURCE_REPO" "$REPO"
INSTALL="$REPO/install.sh"

# Sandbox HOME for the whole run: install.sh (via warn_if_not_on_path /
# add_to_shell_rc) now writes to $HOME/.bashrc or $HOME/.zshrc when BIN_DIR
# is off PATH. Every test in this file must be free to leave BIN_DIR off
# PATH without risking a write to the real developer's rc file.
SMOKE_HOME="$SANDBOX/home"
mkdir -p "$SMOKE_HOME"
HOME="$SMOKE_HOME"
export HOME

PASS=0
FAIL=0
SKIP=0

# Where a section's counts come home in.
#
# A section's assertions run in a subshell, so its PASS, FAIL and SKIP are
# the subshell's own and are gone the moment it exits. That is why every
# section total used to be inflated by the two top-level assertions it had
# inherited, why the global total was always `2 passed`, and why one broken
# assertion was reported as nineteen failures. A file is the way back.
COUNTS="$SANDBOX/counts"

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# An assertion that was not run, and why.
#
# A run on a machine without zsh drops forty-one assertions, and until this
# existed it printed a summary byte-identical to a full run - so the one
# thing a reader most needed to know was the one thing the output could not
# say.
skip() {
  # skip LABEL REASON
  SKIP=$((SKIP + 1))
  printf '  skip %s (%s)\n' "$1" "$2"
}

# Something worth reading that is not a verdict.
note() { printf '  note %s\n' "$1"; }

# A section runs its assertions in a subshell, and these four helpers are
# what make that subshell reportable.
#
# The subshell used to sit on the left of `||`, which exempts a compound
# command from errexit - and the exemption reaches inside it, so every
# mkdir, cp, ln and `printf >file` that built a fixture was unguarded. A
# section whose setup failed carried on and reported whatever the
# assertions made of the wreckage, and the negative assertions passed
# *harder* for it, because the thing they check for the absence of was
# never created.
#
# Taking the subshell out of that position is only half the fix. Errexit
# has to be off in the parent across the fork, or a section that fails
# kills the run before its status can be read; and it has to be turned back
# on as the subshell's first statement, because the subshell inherits the
# `+e` it was forked under. Neither half works without the other.
section_begin() {
  # section_begin NAME
  printf '\n== %s ==\n' "$1"
  rm -f "$COUNTS"
  set +e
}

section_reset() {
  PASS=0
  FAIL=0
  SKIP=0
}

section_report() {
  printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  printf '%s %s %s\n' "$PASS" "$FAIL" "$SKIP" > "$COUNTS"
  [ "$FAIL" -eq 0 ] || exit 1
}

# A section that died before section_report leaves no counts behind, and
# that absence is the only evidence there is that its fixtures failed.
# Making a fixture failure visible is the entire point of running the body
# under errexit, so it is counted as one failure of its own rather than
# passing silently for having asserted nothing.
section_end() {
  # section_end RC
  local rc=$1 p f s
  if [ -f "$COUNTS" ]; then
    read -r p f s < "$COUNTS"
    PASS=$((PASS + p))
    FAIL=$((FAIL + f))
    SKIP=$((SKIP + s))
  else
    printf '  FAIL section aborted (rc=%s)\n' "$rc"
    FAIL=$((FAIL + 1))
  fi
  set -e
}

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

# Assert that VALUE holds no bytes at all.
#
# `assert_eq "" "$(cmd)"` cannot make that claim: command substitution
# strips every trailing newline, so a command that prints nothing and one
# that prints a bare "\n" arrive here as the same empty string. Counting
# bytes is the only way to tell the two apart, and `capture` below is how a
# caller gets a value with the byte in question still on the end of it.
assert_empty() {
  # assert_empty LABEL VALUE
  local n
  n=$(printf '%s' "$2" | wc -c | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    pass "$1"
  else
    fail "$1 ($n bytes, not none)"
    printf '       actual:   [%s]\n' "$2"
  fi
}

# Run CMD and leave its output in CAPTURED with its trailing newlines on.
#
# The result goes into a variable rather than onto stdout because stdout is
# precisely what would strip it again. Printing a sentinel byte inside the
# substitution and taking it off afterwards is the portable way to keep
# what `$(...)` throws away; bash 3.2 offers nothing better.
capture() {
  # capture CMD...
  CAPTURED=$("$@"; printf X)
  CAPTURED=${CAPTURED%X}
}

# The subshell here is not for isolation. A command killed by a signal
# makes the shell that reaped it print a job-control notice - "Terminated",
# "Segmentation fault" - to its own stderr, which is this log. Running the
# command one level down with that level's stderr closed off puts the
# notice where nobody has to read it, and `exit $?` makes the subshell die
# of its own accord rather than by the same signal, which is what stops
# this shell printing a second copy. The status arrives intact either way.
assert_ok() {
  # assert_ok LABEL CMD...
  local label=$1 rc
  shift
  set +e
  ( "$@" >/dev/null 2>&1; exit $? ) 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "$label"
  else
    fail "$label (exit $rc)"
  fi
}

assert_fail() {
  # assert_fail EXPECTED_CODE LABEL CMD...
  local expected=$1 label=$2 actual
  shift 2
  set +e
  ( "$@" >/dev/null 2>&1; exit $? ) 2>/dev/null
  actual=$?
  set -e
  assert_eq "$expected" "$actual" "$label"
}

# Exit 0 *and* nothing on stderr.
#
# assert_ok throws stderr away, so a command that exits 0 while printing
# errors is indistinguishable there from a clean run. That is how this
# suite came to be green over an installer which, pointed at an unwritable
# directory, printed two `link` lines, created nothing, and exited 0.
#
# Nothing calls this yet, on purpose: the installer has to be fixed before
# the assertions that would use it can be green, and a helper adopted
# ahead of its fix only paints the file red without telling anyone
# anything new.
assert_clean() {
  # assert_clean LABEL CMD...
  local label=$1 rc err="$SANDBOX/assert_clean.err"
  shift
  set +e
  ( "$@" >/dev/null 2>"$err"; exit $? ) 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "$label (exit $rc)"
  elif [ -s "$err" ]; then
    fail "$label (exit 0, and then wrote to stderr)"
    sed 's/^/       /' "$err"
  else
    pass "$label"
  fi
}

PATHS="$REPO/shell/wd40-paths.sh"

# shell/wd40-paths.sh claims to behave identically under bash 3.2 and zsh,
# and that is the easiest claim in the design to break without noticing:
# nothing in a bash-only test run would ever fail. So every assertion about
# it runs once per shell in this list.
#
# zsh is not installed everywhere, and a missing zsh is not a defect in
# wd40, so it is skipped with a note rather than failed.
SHELLS="bash"
if command -v zsh >/dev/null 2>&1; then
  SHELLS="bash zsh"
fi

# Run SNIPPET under SHELL and describe the result as one comparable line.
#
# The line carries a line count for each stream as well as its first line.
# Both are needed: "stdout was empty" and "stdout's first line was empty"
# are different claims, and a test that cannot tell them apart would pass
# on a function that printed a stray blank line. Collapsing a whole run
# into one string also keeps a fourteen-row table to fourteen assertions
# instead of seventy.
#
# CLEAN-PATH, when given, is the whole environment: the shell is started
# under `env -i` with that PATH and nothing else. Assigning `WD40_CLIP=`
# inside the snippet only makes the variable empty, which is one of the
# two things `_wd40_clip` treats as absent - close enough for the
# cascade, and not close enough for a claim about a machine that has
# nothing. The interpreter is resolved before `env -i` takes the PATH
# away, because otherwise `env` would look for it on the new one.
probe_shell() {
  # probe_shell SHELL SNIPPET [CLEAN-PATH]
  local sh=$1 snippet=$2 clean=${3:-} dir rc outn errn out1 err1
  # Under the run sandbox, so that the trap on it collects the two hundred
  # of these a run makes. On its own each is removed below; on an interrupt
  # none of them were.
  dir=$(mktemp -d "$SANDBOX/probe.XXXXXX")
  set +e
  if [ -n "$clean" ]; then
    ( env -i PATH="$clean" "$(command -v "$sh")" -c "$snippet" \
        >"$dir/out" 2>"$dir/err"; exit $? ) 2>/dev/null
  else
    ( "$sh" -c "$snippet" >"$dir/out" 2>"$dir/err"; exit $? ) 2>/dev/null
  fi
  rc=$?
  set -e
  outn=$(wc -l < "$dir/out" | tr -d ' ')
  errn=$(wc -l < "$dir/err" | tr -d ' ')
  out1=$(head -n 1 "$dir/out")
  err1=$(head -n 1 "$dir/err")
  rm -rf "$dir"
  printf 'rc=%s out=%s err=%s out1=[%s] err1=[%s]\n' \
    "$rc" "$outn" "$errn" "$out1" "$err1"
}

# Build a throwaway repository that install.sh can be run out of.
#
# install.sh derives REPO_ROOT from its own location and decides what it
# owns by resolving symlinks back into that root, so a fixture needs its
# own copy of the installer at its own root. Running the repository's real
# install.sh with --dir pointed at a fixture would test the real scripts/
# and shell/ instead of the ones the test just laid out.
make_fixture() {
  # make_fixture DIR
  mkdir -p "$1"
  cp "$INSTALL" "$1/install.sh"
  chmod +x "$1/install.sh"
}

section_begin 'run sandbox'
(
  set -e
  section_reset

  # Everything below this point is aimed at the copy, so a `cp -a` that
  # quietly dropped a file, a mode or a symlink would leave the whole run
  # testing something other than the repository - and saying so afterwards
  # is no use, because by then the assertions have already agreed with the
  # wrong tree.
  #
  # Content and modes are asked about separately because `diff -r` follows
  # symlinks and says nothing whatever about permissions, which is the one
  # thing the copy exists to protect.
  assert_empty "the copy is the repository, byte for byte" \
    "$(diff -r "$SOURCE_REPO" "$REPO" 2>&1 || true)"

  # `stat -c` is GNU and `stat -f` is BSD; the first ten characters of an
  # `ls -ld` line are neither, and they carry the file's type as well as
  # its mode, so a symlink that arrived as a regular file shows up here too.
  modes_of() {
    # modes_of DIR
    ( cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
        printf '%s %s\n' "$(ls -ld "$p" | cut -c1-10)" "$p"
      done )
  }
  assert_eq "$(modes_of "$SOURCE_REPO")" "$(modes_of "$REPO")" \
    "and carries every mode the repository had"

  # The one assertion that has to hold for any of the others to be safe to
  # run at all. install.sh appends to ~/.bashrc and ~/.zshrc whenever
  # BIN_DIR is off PATH, and most of the runs below put it off PATH on
  # purpose.
  assert_eq "$SANDBOX/home" "$HOME" "HOME is the sandbox and not the developer's"

  section_report
)
section_end $?

section_begin 'bash 3.2 and BSD portability'
(
  set -e
  section_reset

  # Every file scanned below claims bash 3.2 in its header, and the claim
  # is the one thing this suite cannot test by running anything: it
  # resolves `bash` through PATH, which here is bash 5 and on macOS is
  # usually a Homebrew build, so the half of the matrix that exists to
  # defend the claim never runs on the version in question. Installing bash
  # 3.2 to fix that is not on offer, so the claim is guarded statically
  # instead - and the version that did run is reported rather than assumed.
  note "bash is $(command -v bash) ($(bash --version | sed -n '1p'))"
  if [ "$SHELLS" = "bash" ]; then
    note "zsh is not on PATH; the assertions that need one are skipped below"
  else
    note "zsh is $(command -v zsh) ($(zsh --version))"
  fi

  # Reading the raw text would fail on the documentation of the very rule
  # being enforced: every construct on the list below is named in these
  # files' headers, in prose, precisely because it is forbidden. So the
  # text is scanned first and the constructs are looked for in what is
  # left.
  #
  # This is a scanner and not a shell parser. It follows single quotes,
  # double quotes, backslash escapes, here-documents, and the `#` that
  # opens a comment only at the start of a word, and it starts each line
  # afresh - so a string spanning several lines is read as code. That is
  # deliberate: the failure it produces is a false positive, which is loud
  # and gets fixed, rather than a false negative, which is silent and is
  # the failure this whole section exists to prevent.
  #
  # The program itself lives in a quoted here-document because a quoted
  # here-document is data, and the scanner skips it. A scanner that read
  # its own source as shell would be the first thing to trip it.
  STRIPPER=$(cat <<'AWK'
  heredoc != "" {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line == heredoc) heredoc = ""
    print ""
    next
  }
  {
    out = ""
    q = ""
    n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q == "s") { if (c == "\047") q = ""; continue }
      if (q == "d") {
        if (c == "\\") { i++; continue }
        if (c == "\"") q = ""
        continue
      }
      if (c == "\\")   { i++; out = out " "; continue }
      if (c == "\047") { q = "s"; out = out " "; continue }
      if (c == "\"")   { q = "d"; out = out " "; continue }
      if (c == "#" && (out == "" || substr(out, length(out), 1) ~ /[[:space:];&|(]/)) break
      out = out c
    }
    print out
    if (index(out, "<<") > 0 && match($0, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      w = substr($0, RSTART, RLENGTH)
      sub(/^<<-?[[:space:]]*/, "", w)
      gsub(/[\047"]/, "", w)
      heredoc = w
    }
  }
AWK
)

  # One pass per file rather than one per file and construct, with the name
  # and line number carried along so a hit can be gone straight to.
  #
  # The list is every file this repository ships that claims bash 3.2.
  # scripts/wd40.sh is on it because it was written under the claim and is
  # the newest of them, which makes it the likeliest to acquire a bash 4
  # habit; scripts/smem-groups.sh is on it because it says the same thing
  # in its own header, about `declare -A` by name.
  code="$SANDBOX/portability-code"
  : > "$code"
  for f in install.sh scripts/smem-groups.sh scripts/wd40.sh \
           shell/wd40-paths.sh test/smoke.sh; do
    awk "$STRIPPER" "$REPO/$f" |
      awk -v name="$f" '{ printf "%s:%d: %s\n", name, NR, $0 }' >> "$code"
  done

  # `--` before the pattern, and it is the difference between a guard and a
  # decoration. `find -printf`'s pattern begins with `-p`, grep read it as a
  # flag bundle, and answered `invalid option -- 'p'` with status 2; `|| true`
  # then swallowed the status, `hits` came back empty, and the row passed
  # unconditionally. A real `find . -printf '%p\n'` planted in install.sh was
  # reported as `ok no find -printf`. Every future pattern opening with `-`
  # inherited the same fault, which is why the fix is `--` here rather than a
  # rewritten pattern there.
  #
  # The two probes below carry `--` for the same reason even though their
  # patterns are literals that begin with a letter: the rule is about where
  # the pattern comes from, not about what today's happens to say.
  forbids() {
    # forbids LABEL PATTERN
    local hits
    hits=$(grep -E -- "$2" "$code" || true)
    if [ -z "$hits" ]; then
      pass "no $1"
    else
      fail "no $1"
      printf '%s\n' "$hits" | sed 's/^/       /'
    fi
  }

  # The list the two headers forbid, as patterns rather than as prose. The
  # flag forms are written to catch the flag wherever it sits in a bundle,
  # so `grep -rn` is caught by the same row as `grep -r`.
  #
  # The fields are split on '@' rather than the '|' used by the table in
  # == fp contract ==, because almost every pattern here is an
  # alternation and one of them is `|&` itself.
  while IFS='@' read -r label pattern; do
    [ -n "$label" ] || continue
    forbids "$label" "$pattern"
  done <<'CONSTRUCTS'
associative arrays@(declare|typeset|local)[[:space:]]+-[A-Za-z]*A
${var,,}@\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)
mapfile@(^|[^A-Za-z0-9_.-])mapfile([^A-Za-z0-9_-]|$)
readarray@(^|[^A-Za-z0-9_.-])readarray([^A-Za-z0-9_-]|$)
globstar@globstar
readlink -f@readlink[[:space:]]+-[A-Za-z]*f
realpath@(^|[^A-Za-z0-9_.-])realpath([^A-Za-z0-9_-]|$)
timeout@(^|[^A-Za-z0-9_.-])timeout([^A-Za-z0-9_-]|$)
seq@(^|[^A-Za-z0-9_.-])seq([^A-Za-z0-9_-]|$)
grep -P@grep[[:space:]]+-[A-Za-z]*P
grep -r@grep[[:space:]]+-[A-Za-z]*[rR]
sed -i@sed[[:space:]]+-[A-Za-z]*i
sed -r@sed[[:space:]]+-[A-Za-z]*r
find -printf@-printf([^A-Za-z0-9_-]|$)
stat -c@stat[[:space:]]+-[A-Za-z]*c
echo -e@echo[[:space:]]+-[A-Za-z]*e
echo -n@echo[[:space:]]+-[A-Za-z]*n
&>@&>
|&@\|&
coproc@(^|[^A-Za-z0-9_.-])coproc([^A-Za-z0-9_-]|$)
wait -n@wait[[:space:]]+-[A-Za-z]*n
shopt@(^|[^A-Za-z0-9_.-])shopt([^A-Za-z0-9_-]|$)
CONSTRUCTS

  # A guard that cannot fire is worse than no guard at all, and the twenty-
  # two assertions above stay green whether the scanner works or returns
  # nothing at all. These two are the difference between the two states.
  probe="$SANDBOX/portability-probe.sh"
  {
    printf '# a comment that names realpath\n'
    printf 'x="realpath in a double-quoted string"\n'
    printf "y='realpath in a single-quoted one'\n"
  } > "$probe"
  assert_empty "prose and quoted text are read as neither" \
    "$(awk "$STRIPPER" "$probe" | grep -E -- 'realpath' || true)"

  printf 'realpath /tmp\n' >> "$probe"
  assert_eq "realpath /tmp" \
    "$(awk "$STRIPPER" "$probe" | grep -E -- 'realpath' | sed 's/^ *//;s/ *$//')" \
    "and a real use of one is read as code"

  # And the pattern that could not be looked for until `--` was added. A row
  # of the table above is only worth its line if planting the construct it
  # names turns it red, and this is the one row where planting it did not.
  printf 'find . -printf "%%p\\n"\n' >> "$probe"
  assert_eq "find . -printf" \
    "$(awk "$STRIPPER" "$probe" | grep -E -- '-printf([^A-Za-z0-9_-]|$)' | sed 's/^ *//;s/ *$//')" \
    "and a pattern beginning with a dash reaches grep as a pattern"

  section_report
)
section_end $?

section_begin 'argument handling'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  line() { printf '%s\n' "$1" | sed -n "$2p"; }

  assert_clean "--help exits 0"        "$INSTALL" --help
  assert_clean "and so does -h"        "$INSTALL" -h
  assert_fail 1 "unknown flag exits 1" "$INSTALL" --nonsense

  # THE USAGE TEXT ITSELF
  #
  # Only its exit code was ever asserted, so every word of it was free to
  # drift away from the program - and two of its lines are the only written
  # statement of the precedence rules anywhere in the repository. It is
  # asserted line by line for the same reason the generated loader block is:
  # a summary assertion passes over exactly the character somebody edits.
  usage_text=$("$INSTALL" --help)
  assert_eq "16" "$(printf '%s\n' "$usage_text" | wc -l | tr -d ' ')" "usage is sixteen lines"
  assert_eq 'Usage: install.sh [options]' "$(line "$usage_text" 1)" "line 1 names the command"
  assert_empty "line 2 is blank" "$(line "$usage_text" 2)"
  assert_eq '  -d, --dir DIR        directory for script symlinks (default: ~/.local/sbin)' \
    "$(line "$usage_text" 3)" "line 3 documents --dir and its short form"
  assert_eq '  -s, --shell-dir DIR  directory for shell files (default: ~/.zsh_aliases.d)' \
    "$(line "$usage_text" 4)" "line 4 documents --shell-dir and its short form"
  # --rc has no short form, and takes four lines because the surprising half
  # of it needs saying: a file this installer does not recognise is searched
  # for itself and not as part of any shell's startup chain. A user pointing
  # it at ~/.config/fish/config.fish has to be able to find that out here.
  assert_eq '      --rc FILE        startup file to configure; repeatable, replaces the' \
    "$(line "$usage_text" 5)" "line 5 opens --rc and says it is repeatable"
  assert_eq '                       default set of ~/.bashrc and ~/.zshrc. A FILE this' \
    "$(line "$usage_text" 6)" "line 6 names the default set it replaces"
  assert_eq '                       installer does not recognise is searched only for' \
    "$(line "$usage_text" 7)" "line 7 opens the unrecognised-file rule"
  assert_eq '                       itself, not as part of any shell'"'"'s startup chain' \
    "$(line "$usage_text" 8)" "line 8 closes it"
  assert_eq '  -n, --dry-run        print what would happen; change nothing' \
    "$(line "$usage_text" 9)" "line 9 documents --dry-run"
  assert_eq '  -f, --force          overwrite existing files that are not ours' \
    "$(line "$usage_text" 10)" "line 10 documents --force"
  assert_eq '  -u, --uninstall      remove this repository'"'"'s symlinks' \
    "$(line "$usage_text" 11)" "line 11 documents --uninstall"
  assert_eq '  -h, --help           show this help' \
    "$(line "$usage_text" 12)" "line 12 documents --help"
  assert_empty "line 13 is blank" "$(line "$usage_text" 13)"
  assert_eq 'Script directory precedence: --dir > $WD40_BIN_DIR > ~/.local/sbin' \
    "$(line "$usage_text" 14)" "line 14 states the script directory precedence"
  assert_eq 'Shell directory precedence:  --shell-dir > $WD40_SHELL_DIR > ~/.zsh_aliases.d' \
    "$(line "$usage_text" 15)" "line 15 states the shell directory precedence"
  # The one line that says the installer no longer picks a shell. It is the
  # whole of the written statement of that rule in the program, which is why
  # it is asserted rather than left to drift.
  assert_eq 'Startup files: every one of ~/.bashrc and ~/.zshrc that exists, unless --rc' \
    "$(line "$usage_text" 16)" "line 16 states that every known rc file is a target"

  # And the defaults it names are the defaults the program uses. Asserting
  # the sentence and the behaviour separately is what lets the two drift;
  # this reads the default out of the text and holds the program to it.
  set +e
  out=$("$fix/install.sh" --dry-run 2>&1)
  set -e
  case $out in
    *"$home/.local/sbin/tool"*)   pass "and a run with no flags uses the ~/.local/sbin it names" ;;
    *) fail "and a run with no flags uses the ~/.local/sbin it names" ;;
  esac
  case $out in
    *"$home/.zsh_aliases.d/lib.sh"*) pass "and the ~/.zsh_aliases.d it names as well" ;;
    *) fail "and the ~/.zsh_aliases.d it names as well" ;;
  esac

  # --help is something asked for and goes to stdout; usage printed because
  # an argument was wrong is a diagnostic and goes to stderr, where it
  # cannot be mistaken for a result.
  "$INSTALL" --help >"$work/h.out" 2>"$work/h.err"
  assert_eq 'Usage: install.sh [options]' "$(sed -n '1p' "$work/h.out")" "--help writes usage to stdout"
  assert_empty "and nothing at all to stderr" "$(cat "$work/h.err")"
  set +e
  "$INSTALL" --nonsense >"$work/n.out" 2>"$work/n.err"
  set -e
  assert_empty "an unknown argument writes nothing to stdout" "$(cat "$work/n.out")"
  assert_eq 'Usage: install.sh [options]' "$(sed -n '1p' "$work/n.err")" "and the usage it prints goes to stderr"
  assert_eq "Error: unknown argument '--nonsense'" "$(sed -n '$p' "$work/n.err")" "and it names the argument"

  # AN EMPTY VALUE ON THE =-JOINED FORM
  #
  # `--dir=` was taken as a real directory. The installer went on to
  # announce `link /tool` and, unprivileged, failed at the symlink; under
  # sudo it would have left litter at the root of the filesystem. It is the
  # same mistake as `--dir` with nothing after it, so it gets the same
  # answer, and the whole of the output is asserted because refusing early
  # is half the claim.
  set +e
  out=$("$fix/install.sh" --dir= --shell-dir "$work/sd-empty" --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--dir= with an empty value is refused"
  assert_eq "Error: --dir requires an argument" "$out" \
    "and says exactly what --dir with no argument says, and nothing else"

  set +e
  out=$("$fix/install.sh" --dir "$work/bin-empty" --shell-dir= --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--shell-dir= with an empty value is refused too"
  assert_eq "Error: --shell-dir requires an argument" "$out" \
    "and says exactly what --shell-dir with no argument says"

  assert_fail 1 "and nothing was linked at the root of the filesystem" test -e /tool

  # THE =-JOINED FORMS AND THE SHORT FLAGS
  #
  # Six spellings with no assertion of any kind between them until now. A
  # short flag is one character away from another short flag, and the
  # =-joined form is parsed by a different arm of the case than the spaced
  # one it is meant to be identical to.
  "$fix/install.sh" --dir="$work/bin-eq" --shell-dir="$work/sd-eq" >/dev/null 2>&1
  assert_ok "--dir= takes a value"       test -L "$work/bin-eq/tool"
  assert_ok "and so does --shell-dir="   test -L "$work/sd-eq/lib.sh"

  "$fix/install.sh" -d "$work/bin-short" -s "$work/sd-short" >/dev/null 2>&1
  assert_ok "-d is --dir"        test -L "$work/bin-short/tool"
  assert_ok "and -s is --shell-dir" test -L "$work/sd-short/lib.sh"

  set +e
  out=$("$fix/install.sh" -d "$work/bin-n" -s "$work/sd-n" -n 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "-n exits 0"
  assert_fail 1 "and is --dry-run: it created nothing" test -e "$work/bin-n"
  case $out in
    *"Dry run. Nothing will be changed."*) pass "and said so" ;;
    *)                                     fail "and said so" ;;
  esac

  printf 'not ours\n' > "$work/bin-short/tool"
  "$fix/install.sh" -d "$work/bin-short" -s "$work/sd-short" -f >/dev/null 2>&1
  assert_ok "-f is --force: it replaced a file that was not ours" test -L "$work/bin-short/tool"

  "$fix/install.sh" -d "$work/bin-short" -s "$work/sd-short" -u >/dev/null 2>&1
  assert_fail 1 "-u is --uninstall: the script link went" test -e "$work/bin-short/tool"
  assert_fail 1 "and the shell link with it"              test -e "$work/sd-short/lib.sh"

  section_report
)
section_end $?

section_begin 'resolve_path'
(
  set -e
  section_reset
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

  # A failure here is a returned status and a line on stderr, never a dead
  # process. resolve_path used to `die`, and every one of its callers reads
  # it as `current=$(resolve_path ...)` - so the exit killed the command
  # substitution and nothing else, the caller carried on with an empty
  # $current, and the user was told `symlink points outside this repo ()`.
  # The empty parenthesis was the whole of the evidence. Once errexit was
  # live the same die took the entire run down instead, which is honest and
  # still wrong: one unresolvable destination is no reason to abandon the
  # others.
  #
  # Calling it on a line of its own is what makes the claim testable. A
  # `die` in here would take this section's subshell with it and the run
  # would report `section aborted`; every assertion after this point is
  # therefore also evidence that it returned.
  err="$real/resolve.err"
  set +e
  resolve_path "$real/a" >"$real/resolve.out" 2>"$err"
  rc=$?
  set -e
  assert_eq "1" "$rc" "a symlink cycle is a failed status"
  pass "and the caller lives to read it"
  assert_empty "and nothing is printed on stdout" "$(cat "$real/resolve.out")"
  case $(cat "$err") in
    *"symlink cycle detected resolving '$real/a'"*)
      pass "and the reason names the path on stderr" ;;
    *) fail "and the reason names the path on stderr" ;;
  esac

  # The other way out of the function, which is a different branch and was
  # a different die: the final component may be missing, but its parent
  # directory has to exist.
  printf 'x\n' > "$real/notadir"
  set +e
  resolve_path "$real/notadir/child" >"$real/resolve.out" 2>"$err"
  rc=$?
  set -e
  assert_eq "1" "$rc" "a parent that is not a directory is a failed status too"
  assert_empty "and prints nothing on stdout either" "$(cat "$real/resolve.out")"
  case $(cat "$err") in
    *"cannot resolve '$real/notadir/child'"*)
      pass "and that reason names the path as well" ;;
    *) fail "and that reason names the path as well" ;;
  esac

  section_report
)
section_end $?

section_begin 'discovery'
(
  set -e
  section_reset
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

  # A SYMLINK UNDER scripts/
  #
  # Not followed and not installed, and that half is a decision rather than
  # an accident of `find -type f`: ownership is decided by resolving a
  # destination back into REPO_ROOT, and a link under scripts/ pointing
  # anywhere else would install a file this repository does not own under a
  # name that says it does.
  #
  # What was an accident was the silence. Discovery skipped it, and so did
  # the report of what was ignored, so a contributor who added one got no
  # link, no line and no error - the only evidence being a command that
  # never appeared. detect_symlinks is the answer to that half: passed
  # over, and said so.
  ln -s "$fix/scripts/alpha.sh" "$fix/scripts/linked.sh"
  found=$(discover_scripts "$fix" | sed "s|^$fix/scripts/||" | tr '\n' ' ')
  assert_eq "alpha.sh beta.py nested/delta.sh " "$found" \
    "a symlink under scripts/ is not discovered, because its target is not ours to resolve"
  skipped=$(discover_ignored "$fix" | sed "s|^$fix/scripts/||" | tr '\n' ' ')
  assert_eq "README.md gamma.ps1 noext " "$skipped" \
    "and it is not one of the extension skips, which are a different reason"
  seen=$(detect_symlinks "$fix" | sed "s|^$fix/||" | tr '\n' ' ')
  assert_eq "scripts/linked.sh " "$seen" \
    "but detect_symlinks names it, so it is no longer invisible in both directions"

  # A symlink is reported for being a symlink and for nothing else, so it
  # is never named twice: `find -type f` cannot see one, which is what
  # keeps the extension stanza and the symlink stanza from both claiming
  # the same path.
  ln -s "$fix/scripts/README.md" "$fix/scripts/linked.md"
  skipped=$(discover_ignored "$fix" | sed "s|^$fix/scripts/||" | tr '\n' ' ')
  assert_eq "README.md gamma.ps1 noext " "$skipped" \
    "a symlink with an uninstallable extension is still not an extension skip"
  seen=$(detect_symlinks "$fix" | sed "s|^$fix/||" | tr '\n' ' ')
  assert_eq "scripts/linked.md scripts/linked.sh " "$seen" \
    "and it is named once, for the one reason that applies to it"

  # A symlink to a *directory* is the same rule and the larger loss: find
  # does not descend into one, so every file underneath it is invisible as
  # well, and one line naming the link is the only notice there can be.
  mkdir -p "$fix/elsewhere"
  touch "$fix/elsewhere/hidden.sh"
  ln -s "$fix/elsewhere" "$fix/scripts/linkdir"
  found=$(discover_scripts "$fix" | sed "s|^$fix/scripts/||" | tr '\n' ' ')
  assert_eq "alpha.sh beta.py nested/delta.sh " "$found" \
    "a symlinked directory under scripts/ is not descended into"
  seen=$(detect_symlinks "$fix" | sed "s|^$fix/||" | tr '\n' ' ')
  assert_eq "scripts/linkdir scripts/linked.md scripts/linked.sh " "$seen" \
    "and it is named as well, so what is under it is not lost in silence"

  section_report
)
section_end $?

section_begin 'link naming'
(
  set -e
  section_reset
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
  capture detect_collisions "$fix"
  assert_empty "prune.sh and prune.ps1 are different platforms, not a collision" "$CAPTURED"

  touch "$fix/scripts/prune.py"
  assert_eq "prune" "$(detect_collisions "$fix")" "prune.sh and prune.py both install here, so they collide"

  section_report
)
section_end $?

section_begin 'shell file discovery and naming'
(
  set -e
  section_reset
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fix=$(cd "$tmp" && pwd -P)

  # The shell/ allowlist is narrower than the one next door on purpose: a
  # .py file is installable as a script and meaningless as something an
  # interactive shell sources.
  assert_ok   "the shell allowlist takes .sh"        is_installable_shell_file /a/b/x.sh
  assert_fail 1 "the shell allowlist refuses .py"    is_installable_shell_file /a/b/x.py
  assert_fail 1 "the shell allowlist refuses .md"    is_installable_shell_file /a/b/x.md
  assert_fail 1 "the shell allowlist refuses no extension" is_installable_shell_file /a/b/x

  # The extension survives here, which is the same reasoning that strips it
  # for scripts/ reaching the opposite conclusion: a loader globbing *.sh
  # would pass a link named `wd40-paths` over in silence.
  assert_eq "wd40-paths.sh" "$(shell_link_name_for /a/b/wd40-paths.sh)" "keeps the .sh extension"
  assert_eq "my.tool.sh"    "$(shell_link_name_for /a/b/my.tool.sh)"    "keeps every dot in the name"
  assert_eq "plain"         "$(shell_link_name_for /a/b/plain)"         "leaves an extensionless name alone"

  # A clone with no shell/ directory is an older clone, not an error.
  capture discover_shell_files "$fix"
  assert_empty "a missing shell/ yields nothing"   "$CAPTURED"
  capture discover_ignored_shell_files "$fix"
  assert_empty "a missing shell/ ignores nothing" "$CAPTURED"
  capture detect_symlinks "$fix"
  assert_empty "and holds no symlinks to report"  "$CAPTURED"

  mkdir -p "$fix/shell/nested"
  touch "$fix/shell/alpha.sh"
  touch "$fix/shell/beta.py"
  touch "$fix/shell/README.md"
  touch "$fix/shell/noext"
  touch "$fix/shell/nested/delta.sh"

  found=$(discover_shell_files "$fix" | sed "s|^$fix/shell/||" | tr '\n' ' ')
  assert_eq "alpha.sh nested/delta.sh " "$found" "allowlist keeps only .sh, and recurses"

  skipped=$(discover_ignored_shell_files "$fix" | sed "s|^$fix/shell/||" | tr '\n' ' ')
  assert_eq "README.md beta.py noext " "$skipped" "everything else is ignored, .py included"

  # The same on this side, and asserted separately because these are two
  # functions rather than one. The report of them is a single function for
  # both directories, though, because the rule that passes a symlink over
  # does not depend on which of the two allowlists would have judged it.
  ln -s "$fix/shell/alpha.sh" "$fix/shell/linked.sh"
  found=$(discover_shell_files "$fix" | sed "s|^$fix/shell/||" | tr '\n' ' ')
  assert_eq "alpha.sh nested/delta.sh " "$found" \
    "a symlink under shell/ is not discovered either, for the same reason"
  skipped=$(discover_ignored_shell_files "$fix" | sed "s|^$fix/shell/||" | tr '\n' ' ')
  assert_eq "README.md beta.py noext " "$skipped" \
    "and is not an extension skip on this side either"
  seen=$(detect_symlinks "$fix" | sed "s|^$fix/||" | tr '\n' ' ')
  assert_eq "shell/linked.sh " "$seen" "while detect_symlinks names it here too"

  # A collision is a property of a destination, not of a name.
  mkdir -p "$fix/scripts"
  touch "$fix/scripts/alpha.sh"
  capture detect_shell_collisions "$fix"
  assert_empty "scripts/alpha.sh and shell/alpha.sh land in different directories" "$CAPTURED"
  capture detect_collisions "$fix"
  assert_empty "and neither is a script collision" "$CAPTURED"

  # One function, both directories, one list: a run has one report to make
  # and the reader should not have to assemble it from two.
  ln -s "$fix/scripts/alpha.sh" "$fix/scripts/linked.sh"
  seen=$(detect_symlinks "$fix" | sed "s|^$fix/||" | tr '\n' ' ')
  assert_eq "scripts/linked.sh shell/linked.sh " "$seen" \
    "and one call reports both directories"

  # Two files under shell/ do collide, which recursive discovery makes
  # reachable: shell/a/x.sh and shell/b/x.sh both want SHELL_DIR/x.sh.
  mkdir -p "$fix/shell/a" "$fix/shell/b"
  touch "$fix/shell/a/x.sh" "$fix/shell/b/x.sh"
  assert_eq "x.sh" "$(detect_shell_collisions "$fix")" "two shell files claiming one name collide"

  section_report
)
section_end $?

section_begin 'install'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/nested/does/not/exist/yet"
  # Every run of the real installer now lands two kinds of artefact, so
  # --shell-dir is given explicitly rather than left to default into the
  # sandboxed HOME. Two tests sharing ~/.zsh_aliases.d would make each
  # one's result depend on what the other left behind.
  sdir="$work/aliases.d"

  # Not assert_clean, either here or on the re-run below: BIN_DIR is off
  # PATH and a shell file lands, so both of the installer's advisory
  # blocks fire and stderr is legitimately full.
  assert_ok "install into a missing directory" "$INSTALL" --dir "$bin" --shell-dir "$sdir"
  assert_ok "symlink was created"              test -L "$bin/smem-groups"

  target=$(readlink "$bin/smem-groups")
  case $target in
    /*) pass "symlink target is absolute" ;;
    *)  fail "symlink target is absolute (got '$target')" ;;
  esac
  assert_eq "$REPO/scripts/smem-groups.sh" "$target" "symlink points at the source script"

  assert_ok "the link actually runs"    "$bin/smem-groups" --help

  # The count is read off the first run rather than written down. A
  # literal `1` was a statement about how many scripts this repository
  # happened to hold on the day it was written, and it went red the moment
  # a second one arrived - having said nothing whatever about duplicates,
  # which are what it is for.
  linked=$(ls -1 "$bin" | wc -l | tr -d ' ')
  assert_ok "re-running is idempotent"  "$INSTALL" --dir "$bin" --shell-dir "$sdir"
  assert_eq "$linked" "$(ls -1 "$bin" | wc -l | tr -d ' ')" "re-run created no duplicates"

  section_report
)
section_end $?

section_begin 'installing shell files'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  # A HOME per block, so nothing here can be decided by a startup file
  # another block left in the run-wide sandbox.
  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\necho tool\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'            > "$fix/shell/lib.sh"
  printf 'not a shell file\n'     > "$fix/shell/notes.md"
  # An ignored file on the scripts/ side as well. report_ignored reads both
  # halves and only the shell/ half had ever been exercised, so the
  # discover_ignored call next to it was free to be wrong.
  printf 'not a script\n'         > "$fix/scripts/notes.txt"

  bin="$work/bin"
  sdir="$work/aliases.d"
  "$fix/install.sh" --dir "$bin" --shell-dir "$sdir" >/dev/null 2>&1

  assert_ok     "SHELL_DIR is created when absent"   test -d "$sdir"
  assert_ok     "the link keeps the .sh extension"   test -L "$sdir/lib.sh"
  assert_fail 1 "no extensionless link is made"      test -e "$sdir/lib"
  assert_fail 1 "a non-.sh file under shell/ is not linked" test -e "$sdir/notes.md"

  target=$(readlink "$sdir/lib.sh")
  case $target in
    "$fix"/*) pass "the link resolves back into the repository" ;;
    *)        fail "the link resolves back into the repository (got '$target')" ;;
  esac
  assert_eq "$fix/shell/lib.sh" "$target" "the link points at the source file"

  # install_one chmod +x's the source before linking, and a symlink reports
  # its target's permissions. The author's loader sources a file only when
  # it is executable, so this bit is load-bearing.
  assert_ok "the link is executable" test -x "$sdir/lib.sh"

  # SHELL_DIR defaults into the user's home directory, so creating an empty
  # one on a clone that ships nothing sourceable is litter nobody asked for
  # and nothing removes.
  fixnone="$work/repo-nothing-sourceable"
  make_fixture "$fixnone"
  mkdir -p "$fixnone/scripts" "$fixnone/shell"
  printf '#!/bin/sh\n:\n' > "$fixnone/scripts/t.sh"
  printf 'notes\n'        > "$fixnone/shell/notes.md"
  "$fixnone/install.sh" --dir "$work/bin-none" --shell-dir "$work/sd-none" >/dev/null 2>&1
  assert_fail 1 "SHELL_DIR is not created when shell/ holds nothing installable" test -e "$work/sd-none"

  # A missing shell/ is an older clone, not an error: the scripts still
  # install and the run says nothing about a directory it has no use for.
  fixold="$work/repo-no-shell-dir"
  make_fixture "$fixold"
  mkdir -p "$fixold/scripts"
  printf '#!/bin/sh\n:\n' > "$fixold/scripts/t.sh"
  set +e
  out=$("$fixold/install.sh" --dir "$work/bin-old" --shell-dir "$work/sd-old" 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "a repository with no shell/ still installs"
  assert_ok     "and its script was linked" test -L "$work/bin-old/t"
  assert_fail 1 "and SHELL_DIR was not created" test -e "$work/sd-old"
  case $out in
    *"$work/sd-old"*) fail "and nothing is said about SHELL_DIR" ;;
    *)                pass "and nothing is said about SHELL_DIR" ;;
  esac

  # Same name, two kinds, two destinations, two naming rules: not a clash.
  fixboth="$work/repo-both-kinds"
  make_fixture "$fixboth"
  mkdir -p "$fixboth/scripts" "$fixboth/shell"
  printf '#!/bin/sh\n:\n' > "$fixboth/scripts/foo.sh"
  printf 'FOO=1\n'        > "$fixboth/shell/foo.sh"
  set +e
  "$fixboth/install.sh" --dir "$work/bin-both" --shell-dir "$work/sd-both" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "0" "$rc" "scripts/foo.sh and shell/foo.sh are not a collision"
  assert_ok     "the script landed as foo"        test -L "$work/bin-both/foo"
  assert_ok     "the shell file landed as foo.sh" test -L "$work/sd-both/foo.sh"

  # Two under shell/ are, and the installer refuses to pick a winner.
  fixdupe="$work/repo-shell-dupes"
  make_fixture "$fixdupe"
  mkdir -p "$fixdupe/scripts" "$fixdupe/shell/a" "$fixdupe/shell/b"
  printf '#!/bin/sh\n:\n' > "$fixdupe/scripts/t.sh"
  printf 'A=1\n'          > "$fixdupe/shell/a/x.sh"
  printf 'B=1\n'          > "$fixdupe/shell/b/x.sh"
  set +e
  out=$("$fixdupe/install.sh" --dir "$work/bin-dupe" --shell-dir "$work/sd-dupe" 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "shell/a/x.sh and shell/b/x.sh are a collision"
  case $out in
    *"two shell files claim the same name"*) pass "and the message names the problem" ;;
    *)                                       fail "and the message names the problem" ;;
  esac

  # Nothing linked in either destination is still exit 2.
  blockedbin="$work/bin-blocked"
  blockedsd="$work/sd-blocked"
  mkdir -p "$blockedbin" "$blockedsd"
  printf 'not ours\n' > "$blockedbin/tool"
  printf 'not ours\n' > "$blockedsd/lib.sh"
  assert_fail 2 "neither kind linking anything is exit 2" \
    "$fix/install.sh" --dir "$blockedbin" --shell-dir "$blockedsd"

  # --dry-run prints both kinds, reports what it passed over, creates nothing.
  set +e
  out=$("$fix/install.sh" --dir "$work/bin-dry" --shell-dir "$work/sd-dry" --dry-run 2>&1)
  set -e
  assert_fail 1 "--dry-run created no script directory" test -e "$work/bin-dry"
  assert_fail 1 "--dry-run created no shell directory"  test -e "$work/sd-dry"
  case $out in
    *"$work/bin-dry/tool"*) pass "--dry-run names the script link it would create" ;;
    *)                      fail "--dry-run names the script link it would create" ;;
  esac
  case $out in
    *"$work/sd-dry/lib.sh"*) pass "--dry-run names the shell link it would create" ;;
    *)                       fail "--dry-run names the shell link it would create" ;;
  esac
  case $out in
    *Ignored*notes.md*) pass "--dry-run reports the ignored shell file" ;;
    *)                  fail "--dry-run reports the ignored shell file" ;;
  esac
  case $out in
    *Ignored*notes.txt*) pass "and the ignored script file, which is the other half of report_ignored" ;;
    *)                   fail "and the ignored script file, which is the other half of report_ignored" ;;
  esac
  assert_fail 1 "and neither of them was linked" test -e "$work/bin-dry/notes"

  # --shell-dir > $WD40_SHELL_DIR > ~/.zsh_aliases.d, checked one step at a
  # time so a failure says which step broke.
  WD40_SHELL_DIR="$work/sd-env-loses" \
    "$fix/install.sh" --dir "$work/bin-p1" --shell-dir "$work/sd-flag-wins" >/dev/null 2>&1
  assert_ok     "--shell-dir wins"                 test -L "$work/sd-flag-wins/lib.sh"
  assert_fail 1 "and WD40_SHELL_DIR was not used"  test -e "$work/sd-env-loses"

  WD40_SHELL_DIR="$work/sd-env-wins" \
    "$fix/install.sh" --dir "$work/bin-p2" >/dev/null 2>&1
  assert_ok     "WD40_SHELL_DIR wins over the default" test -L "$work/sd-env-wins/lib.sh"
  assert_fail 1 "and the default was not used"         test -e "$home/.zsh_aliases.d"

  "$fix/install.sh" --dir "$work/bin-p3" >/dev/null 2>&1
  assert_ok "the default is ~/.zsh_aliases.d" test -L "$home/.zsh_aliases.d/lib.sh"

  # --dir > $WD40_BIN_DIR > ~/.local/sbin, the other half of the same rule.
  # The string WD40_BIN_DIR did not appear anywhere in this file, so the
  # environment variable the usage text documents had never been set by a
  # test - and the two halves are two separate lines of install.sh, only
  # one of which would be fixed by accident.
  WD40_BIN_DIR="$work/bin-env-loses" \
    "$fix/install.sh" --dir "$work/bin-flag-wins" --shell-dir "$work/sd-b1" >/dev/null 2>&1
  assert_ok     "--dir wins over WD40_BIN_DIR"  test -L "$work/bin-flag-wins/tool"
  assert_fail 1 "and WD40_BIN_DIR was not used" test -e "$work/bin-env-loses"

  WD40_BIN_DIR="$work/bin-env-wins" \
    "$fix/install.sh" --shell-dir "$work/sd-b2" >/dev/null 2>&1
  assert_ok     "WD40_BIN_DIR wins over the default" test -L "$work/bin-env-wins/tool"
  assert_fail 1 "and the default was not used"       test -e "$home/.local/sbin"

  "$fix/install.sh" --shell-dir "$work/sd-b3" >/dev/null 2>&1
  assert_ok "the default is ~/.local/sbin" test -L "$home/.local/sbin/tool"

  # TWO SCRIPTS CLAIMING ONE COMMAND NAME, END TO END
  #
  # Its shell-file twin is asserted above, message and all; this half had
  # only ever had its exit code looked at, so the sentence
  # `two scripts claim the same command name` and the names it prints were
  # free to drift. The two are written side by side because the rule they
  # enforce is one rule: whichever kind collides, the user hears about it
  # the same way.
  fixsd="$work/repo-script-dupes"
  make_fixture "$fixsd"
  mkdir -p "$fixsd/scripts" "$fixsd/shell"
  printf '#!/bin/sh\n:\n' > "$fixsd/scripts/prune.sh"
  printf 'print("prune")\n' > "$fixsd/scripts/prune.py"
  printf 'A=1\n'          > "$fixsd/shell/lib.sh"
  set +e
  out=$("$fixsd/install.sh" --dir "$work/bin-sdupe" --shell-dir "$work/sd-sdupe" 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "prune.sh and prune.py both install under the name prune, so the run is refused"
  case $out in
    *"two scripts claim the same command name"*) pass "and the message names the problem" ;;
    *)                                           fail "and the message names the problem" ;;
  esac
  case $out in
    *"rename one of them; refusing to guess"*) pass "and refuses to pick a winner" ;;
    *)                                         fail "and refuses to pick a winner" ;;
  esac
  case $out in
    *prune*) pass "and prints the name they are fighting over" ;;
    *)       fail "and prints the name they are fighting over" ;;
  esac
  # Refused before anything happened, on either side: a collision is a
  # defect in the repository and no part of it is safe to act on.
  assert_fail 1 "and nothing was linked for the scripts" test -e "$work/bin-sdupe"
  assert_fail 1 "and nothing for the shell files either" test -e "$work/sd-sdupe"

  section_report
)
section_end $?

section_begin 'a symlink under scripts/ or shell/'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  # A HOME of its own, as everywhere that runs a real install: these runs
  # leave BIN_DIR off PATH, and a startup file one of them wrote is not
  # allowed to decide the next one's result.
  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"
  ln -s "$fix/scripts/tool.sh" "$fix/scripts/linked.sh"
  ln -s "$fix/shell/lib.sh"    "$fix/shell/linkedlib.sh"

  run_installer() {
    # run_installer BIN_DIR SHELL_DIR [ARG...]
    local b=$1 s=$2
    shift 2
    set +e
    "$fix/install.sh" --dir "$b" --shell-dir "$s" "$@" >"$work/out" 2>"$work/err"
    RC=$?
    set -e
    OUT=$(cat "$work/out")
    ERR=$(cat "$work/err")
  }

  # A DRY RUN SAYS SO IN THE PREVIEW
  #
  # The preview is where a run answers "what would this do?", and a file
  # that produces neither a link nor a word is the one answer it may not
  # give. The stanza is its own, with a reason of its own: a reader who
  # cannot tell an extension skip from a symlink has been told nothing.
  run_installer "$work/bin-dry" "$work/sd-dry" --dry-run
  assert_eq "0" "$RC" "a dry run over a symlink still exits 0"
  case $OUT in
    *"Ignored (a symlink, which is not followed):"*)
      pass "and the preview opens a stanza of its own for it" ;;
    *) fail "and the preview opens a stanza of its own for it" ;;
  esac
  case $OUT in
    *"$fix/scripts/linked.sh"*) pass "and names the one under scripts/" ;;
    *)                          fail "and names the one under scripts/" ;;
  esac
  case $OUT in
    *"$fix/shell/linkedlib.sh"*) pass "and the one under shell/" ;;
    *)                           fail "and the one under shell/" ;;
  esac
  case $OUT in
    *"link $work/bin-dry/linked"*)      fail "and promises a link for neither" ;;
    *"link $work/sd-dry/linkedlib.sh"*) fail "and promises a link for neither" ;;
    *)                                  pass "and promises a link for neither" ;;
  esac
  # The file it was told about is still installed. A symlink beside it is
  # an anomaly to report, not a reason to abandon the rest of the run.
  case $OUT in
    *"link $work/bin-dry/tool"*) pass "while the regular script is still promised" ;;
    *)                           fail "while the regular script is still promised" ;;
  esac

  # A REAL RUN HAS NO PREVIEW, SO IT SAYS SO ON STDERR
  #
  # The contributor who adds a symlink has no reason to reach for
  # --dry-run: as far as they can tell the install succeeded, and the only
  # evidence that it did not is a command that never appears. An extension
  # skip is at least guessable from the name - nothing about `linked.sh`
  # says why it was passed over, so a real run has to say it out loud.
  run_installer "$work/bin" "$work/sd"
  assert_eq "0" "$RC" "a symlink is not a failure: the rest of the run still installs"
  assert_ok     "the regular script was linked"       test -L "$work/bin/tool"
  assert_ok     "and the regular shell file was too"  test -L "$work/sd/lib.sh"
  assert_fail 1 "and nothing was linked for the symlink under scripts/" test -e "$work/bin/linked"
  assert_fail 1 "nor for the one under shell/"        test -e "$work/sd/linkedlib.sh"
  case $ERR in
    *"these are symlinks, and are not installed"*)
      pass "and the run says so on stderr, where a diagnostic goes" ;;
    *) fail "and the run says so on stderr, where a diagnostic goes" ;;
  esac
  case $ERR in
    *"$fix/scripts/linked.sh"*) pass "naming the symlink under scripts/" ;;
    *)                          fail "naming the symlink under scripts/" ;;
  esac
  case $ERR in
    *"$fix/shell/linkedlib.sh"*) pass "and the one under shell/" ;;
    *)                           fail "and the one under shell/" ;;
  esac
  case $ERR in
    *"outside this repository"*)
      pass "and gives the reason, which is the rule the whole installer rests on" ;;
    *) fail "and gives the reason, which is the rule the whole installer rests on" ;;
  esac

  # The preview has already said it on stdout, and one voice saying a thing
  # once is the whole of the difference between a report and noise.
  run_installer "$work/bin-dry2" "$work/sd-dry2" --dry-run
  case $ERR in
    *"these are symlinks"*) fail "while a dry run does not repeat it on stderr" ;;
    *)                      pass "while a dry run does not repeat it on stderr" ;;
  esac

  # A repository with no symlinks hears nothing about them. A report that
  # fires when there is nothing to report teaches the reader to skip it.
  fixclean="$work/repo-clean"
  make_fixture "$fixclean"
  mkdir -p "$fixclean/scripts" "$fixclean/shell"
  printf '#!/bin/sh\n:\n' > "$fixclean/scripts/t.sh"
  printf 'A=1\n'          > "$fixclean/shell/a.sh"
  set +e
  "$fixclean/install.sh" --dir "$work/bin-clean" --shell-dir "$work/sd-clean" \
    >"$work/out" 2>"$work/err"
  set -e
  case $(cat "$work/err") in
    *symlink*) fail "a repository with no symlinks is told nothing about any" ;;
    *)         pass "a repository with no symlinks is told nothing about any" ;;
  esac
  set +e
  "$fixclean/install.sh" --dir "$work/bin-clean2" --shell-dir "$work/sd-clean2" \
    --dry-run >"$work/out" 2>"$work/err"
  set -e
  case $(cat "$work/out") in
    *Ignored*) fail "and no ignored stanza is opened for it under --dry-run" ;;
    *)         pass "and no ignored stanza is opened for it under --dry-run" ;;
  esac

  # An uninstall never made the link, so there is nothing for it to take
  # away and nothing for it to say. Repeating the anomaly at removal time
  # would be a second voice on a subject the install has already closed.
  set +e
  "$fix/install.sh" --dir "$work/bin" --shell-dir "$work/sd" --uninstall \
    >"$work/out" 2>"$work/err"
  rc=$?
  set -e
  assert_eq "0" "$rc" "an uninstall over a symlink exits 0"
  case $(cat "$work/err") in
    *symlink*) fail "and says nothing about a link it was never asked to make" ;;
    *)         pass "and says nothing about a link it was never asked to make" ;;
  esac
  assert_fail 1 "while the links it did make are gone" test -e "$work/bin/tool"

  section_report
)
section_end $?

section_begin 'collisions'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/bin"
  sdir="$work/aliases.d"
  mkdir -p "$bin" "$sdir"

  # The installer's own discovery, borrowed so that "every destination" is
  # a question this section asks rather than a list it carries.
  #
  # The three exit-2 assertions below need *nothing* linkable anywhere, and
  # a written-down list of names is only that as long as nobody adds a
  # script. scripts/wd40.sh arriving turned "blocked everywhere" into
  # "blocked nearly everywhere", which is exit 0 - so the assertions went
  # red having said nothing about the rule they exist for. That is the
  # coupling the run sandbox was introduced to break, met again one level
  # up.
  #
  # WD40_SOURCE_ONLY is deliberately not exported: this section also runs
  # the installer as a subprocess, and a child that inherited it would
  # define its functions and install nothing.
  WD40_SOURCE_ONLY=1
  # shellcheck disable=SC1090
  . "$INSTALL"

  block_scripts() {
    # block_scripts HOW DIR - HOW is `file` or `link`
    local how=$1 b=$2 f dest
    while IFS= read -r f; do
      dest="$b/$(link_name_for "$f")"
      rm -f "$dest"
      if [ "$how" = link ]; then ln -s "$work/foreign" "$dest"
      else printf 'not ours\n' > "$dest"; fi
    done < <(discover_scripts "$REPO")
  }

  block_shell_files() {
    # block_shell_files HOW DIR
    local how=$1 s=$2 f dest
    while IFS= read -r f; do
      dest="$s/$(shell_link_name_for "$f")"
      rm -f "$dest"
      if [ "$how" = link ]; then ln -s "$work/foreign" "$dest"
      else printf 'not ours\n' > "$dest"; fi
    done < <(discover_shell_files "$REPO")
  }

  block_all() {
    # block_all HOW BIN_DIR SHELL_DIR
    block_scripts "$1" "$2"
    block_shell_files "$1" "$3"
  }

  # A destination whose target cannot be established, at every destination.
  #
  # Two links pointing at each other is the cheapest unresolvable thing
  # there is, and the partner link is given a name of its own so that it is
  # never itself a destination this repository claims.
  cycle_all() {
    # cycle_all BIN_DIR SHELL_DIR
    local b=$1 s=$2 f n
    while IFS= read -r f; do
      n=$(link_name_for "$f")
      ln -s "$n-other" "$b/$n"
      ln -s "$n" "$b/$n-other"
    done < <(discover_scripts "$REPO")
    while IFS= read -r f; do
      n=$(shell_link_name_for "$f")
      ln -s "$n-other" "$s/$n"
      ln -s "$n" "$s/$n-other"
    done < <(discover_shell_files "$REPO")
  }

  printf 'someone elses tool\n' > "$work/foreign"

  # These tests ask "does an unownable destination stop the install?", and
  # the answer is now a property of the whole run rather than of one
  # directory: do_install reports success when *either* kind linked
  # something, so blocking only BIN_DIR leaves shell/wd40-paths.sh free to
  # install and the run exits 0. Obstructing every destination is what it
  # now takes to make exit 2 the honest answer.
  block_all file "$bin" "$sdir"
  assert_fail 2 "a regular file in every destination blocks the install" \
    "$INSTALL" --dir "$bin" --shell-dir "$sdir"
  assert_eq "not ours" "$(cat "$bin/smem-groups")"   "the regular script file was left intact"
  assert_eq "not ours" "$(cat "$sdir/wd40-paths.sh")" "the regular shell file was left intact"

  # Not assert_clean: BIN_DIR is off PATH for these runs, so the installer
  # legitimately spends stderr on the PATH and loader advice.
  assert_ok "--force overwrites the regular files" "$INSTALL" --dir "$bin" --shell-dir "$sdir" --force
  assert_ok "the script is a symlink now"          test -L "$bin/smem-groups"
  assert_ok "the shell file is a symlink now"      test -L "$sdir/wd40-paths.sh"

  rm -f "$bin/smem-groups" "$sdir/wd40-paths.sh"
  block_all link "$bin" "$sdir"
  assert_fail 2 "a foreign symlink in every destination blocks the install" \
    "$INSTALL" --dir "$bin" --shell-dir "$sdir"
  assert_eq "$work/foreign" "$(readlink "$bin/smem-groups")"    "the foreign script symlink still points where it did"
  assert_eq "$work/foreign" "$(readlink "$sdir/wd40-paths.sh")" "the foreign shell symlink still points where it did"

  # One kind blocked is not enough, and saying so out loud is the point: it
  # is the exact behaviour that made the two assertions above stale, so it
  # gets an assertion of its own rather than a comment.
  rm -f "$bin"/* "$sdir"/*
  block_scripts link "$bin"
  # Not assert_clean: a skipped destination is the one thing install_one is
  # required to warn about, so stderr here is the feature.
  assert_ok "blocking only the script directory still installs the shell file" \
    "$INSTALL" --dir "$bin" --shell-dir "$sdir"
  assert_ok "and that shell file is ours"       test -L "$sdir/wd40-paths.sh"
  assert_eq "$work/foreign" "$(readlink "$bin/smem-groups")" "while the foreign script symlink survives"

  # A destination whose target cannot be established at all. A symlink
  # cycle is the cheapest way to build one, and it is treated exactly as a
  # destination that is not ours: warn, leave it, install everything else.
  # Before resolve_path returned instead of dying, this run either
  # announced `points outside this repo ()` or - once errexit was live -
  # took the whole install down over one link, shell file included.
  rm -f "$bin"/* "$sdir"/*
  ln -s smem-other "$bin/smem-groups"
  ln -s smem-groups "$bin/smem-other"
  set +e
  out=$("$INSTALL" --dir "$bin" --shell-dir "$sdir" 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "an unresolvable destination does not end the run"
  case $out in
    *"cannot resolve smem-groups; leaving it alone"*)
      pass "and the message says what is true rather than guessing at ownership" ;;
    *) fail "and the message says what is true rather than guessing at ownership" ;;
  esac
  case $out in
    *"points outside this repo ()"*)
      fail "and never claims ownership it could not have decided" ;;
    *)  pass "and never claims ownership it could not have decided" ;;
  esac
  assert_eq "smem-other" "$(readlink "$bin/smem-groups")" "the cycle is left exactly as it was"
  assert_ok "and the shell file still installed" test -L "$sdir/wd40-paths.sh"

  # Unresolvable in every destination is nothing installed, which is exit 2
  # - the same answer a foreign link everywhere gets, because it is the
  # same outcome. It is not a hard failure and it is not exit 1.
  rm -f "$bin"/* "$sdir"/*
  cycle_all "$bin" "$sdir"
  assert_fail 2 "unresolvable in every destination is exit 2, not exit 1" \
    "$INSTALL" --dir "$bin" --shell-dir "$sdir"

  # And the uninstaller is fail-safe about the same thing: it cannot show
  # that the link is ours, so it does not take it away.
  set +e
  out=$("$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "an uninstall meeting one is not a failure either"
  assert_ok "and it leaves the link where it was" test -L "$bin/smem-groups"
  case $out in
    *"cannot resolve smem-groups; leaving it alone"*)
      pass "and says so in the same words" ;;
    *) fail "and says so in the same words" ;;
  esac

  section_report
)
section_end $?

section_begin 'uninstall'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/bin"
  # As in == install ==: pinned so this test cannot be decided by a
  # ~/.zsh_aliases.d another test populated.
  sdir="$work/aliases.d"

  "$INSTALL" --dir "$bin" --shell-dir "$sdir" >/dev/null 2>&1
  assert_ok "installed before uninstalling" test -L "$bin/smem-groups"

  # An uninstall that finds only its own links has nothing to warn about,
  # so its stderr is part of the claim rather than something to discard.
  assert_clean "uninstall exits 0"   "$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall
  assert_eq "0" "$(ls -1 "$bin" | wc -l | tr -d ' ')" "target directory is empty"
  assert_eq "0" "$(ls -1 "$sdir" | wc -l | tr -d ' ')" "shell directory is empty"

  # A link with our name that is not ours must survive.
  printf 'someone elses tool\n' > "$work/foreign"
  ln -s "$work/foreign" "$bin/smem-groups"
  # Not assert_clean: leaving a foreign link alone is exactly the case
  # remove_one is required to say something about.
  assert_ok "uninstall exits 0 with a foreign link present" "$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall
  assert_ok "the foreign link survived"                     test -L "$bin/smem-groups"

  # So must a regular file.
  rm -f "$bin/smem-groups"
  printf 'not ours\n' > "$bin/smem-groups"
  "$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall >/dev/null
  assert_eq "not ours" "$(cat "$bin/smem-groups")" "the regular file survived"

  assert_clean "uninstall on a missing directory exits 0" \
    "$INSTALL" --dir "$work/never" --shell-dir "$work/never-either" --uninstall

  # --force HAS NO MEANING HERE AND IS IGNORED
  #
  # Documented in remove_one's comment and asserted nowhere, so the day
  # somebody wires FORCE into the ownership test the only thing that would
  # notice is a user losing a tool of their own. Ownership is decided by
  # resolving the link, and --force does not make somebody else's link ours.
  rm -f "$bin/smem-groups"
  ln -s "$work/foreign" "$bin/smem-groups"
  printf 'theirs\n' > "$bin/handwritten"
  set +e
  out=$("$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall --force 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "--uninstall --force exits 0"
  assert_ok "and the foreign link with our name still survives it" test -L "$bin/smem-groups"
  assert_eq "$work/foreign" "$(readlink "$bin/smem-groups")" "and points where it did"
  assert_eq "theirs" "$(cat "$bin/handwritten")" "and a regular file of the user's is untouched"
  case $out in
    *"leaving smem-groups alone"*) pass "and the reason given is ownership, not force" ;;
    *)                             fail "and the reason given is ownership, not force" ;;
  esac

  # And the flag order is not what makes it harmless.
  assert_ok "--force --uninstall is the same run in the other order" \
    "$INSTALL" --dir "$bin" --shell-dir "$sdir" --force --uninstall
  assert_ok "and the foreign link is still there" test -L "$bin/smem-groups"

  # Our own link still goes, so "ignored" means ignored and not "disabled".
  rm -f "$bin/smem-groups"
  "$INSTALL" --dir "$bin" --shell-dir "$sdir" >/dev/null 2>&1
  assert_ok "ours was installed" test -L "$bin/smem-groups"
  "$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall --force >/dev/null 2>&1
  assert_fail 1 "and --uninstall --force still removes what is ours" test -e "$bin/smem-groups"

  section_report
)
section_end $?

section_begin 'uninstalling shell files'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  bin="$work/bin"
  sdir="$work/aliases.d"
  "$fix/install.sh" --dir "$bin" --shell-dir "$sdir" >/dev/null 2>&1
  assert_ok "installed before uninstalling" test -L "$sdir/lib.sh"

  # SHELL_DIR is a directory of the user's own alias files, where a name
  # like git.sh is theirs long before it is ever ours. Ownership is decided
  # by resolving the link, never by its name.
  printf 'someone elses tool\n' > "$work/foreign"
  ln -s "$work/foreign" "$sdir/theirs.sh"

  # theirs.sh is not a name this repository claims, so remove_one is never
  # asked about it and the run has nothing to say: assert_clean holds.
  assert_clean "uninstall exits 0"           "$fix/install.sh" --dir "$bin" --shell-dir "$sdir" --uninstall
  assert_fail 1 "our shell link was removed" test -e "$sdir/lib.sh"
  assert_ok     "an unrelated foreign link survived" test -L "$sdir/theirs.sh"

  # And one carrying our exact name survives too, with a warning.
  sdir2="$work/aliases2.d"
  mkdir -p "$sdir2"
  ln -s "$work/foreign" "$sdir2/lib.sh"
  set +e
  out=$("$fix/install.sh" --dir "$work/bin2" --shell-dir "$sdir2" --uninstall 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "a foreign link with our name is not a failure"
  assert_ok "the foreign link with our name survived" test -L "$sdir2/lib.sh"
  assert_eq "$work/foreign" "$(readlink "$sdir2/lib.sh")" "and still points where it did"
  case $out in
    *"leaving lib.sh alone"*) pass "and the user is told why it was left" ;;
    *)                        fail "and the user is told why it was left" ;;
  esac

  section_report
)
section_end $?

section_begin 'filesystem failures'
(
  set -e
  section_reset

  # Several fixtures below are directories nothing may write to, and a mode
  # left behind is a sandbox nothing can remove either. The trap puts the
  # modes back first and takes the tree away second.
  tmp=$(mktemp -d)
  trap 'chmod -R u+rwx "$tmp" >/dev/null 2>&1; rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  # A HOME per section, as everywhere else that runs a real install: these
  # runs leave BIN_DIR off PATH, and a startup file one of them wrote is
  # not allowed to decide the next one's result.
  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  # The two streams are kept apart because every claim below is about one
  # of them and not the other. A `link` line is something the user reads on
  # stdout; whether the run complained at all is on stderr; and the defect
  # this section exists for was precisely the first arriving without the
  # second.
  run_installer() {
    # run_installer BIN_DIR SHELL_DIR [ARG...]
    local b=$1 s=$2
    shift 2
    set +e
    "$fix/install.sh" --dir "$b" --shell-dir "$s" "$@" >"$work/out" 2>"$work/err"
    RC=$?
    set -e
    OUT=$(cat "$work/out")
    ERR=$(cat "$work/err")
  }

  # A mode refuses nobody when the reader is root, so the assertions that
  # depend on one are skipped rather than quietly inverted into their
  # opposites.
  if [ "$(id -u)" = "0" ]; then
    skip "the unwritable-directory assertions" "a mode does not refuse root"
  else
    # BIN_DIR's parent is read-only, SHELL_DIR's is not. The two kinds are
    # independent, so the half that can be done still is - and the run
    # still has to say the other half was not.
    robin="$work/ro-bin"
    mkdir -p "$robin"
    chmod 555 "$robin"
    bin="$robin/bin"
    sdir="$work/sd-while-bin-blocked"
    run_installer "$bin" "$sdir"

    assert_eq "1" "$RC" "a BIN_DIR that cannot be created is a failure"
    case $OUT in
      *"link $bin"*) fail "and no script link is announced" ;;
      *)             pass "and no script link is announced" ;;
    esac
    assert_fail 1 "and BIN_DIR was not created" test -e "$bin"
    case $ERR in
      *"cannot create the script directory $bin"*)
        pass "and the run names the directory it could not create" ;;
      *) fail "and the run names the directory it could not create" ;;
    esac
    assert_ok "while the shell file still installed" test -L "$sdir/lib.sh"

    # The same the other way round, because the two destinations are
    # created by two different lines and only one of them would be fixed by
    # accident.
    rosd="$work/ro-sd"
    mkdir -p "$rosd"
    chmod 555 "$rosd"
    bin2="$work/bin-while-sd-blocked"
    sdir2="$rosd/sd"
    run_installer "$bin2" "$sdir2"

    assert_eq "1" "$RC" "a SHELL_DIR that cannot be created is a failure too"
    case $OUT in
      *"link $sdir2"*) fail "and no shell link is announced" ;;
      *)               pass "and no shell link is announced" ;;
    esac
    assert_fail 1 "and SHELL_DIR was not created" test -e "$sdir2"
    case $ERR in
      *"cannot create the shell directory $sdir2"*)
        pass "and the run names that directory too" ;;
      *) fail "and the run names that directory too" ;;
    esac
    assert_ok "while the script still installed" test -L "$bin2/tool"

    # The audit's own reproduction: both destinations under one read-only
    # parent. Two link lines, nothing created, exit 0.
    roboth="$work/ro-both"
    mkdir -p "$roboth"
    chmod 555 "$roboth"
    run_installer "$roboth/bin" "$roboth/sd"

    assert_eq "1" "$RC" "neither destination creatable is a failure"
    case $OUT in
      *"   link "*) fail "and not one link line is printed" ;;
      *)            pass "and not one link line is printed" ;;
    esac
    assert_eq "0" "$(ls -A "$roboth" | wc -l | tr -d ' ')" \
      "and the read-only directory is still empty"

    # The second half of the same defect. rm -f fails, `remove` is printed
    # anyway, and the uninstall exits 0 with the link still on PATH.
    ubin="$work/u-bin"
    usdir="$work/u-sd"
    "$fix/install.sh" --dir "$ubin" --shell-dir "$usdir" >/dev/null 2>&1
    chmod 555 "$ubin"
    run_installer "$ubin" "$usdir" --uninstall

    assert_eq "1" "$RC" "an uninstall that cannot remove a link is a failure"
    case $OUT in
      *"remove $ubin/tool"*) fail "and no removal is announced for a link that survived" ;;
      *)                     pass "and no removal is announced for a link that survived" ;;
    esac
    assert_ok "and the link is still where it was" test -L "$ubin/tool"
  fi

  # The likelier trigger, and the one that needs no permissions at all:
  # BIN_DIR is a path that already holds a regular file.
  binfile="$work/bin-is-a-file"
  printf 'not a directory\n' > "$binfile"
  run_installer "$binfile" "$work/sd-binfile"

  assert_eq "1" "$RC" "a BIN_DIR that is a regular file is a failure"
  case $OUT in
    *"link $binfile"*) fail "and no script link is announced for it" ;;
    *)                 pass "and no script link is announced for it" ;;
  esac
  case $ERR in
    *"cannot create the script directory $binfile"*)
      pass "and the message names the path that is in the way" ;;
    *) fail "and the message names the path that is in the way" ;;
  esac

  # `chmod +x` is the one operation here that no mode can provoke: chmod
  # answers to ownership, not to the permissions of the directory a file
  # sits in, so an unprivileged test cannot make a source it owns refuse.
  # A shim first on PATH is how the clipboard section reaches its otherwise
  # unreachable branch too, and this one matters because a source that
  # never got the executable bit is a command that will not run.
  shim="$work/shim"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/chmod"
  chmod +x "$shim/chmod"
  shimbin="$work/bin-shim"
  set +e
  env PATH="$shim:$PATH" "$fix/install.sh" \
    --dir "$shimbin" --shell-dir "$work/sd-shim" >"$work/out" 2>"$work/err"
  RC=$?
  set -e
  OUT=$(cat "$work/out")
  ERR=$(cat "$work/err")

  assert_eq "1" "$RC" "a chmod +x that fails is a failure"
  case $OUT in
    *"   link "*) fail "and no link is announced after it" ;;
    *)            pass "and no link is announced after it" ;;
  esac
  assert_eq "0" "$(ls -A "$shimbin" | wc -l | tr -d ' ')" "and nothing was linked"
  case $ERR in
    *"cannot make $fix/scripts/tool.sh executable"*)
      pass "and the message names the file that stayed unexecutable" ;;
    *) fail "and the message names the file that stayed unexecutable" ;;
  esac

  # A repository with nothing sourceable, installed into a BIN_DIR that is
  # already on PATH, is the one shape of successful run with nothing to
  # say: no PATH to fix, and no shell file linked, so no loader to wire up.
  # assert_clean is the whole point of these two - assert_ok would throw
  # away the one stream the claim is about.
  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/only.sh"
  cleanbin="$work/bin-clean"
  assert_clean "a successful install says nothing on stderr" \
    env PATH="$cleanbin:$PATH" "$fixs/install.sh" \
      --dir "$cleanbin" --shell-dir "$work/sd-clean"
  assert_clean "a successful uninstall says nothing on stderr" \
    "$fixs/install.sh" --dir "$cleanbin" --shell-dir "$work/sd-clean" --uninstall

  # The three outcomes the fix is not allowed to move. Every one of them
  # runs through code this change restructured, and each is asserted where
  # it belongs as well as here: an exit code that survived the
  # restructuring by luck is one nobody would notice losing.
  blockedbin="$work/blocked-bin"
  blockedsd="$work/blocked-sd"
  mkdir -p "$blockedbin" "$blockedsd"
  printf 'not ours\n' > "$blockedbin/tool"
  printf 'not ours\n' > "$blockedsd/lib.sh"
  assert_fail 2 "nothing linked in either destination is still exit 2" \
    "$fix/install.sh" --dir "$blockedbin" --shell-dir "$blockedsd"

  fixdupe="$work/repo-dupes"
  make_fixture "$fixdupe"
  mkdir -p "$fixdupe/scripts"
  printf '#!/bin/sh\n:\n' > "$fixdupe/scripts/t.sh"
  printf 'print("t")\n'   > "$fixdupe/scripts/t.py"
  assert_fail 1 "a name collision is still exit 1" \
    "$fixdupe/install.sh" --dir "$work/bin-dupe" --shell-dir "$work/sd-dupe"

  run_installer "$work/bin-dry" "$work/sd-dry" --dry-run
  assert_eq "0" "$RC" "a dry run still exits 0"
  assert_fail 1 "and still creates no script directory" test -e "$work/bin-dry"
  assert_fail 1 "and still creates no shell directory"  test -e "$work/sd-dry"

  # A DRY RUN THAT TELLS THE TRUTH ABOUT WHERE IT WOULD HAVE FAILED
  #
  # A dry run runs no mkdir, so no mkdir fails, so the preview promised two
  # links into a directory the run could never have made and exited 0 -
  # correct under the contract and still a lie, which is the one thing a
  # preview may not be. Nothing is created to find this out: the walk goes
  # up to the nearest ancestor that exists and asks whether it is writable.
  #
  # A destination that *is* creatable must stay silent, or the warning
  # means nothing. That half needs no permissions and is asserted first.
  case $ERR in
    *"cannot be created"*) fail "a dry run into a creatable directory says nothing about creating it" ;;
    *)                     pass "a dry run into a creatable directory says nothing about creating it" ;;
  esac

  # BIN_DIR as a path that already holds a regular file needs no mode
  # either, and mkdir -p would refuse it for a reason of its own.
  run_installer "$binfile" "$work/sd-dryfile" --dry-run
  assert_eq "0" "$RC" "a dry run onto a regular file still exits 0"
  case $ERR in
    *"the script directory $binfile cannot be created: it is not a directory"*)
      pass "and says the path in the way is not a directory" ;;
    *) fail "and says the path in the way is not a directory" ;;
  esac
  assert_eq "not a directory" "$(cat "$binfile")" "and does not touch it"

  if [ "$(id -u)" = "0" ]; then
    skip "the unwritable-directory half of the dry-run preview" "a mode does not refuse root"
  else
    rodry="$work/ro-dry"
    mkdir -p "$rodry"
    chmod 555 "$rodry"
    run_installer "$rodry/bin" "$rodry/sd" --dry-run

    assert_eq "0" "$RC" "an unwritable destination does not change a dry run's exit status"
    assert_fail 1 "and still creates nothing" test -e "$rodry/bin"
    assert_eq "0" "$(ls -A "$rodry" | wc -l | tr -d ' ')" "and leaves the directory empty"
    case $ERR in
      *"the script directory $rodry/bin cannot be created: $rodry is not writable"*)
        pass "and names the ancestor that refused, for the script directory" ;;
      *) fail "and names the ancestor that refused, for the script directory" ;;
    esac
    case $ERR in
      *"the shell directory $rodry/sd cannot be created: $rodry is not writable"*)
        pass "and for the shell directory too" ;;
      *) fail "and for the shell directory too" ;;
    esac
    # The preview still says what it would have done. The warning qualifies
    # the link lines; it does not replace them, and a run that suppressed
    # them would have counted nothing linked and changed the exit code.
    case $OUT in
      *"link $rodry/bin/tool"*) pass "while the preview still says what it would have linked" ;;
      *)                        fail "while the preview still says what it would have linked" ;;
    esac

    # A destination several levels below the nearest existing ancestor, so
    # that the walk has more than one step to take.
    run_installer "$rodry/a/b/c" "$work/sd-deep" --dry-run
    case $ERR in
      *"the script directory $rodry/a/b/c cannot be created: $rodry is not writable"*)
        pass "and the walk reaches the nearest ancestor that exists, not just the parent" ;;
      *) fail "and the walk reaches the nearest ancestor that exists, not just the parent" ;;
    esac

    chmod 755 "$rodry"
  fi

  section_report
)
section_end $?

section_begin 'dry run and PATH'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  bin="$work/bin"
  sdir="$work/aliases.d"

  # Not assert_clean: BIN_DIR is off PATH here on purpose, so the run
  # legitimately warns about that and about the loader on stderr.
  assert_ok "dry run exits 0"           "$INSTALL" --dir "$bin" --shell-dir "$sdir" --dry-run
  assert_fail 1 "dry run created nothing" test -e "$bin"

  out=$("$INSTALL" --dir "$bin" --shell-dir "$sdir" --dry-run 2>&1)
  case $out in
    *smem-groups*) pass "dry run names the link it would create" ;;
    *)             fail "dry run names the link it would create" ;;
  esac

  # A dry run answers "what would this do?", and putting BIN_DIR on PATH by
  # appending to a startup file is the largest part of the answer. Staying
  # quiet about it was the bug: the DRY_RUN branch inside add_to_shell_rc
  # existed from the start and nothing could reach it.
  dryhome="$work/dryhome"
  mkdir -p "$dryhome"
  printf 'echo hello\n' > "$dryhome/.bashrc"
  before=$(cat "$dryhome/.bashrc")
  set +e
  out=$(HOME="$dryhome" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$INSTALL" --dir "$work/bin-dry" --shell-dir "$work/sd-dry" --dry-run 2>&1)
  set -e
  case $out in
    *"is not in any shell's startup files"*) pass "a dry run still warns that the directory is off PATH" ;;
    *)                    fail "a dry run still warns that the directory is off PATH" ;;
  esac
  case $out in
    *"Would add this block to $dryhome/.bashrc"*) pass "and names the rc file it would have edited" ;;
    *)                                            fail "and names the rc file it would have edited" ;;
  esac
  case $out in
    *"export PATH=\"$work/bin-dry:\$PATH\""*) pass "and prints the exact line it would have appended" ;;
    *)                                        fail "and prints the exact line it would have appended" ;;
  esac
  assert_eq "$before" "$(cat "$dryhome/.bashrc")" "and changes not one byte of it"

  # A HOME of its own for every run that gets near a startup file. The
  # run-wide sandbox stops the real ~/.bashrc being written; a per-test
  # HOME stops one of these runs deciding the next one's result.
  fakehome="$work/fakehome"
  mkdir -p "$fakehome"
  out=$(HOME="$fakehome" PATH="/usr/bin:/bin" "$INSTALL" --dir "$bin" --shell-dir "$work/sd-offpath" 2>&1)
  case $out in
    *"is not in any shell's startup files"*) pass "warns when the directory is off PATH" ;;
    *)                    fail "warns when the directory is off PATH" ;;
  esac

  # Said once, by the function that detects it. warn_if_not_on_path names
  # the condition and add_to_shell_rc says only what is being done about
  # it; both saying it produced two consecutive lines that opened with the
  # same eight words. Counting is the assertion, so a re-worded message
  # still passes and a second copy of it still fails.
  #
  # `grep -c` counts matching *lines*, so two copies of a message that
  # landed on one line counted as one - and "said once" is the whole claim
  # these four assertions make. awk's gsub returns the number of
  # substitutions it made, which is the number actually wanted; PATTERN is
  # an extended regular expression there rather than a basic one, which
  # for the literals below is the same thing.
  said_on() {
    # said_on TEXT PATTERN
    printf '%s\n' "$1" | awk -v pat="$2" '{ n += gsub(pat, "") } END { print n + 0 }'
  }

  norchome="$work/norchome"
  mkdir -p "$norchome"
  out=$(HOME="$norchome" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$INSTALL" --dir "$work/bin-norc" --shell-dir "$work/sd-norc" 2>&1)
  assert_eq "1" "$(said_on "$out" "is not in any shell.s startup files")" \
    "with no rc file to append to, the PATH condition is stated once"
  assert_eq "1" "$(said_on "$out" 'mentions')" \
    "and the loader condition is stated once"

  withrchome="$work/withrchome"
  mkdir -p "$withrchome"
  printf 'echo hello\n' > "$withrchome/.bashrc"
  out=$(HOME="$withrchome" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$INSTALL" --dir "$work/bin-withrc" --shell-dir "$work/sd-withrc" 2>&1)
  assert_eq "1" "$(said_on "$out" "is not in any shell.s startup files")" \
    "with an rc file to append to, the PATH condition is stated once"
  assert_eq "1" "$(said_on "$out" 'mentions')" \
    "and the loader condition is stated once there too"

  rm -rf "$bin"
  onpathhome="$work/onpathhome"
  mkdir -p "$onpathhome"
  out=$(HOME="$onpathhome" PATH="$bin:/usr/bin:/bin" "$INSTALL" --dir "$bin" --shell-dir "$work/sd-onpath" 2>&1)
  case $out in
    *"is not in any shell's startup files"*) fail "stays quiet when the directory is on PATH" ;;
    *)                    pass "stays quiet when the directory is on PATH" ;;
  esac

  # A BIN_DIR THAT IS A PREFIX OF A PATH ENTRY
  #
  # /x/bin must not be satisfied by /x/bins, and the colons in
  # `case ":$PATH:" in *":$BIN_DIR:"*` are the whole of what stops it. It
  # is the same mistake spellings_for refuses when it declines to read
  # /home/user2 as a directory under /home/user, and it was asserted there
  # and nowhere here - so the two guards against one error had one test
  # between them.
  prefixhome="$work/prefixhome"
  mkdir -p "$prefixhome"
  pbin="$work/p/bin"
  mkdir -p "$pbin" "$work/p/bins"
  out=$(HOME="$prefixhome" SHELL=/bin/bash PATH="$work/p/bins:/usr/bin:/bin" \
    "$INSTALL" --dir "$pbin" --shell-dir "$work/sd-prefix" 2>&1)
  case $out in
    *"$pbin is not in any shell's startup files"*) pass "/x/bins on PATH does not satisfy a BIN_DIR of /x/bin" ;;
    *)                             fail "/x/bins on PATH does not satisfy a BIN_DIR of /x/bin" ;;
  esac

  # The other direction of the same test, so that a fix which simply
  # stopped matching anything could not pass both.
  out=$(HOME="$prefixhome" SHELL=/bin/bash PATH="$work/p/bins:$pbin:/usr/bin:/bin" \
    "$INSTALL" --dir "$pbin" --shell-dir "$work/sd-prefix2" 2>&1)
  case $out in
    *"is not in any shell's startup files"*) fail "while the directory itself on PATH does satisfy it" ;;
    *)                       pass "while the directory itself on PATH does satisfy it" ;;
  esac

  # And the first and last entries of PATH, which the colon padding exists
  # to reach: without it neither would ever match.
  out=$(HOME="$prefixhome" SHELL=/bin/bash PATH="$pbin:/usr/bin:/bin" \
    "$INSTALL" --dir "$pbin" --shell-dir "$work/sd-prefix3" 2>&1)
  case $out in
    *"is not in any shell's startup files"*) fail "the first entry of PATH counts" ;;
    *)                       pass "the first entry of PATH counts" ;;
  esac
  out=$(HOME="$prefixhome" SHELL=/bin/bash PATH="/usr/bin:/bin:$pbin" \
    "$INSTALL" --dir "$pbin" --shell-dir "$work/sd-prefix4" 2>&1)
  case $out in
    *"is not in any shell's startup files"*) fail "and so does the last" ;;
    *)                       pass "and so does the last" ;;
  esac

  section_report
)
section_end $?

section_begin 'a run with no HOME at all'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  # cron, systemd units, `env -i` and Docker layers routinely have no HOME.
  # $HOME used to be expanded at the top of the file, before a single
  # argument had been read, so a run handed both of its directories
  # explicitly - a run that never needs a home directory for anything -
  # aborted with `install.sh: line 174: HOME: unbound variable`. A bash
  # trace carrying a line number is not a diagnostic.
  #
  # `env -u HOME` is how the variable is removed rather than emptied: an
  # empty HOME and an unset HOME are different states and `set -u` only
  # objects to one of them.
  no_home() {
    # no_home BIN_DIR SHELL_DIR [ARG...]
    local b=$1 s=$2
    shift 2
    set +e
    env -u HOME "$fix/install.sh" --dir "$b" --shell-dir "$s" "$@" \
      >"$work/out" 2>"$work/err"
    RC=$?
    set -e
    OUT=$(cat "$work/out")
    ERR=$(cat "$work/err")
  }

  no_home "$work/bin-dry" "$work/sd-dry" --dry-run
  assert_eq "0" "$RC" "a dry run with both directories given needs no HOME"
  case $ERR in
    *"unbound variable"*) fail "and no bash trace reaches the user" ;;
    *)                    pass "and no bash trace reaches the user" ;;
  esac

  no_home "$work/bin" "$work/sd"
  assert_eq "0" "$RC" "and neither does a real install"
  assert_ok "the script was linked"     test -L "$work/bin/tool"
  assert_ok "and the shell file was too" test -L "$work/sd/lib.sh"
  case $ERR in
    *"unbound variable"*) fail "and still no bash trace" ;;
    *)                    pass "and still no bash trace" ;;
  esac

  no_home "$work/bin" "$work/sd" --uninstall
  assert_eq "0" "$RC" "an uninstall needs no HOME either"
  assert_fail 1 "and the script link went" test -e "$work/bin/tool"

  # The one step that genuinely cannot be done without a home directory is
  # finding the file a shell reads at startup. That step, and only that
  # step, names HOME as the problem - the rest of the run has no use for it.
  #
  # BIN_DIR is off PATH here, which is what makes the installer try.
  set +e
  out=$(env -u HOME PATH="/usr/bin:/bin" "$fix/install.sh" \
    --dir "$work/bin-rc" --shell-dir "$work/sd-rc" 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "a run that cannot wire up an rc file still installs"
  assert_ok "and the links are there" test -L "$work/bin-rc/tool"
  case $out in
    *"HOME is not set, so I cannot find your shell's startup file"*)
      pass "and the PATH step names HOME as the reason" ;;
    *) fail "and the PATH step names HOME as the reason" ;;
  esac
  case $out in
    *"HOME is not set, so I cannot tell whether anything already sources"*)
      pass "and so does the loader step" ;;
    *) fail "and so does the loader step" ;;
  esac
  case $out in
    *_wd40_load_aliases*) pass "and the block to paste by hand is printed anyway" ;;
    *)                    fail "and the block to paste by hand is printed anyway" ;;
  esac
  case $out in
    *"export PATH=\"$work/bin-rc:\$PATH\""*)
      pass "and so is the PATH line to paste by hand" ;;
    *) fail "and so is the PATH line to paste by hand" ;;
  esac

  # NO HOME AND NO --dir IS NOT A DESTINATION AT THE ROOT
  #
  # `~/.local/sbin` with no `~` to expand used to be `/.local/sbin`.
  # Unprivileged that failed honestly, at the mkdir, naming a directory it
  # could not create. As root with no HOME - `env -i` in CI, some container
  # layers - it would have *created* `/.local/sbin`, which is the same
  # litter that refusing `--dir=` exists to prevent, arriving through a
  # different door. The default now expands to nothing, and nothing is
  # refused wherever it came from.
  set +e
  out=$(env -u HOME "$fix/install.sh" --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "with no HOME and no --dir the run is refused"
  # The whole sentence, not the two words `HOME is not set`: the rc-wiring
  # step says those too, and an assertion that took them for this one would
  # be green on the very behaviour it was written to replace.
  case $out in
    *"HOME is not set, so the default install directory has no ~ to expand"*)
      pass "and the message names HOME as the cause" ;;
    *) fail "and the message names HOME as the cause" ;;
  esac
  # The nearest flag is not the cause and must not be blamed for it. A user
  # who never typed `--dir` and is told `--dir requires an argument` has
  # been sent to look at the wrong thing entirely.
  case $out in
    *"--dir requires an argument"*) fail "and does not blame a flag the user never typed" ;;
    *)                              pass "and does not blame a flag the user never typed" ;;
  esac
  # What it says to do instead, which is the only action available to a
  # user who has no home directory.
  case $out in
    *"--dir DIR and --shell-dir DIR"*)
      pass "and names both directories, because one run has to supply both" ;;
    *) fail "and names both directories, because one run has to supply both" ;;
  esac
  case $out in
    *"WD40_BIN_DIR and WD40_SHELL_DIR"*)
      pass "and the environment variables that do the same job" ;;
    *) fail "and the environment variables that do the same job" ;;
  esac
  assert_fail 1 "and nothing exists at the root of the filesystem" test -e /.local/sbin
  assert_fail 1 "and nothing at the other one either"              test -e /.zsh_aliases.d

  # Half a run is refused the same way and names only the half that is
  # missing: a user who has already supplied --dir does not need to be
  # asked for it again.
  set +e
  out=$(env -u HOME "$fix/install.sh" --dir "$work/bin-half" --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--dir alone with no HOME is still refused, over the shell directory"
  case $out in
    *"--shell-dir DIR"*) pass "and names --shell-dir" ;;
    *)                   fail "and names --shell-dir" ;;
  esac
  case $out in
    *"--dir DIR"*) fail "and does not ask again for the one already given" ;;
    *)             pass "and does not ask again for the one already given" ;;
  esac

  set +e
  out=$(env -u HOME "$fix/install.sh" --shell-dir "$work/sd-half" --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--shell-dir alone with no HOME is refused over the script directory"
  case $out in
    *"pass --dir DIR (or set WD40_BIN_DIR)"*)
      pass "and names --dir and WD40_BIN_DIR, and only those" ;;
    *) fail "and names --dir and WD40_BIN_DIR, and only those" ;;
  esac

  # AN EMPTY VALUE, WHATEVER PRODUCED IT
  #
  # The =-joined form was the only origin the old code checked, and the
  # spaced form with an empty argument walked straight past it: `--dir ""`
  # satisfies `[ $# -ge 2 ]`, so BIN_DIR became the empty string and the
  # run announced `link /tool`. One check after parsing is what closes
  # every door at once, and the sentence still names whichever one was
  # opened.
  set +e
  out=$(env -u HOME "$fix/install.sh" --dir "" --shell-dir "$work/sd-e" --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--dir with an empty argument is refused"
  assert_eq "Error: --dir requires an argument" "$out" \
    "and is blamed on the flag, because the flag is what was typed"

  set +e
  out=$(env -u HOME "$fix/install.sh" --dir "$work/bin-e" --shell-dir "" --dry-run 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--shell-dir with an empty argument is refused too"
  assert_eq "Error: --shell-dir requires an argument" "$out" "and blamed on its own flag"

  # A flag typed wrongly outranks an absent HOME when both are true, because
  # the flag is the one of the two the user can see they got wrong.
  set +e
  out=$(env -u HOME "$fix/install.sh" --dir= --dry-run 2>&1)
  set -e
  assert_eq "Error: --dir requires an argument" "$out" \
    "and a mistyped flag outranks an absent HOME when both are wrong"

  # --help asks a question that needs no destination to answer.
  assert_clean "--help still works with no HOME at all" env -u HOME "$fix/install.sh" --help

  # An uninstall is refused for the same reason an install is: an empty
  # BIN_DIR would have it looking for `/tool`.
  assert_fail 1 "an uninstall with no HOME and no --dir is refused as well" \
    env -u HOME "$fix/install.sh" --uninstall

  # REFUSED BEFORE ANY mkdir COULD RUN
  #
  # The root case cannot be reproduced without root, and it does not need
  # to be: what makes it safe is that the run is over before the one
  # command that could create anything is reached. A `mkdir` first on PATH
  # that records having been called is how that is asked without
  # privileges.
  shim="$work/shim"
  mkdir -p "$shim"
  marker="$work/mkdir-was-called"
  printf '#!/bin/sh\n: > "%s"\nexit 1\n' "$marker" > "$shim/mkdir"
  chmod +x "$shim/mkdir"
  set +e
  env -u HOME PATH="$shim:$PATH" "$fix/install.sh" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "1" "$rc" "a real run with no HOME and no --dir is refused"
  assert_fail 1 "and mkdir was never reached, so the root case cannot arise" test -e "$marker"

  # And the shim is a shim that works. Without this the assertion above
  # would be green on a `mkdir` that had never been called by anything, and
  # a guard that cannot fire is worse than no guard at all.
  set +e
  env -u HOME PATH="$shim:$PATH" "$fix/install.sh" \
    --dir "$work/bin-shim" --shell-dir "$work/sd-shim" >/dev/null 2>&1
  set -e
  assert_ok "while a run that was given its directories does reach mkdir" test -e "$marker"

  section_report
)
section_end $?

section_begin 'which stream the generated blocks go to'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  # The two blocks used to change stream depending on whether the rc file
  # existed: to stdout when it did, to stderr when it did not. So
  # `--dry-run > preview.txt` - the natural way to read what a run would do
  # before agreeing to it - dropped both blocks on a fresh machine, which
  # is precisely the machine where a paste-this-by-hand block is the whole
  # of the answer. They are content the user copies, not diagnostics, so
  # they go to stdout in every branch and the warnings stay on stderr.
  #
  # Every assertion here keeps the two streams in two files. Merging them
  # with 2>&1 is what made the defect invisible for as long as it lasted.
  streams() {
    # streams HOME SHELL BIN_DIR SHELL_DIR [ARG...]
    local h=$1 sh=$2 b=$3 s=$4
    shift 4
    set +e
    HOME="$h" SHELL="$sh" PATH="/usr/bin:/bin" \
      "$fix/install.sh" --dir "$b" --shell-dir "$s" "$@" \
      >"$work/stdout" 2>"$work/stderr"
    RC=$?
    set -e
    OUT=$(cat "$work/stdout")
    ERR=$(cat "$work/stderr")
  }

  says() {
    # says TEXT NEEDLE LABEL
    case $1 in
      *"$2"*) pass "$3" ;;
      *)      fail "$3" ;;
    esac
  }
  says_not() {
    # says_not TEXT NEEDLE LABEL
    case $1 in
      *"$2"*) fail "$3" ;;
      *)      pass "$3" ;;
    esac
  }

  # A fresh machine: HOME exists, no rc file in it. This is the branch that
  # used to lose both blocks.
  hfresh="$work/h-fresh"
  mkdir -p "$hfresh"
  streams "$hfresh" /bin/bash "$work/bin-fresh" "$work/sd-fresh" --dry-run
  assert_eq "0" "$RC" "a dry run with no rc file still exits 0"
  says     "$OUT" "export PATH=\"$work/bin-fresh:\$PATH\"" "with no rc file the PATH line is on stdout"
  says_not "$ERR" "export PATH=\"$work/bin-fresh:\$PATH\"" "and not on stderr"
  says     "$OUT" "_wd40_load_aliases"                     "and the loader block is on stdout too"
  says_not "$ERR" "_wd40_load_aliases"                     "and not on stderr either"

  # The same run's warnings are diagnostics and stay where diagnostics go.
  says     "$ERR" "is not in any shell's startup files"    "while the PATH warning is on stderr"
  says_not "$OUT" "is not in any shell's startup files"    "and not on stdout"
  says     "$ERR" "nothing in your startup files mentions" "and so is the loader warning"
  says_not "$OUT" "nothing in your startup files mentions" "and it is not on stdout either"

  # An rc file that exists takes a different branch in both functions, and
  # it has to answer the same way.
  hrc="$work/h-rc"
  mkdir -p "$hrc"
  printf 'echo hello\n' > "$hrc/.bashrc"
  streams "$hrc" /bin/bash "$work/bin-rc" "$work/sd-rc" --dry-run
  says     "$OUT" "Would add this block to $hrc/.bashrc" "with an rc file the header is on stdout"
  says     "$OUT" 'export PATH='                         "and so is the PATH block"
  says     "$OUT" "_wd40_load_aliases"                   "and so is the loader block"
  says_not "$ERR" "_wd40_load_aliases"                   "and none of it is on stderr"

  # The blank lines that used to be printed ahead of a block now follow it.
  # Two claims, because moving one newline could satisfy either alone: the
  # first block starts straight after the last line above it, and the last
  # thing on stdout is the blank that closes the last block.
  first=$(grep -n -F -- 'Would add this block to' "$work/stdout" |
          sed -n '1s/^\([0-9]*\):.*/\1/p')
  assert_eq "   link $work/sd-rc/lib.sh -> $fix/shell/lib.sh" \
    "$(sed -n "$((first - 1))p" "$work/stdout")" \
    "and no blank line is printed ahead of the first block"
  assert_eq "" "$(sed -n '$p' "$work/stdout")" \
    "while the last line of stdout is the blank that follows the last block"

  # A machine with no rc file at all is the third branch, and it is the one
  # where the block is all the user gets. It used to be reached by naming a
  # shell install.sh could not configure; $SHELL is no longer consulted, so
  # the way in is now the only thing that can genuinely produce it - an
  # empty home directory.
  hf="$work/h-norc"
  mkdir -p "$hf"
  streams "$hf" /usr/bin/fish "$work/bin-fish" "$work/sd-fish"
  says     "$OUT" 'export PATH='       "a machine with no rc file gets the PATH block on stdout"
  says     "$OUT" "_wd40_load_aliases" "and the loader block on stdout"
  says_not "$ERR" "_wd40_load_aliases" "and nothing of either on stderr"
  says     "$ERR" "I found no startup file for" "while the reason stays on stderr"

  # And a shell with no name at all, end to end. Both functions were fixed
  # separately and both are reached by one run, so this is where a fix
  # applied to only one of them would show. The name now comes from the
  # parent process, and this suite's parent is a bash, so the hole between
  # two spaces cannot come back by way of an empty $SHELL either.
  hnn="$work/h-noname"
  mkdir -p "$hnn"
  streams "$hnn" "" "$work/bin-noname" "$work/sd-noname"
  says     "$ERR" "I found no startup file for" \
    "a run with no rc file and no \$SHELL still names the condition"
  says_not "$ERR" "startup file for . " \
    "and leaves no hole between two spaces where the name should be"
  says     "$OUT" "_wd40_load_aliases" "and the block to paste is still on stdout"

  section_report
)
section_end $?

section_begin 'shell rc auto-configuration'
(
  set -e
  section_reset
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  # THE TARGET SET
  #
  # rc_file_for_shell is gone, and with it the whole idea of choosing one rc
  # file out of two. It mapped $SHELL to a single file, $SHELL is the login
  # shell out of the password database, and the author logs in with bash and
  # works in zsh - so his zsh got nothing. What replaces it is a set: every
  # known rc file that exists.
  home="$tmp/home"
  mkdir -p "$home"

  assert_empty "with no rc file at all there are no targets" \
    "$(HOME=$home rc_targets)"

  : > "$home/.bashrc"
  assert_eq "$home/.bashrc" "$(HOME=$home rc_targets)" "a lone ~/.bashrc is the only target"

  : > "$home/.zshrc"
  assert_eq "$(printf '%s\n%s' "$home/.bashrc" "$home/.zshrc")" \
    "$(HOME=$home rc_targets)" "and with both present, both are targets"

  rm -f "$home/.bashrc"
  assert_eq "$home/.zshrc" "$(HOME=$home rc_targets)" "a lone ~/.zshrc is the only target"

  # A file that is not there is not a target, and is not created to become
  # one: the block to paste by hand is what a machine with no rc file gets.
  rm -f "$home/.zshrc"
  assert_empty "a target set is filtered by what exists, not by what could" \
    "$(HOME=$home rc_targets)"
  assert_fail 1 "and asking never creates one" test -e "$home/.zshrc"

  # PER-SHELL CHAINS
  #
  # The scoping that makes "already configured" a question with one answer
  # per shell instead of one per machine.
  bash_chain=$(HOME=$home rc_chain_for "$home/.bashrc" | tr '\n' ' ')
  assert_eq "$home/.bashrc $home/.bash_profile $home/.bash_aliases $home/.profile " \
    "$bash_chain" "bash's chain is .bashrc, .bash_profile, .bash_aliases and .profile"

  zsh_chain=$(HOME=$home rc_chain_for "$home/.zshrc" | tr '\n' ' ')
  assert_eq "$home/.zshrc $home/.zprofile $home/.zsh_aliases " \
    "$zsh_chain" "zsh's chain is .zshrc, .zprofile and .zsh_aliases"

  # ~/.profile is bash's and not zsh's: zsh does not read it outside
  # sh-emulation, so counting it for zsh would suppress a block zsh needs.
  case $zsh_chain in
    *.profile*) fail "and ~/.profile is not on zsh's chain" ;;
    *)          pass "and ~/.profile is not on zsh's chain" ;;
  esac

  # Every member of a chain names the same chain, so --rc ~/.bash_aliases is
  # scoped exactly as --rc ~/.bashrc is.
  assert_eq "$bash_chain" "$(HOME=$home rc_chain_for "$home/.bash_aliases" | tr '\n' ' ')" \
    "any member of bash's chain names the whole of it"
  assert_eq "$zsh_chain" "$(HOME=$home rc_chain_for "$home/.zprofile" | tr '\n' ' ')" \
    "and any member of zsh's"

  # A file this installer does not recognise is its own chain and nothing
  # else. Inferring a startup chain from ~/.config/fish/config.fish would be
  # the same guessing that has just been taken out of the common path.
  assert_eq "$home/.config/fish/config.fish" \
    "$(HOME=$home rc_chain_for "$home/.config/fish/config.fish")" \
    "an unrecognised file is searched only for itself"

  # And the label each report line carries.
  assert_eq "bash" "$(shell_for_rc "$home/.bashrc")"       "a bash file is labelled bash"
  assert_eq "bash" "$(shell_for_rc "$home/.profile")"      "and so is ~/.profile"
  assert_eq "zsh"  "$(shell_for_rc "$home/.zsh_aliases")"  "a zsh file is labelled zsh"
  capture shell_for_rc "$home/.config/fish/config.fish"
  assert_empty "and an unrecognised file gets no label rather than a guessed one" "$CAPTURED"

  # mentioned_in_chain names the file that matched, not a yes or no: on the
  # author's machine ~/.zshrc names ~/.zsh_aliases and it is that file which
  # names the aliases directory.
  h2="$tmp/h2"
  mkdir -p "$h2"
  : > "$h2/.zshrc"
  : > "$h2/.bashrc"
  printf 'for f in ~/aliases.d/*.sh; do . "$f"; done\n' > "$h2/.zsh_aliases"
  assert_eq "$h2/.zsh_aliases" "$(HOME=$h2 mentioned_in_chain "$h2/.zshrc" "$h2/aliases.d")" \
    "a mention anywhere in zsh's chain is found, and the file is named"
  capture env HOME="$h2" bash -c \
    'WD40_SOURCE_ONLY=1 . "$0"; mentioned_in_chain "$1" "$2"' "$INSTALL" "$h2/.bashrc" "$h2/aliases.d"
  assert_empty "while bash's chain does not see it, which is the whole point" "$CAPTURED"

  # WRITING, WHICH NO LONGER CONSULTS $SHELL
  #
  # Every one of these used to be decided by $SHELL. They are now decided by
  # which files exist, so the same run configures both shells.
  BIN_DIR="$tmp/bin"

  h3="$tmp/h3"
  mkdir -p "$h3"
  HOME="$h3" SHELL=/bin/bash add_to_shell_rc >/dev/null 2>&1
  assert_fail 1 "no rc file: ~/.bashrc is not created" test -e "$h3/.bashrc"
  assert_fail 1 "and neither is ~/.zshrc" test -e "$h3/.zshrc"

  # Both present, so both are written - the defect this change exists to
  # fix, asserted at the level of the function that used to choose.
  h4="$tmp/h4"
  mkdir -p "$h4"
  printf 'echo hello\n' > "$h4/.bashrc"
  printf 'echo hello\n' > "$h4/.zshrc"
  HOME="$h4" SHELL=/bin/bash add_to_shell_rc >/dev/null 2>&1
  case $(cat "$h4/.bashrc") in
    *"added by wd40 install.sh"*"$BIN_DIR"*) pass "~/.bashrc gets the guarded block" ;;
    *) fail "~/.bashrc gets the guarded block" ;;
  esac
  case $(cat "$h4/.zshrc") in
    *"added by wd40 install.sh"*"$BIN_DIR"*) pass "and ~/.zshrc gets it in the same run" ;;
    *) fail "and ~/.zshrc gets it in the same run" ;;
  esac

  before_b=$(cat "$h4/.bashrc"); before_z=$(cat "$h4/.zshrc")
  HOME="$h4" SHELL=/bin/bash add_to_shell_rc >/dev/null 2>&1
  assert_eq "$before_b" "$(cat "$h4/.bashrc")" "re-running does not duplicate the block in ~/.bashrc"
  assert_eq "$before_z" "$(cat "$h4/.zshrc")"  "nor in ~/.zshrc"

  # $SHELL naming a shell this installer has no rc file for used to mean
  # "write nothing anywhere". It now means nothing at all: the files decide.
  h5="$tmp/h5"
  mkdir -p "$h5"
  printf 'echo hello\n' > "$h5/.bashrc"
  HOME="$h5" SHELL=/usr/bin/fish add_to_shell_rc >/dev/null 2>&1
  case $(cat "$h5/.bashrc") in
    *"added by wd40 install.sh"*) pass "a \$SHELL of fish no longer stops ~/.bashrc being written" ;;
    *) fail "a \$SHELL of fish no longer stops ~/.bashrc being written" ;;
  esac

  # An empty or unset $SHELL was a branch of its own and is now not consulted
  # at all. It must still not be a failure, and must still write.
  h6="$tmp/h6"
  mkdir -p "$h6"
  printf 'echo hello\n' > "$h6/.zshrc"
  set +e
  out=$(HOME="$h6" SHELL= add_to_shell_rc 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "an empty SHELL is not a failure"
  case $(cat "$h6/.zshrc") in
    *"added by wd40 install.sh"*) pass "and the rc file that exists is still written" ;;
    *) fail "and the rc file that exists is still written" ;;
  esac
  case $out in
    *"configure  automatically"*) fail "and no sentence has a hole between two spaces in it" ;;
    *)                            pass "and no sentence has a hole between two spaces in it" ;;
  esac

  set +e
  out=$(HOME="$h6"; unset SHELL; add_to_shell_rc 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "an unset SHELL is not a failure either"

  # THE NO-RC-FILE FALLBACK, WHICH IS THE ONE PLACE A SHELL IS STILL NAMED
  #
  # Nothing to write to, so the block is printed and a shell is named. That
  # name comes from the parent process, not from $SHELL - see the parent
  # detection section below for the evidence that it does.
  h7="$tmp/h7"
  mkdir -p "$h7"
  set +e
  out=$(HOME="$h7" SHELL=/bin/bash add_to_shell_rc 2>&1)
  set -e
  case $out in
    *"I found no startup file for"*) pass "with no rc file the run says it found none" ;;
    *)                               fail "with no rc file the run says it found none" ;;
  esac
  case $out in
    *"export PATH=\"$BIN_DIR:\$PATH\""*) pass "and the block to paste is printed anyway" ;;
    *)                                   fail "and the block to paste is printed anyway" ;;
  esac
  assert_fail 1 "and still nothing is created" test -e "$h7/.bashrc"

  # Dry run never writes, to either file.
  h8="$tmp/h8"
  mkdir -p "$h8"
  printf 'echo hello\n' > "$h8/.bashrc"
  printf 'echo hello\n' > "$h8/.zshrc"
  b8=$(cat "$h8/.bashrc"); z8=$(cat "$h8/.zshrc")
  HOME="$h8" SHELL=/bin/bash DRY_RUN=1 add_to_shell_rc >/dev/null 2>&1
  assert_eq "$b8" "$(cat "$h8/.bashrc")" "--dry-run never writes to ~/.bashrc"
  assert_eq "$z8" "$(cat "$h8/.zshrc")"  "nor to ~/.zshrc"

  # add_loader_to_shell_rc is the same shape and gets the same treatment: a
  # fix applied to one of a pair is the defect this file exists to catch.
  SHELL_DIR="$tmp/aliases.d"
  h9="$tmp/h9"
  mkdir -p "$h9"
  printf 'echo hello\n' > "$h9/.bashrc"
  printf 'echo hello\n' > "$h9/.zshrc"
  HOME="$h9" SHELL=/usr/bin/fish add_loader_to_shell_rc >/dev/null 2>&1
  case $(cat "$h9/.bashrc") in
    *_wd40_load_aliases*) pass "the loader goes to ~/.bashrc whatever \$SHELL says" ;;
    *)                    fail "the loader goes to ~/.bashrc whatever \$SHELL says" ;;
  esac
  case $(cat "$h9/.zshrc") in
    *_wd40_load_aliases*) pass "and to ~/.zshrc in the same run" ;;
    *)                    fail "and to ~/.zshrc in the same run" ;;
  esac

  h10="$tmp/h10"
  mkdir -p "$h10"
  set +e
  out=$(HOME="$h10" SHELL= add_loader_to_shell_rc 2>&1)
  rc=$?
  set -e
  assert_eq "0" "$rc" "an empty SHELL is not a failure for the loader either"
  case $out in
    *"I found no startup file for"*) pass "and with no rc file it says it found none" ;;
    *)                               fail "and with no rc file it says it found none" ;;
  esac
  case $out in
    *_wd40_load_aliases*) pass "and the loader block to paste is printed anyway" ;;
    *)                    fail "and the loader block to paste is printed anyway" ;;
  esac

  section_report
)
section_end $?

section_begin 'loader wiring'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  bin="$work/bin"

  # Count the loader block only, by the one name that appears nowhere else.
  # install.sh may append its *other* guarded block - the one that fixes
  # PATH - to the same file, and a byte-for-byte "did .zshrc change?" test
  # would keep being answered by the wrong one of the two.
  #
  # `grep -c` exits 1 on zero matches after printing the 0, so the status
  # is discarded rather than allowed to trip `set -e`.
  loader_lines() {
    if [ -f "$1" ]; then
      grep -c '_wd40_alias_file' "$1" 2>/dev/null || true
    else
      printf '0\n'
    fi
  }

  # BIN_DIR is put on PATH for every run below so that warn_if_not_on_path
  # returns early. Only one of the installer's two blocks may be in play at
  # a time, and these assertions are about the loader.
  run_install() {
    # run_install HOME SHELL SHELL_DIR [ARG...]
    local h=$1 sh=$2 sd=$3 rc
    shift 3
    set +e
    HOME="$h" SHELL="$sh" PATH="$bin:$PATH" \
      "$fix/install.sh" --dir "$bin" --shell-dir "$sd" "$@" >/dev/null 2>&1
    rc=$?
    set -e
    return "$rc"
  }

  # Nothing mentions SHELL_DIR anywhere: the block is written.
  h="$work/h-fresh"
  mkdir -p "$h"
  : > "$h/.zshrc"
  run_install "$h" /bin/zsh "$work/sd-fresh" || true
  assert_eq "3" "$(loader_lines "$h/.zshrc")" "the loader block is appended to ~/.zshrc"
  assert_ok  "and the shell file was linked"  test -L "$work/sd-fresh/lib.sh"

  # Re-running is not allowed to grow the file.
  run_install "$h" /bin/zsh "$work/sd-fresh" || true
  assert_eq "3" "$(loader_lines "$h/.zshrc")" "re-running does not append the block twice"

  # The same for bash, whose rc file is a different one.
  hb="$work/h-bash"
  mkdir -p "$hb"
  : > "$hb/.bashrc"
  run_install "$hb" /bin/bash "$work/sd-bash" || true
  assert_eq "3" "$(loader_lines "$hb/.bashrc")" "the loader block is appended to ~/.bashrc for bash"

  # THE AUTHOR'S LAYOUT. ~/.zshrc sources ~/.zsh_aliases, and it is that
  # file which names ~/.zsh_aliases.d. Grepping only the rc gives a
  # confident false negative and appends a second, redundant loader to a
  # configuration that already worked - a regression on the one machine
  # this feature was written for.
  ha="$work/h-author"
  mkdir -p "$ha"
  sda="$work/sd-author"
  : > "$ha/.zshrc"
  printf 'for f in %s/*.sh; do . "$f"; done\n' "$sda" > "$ha/.zsh_aliases"
  run_install "$ha" /bin/zsh "$sda" || true
  assert_eq "0" "$(loader_lines "$ha/.zshrc")" "~/.zsh_aliases mentioning SHELL_DIR leaves ~/.zshrc alone"
  assert_ok  "and the shell file was still linked" test -L "$sda/lib.sh"

  # Every other file in zsh's chain counts for the same reason - and no
  # file outside it does. This loop used to run over all six files the old
  # global search read, and it passed for every one of them; that it passed
  # for `.bash_aliases` and `.profile` is precisely the defect. A file bash
  # reads cannot speak for zsh.
  #
  # Both halves are asserted in one loop, because a fix that suppressed
  # nothing at all would satisfy the first half alone.
  for name in .zshrc .zprofile .zsh_aliases; do
    hn="$work/h-zmentions$name"
    mkdir -p "$hn"
    sdn="$work/sd-zmentions$name"
    : > "$hn/.zshrc"
    printf 'something already sources %s\n' "$sdn" > "$hn/$name"
    run_install "$hn" /bin/zsh "$sdn" || true
    assert_eq "0" "$(loader_lines "$hn/.zshrc")" "$name mentioning SHELL_DIR suppresses the block in ~/.zshrc"
    assert_ok  "$name case: the shell file was still linked" test -L "$sdn/lib.sh"
  done

  # THE REVERSAL
  #
  # A file on bash's chain no longer suppresses zsh's block, and a file on
  # zsh's no longer suppresses bash's. Under the old global search each of
  # these wrote nothing and reported success, which is how the author ended
  # up with a loader in neither of the shells that needed one.
  for name in .bashrc .bash_profile .bash_aliases .profile; do
    hn="$work/h-bmentions$name"
    mkdir -p "$hn"
    sdn="$work/sd-bmentions$name"
    : > "$hn/.zshrc"
    printf 'something already sources %s\n' "$sdn" > "$hn/$name"
    run_install "$hn" /bin/zsh "$sdn" || true
    assert_eq "3" "$(loader_lines "$hn/.zshrc")" \
      "$name mentioning SHELL_DIR does not suppress the block in ~/.zshrc"
    # And the bash file it was written in is left alone, because bash's own
    # chain does mention it. One run, two shells, two different answers.
    if [ "$name" = ".bashrc" ]; then
      assert_eq "0" "$(loader_lines "$hn/.bashrc")" \
        "$name case: while ~/.bashrc itself is left alone"
    fi
  done

  # The same reversal read from the other side: a zsh file does not speak
  # for bash. ~/.zsh_aliases is the author's own case, and ~/.bashrc is the
  # file that must still be written.
  hz="$work/h-zsh-not-bash"
  mkdir -p "$hz"
  sdz="$work/sd-zsh-not-bash"
  : > "$hz/.bashrc"
  : > "$hz/.zshrc"
  printf 'something already sources %s\n' "$sdz" > "$hz/.zsh_aliases"
  run_install "$hz" /bin/zsh "$sdz" || true
  assert_eq "3" "$(loader_lines "$hz/.bashrc")" \
    "~/.zsh_aliases mentioning SHELL_DIR does not suppress the block in ~/.bashrc"
  assert_eq "0" "$(loader_lines "$hz/.zshrc")" \
    "while ~/.zshrc, whose chain does mention it, is left alone"

  # A run that installed nothing but scripts has no reason to talk about
  # SHELL_DIR at all, let alone to edit an rc file over it.
  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/only.sh"
  hs="$work/h-scripts-only"
  mkdir -p "$hs"
  : > "$hs/.zshrc"
  set +e
  HOME="$hs" SHELL=/bin/zsh PATH="$work/bin-s:$PATH" \
    "$fixs/install.sh" --dir "$work/bin-s" --shell-dir "$work/sd-s" >/dev/null 2>&1
  set -e
  assert_eq "0" "$(loader_lines "$hs/.zshrc")" "a run that linked only scripts writes no loader block"

  # --dry-run has to be loud about this and still write nothing. Editing a
  # user's .zshrc is the most invasive thing this installer does, so it is
  # the one step a dry run must not pass over in silence - but a dry run
  # that left a byte behind would be a worse bug than the silence was.
  #
  # BIN_DIR is kept *off* PATH here, unlike every other run in this block,
  # because both of the installer's blocks are in play: this is the only
  # place that asserts the PATH block and the loader block are printed by
  # the same run.
  hd="$work/h-dry"
  mkdir -p "$hd"
  printf 'echo hello\n' > "$hd/.zshrc"
  before=$(cat "$hd/.zshrc")
  set +e
  out=$(HOME="$hd" SHELL=/bin/zsh PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$work/bin-dry" --shell-dir "$work/sd-dry" --dry-run 2>&1)
  set -e
  assert_eq "0" "$(loader_lines "$hd/.zshrc")"  "--dry-run never writes the loader block"
  assert_eq "$before" "$(cat "$hd/.zshrc")"     "--dry-run leaves an existing rc file byte for byte"
  assert_fail 1 "--dry-run creates no script directory" test -e "$work/bin-dry"
  assert_fail 1 "--dry-run creates no shell directory"  test -e "$work/sd-dry"
  case $out in
    *"Would add this block to $hd/.zshrc"*) pass "--dry-run names the rc file it would have written to" ;;
    *)                                      fail "--dry-run names the rc file it would have written to" ;;
  esac
  case $out in
    *_wd40_load_aliases*) pass "--dry-run prints the loader block it would have written" ;;
    *)                    fail "--dry-run prints the loader block it would have written" ;;
  esac
  case $out in
    *"export PATH=\"$work/bin-dry:\$PATH\""*) pass "--dry-run prints the PATH block from the same run" ;;
    *)                                        fail "--dry-run prints the PATH block from the same run" ;;
  esac

  # The same guarantee with no rc file to append to, which is a different
  # branch in both functions: it prints the block to paste, and creating
  # the missing file is exactly the temptation it must resist.
  hn="$work/h-dry-no-rc"
  mkdir -p "$hn"
  set +e
  out=$(HOME="$hn" SHELL=/bin/zsh PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$work/bin-dry2" --shell-dir "$work/sd-dry2" --dry-run 2>&1)
  set -e
  assert_fail 1 "--dry-run does not create a missing rc file" test -e "$hn/.zshrc"
  capture ls -A "$hn"
  assert_empty "--dry-run leaves an empty HOME empty" "$CAPTURED"
  assert_fail 1 "--dry-run with no rc file creates no script directory" test -e "$work/bin-dry2"
  assert_fail 1 "--dry-run with no rc file creates no shell directory"  test -e "$work/sd-dry2"
  case $out in
    *_wd40_load_aliases*) pass "--dry-run with no rc file still prints the loader block to paste" ;;
    *)                    fail "--dry-run with no rc file still prints the loader block to paste" ;;
  esac
  case $out in
    *"export PATH=\"$work/bin-dry2:\$PATH\""*) pass "--dry-run with no rc file still prints the PATH line to paste" ;;
    *)                                         fail "--dry-run with no rc file still prints the PATH line to paste" ;;
  esac

  # A $SHELL this installer used to refuse to configure now changes nothing
  # at all: the rc files that exist are the targets, and both of them get
  # the block. This assertion is the exact reverse of the one it replaces,
  # which said "and ~/.zshrc is not written" - and that refusal is what left
  # a fish user, and everybody else whose $SHELL was not the shell they were
  # using, with two rc files the installer had looked at and declined to fix.
  hf="$work/h-fish"
  mkdir -p "$hf"
  : > "$hf/.zshrc"
  : > "$hf/.bashrc"
  set +e
  HOME="$hf" SHELL=/bin/fish PATH="$bin:$PATH" \
    "$fix/install.sh" --dir "$bin" --shell-dir "$work/sd-fish" >/dev/null 2>&1
  set -e
  assert_eq "3" "$(loader_lines "$hf/.zshrc")"  "a \$SHELL of fish does not stop ~/.zshrc being written"
  assert_eq "3" "$(loader_lines "$hf/.bashrc")" "nor ~/.bashrc, in the same run"

  # And with no rc file to write to, the block is still printed to paste.
  # That is the one branch where a shell is named, and the name comes from
  # the parent process rather than from $SHELL.
  hfn="$work/h-fish-norc"
  mkdir -p "$hfn"
  set +e
  out=$(HOME="$hfn" SHELL=/bin/fish PATH="$bin:$PATH" \
    "$fix/install.sh" --dir "$bin" --shell-dir "$work/sd-fish2" 2>&1)
  set -e
  case $out in
    *_wd40_alias_file*) pass "with no rc file at all the block is printed to paste" ;;
    *)                  fail "with no rc file at all the block is printed to paste" ;;
  esac
  assert_fail 1 "and no rc file is brought into existence to hold it" test -e "$hfn/.zshrc"

  section_report
)
section_end $?

section_begin 'path spellings'
(
  set -e
  section_reset
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  # The expected values below are single-quoted so that the `$HOME` and
  # `${HOME}` in them stay the six and eight characters a startup file
  # would contain. A double-quoted expectation would be expanded by this
  # test and would then agree with an installer that expanded it too.
  assert_eq '/home/user/x/y ~/x/y $HOME/x/y ${HOME}/x/y ' \
    "$(HOME=/home/user spellings_for /home/user/x/y | tr '\n' ' ')" \
    "a directory under \$HOME has four spellings"

  assert_eq '/opt/tools ' \
    "$(HOME=/home/user spellings_for /opt/tools | tr '\n' ' ')" \
    "a directory outside \$HOME has one"

  # /home/user2 begins with every character of /home/user and is somebody
  # else's home. A substring test would rewrite it to ~2/x; matching on
  # "$HOME"/* in a case is what refuses to.
  assert_eq '/home/user2/x ' \
    "$(HOME=/home/user spellings_for /home/user2/x | tr '\n' ' ')" \
    "a sibling home is not mistaken for one under \$HOME"

  # $HOME itself is a path, not a prefix of one, and gets the same answer
  # as any other directory that is not under $HOME.
  assert_eq '/home/user ' \
    "$(HOME=/home/user spellings_for /home/user | tr '\n' ' ')" \
    "\$HOME itself has one spelling"

  # An empty or unset $HOME, and a $HOME of /, would each make every
  # absolute path look like it lived under the home directory. Neither may
  # produce a ~ form, because there is no home directory to abbreviate.
  assert_eq '/home/user/x ' \
    "$(HOME= spellings_for /home/user/x | tr '\n' ' ')" \
    "an empty \$HOME abbreviates nothing"

  assert_eq '/home/user/x ' \
    "$(unset HOME; spellings_for /home/user/x | tr '\n' ' ')" \
    "an unset \$HOME abbreviates nothing"

  assert_eq '/home/user/x ' \
    "$(HOME=/ spellings_for /home/user/x | tr '\n' ' ')" \
    "a \$HOME of / abbreviates nothing"

  # And the spellings are what a file is searched for, one at a time.
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)
  HOME="$work"
  export HOME

  printf 'for f in ~/aliases.d/*.sh; do . "$f"; done\n' > "$work/rc-tilde"
  printf 'for f in $HOME/aliases.d/*.sh; do . "$f"; done\n' > "$work/rc-dollar"
  printf 'for f in ${HOME}/aliases.d/*.sh; do . "$f"; done\n' > "$work/rc-braced"
  printf 'for f in %s/aliases.d/*.sh; do . "$f"; done\n' "$work" > "$work/rc-expanded"
  printf 'nothing to see here\n' > "$work/rc-silent"

  assert_ok     "a tilde spelling counts as a mention"    mentions_dir "$work/rc-tilde"    "$work/aliases.d"
  assert_ok     "so does \$HOME"                          mentions_dir "$work/rc-dollar"   "$work/aliases.d"
  assert_ok     "so does \${HOME}"                        mentions_dir "$work/rc-braced"   "$work/aliases.d"
  assert_ok     "so does the expanded path"               mentions_dir "$work/rc-expanded" "$work/aliases.d"
  assert_fail 1 "and a file that says none of them does not" mentions_dir "$work/rc-silent" "$work/aliases.d"

  # grep -F throughout, so `$`, `{`, `}` and the dots in a name like
  # .zsh_aliases.d are characters to look for rather than pattern syntax.
  printf 'mentions %s/aXbliases.d here\n' "$work" > "$work/rc-regex"
  assert_fail 1 "the expanded spelling is matched literally" \
    mentions_dir "$work/rc-regex" "$work/a.bliases.d"

  printf 'mentions ~/aXb here\n' > "$work/rc-regex-tilde"
  assert_fail 1 "and so is the tilde spelling" \
    mentions_dir "$work/rc-regex-tilde" "$work/a.b"

  # A spelling that begins with `-` is a string to find, not a flag bundle.
  # `grep -F "-x" file` is `grep -F -x file`: the pattern is eaten as the
  # exact-line flag, the *file* becomes the pattern, and grep then blocks
  # reading stdin. `</dev/null` below is what keeps the failing form from
  # hanging this suite rather than failing it. This is the same fault the
  # portability guard had, where it had left one of twenty-two rows unable
  # to fire.
  printf 'mentions -x here\n' > "$work/rc-dash"
  set +e
  ( mentions_dir "$work/rc-dash" "-x" ) </dev/null >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "0" "$rc" "a directory whose name opens with a dash is still looked for"
  set +e
  ( mentions_dir "$work/rc-silent" "-x" ) </dev/null >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "1" "$rc" "and a file that does not name it still says so"

  section_report
)
section_end $?

section_begin 'a file name with a newline in it'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  # `$(printf '\n')` is the one value command substitution is guaranteed to
  # throw away, so the newline is carried past it on the back of a sentinel.
  nl=$(printf '\nX')
  nl=${nl%X}

  # Discovery is `find | while read`, which splits on newlines, so
  # `two<newline>lines.sh` arrives as two half-paths and neither of them is
  # the file. Reproduced before the refusal existed: with a `lines.sh` in
  # the working directory the run announced
  # `link .../bin/lines -> lines.sh`, exited 0, left a relative symlink on
  # PATH that dangles from every directory but one, and then the
  # uninstaller declined to remove it because a relative target does not
  # resolve inside the repository. A permanent broken command on PATH is
  # the outcome being refused here.
  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/ok.sh"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/two${nl}lines.sh"

  # The bogus half made to exist, which is what turned this from a crash
  # into a dangling link. The run below is started from that directory.
  cwd="$work/cwd"
  mkdir -p "$cwd"
  printf '#!/bin/sh\n:\n' > "$cwd/lines.sh"

  set +e
  out=$(cd "$cwd" && "$fix/install.sh" --dir "$work/bin" --shell-dir "$work/sd" 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "a script whose name holds a newline is refused"
  case $out in
    *"a file name contains a newline"*) pass "and the run says what is wrong" ;;
    *)                                  fail "and the run says what is wrong" ;;
  esac
  # The name is printed as the bytes it is, so it arrives on two lines. Both
  # halves are asserted, because naming the file is the whole point of
  # refusing rather than crashing over it.
  case $out in
    *"$fix/scripts/two"*) pass "and names the file, first half" ;;
    *)                    fail "and names the file, first half" ;;
  esac
  case $out in
    *"lines.sh"*) pass "and second half" ;;
    *)            fail "and second half" ;;
  esac
  assert_fail 1 "and nothing at all was linked" test -e "$work/bin"
  assert_fail 1 "not even the file that was fine" test -e "$work/bin/ok"

  # A dry run reads the same repository and reaches the same verdict: this
  # is a property of what is on disk, not of what the run was going to do
  # about it.
  assert_fail 1 "a dry run refuses it too" \
    "$fix/install.sh" --dir "$work/bin-dry" --shell-dir "$work/sd-dry" --dry-run

  # And an uninstall, which would otherwise be acting on a name it misread.
  assert_fail 1 "and so does an uninstall" \
    "$fix/install.sh" --dir "$work/bin" --shell-dir "$work/sd" --uninstall

  # shell/ is discovered by the same machinery and gets the same answer.
  fixs="$work/repo-shell"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts" "$fixs/shell"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/ok.sh"
  printf 'A=1\n'          > "$fixs/shell/two${nl}lines.sh"
  set +e
  out=$("$fixs/install.sh" --dir "$work/bin-s" --shell-dir "$work/sd-s" 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "a shell file whose name holds a newline is refused"
  case $out in
    *"a file name contains a newline"*) pass "in the same words" ;;
    *)                                  fail "in the same words" ;;
  esac
  assert_fail 1 "and nothing was linked for it either" test -e "$work/bin-s"

  # A directory with a newline in its name is the same defect one level up:
  # every path underneath it carries the newline, and `-type f` would have
  # looked straight past the directory itself.
  fixd="$work/repo-dir"
  make_fixture "$fixd"
  mkdir -p "$fixd/scripts/two${nl}lines"
  printf '#!/bin/sh\n:\n' > "$fixd/scripts/two${nl}lines/inner.sh"
  assert_fail 1 "a directory whose name holds a newline is refused as well" \
    "$fixd/install.sh" --dir "$work/bin-d" --shell-dir "$work/sd-d"

  # And a repository with nothing of the sort in it is unaffected, which is
  # what stops the check being a way to fail every run.
  fixok="$work/repo-ok"
  make_fixture "$fixok"
  mkdir -p "$fixok/scripts" "$fixok/shell"
  printf '#!/bin/sh\n:\n' > "$fixok/scripts/ok.sh"
  printf 'A=1\n'          > "$fixok/shell/ok.sh"
  assert_ok "an ordinary repository is not refused" \
    "$fixok/install.sh" --dir "$work/bin-ok" --shell-dir "$work/sd-ok"
  assert_ok "and its script was linked" test -L "$work/bin-ok/ok"

  section_report
)
section_end $?

section_begin 'a trailing slash on a directory'
(
  set -e
  section_reset
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  # Shell tab-completion supplies the slash for free, so
  # `--shell-dir ~/.zsh_aliases.d/` is what a user types without meaning
  # anything by it. It used to reach spellings_for intact, which then
  # offered `~/x/`, `$HOME/x/` and `${HOME}/x/` to a search of an rc file
  # that writes `~/x` - every spelling missed, the installer concluded
  # nothing sourced the directory, and appended a second loader to a
  # configuration that already worked. That false negative is the worst
  # outcome this design has, and one keystroke bought it.
  assert_eq "/x/y" "$(strip_trailing_slashes /x/y/)"    "one trailing slash goes"
  assert_eq "/x/y" "$(strip_trailing_slashes /x/y///)"  "and so do several"
  assert_eq "/x/y" "$(strip_trailing_slashes /x/y)"     "a path without one is left alone"
  assert_eq "/"    "$(strip_trailing_slashes /)"        "root keeps its slash: it has nothing else"
  assert_eq "/"    "$(strip_trailing_slashes ///)"      "and a value that is nothing but slashes is root"
  # The empty string is not turned into root on the way past. Refusing an
  # empty directory is done at parse time, by the code whose job it is, and
  # a normaliser that quietly invented `/` here would take that decision
  # away from it. `$( )` is how every caller reads this, so it is how the
  # claim is stated.
  assert_eq ""     "$(strip_trailing_slashes '')"       "an empty value stays empty rather than becoming root"

  # One path, one spelling. A trailing slash on the directory, and a
  # trailing slash on $HOME, are two different ways of reaching the same
  # wrong answer.
  assert_eq '/home/user/x/y ~/x/y $HOME/x/y ${HOME}/x/y ' \
    "$(HOME=/home/user/ spellings_for /home/user/x/y | tr '\n' ' ')" \
    "a trailing slash on \$HOME changes none of a directory's four spellings"
  # And the division of labour, said out loud: spellings_for normalises
  # $HOME because $HOME is the environment's and arrives however it arrives,
  # and takes the directory as given because main normalised it the moment
  # it was parsed. A second normalisation point here would be a second
  # place for the rule to drift.
  assert_eq '/home/user/x/y/ ~/x/y/ $HOME/x/y/ ${HOME}/x/y/ ' \
    "$(HOME=/home/user/ spellings_for /home/user/x/y/ | tr '\n' ' ')" \
    "and the directory is taken as given, because main has already stripped it"
  assert_eq '/home/user/x ' \
    "$(HOME=// spellings_for /home/user/x | tr '\n' ' ')" \
    "a \$HOME of // is a \$HOME of / and abbreviates nothing"

  # And the whole of it end to end, on the layout it damages.
  #
  # WD40_SOURCE_ONLY is exported above so that sourcing this file defines
  # its functions instead of running an install - and an exported variable
  # is inherited, so every child install.sh below would have done the same
  # thing: define its functions, run nothing, exit 0, and leave every
  # assertion here passing over a run that never happened. Taking it out of
  # the environment is what makes the rest of this section a test.
  unset WD40_SOURCE_ONLY

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  loader_lines() {
    if [ -f "$1" ]; then
      grep -c '_wd40_alias_file' "$1" 2>/dev/null || true
    else
      printf '0\n'
    fi
  }

  h="$work/home"
  sd="$h/.zsh_aliases.d"
  mkdir -p "$sd"
  # ~/.zshrc already names BIN_DIR, so the PATH block is suppressed by file
  # evidence and the loader is the only block that could reach this file.
  # It used to be enough to put BIN_DIR on the live PATH; that no longer
  # decides whether a startup file is written, and this is the isolation
  # that replaces it.
  printf 'export PATH="%s:$PATH"\n' "$work/bin" > "$h/.zshrc"
  # An rc that names the directory and then puts the slash somewhere else,
  # which is the shape the old spellings could not match.
  printf 'wd40_dir=~/.zsh_aliases.d\nfor f in "$wd40_dir"/*.sh; do . "$f"; done\n' \
    > "$h/.zsh_aliases"
  cp "$h/.zshrc" "$work/zshrc-before"

  set +e
  out=$(HOME="$h" SHELL=/bin/zsh PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$work/bin" --shell-dir "$sd/" 2>&1)
  set -e
  assert_eq "0" "$(loader_lines "$h/.zshrc")" \
    "--shell-dir with a trailing slash still finds the file that sources it"
  if cmp -s "$work/zshrc-before" "$h/.zshrc"; then
    pass "and ~/.zshrc is left byte for byte"
  else
    fail "and ~/.zshrc is left byte for byte"
  fi
  case $out in
    *"$h/.zsh_aliases already mentions"*) pass "and the file that handles it is named" ;;
    *)                                    fail "and the file that handles it is named" ;;
  esac
  # The directory the user is told about is the one they will type again,
  # so the slash must not survive into the message either.
  case $out in
    *"already mentions $sd - "*) pass "and the slash is gone from what is said back to them" ;;
    *)                           fail "and the slash is gone from what is said back to them" ;;
  esac
  assert_ok "and the shell file landed in the directory without it" test -L "$sd/lib.sh"

  # The PATH half has the same weakness. `case ":$PATH:" in *":$BIN_DIR:"*`
  # cannot see /x/bin on PATH when BIN_DIR says /x/bin/, so the installer
  # believed it had a problem to fix and offered to edit a startup file
  # over a directory that was already there.
  #
  # A repository with nothing sourceable, so that the loader block cannot
  # be what changes the rc file and "did it change?" has one possible
  # answer.
  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/tool.sh"

  h2="$work/home2"
  mkdir -p "$h2"
  bin2="$work/bin2"
  mkdir -p "$bin2"
  # The rc file names the directory without the slash, and the live PATH
  # holds it without the slash, while --dir is given it with one. Both
  # normalisations have to work for this run to have nothing to say: the
  # one in mentions_dir, which is what makes the file count, and the one in
  # the `case ":$PATH:"`, which is what makes the silence legal.
  printf 'export PATH="%s:$PATH"\n' "$bin2" > "$h2/.bashrc"
  cp "$h2/.bashrc" "$work/bashrc-before"
  set +e
  HOME="$h2" SHELL=/bin/bash PATH="$bin2:/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$bin2/" --shell-dir "$work/sd2" \
    >/dev/null 2>"$work/slash.err"
  set -e
  out=$(cat "$work/slash.err")
  case $out in
    *"is not in any shell's startup files"*) fail "--dir with a trailing slash is still seen on PATH" ;;
    *)                       pass "--dir with a trailing slash is still seen on PATH" ;;
  esac
  # `[ -s ]` and not a command substitution, which strips the trailing
  # newline and so cannot tell one blank line from no output at all.
  if [ -s "$work/slash.err" ]; then
    fail "and a run with nothing to fix says nothing at all"
    sed 's/^/       /' "$work/slash.err"
  else
    pass "and a run with nothing to fix says nothing at all"
  fi
  if cmp -s "$work/bashrc-before" "$h2/.bashrc"; then
    pass "and ~/.bashrc gains no PATH block it did not need"
  else
    fail "and ~/.bashrc gains no PATH block it did not need"
  fi
  assert_ok "and the script landed in the directory without the slash" test -L "$bin2/tool"

  # A directory that is nothing but slashes is root, and the two spellings
  # have to be the same run. What root's own link path then looks like is
  # not asserted here: `/` keeps its slash on purpose, so `$BIN_DIR/$name`
  # is `//tool`, which is `/tool` and is nobody's business but the
  # filesystem's.
  set +e
  out1=$(HOME="$h2" "$fixs/install.sh" --dir=/ --shell-dir "$work/sd3" --dry-run 2>/dev/null)
  out2=$(HOME="$h2" "$fixs/install.sh" --dir=/// --shell-dir "$work/sd3" --dry-run 2>/dev/null)
  set -e
  assert_eq "$out1" "$out2" "a --dir of /// is the same run as a --dir of /"

  section_report
)
section_end $?

section_begin 'startup files that spell the directory differently'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  # A repository with nothing sourceable in it, for the BIN_DIR half
  # below: with no shell file linked the installer never reaches the
  # loader, so the only block that can reach the rc file is the PATH one
  # and "did the file change?" has a single possible answer.
  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/tool.sh"

  # `$(cat file)` throws away trailing newlines, so two files differing
  # only in how many they end with compare equal under it. `cmp` is POSIX,
  # is on BSD and GNU alike, and is the only one of the two that can say
  # "byte for byte" and mean it.
  assert_unchanged() {
    # assert_unchanged SNAPSHOT FILE LABEL
    if cmp -s "$1" "$2"; then pass "$3"; else fail "$3"; fi
  }

  # The four ways a startup file can name a directory under $HOME. The
  # last three are single-quoted so this test writes the characters a
  # human would have typed rather than what they expand to here.
  #
  # These are looped over rather than written out, and so is the file
  # list: the claim is that every spelling counts in every file on the
  # chain, and twelve hand-written cases is twelve chances to leave one
  # out.
  #
  # The file list is zsh's chain and not the old list of six. A file bash
  # reads is not evidence about zsh, which is what the reversal asserted in
  # == loader wiring == is about; here the question is only whether every
  # spelling is seen in every file that genuinely counts.
  SPELLINGS="expanded tilde dollar braced"
  FILES=".zshrc .zprofile .zsh_aliases"

  for form in $SPELLINGS; do
    for name in $FILES; do
      h="$work/h-shell-$form$name"
      mkdir -p "$h"
      sd="$h/aliases.d"
      case $form in
        expanded) spelling="$sd" ;;
        tilde)    spelling='~/aliases.d' ;;
        dollar)   spelling='$HOME/aliases.d' ;;
        braced)   spelling='${HOME}/aliases.d' ;;
      esac

      # ~/.zshrc already names BIN_DIR, so the PATH block is suppressed by
      # file evidence and the loader is the only block that could reach
      # this file - which is what "left byte for byte" is a claim about.
      #
      # BIN_DIR is deliberately kept *off* the live PATH. It used to be put
      # on it to achieve the same isolation, and that no longer isolates
      # anything: the live $PATH is a fact about this process and no longer
      # decides whether a startup file gets written. Keeping it off is the
      # stronger test - if the rc file stopped suppressing the PATH block,
      # this assertion would go red rather than passing on an accident of
      # the environment.
      printf 'export PATH="%s:$PATH"\n' "$work/bin-shell" > "$h/.zshrc"
      # Appended, not written, because for one of the three rows this is
      # the same file as the line above.
      printf 'for f in %s/*.sh; do . "$f"; done\n' "$spelling" >> "$h/$name"
      cp "$h/.zshrc" "$work/snapshot"

      set +e
      out=$(HOME="$h" SHELL=/bin/zsh PATH="/usr/bin:/bin" \
        "$fix/install.sh" --dir "$work/bin-shell" --shell-dir "$sd" 2>&1)
      set -e

      assert_unchanged "$work/snapshot" "$h/.zshrc" \
        "$form in $name: ~/.zshrc is left byte for byte"
      assert_ok "$form in $name: the shell file is still linked" test -L "$sd/lib.sh"
      case $out in
        *"$h/$name already mentions"*) pass "$form in $name: the message names the file" ;;
        *)                             fail "$form in $name: the message names the file" ;;
      esac
    done
  done

  # The PATH check has the same weakness and the same fix. An rc that
  # already puts BIN_DIR on PATH by any of these spellings must not gain a
  # second block saying so.
  for form in $SPELLINGS; do
    h="$work/h-path-$form"
    mkdir -p "$h"
    bin="$h/.local/sbin"
    case $form in
      expanded) spelling="$bin" ;;
      tilde)    spelling='~/.local/sbin' ;;
      dollar)   spelling='$HOME/.local/sbin' ;;
      braced)   spelling='${HOME}/.local/sbin' ;;
    esac

    printf 'export PATH="%s:$PATH"\n' "$spelling" > "$h/.bashrc"
    cp "$h/.bashrc" "$work/snapshot"

    # BIN_DIR is kept off PATH, which is the whole point: the installer
    # believes it has a problem to fix and the rc file is what stops it.
    set +e
    out=$(HOME="$h" SHELL=/bin/bash PATH="/usr/bin:/bin" \
      "$fixs/install.sh" --dir "$bin" --shell-dir "$work/sd-path-$form" 2>&1)
    set -e

    assert_unchanged "$work/snapshot" "$h/.bashrc" \
      "$form for BIN_DIR: ~/.bashrc gains no second PATH block"
    assert_ok "$form for BIN_DIR: the script is still linked" test -L "$bin/tool"
    case $out in
      *"$h/.bashrc already mentions it"*) pass "$form for BIN_DIR: the message names the rc file" ;;
      *)                                  fail "$form for BIN_DIR: the message names the rc file" ;;
    esac
  done

  section_report
)
section_end $?

section_begin "the author's own layout"
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  # The machine this feature was written for, reproduced from its actual
  # dotfiles: ~/.zshrc sources ~/.zsh_aliases by ${HOME} and never names
  # the .d directory at all, and ~/.zsh_aliases names it with a tilde.
  #
  # A real install against this layout used to append a second loader to a
  # configuration that already worked, which is the worst outcome this
  # installer has. Nothing may be written here.
  h="$work/home"
  mkdir -p "$h"
  sd="$h/.zsh_aliases.d"

  cat <<'ZSHRC' > "$h/.zshrc"
if [ -r "${HOME}/.zsh_aliases" ]; then
  . "${HOME}/.zsh_aliases"
fi
ZSHRC

  # The PATH half is taken out of play by file evidence rather than by the
  # live $PATH, which no longer decides whether a startup file is written.
  # Without this line ~/.zshrc would legitimately gain the PATH block and
  # "left byte for byte" would be answered by the wrong one of the two.
  # The shape with both blocks genuinely in play is asserted in
  # == every known rc file == below, which is the author's real machine.
  printf 'export PATH="%s:$PATH"\n' "$work/bin" >> "$h/.zshrc"

  cat <<'ALIASES' > "$h/.zsh_aliases"
if [ -d ~/.zsh_aliases.d ]; then
  for alias_file in ~/.zsh_aliases.d/*.sh; do
    if [ -x "$alias_file" ]; then
      . "$alias_file"
    fi
  done
  unset alias_file
fi
ALIASES

  cp "$h/.zshrc"       "$work/zshrc-before"
  cp "$h/.zsh_aliases" "$work/aliases-before"

  set +e
  out=$(HOME="$h" SHELL=/bin/zsh PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$work/bin" --shell-dir "$sd" 2>&1)
  set -e

  if cmp -s "$work/zshrc-before" "$h/.zshrc"; then
    pass "~/.zshrc is left byte for byte"
  else
    fail "~/.zshrc is left byte for byte"
  fi
  if cmp -s "$work/aliases-before" "$h/.zsh_aliases"; then
    pass "~/.zsh_aliases is left byte for byte"
  else
    fail "~/.zsh_aliases is left byte for byte"
  fi

  assert_ok "and the shell file was still linked" test -L "$sd/lib.sh"

  # ~/.zshrc is searched first and says `${HOME}/.zsh_aliases`, which is
  # not a mention of `${HOME}/.zsh_aliases.d`. The file that does mention
  # it is the one the user has to be told about.
  case $out in
    *"$h/.zsh_aliases already mentions"*) pass "and ~/.zsh_aliases is named as the file that handles it" ;;
    *)                                    fail "and ~/.zsh_aliases is named as the file that handles it" ;;
  esac
  case $out in
    *"nothing in your startup files mentions"*) fail "and the false negative is not printed" ;;
    *)                                          pass "and the false negative is not printed" ;;
  esac

  section_report
)
section_end $?

section_begin 'every known rc file'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  # A repository with nothing sourceable, for the runs that are about the
  # PATH block alone: with no shell file linked the loader step is never
  # reached, so "did this file change?" has one possible answer.
  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/tool.sh"

  # The guard line, which is unique to the PATH block. Counting
  # "# added by wd40 install.sh" would count the loader block as well - both
  # carry it - and a file that legitimately holds one of each would read as
  # two PATH blocks. A hand-written `export PATH=` does not match it either,
  # which is what keeps "the file already named the directory" and "the file
  # has our block in it" apart.
  path_lines() {
    if [ -f "$1" ]; then
      grep -c -F 'if [[ ":$PATH:" != *":' "$1" 2>/dev/null || true
    else
      printf '0\n'
    fi
  }
  loader_lines() {
    if [ -f "$1" ]; then
      grep -c '_wd40_alias_file' "$1" 2>/dev/null || true
    else
      printf '0\n'
    fi
  }

  # BOTH RC FILES EXIST, SO BOTH ARE WRITTEN
  #
  # The whole change in one assertion. install.sh used to pick one file out
  # of $SHELL and write to it; a machine with bash and zsh both installed
  # got one working shell and one broken one, and which was which depended
  # on a password-database field the user had probably never seen.
  hb="$work/h-both"
  mkdir -p "$hb"
  : > "$hb/.bashrc"
  : > "$hb/.zshrc"
  set +e
  HOME="$hb" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-both" --shell-dir "$work/sd-both" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hb/.bashrc")" "with both rc files present, ~/.bashrc gets the PATH block"
  assert_eq "1" "$(path_lines "$hb/.zshrc")"  "and ~/.zshrc gets it in the same run"

  # Re-running changes nothing anywhere. Idempotency is per file now, so it
  # has to be asserted per file: a check that answered for the machine
  # would be satisfied by either one of them being right.
  cp "$hb/.bashrc" "$work/both-bashrc"
  cp "$hb/.zshrc"  "$work/both-zshrc"
  set +e
  HOME="$hb" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-both" --shell-dir "$work/sd-both" >/dev/null 2>&1
  set -e
  if cmp -s "$work/both-bashrc" "$hb/.bashrc"; then
    pass "re-running leaves ~/.bashrc byte for byte"
  else
    fail "re-running leaves ~/.bashrc byte for byte"
  fi
  if cmp -s "$work/both-zshrc" "$hb/.zshrc"; then
    pass "and ~/.zshrc byte for byte"
  else
    fail "and ~/.zshrc byte for byte"
  fi

  # ONLY ONE OF THEM EXISTS
  #
  # Existence is the filter, and the file that is not there is not created
  # to become a target: a ~/.zshrc on a machine with no zsh is litter, and
  # the block to paste is what a machine with no rc file gets instead.
  hbo="$work/h-bash-only"
  mkdir -p "$hbo"
  : > "$hbo/.bashrc"
  set +e
  HOME="$hbo" SHELL=/bin/zsh PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-bo" --shell-dir "$work/sd-bo" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hbo/.bashrc")" "with only ~/.bashrc present it is written"
  assert_fail 1 "and ~/.zshrc is not created" test -e "$hbo/.zshrc"

  hzo="$work/h-zsh-only"
  mkdir -p "$hzo"
  : > "$hzo/.zshrc"
  set +e
  HOME="$hzo" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-zo" --shell-dir "$work/sd-zo" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hzo/.zshrc")" "with only ~/.zshrc present it is written"
  assert_fail 1 "and ~/.bashrc is not created" test -e "$hzo/.bashrc"

  # NEITHER EXISTS
  hn="$work/h-neither"
  mkdir -p "$hn"
  set +e
  out=$(HOME="$hn" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$work/bin-n" --shell-dir "$work/sd-n" 2>&1)
  set -e
  capture ls -A "$hn"
  assert_empty "with neither rc file present the home directory is left empty" "$CAPTURED"
  case $out in
    *"export PATH=\"$work/bin-n:\$PATH\""*) pass "and the PATH block is printed to paste" ;;
    *)                                      fail "and the PATH block is printed to paste" ;;
  esac
  case $out in
    *_wd40_load_aliases*) pass "and the loader block with it" ;;
    *)                    fail "and the loader block with it" ;;
  esac

  # THE AUTHOR'S EXACT SHAPE
  #
  # This is the machine the whole change is for, reproduced from his real
  # dotfiles: ~/.zshrc sources ~/.zsh_aliases by ${HOME} and never names
  # the .d directory; ~/.zsh_aliases names it with a tilde; ~/.bashrc
  # already carries the wd40 PATH block from an earlier real install; and
  # both rc files exist.
  #
  # Measured on that machine before the fix: zsh had no ~/.local/sbin on
  # PATH and no `wd40` command, while bash had no `fp`. Half the
  # install was dead in the shell he actually uses, and the run reported
  # success.
  #
  # Four cells, four assertions, because three of them can be right while
  # the fourth is the defect.
  ha="$work/h-author"
  mkdir -p "$ha"
  sda="$ha/.zsh_aliases.d"
  bina="$ha/.local/sbin"

  cat <<'AZSHRC' > "$ha/.zshrc"
if [ -r "${HOME}/.zsh_aliases" ]; then
  . "${HOME}/.zsh_aliases"
fi
AZSHRC

  cat <<'AALIASES' > "$ha/.zsh_aliases"
if [ -d ~/.zsh_aliases.d ]; then
  for alias_file in ~/.zsh_aliases.d/*.sh; do
    if [ -x "$alias_file" ]; then
      . "$alias_file"
    fi
  done
  unset alias_file
fi
AALIASES

  # ~/.bashrc as a previous run left it: the PATH block and nothing about
  # the aliases directory.
  {
    printf "alias ll='ls -l'\n"
    printf '\n# added by wd40 install.sh\n'
    printf 'if [[ ":$PATH:" != *":%s:"* ]]; then\n' "$bina"
    printf '  export PATH="%s:$PATH"\n' "$bina"
    printf 'fi\n'
  } > "$ha/.bashrc"

  cp "$ha/.zsh_aliases" "$work/author-aliases-before"

  set +e
  out=$(HOME="$ha" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$bina" --shell-dir "$sda" 2>&1)
  set -e

  # Cell 1 and 2: the PATH block goes to ~/.zshrc and only there. ~/.bashrc
  # already names the directory, so it keeps the one block it had.
  assert_eq "1" "$(path_lines "$ha/.zshrc")" \
    "the author's shape: the PATH block goes to ~/.zshrc"
  assert_eq "1" "$(path_lines "$ha/.bashrc")" \
    "and ~/.bashrc, which already had one, does not gain a second"

  # Cell 3 and 4: the loader goes to ~/.bashrc and only there. zsh's chain
  # already sources the directory through ~/.zsh_aliases, which under the
  # old global search spoke for bash as well - and so bash got nothing.
  assert_eq "3" "$(loader_lines "$ha/.bashrc")" \
    "the loader goes to ~/.bashrc, whose chain does not source the directory"
  assert_eq "0" "$(loader_lines "$ha/.zshrc")" \
    "and not to ~/.zshrc, whose chain already does"

  # The file that was already right is not touched at all.
  if cmp -s "$work/author-aliases-before" "$ha/.zsh_aliases"; then
    pass "and ~/.zsh_aliases is left byte for byte"
  else
    fail "and ~/.zsh_aliases is left byte for byte"
  fi

  # Neither block lands twice: one run, one copy of each, in one file each.
  assert_eq "2" "$(grep -c 'added by wd40 install.sh' "$ha/.bashrc" 2>/dev/null || true)" \
    "~/.bashrc holds exactly two wd40 blocks: the PATH one it had and the loader"
  assert_eq "1" "$(grep -c 'added by wd40 install.sh' "$ha/.zshrc" 2>/dev/null || true)" \
    "and ~/.zshrc exactly one: the PATH block"

  # The report names every one of the four outcomes.
  case $out in
    *"$ha/.bashrc already mentions it"*) pass "and the report says ~/.bashrc already had the PATH entry" ;;
    *)                                   fail "and the report says ~/.bashrc already had the PATH entry" ;;
  esac
  case $out in
    *"a PATH block was added to $ha/.zshrc"*) pass "and that ~/.zshrc gained one" ;;
    *)                                        fail "and that ~/.zshrc gained one" ;;
  esac
  case $out in
    *"a loader was added to $ha/.bashrc"*) pass "and that ~/.bashrc gained a loader" ;;
    *)                                     fail "and that ~/.bashrc gained a loader" ;;
  esac
  case $out in
    *"$ha/.zsh_aliases already mentions $sda - "*) pass "and that ~/.zsh_aliases already sourced the directory" ;;
    *)                                             fail "and that ~/.zsh_aliases already sourced the directory" ;;
  esac

  # Re-running the author's shape changes nothing in either file.
  cp "$ha/.bashrc" "$work/author-bashrc-1"
  cp "$ha/.zshrc"  "$work/author-zshrc-1"
  set +e
  HOME="$ha" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$bina" --shell-dir "$sda" >/dev/null 2>&1
  set -e
  if cmp -s "$work/author-bashrc-1" "$ha/.bashrc"; then
    pass "re-running the author's shape leaves ~/.bashrc byte for byte"
  else
    fail "re-running the author's shape leaves ~/.bashrc byte for byte"
  fi
  if cmp -s "$work/author-zshrc-1" "$ha/.zshrc"; then
    pass "and ~/.zshrc byte for byte"
  else
    fail "and ~/.zshrc byte for byte"
  fi

  # PER-SHELL SCOPING FOR THE PATH BLOCK
  #
  # == loader wiring == asserts the reversal for the loader. The PATH block
  # is scoped by the same rc_chain_for and has to be asserted separately,
  # because a fix applied to one of a pair is the defect this file exists
  # to catch.
  hp="$work/h-path-scope"
  mkdir -p "$hp"
  binp="$work/bin-scope"
  : > "$hp/.zshrc"
  printf 'export PATH="%s:$PATH"\n' "$binp" > "$hp/.bash_aliases"
  : > "$hp/.bashrc"
  set +e
  HOME="$hp" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$binp" --shell-dir "$work/sd-scope" >/dev/null 2>&1
  set -e
  assert_eq "0" "$(path_lines "$hp/.bashrc")" \
    "~/.bash_aliases naming BIN_DIR suppresses the PATH block in ~/.bashrc"
  assert_eq "1" "$(path_lines "$hp/.zshrc")" \
    "and does not suppress it in ~/.zshrc, which never reads that file"

  hp2="$work/h-path-scope2"
  mkdir -p "$hp2"
  binp2="$work/bin-scope2"
  printf 'export PATH="%s:$PATH"\n' "$binp2" > "$hp2/.zprofile"
  : > "$hp2/.zshrc"
  : > "$hp2/.bashrc"
  set +e
  HOME="$hp2" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$binp2" --shell-dir "$work/sd-scope2" >/dev/null 2>&1
  set -e
  assert_eq "0" "$(path_lines "$hp2/.zshrc")" \
    "~/.zprofile naming BIN_DIR suppresses the PATH block in ~/.zshrc"
  assert_eq "1" "$(path_lines "$hp2/.bashrc")" \
    "and does not suppress it in ~/.bashrc"

  # THE LIVE $PATH NO LONGER SUPPRESSES A WRITE
  #
  # Reproduced on the author's machine: running the installer from a bash
  # whose .bashrc had already put ~/.local/sbin on PATH made the entire
  # PATH step return early, so zsh was never considered. The live $PATH is
  # a fact about this process; the step exists to fix future shells.
  hl="$work/h-live-path"
  mkdir -p "$hl"
  binl="$work/bin-live"
  mkdir -p "$binl"
  : > "$hl/.zshrc"
  printf 'export PATH="%s:$PATH"\n' "$binl" > "$hl/.bashrc"
  set +e
  HOME="$hl" SHELL=/bin/bash PATH="$binl:/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$binl" --shell-dir "$work/sd-live" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hl/.zshrc")" \
    "BIN_DIR already on the live PATH does not stop ~/.zshrc being written"
  assert_eq "0" "$(path_lines "$hl/.bashrc")" \
    "while ~/.bashrc, which already names the directory, gains no block"

  # And the silence it is still responsible for: nothing pending and the
  # directory visible here means there is nothing to do and nothing worth
  # saying. This is the one thing the live $PATH still decides.
  hq="$work/h-quiet"
  mkdir -p "$hq"
  binq="$work/bin-quiet"
  mkdir -p "$binq"
  printf 'export PATH="%s:$PATH"\n' "$binq" > "$hq/.bashrc"
  printf 'export PATH="%s:$PATH"\n' "$binq" > "$hq/.zshrc"
  set +e
  HOME="$hq" SHELL=/bin/bash PATH="$binq:/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$binq" --shell-dir "$work/sd-quiet" \
    >/dev/null 2>"$work/quiet.err"
  set -e
  if [ -s "$work/quiet.err" ]; then
    fail "a run with every rc file right and the directory on PATH says nothing"
    sed 's/^/       /' "$work/quiet.err"
  else
    pass "a run with every rc file right and the directory on PATH says nothing"
  fi

  # --dry-run WRITES NOTHING, FOR EVERY TARGET
  #
  # Two files and two blocks is four things a dry run could leak, and the
  # old shape could only ever have leaked into one file.
  hd="$work/h-dry-both"
  mkdir -p "$hd"
  printf 'echo hello\n' > "$hd/.bashrc"
  printf 'echo hello\n' > "$hd/.zshrc"
  cp "$hd/.bashrc" "$work/dry-bashrc"
  cp "$hd/.zshrc"  "$work/dry-zshrc"
  set +e
  out=$(HOME="$hd" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fix/install.sh" --dir "$work/bin-dryb" --shell-dir "$work/sd-dryb" --dry-run 2>&1)
  set -e
  if cmp -s "$work/dry-bashrc" "$hd/.bashrc"; then
    pass "--dry-run leaves ~/.bashrc byte for byte"
  else
    fail "--dry-run leaves ~/.bashrc byte for byte"
  fi
  if cmp -s "$work/dry-zshrc" "$hd/.zshrc"; then
    pass "and ~/.zshrc byte for byte"
  else
    fail "and ~/.zshrc byte for byte"
  fi
  # No target may go unmentioned in a dry run: the report is what the user
  # reads before agreeing, and a file it did not name is a file they did
  # not agree to.
  case $out in
    *"a PATH block would be added to $hd/.bashrc"*) pass "--dry-run names ~/.bashrc for the PATH block" ;;
    *)                                              fail "--dry-run names ~/.bashrc for the PATH block" ;;
  esac
  case $out in
    *"a PATH block would be added to $hd/.zshrc"*) pass "and ~/.zshrc for it too" ;;
    *)                                             fail "and ~/.zshrc for it too" ;;
  esac
  case $out in
    *"a loader would be added to $hd/.bashrc"*) pass "and ~/.bashrc for the loader" ;;
    *)                                          fail "and ~/.bashrc for the loader" ;;
  esac
  case $out in
    *"a loader would be added to $hd/.zshrc"*) pass "and ~/.zshrc for the loader" ;;
    *)                                         fail "and ~/.zshrc for the loader" ;;
  esac

  # --rc
  #
  # It replaces the target set outright rather than adding to it, so the
  # default files must be left alone even though they exist.
  hr="$work/h-rc"
  mkdir -p "$hr"
  : > "$hr/.bashrc"
  : > "$hr/.zshrc"
  : > "$hr/myrc"
  set +e
  HOME="$hr" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-rc1" --shell-dir "$work/sd-rc1" \
    --rc "$hr/myrc" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hr/myrc")"    "--rc writes to the file it names"
  assert_eq "0" "$(path_lines "$hr/.bashrc")" "and replaces the default set: ~/.bashrc is untouched"
  assert_eq "0" "$(path_lines "$hr/.zshrc")"  "and ~/.zshrc with it"

  : > "$hr/myrc"
  : > "$hr/myrc2"
  set +e
  HOME="$hr" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-rc2" --shell-dir "$work/sd-rc2" \
    --rc "$hr/myrc" --rc "$hr/myrc2" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hr/myrc")"  "--rc twice writes to the first"
  assert_eq "1" "$(path_lines "$hr/myrc2")" "and to the second"

  # An unrecognised file is its own chain, so a mention in ~/.bashrc is not
  # an answer about it - which is what "not as part of any shell's startup
  # chain" in the usage text means.
  : > "$hr/myrc3"
  printf 'export PATH="%s:$PATH"\n' "$work/bin-rc3" > "$hr/.bashrc"
  set +e
  HOME="$hr" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-rc3" --shell-dir "$work/sd-rc3" \
    --rc "$hr/myrc3" >/dev/null 2>&1
  set -e
  assert_eq "1" "$(path_lines "$hr/myrc3")" \
    "an unrecognised --rc file is not answered for by ~/.bashrc"

  # A --rc naming a recognised basename is scoped exactly as the default
  # target of that name would be, so a flag cannot mean something different
  # from the default it replaces.
  hr2="$work/h-rc-known"
  mkdir -p "$hr2"
  : > "$hr2/.bashrc"
  printf 'export PATH="%s:$PATH"\n' "$work/bin-rc4" > "$hr2/.bash_aliases"
  set +e
  HOME="$hr2" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$work/bin-rc4" --shell-dir "$work/sd-rc4" \
    --rc "$hr2/.bashrc" >/dev/null 2>&1
  set -e
  assert_eq "0" "$(path_lines "$hr2/.bashrc")" \
    "--rc ~/.bashrc is scoped to bash's chain, as the default target is"

  # A file that is not there is refused, not created.
  set +e
  out=$(HOME="$hr" "$fixs/install.sh" --dir "$work/bin-rc5" --shell-dir "$work/sd-rc5" \
    --rc "$hr/nope" 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--rc naming a file that does not exist is refused"
  assert_eq "Error: --rc file does not exist: $hr/nope" "$out" "and the message names the path"
  assert_fail 1 "and the file is not brought into existence" test -e "$hr/nope"

  # Both empty spellings, refused with one sentence, exactly as --dir is.
  set +e
  out=$(HOME="$hr" "$fixs/install.sh" --rc 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--rc with no argument is refused"
  assert_eq "Error: --rc requires an argument" "$out" "and says so, and nothing else"

  set +e
  out=$(HOME="$hr" "$fixs/install.sh" --rc= 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "--rc= with an empty value is refused too"
  assert_eq "Error: --rc requires an argument" "$out" "and says exactly the same thing"

  section_report
)
section_end $?

section_begin 'the closing line of each report'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  # WHY THIS SECTION EXISTS
  #
  # Eight hundred assertions stood over this installer and not one of them
  # read its last line. The report was checked target by target - which
  # file was written, which file already handled it - and the sentence that
  # tells the user what to *do* about any of it was checked by nobody. So
  # it said the wrong thing, in two different ways, on the machine this
  # feature was written for: it named ~/.bashrc when the block had gone to
  # ~/.zshrc, and it named one file when two had been written.
  #
  # The hole was not arithmetic. It was that no assertion ever compared the
  # closing line against the set of files actually acted on, so every one
  # of the combinations below was free to be wrong. They are enumerated
  # here in full, for both blocks, in both modes.
  #
  # Two fixtures, because the two reports have to be prised apart before
  # either can be read by position. A repository with a shell file in it
  # reaches both steps; one with only scripts never reaches the loader step
  # at all, so its one closing line can only be the PATH one.
  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts" "$fix/shell"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"
  printf 'FIXTURE=1\n'    > "$fix/shell/lib.sh"

  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/tool.sh"

  shim="$work/shim"
  mkdir -p "$shim"

  # Every fixture home keeps BIN_DIR at ~/bin and SHELL_DIR at ~/aliases.
  # Neither name is a prefix of the other, which matters because
  # mentions_dir is a substring search: ~/bin and ~/bin-two would have made
  # "this file names BIN_DIR" true of a fixture that was seeded to say no.
  home_at() {
    # home_at NAME -> a fresh home directory, empty
    mkdir -p "$work/$1"
    printf '%s/%s\n' "$work" "$1"
  }

  # Seed RC with the two facts the report reads, and with nothing else.
  #
  # `p` makes the file name BIN_DIR, `s` makes it name SHELL_DIR, `-`
  # neither. Those two strings are the whole of what mentioned_in_chain
  # looks for, so a two-letter spec says everything a fixture has to say -
  # and says it on one line, which keeps the case being made from being
  # buried under a heredoc per file.
  seed() {
    # seed HOME RC SPEC
    local f="$1/$2"
    : > "$f"
    case $3 in *p*) printf 'export PATH="%s:$PATH"\n' "$1/bin"     >> "$f" ;; esac
    case $3 in *s*) printf '[ -d "%s" ] || true\n'    "$1/aliases" >> "$f" ;; esac
  }

  # Run the installer against HOME and leave everything it said in OUT.
  #
  # PS-NAME is what the shim `ps` reports as the parent process, and that
  # is the whole of what interactive_shell_name reads. Pinning it here is
  # what makes these assertions say the same thing for a developer sitting
  # in zsh as for one sitting in bash. It is not a convenience: the mixed
  # cases below are exactly where the old code answered differently for the
  # two, so a suite that let the ambient shell decide would have been green
  # on one machine and red on the next, for a defect present on both.
  #
  # ON-PATH puts BIN_DIR on the live PATH of the run. That is the one thing
  # that can silence the PATH report outright, so it is the only door to
  # the case where there is nothing to say at all.
  run_advice() {
    # run_advice HOME FIXTURE PS-NAME ON-PATH DRY
    local h=$1 f=$2 psname=$3 onpath=$4 dry=$5 p
    printf '#!/bin/sh\nprintf "%s\\n"\n' "$psname" > "$shim/ps"
    chmod +x "$shim/ps"
    p="$shim:/usr/bin:/bin"
    if [ "$onpath" = "1" ]; then
      p="$h/bin:$p"
    fi
    set +e
    if [ "$dry" = "1" ]; then
      OUT=$(env -i HOME="$h" SHELL=/bin/bash PATH="$p" "$f/install.sh" \
        --dry-run --dir "$h/bin" --shell-dir "$h/aliases" 2>&1)
    else
      OUT=$(env -i HOME="$h" SHELL=/bin/bash PATH="$p" "$f/install.sh" \
        --dir "$h/bin" --shell-dir "$h/aliases" 2>&1)
    fi
    set -e
  }

  # The closing line of the Nth report, with the warn prefix taken off.
  #
  # The PATH report is printed before the loader report and each prints at
  # most one closing line, so position is what tells them apart. Reading
  # them by position is also the only way to assert that the two *disagree*
  # inside one run, which is the shape the author actually hit and the one
  # a per-run "does the output contain X" check can never make a claim
  # about.
  closing_n() {
    # closing_n OUTPUT N
    printf '%s\n' "$1" |
      grep -e '^!  Restart your shell' -e '^!  After a real run' |
      sed -n "${2}p" |
      sed 's/^!  //'
  }

  # THE PATH BLOCK
  #
  # Run out of the scripts-only fixture throughout, so the loader step is
  # never reached and the first closing line is the only closing line.

  # Both written. The old code named one of the two, and which one depended
  # on the shell the installer happened to be invoked from.
  h=$(home_at path-both); seed "$h" .bashrc -; seed "$h" .zshrc -
  run_advice "$h" "$fixs" zsh 0 0
  assert_eq "Restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "PATH: two files written, and both are named"

  # One target, and it is written. Nothing to disambiguate, so no label.
  h=$(home_at path-bash-only); seed "$h" .bashrc -
  run_advice "$h" "$fixs" zsh 0 0
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH: only ~/.bashrc written, and it is what is named"

  h=$(home_at path-zsh-only); seed "$h" .zshrc -
  run_advice "$h" "$fixs" bash 0 0
  assert_eq "Restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH: only ~/.zshrc written, and it is what is named"

  # Nothing written, because both chains already say it. The advice falls
  # back to naming what already does the job - and names both, because two
  # files doing it is two files worth knowing about.
  h=$(home_at path-both-handled); seed "$h" .bashrc p; seed "$h" .zshrc p
  run_advice "$h" "$fixs" bash 0 0
  assert_eq "Restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "PATH: nothing written and both chains handle it, so both are named"

  # Nothing written, one chain handles it, and the other shell has no rc
  # file to be a target at all.
  h=$(home_at path-one-handled); seed "$h" .bashrc p
  run_advice "$h" "$fixs" bash 0 0
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH: one chain handles it and the other shell has no rc file"

  # THE MIXED CASES
  #
  # One file written, another already handled. The written one is the whole
  # of what the user has to do something about; the other needed nothing
  # and naming it is worse than saying nothing, because sourcing it appears
  # to work and changes nothing. Both directions, because the old code got
  # one of them right by accident on the author's machine and wrong on a
  # machine whose parent shell was the other one.
  h=$(home_at path-mix-bash-written); seed "$h" .bashrc -; seed "$h" .zshrc p
  run_advice "$h" "$fixs" zsh 0 0
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH: bash written and zsh already handled, so ~/.bashrc is named"

  h=$(home_at path-mix-zsh-written); seed "$h" .bashrc p; seed "$h" .zshrc -
  run_advice "$h" "$fixs" bash 0 0
  assert_eq "Restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH: zsh written and bash already handled, so ~/.zshrc is named"

  # NOTHING TO SAY
  #
  # Every chain already names it and this shell can already see it, so
  # warn_if_not_on_path returns before the report starts; the scripts-only
  # fixture means the loader step never runs either. There is no closing
  # line because there is no report, and stderr holds nothing whatever -
  # which is the silence assert_clean was written to defend.
  h=$(home_at path-silent); seed "$h" .bashrc p; seed "$h" .zshrc p
  run_advice "$h" "$fixs" bash 1 0
  capture closing_n "$OUT" 1
  assert_empty "PATH: nothing to say, so there is no closing line" "$CAPTURED"

  h=$(home_at path-silent-clean); seed "$h" .bashrc p; seed "$h" .zshrc p
  printf '#!/bin/sh\nprintf "bash\\n"\n' > "$shim/ps"
  chmod +x "$shim/ps"
  assert_clean "and the whole run says nothing on stderr" \
    env -i HOME="$h" SHELL=/bin/bash PATH="$h/bin:$shim:/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h/bin" --shell-dir "$h/aliases"

  # THE SAME SEVEN UNDER --dry-run
  #
  # A dry run wrote nothing, so `source X` is advice the user cannot act
  # on: the block is not in the file yet. The line is still printed,
  # because the whole point of a dry run is to answer "what would this
  # do?", and needing to source a file afterwards is part of the answer -
  # but it is printed in the subjunctive, and only where something *would*
  # have been written.
  h=$(home_at dry-path-both); seed "$h" .bashrc -; seed "$h" .zshrc -
  run_advice "$h" "$fixs" zsh 0 1
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: two files would be written, and both are named"

  h=$(home_at dry-path-bash-only); seed "$h" .bashrc -
  run_advice "$h" "$fixs" zsh 0 1
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: one file would be written, and it is not spoken of as done"

  h=$(home_at dry-path-zsh-only); seed "$h" .zshrc -
  run_advice "$h" "$fixs" bash 0 1
  assert_eq "After a real run: restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: and the same for ~/.zshrc"

  # Nothing would be written here, so nothing about this run is subjunctive:
  # the files named already hold what they need to, today, and sourcing one
  # of them right now does exactly what the line says it does. This is the
  # assertion that keeps "dry run" from being read as "say everything in
  # the conditional", which would be false of this branch.
  h=$(home_at dry-path-both-handled); seed "$h" .bashrc p; seed "$h" .zshrc p
  run_advice "$h" "$fixs" bash 0 1
  assert_eq "Restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: nothing would be written, so the advice stays in the present tense"

  h=$(home_at dry-path-one-handled); seed "$h" .bashrc p
  run_advice "$h" "$fixs" bash 0 1
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: one chain handles it and the other shell has no rc file"

  h=$(home_at dry-path-mix-bash); seed "$h" .bashrc -; seed "$h" .zshrc p
  run_advice "$h" "$fixs" zsh 0 1
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: bash would be written and zsh already handled"

  h=$(home_at dry-path-mix-zsh); seed "$h" .bashrc p; seed "$h" .zshrc -
  run_advice "$h" "$fixs" bash 0 1
  assert_eq "After a real run: restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "PATH, dry run: zsh would be written and bash already handled"

  h=$(home_at dry-path-silent); seed "$h" .bashrc p; seed "$h" .zshrc p
  run_advice "$h" "$fixs" bash 1 1
  capture closing_n "$OUT" 1
  assert_empty "PATH, dry run: nothing to say, so there is no closing line" "$CAPTURED"

  # THE LOADER BLOCK
  #
  # Reported by a different function, from a different list, so every one
  # of the cases above has to be asked again here rather than argued from
  # the shape of the code. The PATH report is silenced throughout - every
  # chain is seeded with BIN_DIR and the live PATH carries it - so the
  # first closing line is the loader's.

  h=$(home_at load-both); seed "$h" .bashrc p; seed "$h" .zshrc p
  run_advice "$h" "$fix" bash 1 0
  assert_eq "Restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "loader: two files written, and both are named"

  h=$(home_at load-bash-only); seed "$h" .bashrc p
  run_advice "$h" "$fix" zsh 1 0
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "loader: only ~/.bashrc written, and it is what is named"

  h=$(home_at load-zsh-only); seed "$h" .zshrc p
  run_advice "$h" "$fix" bash 1 0
  assert_eq "Restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "loader: only ~/.zshrc written, and it is what is named"

  h=$(home_at load-both-handled); seed "$h" .bashrc ps; seed "$h" .zshrc ps
  run_advice "$h" "$fix" bash 1 0
  assert_eq "Restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "loader: nothing written and both chains handle it, so both are named"

  h=$(home_at load-one-handled); seed "$h" .bashrc ps
  run_advice "$h" "$fix" bash 1 0
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "loader: one chain handles it and the other shell has no rc file"

  h=$(home_at load-mix-bash); seed "$h" .bashrc p; seed "$h" .zshrc ps
  run_advice "$h" "$fix" zsh 1 0
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "loader: bash written and zsh already handled, so ~/.bashrc is named"

  h=$(home_at load-mix-zsh); seed "$h" .bashrc ps; seed "$h" .zshrc p
  run_advice "$h" "$fix" bash 1 0
  assert_eq "Restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "loader: zsh written and bash already handled, so ~/.zshrc is named"

  # The loader report has no live-PATH equivalent to fall silent on, so the
  # only way for it to have nothing to say is for it never to be reached -
  # which is a run that linked no shell file. That is the scripts-only
  # fixture, and it is the run asserted clean above.

  h=$(home_at dry-load-both); seed "$h" .bashrc p; seed "$h" .zshrc p
  run_advice "$h" "$fix" bash 1 1
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: two files would be written, and both are named"

  h=$(home_at dry-load-bash-only); seed "$h" .bashrc p
  run_advice "$h" "$fix" zsh 1 1
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: one file would be written, and it is not spoken of as done"

  h=$(home_at dry-load-zsh-only); seed "$h" .zshrc p
  run_advice "$h" "$fix" bash 1 1
  assert_eq "After a real run: restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: and the same for ~/.zshrc"

  h=$(home_at dry-load-both-handled); seed "$h" .bashrc ps; seed "$h" .zshrc ps
  run_advice "$h" "$fix" bash 1 1
  assert_eq "Restart your shell, or run: source $h/.bashrc (bash) or source $h/.zshrc (zsh)" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: nothing would be written, so the advice stays in the present tense"

  h=$(home_at dry-load-one-handled); seed "$h" .bashrc ps
  run_advice "$h" "$fix" bash 1 1
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: one chain handles it and the other shell has no rc file"

  h=$(home_at dry-load-mix-bash); seed "$h" .bashrc p; seed "$h" .zshrc ps
  run_advice "$h" "$fix" zsh 1 1
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: bash would be written and zsh already handled"

  h=$(home_at dry-load-mix-zsh); seed "$h" .bashrc ps; seed "$h" .zshrc p
  run_advice "$h" "$fix" bash 1 1
  assert_eq "After a real run: restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "loader, dry run: zsh would be written and bash already handled"

  # THE TWO REPORTS DISAGREEING INSIDE ONE RUN
  #
  # The author's own machine, and the shape the bug was found in. ~/.bashrc
  # already puts BIN_DIR on PATH but sources nothing; ~/.zshrc sources
  # ~/.zsh_aliases, and it is that file which names the aliases directory.
  # So the PATH block goes to zsh alone and the loader goes to bash alone,
  # and the two closing lines have to name different files in the same
  # breath. The old code printed the same path twice.
  author_home() {
    # author_home NAME
    local h
    h=$(home_at "$1")
    printf 'export PATH="%s:$PATH"\n' "$h/bin" > "$h/.bashrc"
    printf 'if [ -r "${HOME}/.zsh_aliases" ]; then . "${HOME}/.zsh_aliases"; fi\n' \
      > "$h/.zshrc"
    printf '[ -d ~/aliases ] || true\n' > "$h/.zsh_aliases"
    printf '%s\n' "$h"
  }

  h=$(author_home author-real)
  run_advice "$h" "$fix" bash 0 0
  assert_eq "Restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "the author's layout: the PATH block went to zsh, so ~/.zshrc is named"
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 2)" \
    "and the loader went to bash, so the second line names ~/.bashrc"

  h=$(author_home author-dry)
  run_advice "$h" "$fix" bash 0 1
  assert_eq "After a real run: restart your shell, or run: source $h/.zshrc" \
    "$(closing_n "$OUT" 1)" \
    "the author's layout, dry run: the PATH line names ~/.zshrc and nothing is claimed done"
  assert_eq "After a real run: restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 2)" \
    "and the loader line names ~/.bashrc"

  # A FILE NAMED TWICE IS STILL ONE FILE
  #
  # Two --rc targets on the same chain resolve to the same file when that
  # file is what already names the directory, and the list the advice is
  # built from then holds it twice. `source X or source X` is not an
  # alternative between two things.
  h=$(home_at rc-duplicate); seed "$h" .bashrc p; : > "$h/.bash_profile"
  printf '#!/bin/sh\nprintf "bash\\n"\n' > "$shim/ps"
  chmod +x "$shim/ps"
  set +e
  OUT=$(env -i HOME="$h" SHELL=/bin/bash PATH="$shim:/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h/bin" --shell-dir "$h/aliases" \
    --rc "$h/.bashrc" --rc "$h/.bash_profile" 2>&1)
  set -e
  assert_eq "Restart your shell, or run: source $h/.bashrc" \
    "$(closing_n "$OUT" 1)" \
    "two --rc targets answered by one file name it once"

  section_report
)
section_end $?

section_begin 'the PATH headline states what it checked'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/tool.sh"

  # DEFECT 1 REPRODUCED
  #
  # BIN_DIR is genuinely on the live PATH of this process - not through any
  # rc file, just handed to it directly, the way /etc/profile would. No rc
  # chain names it. warn_if_not_on_path counted rc files, not the live
  # PATH, for this branch, so the old headline said "is not in your PATH"
  # while it demonstrably was - the false claim this section exists to
  # catch a regression of.
  h="$work/h-onpath-norc"
  mkdir -p "$h"
  printf 'echo hello\n' > "$h/.bashrc"
  set +e
  out=$(env -i HOME="$h" SHELL=/bin/bash PATH="$h/bin:/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h/bin" --shell-dir "$work/sd-onpath" 2>&1)
  set -e
  case $out in
    *"$h/bin is not in your PATH"*)
      fail "on live PATH with no rc chain naming it: the headline no longer claims the live PATH" ;;
    *)
      pass "on live PATH with no rc chain naming it: the headline no longer claims the live PATH" ;;
  esac
  case $out in
    *"$h/bin is not in any shell's startup files."*)
      pass "and it states the condition that was actually checked" ;;
    *)
      fail "and it states the condition that was actually checked" ;;
  esac

  # THE TWO SIBLING HEADLINES ARE UNTOUCHED
  #
  # Only the all-chains-empty branch was wrong. The other two read the
  # same before and after this fix, and each is asserted here rather than
  # assumed.
  hall="$work/h-all-handled"
  mkdir -p "$hall"
  printf 'export PATH="%s/bin:$PATH"\n' "$hall" > "$hall/.bashrc"
  set +e
  out=$(env -i HOME="$hall" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$hall/bin" --shell-dir "$work/sd-all" 2>&1)
  set -e
  case $out in
    *"$hall/bin is already in your startup files."*)
      pass "every chain already names it: the 'already in your startup files' headline is unchanged" ;;
    *)
      fail "every chain already names it: the 'already in your startup files' headline is unchanged" ;;
  esac

  hmix="$work/h-mixed"
  mkdir -p "$hmix"
  printf 'export PATH="%s/bin:$PATH"\n' "$hmix" > "$hmix/.bashrc"
  : > "$hmix/.zshrc"
  set +e
  out=$(env -i HOME="$hmix" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$hmix/bin" --shell-dir "$work/sd-mix" 2>&1)
  set -e
  case $out in
    *"$hmix/bin is not in every shell's startup files."*)
      pass "one chain handles it and one does not: the mixed headline is unchanged" ;;
    *)
      fail "one chain handles it and one does not: the mixed headline is unchanged" ;;
  esac

  section_report
)
section_end $?

section_begin 'per-target lines collapse identical facts'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fixs="$work/repo-scripts-only"
  make_fixture "$fixs"
  mkdir -p "$fixs/scripts"
  printf '#!/bin/sh\n:\n' > "$fixs/scripts/tool.sh"

  count_lines() {
    # count_lines OUTPUT PATTERN
    printf '%s\n' "$1" | grep -F -c "$2" || true
  }

  # --rc GIVEN THE SAME FILE TWICE, ALREADY MENTIONING IT
  #
  # Each line is individually true and the report is not: two targets
  # answered by one file is one fact, not two.
  h1="$work/h-same-file-twice"
  mkdir -p "$h1"
  printf 'export PATH="%s/bin:$PATH"\n' "$h1" > "$h1/myrc"
  set +e
  out=$(env -i HOME="$h1" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h1/bin" --shell-dir "$work/sd1" \
    --rc "$h1/myrc" --rc "$h1/myrc" 2>&1)
  set -e
  assert_eq "1" "$(count_lines "$out" "$h1/myrc already mentions it")" \
    "--rc FILE --rc FILE, already mentioning it: one line, not two"

  # TWO DIFFERENT FILES ON THE SAME CHAIN, BOTH ALREADY MENTIONING IT
  #
  # ~/.bashrc names BIN_DIR; ~/.bash_profile does not, but shares bash's
  # chain, so mentioned_in_chain answers both targets with ~/.bashrc.
  h2="$work/h-same-chain-mentions"
  mkdir -p "$h2"
  printf 'export PATH="%s/bin:$PATH"\n' "$h2" > "$h2/.bashrc"
  : > "$h2/.bash_profile"
  set +e
  out=$(env -i HOME="$h2" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h2/bin" --shell-dir "$work/sd2" \
    --rc "$h2/.bashrc" --rc "$h2/.bash_profile" 2>&1)
  set -e
  assert_eq "1" "$(count_lines "$out" "$h2/.bashrc already mentions it")" \
    "two same-chain files both already mentioning it: one line, not two"

  # TWO DIFFERENT FILES ON THE SAME CHAIN, BOTH ENDING UP "WRITTEN"
  #
  # Neither file, nor anything else on bash's chain, names BIN_DIR to
  # start with. The first target to be resolved is written to; by the
  # time the second target's chain is searched that same file now names
  # it, so the second target reports "already mentions it" rather than a
  # second "was added" - the two targets still resolve to one written file
  # and the report still owes the user exactly one sentence about it.
  h3="$work/h-same-chain-written"
  mkdir -p "$h3"
  : > "$h3/.bashrc"
  : > "$h3/.bash_profile"
  set +e
  out=$(env -i HOME="$h3" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h3/bin" --shell-dir "$work/sd3" \
    --rc "$h3/.bashrc" --rc "$h3/.bash_profile" 2>&1)
  set -e
  assert_eq "1" "$(count_lines "$out" "a PATH block was added to $h3/.bashrc")" \
    "two same-chain files, one gets written: exactly one 'was added' line"
  assert_eq "1" "$(count_lines "$out" "already mentions it")" \
    "and the other reports it via one 'already mentions' line, not a second write"

  # THE CROSS-SHELL CASE MUST NOT COLLAPSE
  #
  # bash and zsh reporting the identical outcome about *different* files
  # is two facts, and has to stay two lines. Deduplication is keyed on the
  # file that answered, and a bash file and a zsh file are never the same
  # file.
  h4="$work/h-cross-shell"
  mkdir -p "$h4"
  printf 'export PATH="%s/bin:$PATH"\n' "$h4" > "$h4/.bashrc"
  printf 'export PATH="%s/bin:$PATH"\n' "$h4" > "$h4/.zshrc"
  set +e
  out=$(env -i HOME="$h4" SHELL=/bin/bash PATH="/usr/bin:/bin" \
    "$fixs/install.sh" --dir "$h4/bin" --shell-dir "$work/sd4" 2>&1)
  set -e
  assert_eq "1" "$(count_lines "$out" "$h4/.bashrc already mentions it")" \
    "cross-shell: the bash line still appears once"
  assert_eq "1" "$(count_lines "$out" "$h4/.zshrc already mentions it")" \
    "and the zsh line still appears once, not collapsed with bash's"

  section_report
)
section_end $?

section_begin 'which shell invoked the installer'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  fix="$work/repo"
  make_fixture "$fix"
  mkdir -p "$fix/scripts"
  printf '#!/bin/sh\n:\n' > "$fix/scripts/tool.sh"

  # $SHELL is the login shell out of the password database, and this whole
  # change exists because that is the wrong question. The name is only ever
  # used for a sentence - which shell to call yours, and which file to
  # suggest sourcing - and never to decide what to write.
  #
  # The evidence is taken end to end, through the one branch that still
  # names a shell: an empty home directory, where there is no rc file to
  # write to and the block has to be pasted by hand.
  named_by() {
    # named_by SHELL
    local sh=$1 h
    h=$(mktemp -d "$work/h.XXXXXX")
    set +e
    # `; :` and not a bare command. `sh -c 'cmd'` execs and replaces the
    # shell with cmd, so $PPID would name this suite's own bash and the
    # assertion would be green for a reason that has nothing to do with the
    # shell being tested. A second command in the list is what forces a
    # real fork, and it is the difference between measuring the parent and
    # measuring the grandparent.
    OUT=$("$sh" -c "HOME='$h' SHELL=/bin/bash PATH=/usr/bin:/bin \
      '$fix/install.sh' --dir '$h/bin' --shell-dir '$h/sd' 2>&1; :")
    set -e
  }

  named_by bash
  case $OUT in
    *"I found no startup file for bash"*) pass "invoked from bash, the installer says bash" ;;
    *)                                    fail "invoked from bash, the installer says bash" ;;
  esac
  # And the wrong answer is named, so a fix that simply printed nothing
  # could not pass. $SHELL was /bin/bash in both runs on purpose: it is the
  # constant, and the parent is the variable.
  if [ "$SHELLS" = "bash" ]; then
    skip "the zsh half of parent detection" "zsh is not on PATH"
  else
    named_by zsh
    case $OUT in
      *"I found no startup file for zsh"*) pass "invoked from zsh, the installer says zsh" ;;
      *)                                   fail "invoked from zsh, the installer says zsh" ;;
    esac
    case $OUT in
      *"startup file for bash"*) fail "and does not repeat what \$SHELL said" ;;
      *)                         pass "and does not repeat what \$SHELL said" ;;
    esac
  fi

  # THE FOUR THINGS THAT CAN GO WRONG WITH ps
  #
  # A shim first on PATH is how each is asked without needing a parent of
  # that kind. The functions are called directly, because what is being
  # tested is the reading of ps's answer and not the plumbing around it.
  shim="$work/shim"
  mkdir -p "$shim"
  set_ps() {
    # set_ps BODY
    printf '#!/bin/sh\n%s\n' "$1" > "$shim/ps"
    chmod +x "$shim/ps"
  }
  parent_says() {
    # parent_says  -> the name parent_shell_name returns, through the shim
    PATH="$shim:$PATH" bash -c \
      'WD40_SOURCE_ONLY=1 . "$0"; parent_shell_name' "$INSTALL" 2>/dev/null
  }
  chosen_with() {
    # chosen_with SHELL -> what interactive_shell_name returns
    SHELL=$1 PATH="$shim:$PATH" bash -c \
      'WD40_SOURCE_ONLY=1 . "$0"; interactive_shell_name' "$INSTALL" 2>/dev/null
  }

  set_ps 'printf "zsh\n"'
  assert_eq "zsh" "$(parent_says)" "a plain name is read as it is"

  # A login shell is conventionally invoked with a leading dash.
  set_ps 'printf -- "-zsh\n"'
  assert_eq "zsh" "$(parent_says)" "a login shell's leading dash is stripped"

  # macOS prints the full path in comm; Linux prints the bare name.
  set_ps 'printf "/bin/zsh\n"'
  assert_eq "zsh" "$(parent_says)" "a full path is read through basename, as BSD prints it"

  # A versioned name.
  set_ps 'printf "bash-5.2\n"'
  assert_eq "bash" "$(parent_says)" "a versioned name loses its version"
  # But a name whose digits are not a version keeps them, because the
  # suffix is only taken off at a dash.
  set_ps 'printf "ksh93\n"'
  assert_eq "ksh93" "$(parent_says)" "while ksh93, which has no dash, keeps its digits"

  # The parent is not a shell at all: make, a CI runner, another script.
  set_ps 'printf "make\n"'
  capture parent_says
  assert_empty "a parent that is not a shell yields no name" "$CAPTURED"
  assert_eq "fish" "$(chosen_with /usr/bin/fish)" "and \$SHELL is what answers instead"

  # ps restricted, and ps absent. Neither may end the run, and both leave
  # through the same `|| :`.
  set_ps 'exit 1'
  capture parent_says
  assert_empty "a ps that refuses yields no name" "$CAPTURED"
  assert_eq "bash" "$(chosen_with /bin/bash)" "and falls back to \$SHELL without failing"

  set_ps 'exit 127'
  capture parent_says
  assert_empty "a ps that is not there yields no name" "$CAPTURED"

  # Nothing to fall back to either: no name at all, which shell_display_name
  # turns into "your shell" rather than a hole between two spaces.
  capture env SHELL= PATH="$shim:$PATH" bash -c \
    'WD40_SOURCE_ONLY=1 . "$0"; interactive_shell_name' "$INSTALL"
  assert_empty "with no ps and no \$SHELL there is no name" "$CAPTURED"
  assert_eq "your shell" \
    "$(PATH="$shim:$PATH" bash -c 'WD40_SOURCE_ONLY=1 . "$0"; shell_display_name ""' "$INSTALL")" \
    "and that is the hole shell_display_name fills"

  # A broken ps must not take an install down with it. This is the whole of
  # the claim that detection can never fail the run.
  hps="$work/h-ps"
  mkdir -p "$hps"
  set_ps 'exit 127'
  set +e
  PATH="$shim:/usr/bin:/bin" HOME="$hps" SHELL=/bin/bash \
    "$fix/install.sh" --dir "$work/bin-ps" --shell-dir "$work/sd-ps" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "0" "$rc" "an install with a broken ps still exits 0"
  assert_ok "and still links what it was asked to" test -L "$work/bin-ps/tool"

  section_report
)
section_end $?

section_begin 'the generated loader block'
(
  set -e
  section_reset
  WD40_SOURCE_ONLY=1
  export WD40_SOURCE_ONLY
  # shellcheck disable=SC1090
  . "$INSTALL"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  SHELL_DIR="$work/aliases.d"
  mkdir -p "$SHELL_DIR"
  cp "$REPO/shell/wd40-paths.sh" "$SHELL_DIR/wd40-paths.sh"

  line() { printf '%s\n' "$1" | sed -n "$2p"; }

  block=$(print_loader_block '')
  assert_eq "17" "$(printf '%s\n' "$block" | wc -l | tr -d ' ')" "the block is seventeen lines"
  assert_eq '# added by wd40 install.sh' "$(line "$block" 1)" "line 1 labels the block"
  assert_eq '_wd40_load_aliases() {' "$(line "$block" 2)" "line 2 opens a function, the only place a shell option can be scoped"
  assert_eq "  [ -d \"$SHELL_DIR\" ] || return 0" "$(line "$block" 3)" "line 3 guards on the directory existing"
  assert_eq '  if [ -n "${ZSH_VERSION:-}" ]; then' "$(line "$block" 4)" "line 4 fences the zsh-only part off from bash"
  assert_eq '    _wd40_nomatch=off' "$(line "$block" 5)" "line 5 defaults the saved option to off"
  assert_eq '    if [[ -o nomatch ]]; then _wd40_nomatch=on; fi' "$(line "$block" 6)" "line 6 saves NO_MATCH by asking the shell, not by parsing setopt"
  assert_eq '    setopt no_nomatch' "$(line "$block" 7)" "line 7 turns NO_MATCH off for the glob"
  assert_eq '  fi' "$(line "$block" 8)" "line 8 closes the zsh fence"
  assert_eq "  for _wd40_alias_file in \"$SHELL_DIR\"/*.sh; do" "$(line "$block" 9)" "line 9 globs *.sh with a prefixed loop variable"
  assert_eq '    [ -r "$_wd40_alias_file" ] && . "$_wd40_alias_file"' "$(line "$block" 10)" "line 10 tests -r, not -x: sourcing is a read"
  assert_eq '  done' "$(line "$block" 11)" "line 11 closes the loop"
  assert_eq '  if [ "${_wd40_nomatch:-off}" = on ]; then setopt nomatch; fi' "$(line "$block" 12)" "line 12 restores NO_MATCH only for a user who had it on"
  assert_eq '  unset _wd40_alias_file _wd40_nomatch' "$(line "$block" 13)" "line 13 unsets both of the names it introduced"
  assert_eq '  return 0' "$(line "$block" 14)" "line 14 hands back a status that cannot fail"
  assert_eq '}' "$(line "$block" 15)" "line 15 closes the function"
  assert_eq '_wd40_load_aliases' "$(line "$block" 16)" "line 16 calls it"
  assert_eq 'unset -f _wd40_load_aliases' "$(line "$block" 17)" "line 17 takes the helper back out of the user's shell"

  # `setopt local_options` would be one line instead of four and was
  # rejected: it restores *every* option when the function returns, so a
  # file the loop sources that deliberately runs `setopt extended_glob`
  # would have it silently rolled back. The explicit save/restore above
  # touches NOMATCH and nothing else. There is a test for that below; this
  # one states the rule in the one place a future edit would break it.
  case $block in
    *local_options*) fail "the block does not reach for setopt local_options" ;;
    *)               pass "the block does not reach for setopt local_options" ;;
  esac

  indented=$(print_loader_block '>>')
  assert_eq '>># added by wd40 install.sh' "$(line "$indented" 1)" "the indent argument prefixes the first line"
  assert_eq '>>unset -f _wd40_load_aliases' "$(line "$indented" 17)" "and the last"
  assert_eq "0" "$(printf '%s\n' "$indented" | grep -cv '^>>' || true)" "and every line in between"

  # What the installer writes has to be what actually works, so every case
  # below is written to a file and sourced by a real shell rather than read.
  #
  # The marker on the last line is the whole point of the exercise. zsh has
  # NO_MATCH on by default, and under it a glob that matches nothing aborts
  # the *enclosing file* - so a bad block takes every later line of the
  # user's .zshrc with it, in silence, and the only evidence is that this
  # marker never printed.
  make_rc() {
    # make_rc FILE [PRELUDE_LINE...]
    local f=$1 prelude
    shift
    : > "$f"
    for prelude in "$@"; do printf '%s\n' "$prelude" >> "$f"; done
    print_loader_block '' >> "$f"
    printf 'printf "rc-reached-end\\n"\n' >> "$f"
  }

  reached_end="rc=0 out=1 err=0 out1=[rc-reached-end] err1=[]"

  # Three states of SHELL_DIR need three rc files, because
  # print_loader_block bakes the directory in at generation time.
  empty_dir="$work/empty.d"
  missing_dir="$work/missing.d"
  mkdir -p "$empty_dir"

  full_dir="$SHELL_DIR"
  make_rc "$work/rc-full"
  SHELL_DIR="$empty_dir";   make_rc "$work/rc-empty"
  SHELL_DIR="$missing_dir"; make_rc "$work/rc-missing"
  SHELL_DIR="$full_dir"

  if [ "$SHELLS" = "bash" ]; then
    skip "the zsh half of the sourcing table" "zsh is not on PATH"
  fi
  for sh in $SHELLS; do
    assert_eq "$reached_end" "$(probe_shell "$sh" ". '$work/rc-full'")" \
      "$sh: a populated SHELL_DIR loads and the rc file reaches its end"
    assert_eq "$reached_end" "$(probe_shell "$sh" ". '$work/rc-empty'")" \
      "$sh: an empty SHELL_DIR is not an error and the rc file reaches its end"
    assert_eq "$reached_end" "$(probe_shell "$sh" ". '$work/rc-missing'")" \
      "$sh: a missing SHELL_DIR is not an error and the rc file reaches its end"

    # An rc file sourced under the caller's `set -e` takes the block's exit
    # status as its own, and an empty directory is where a careless block
    # would hand back the failed `[ -r ]` test.
    assert_eq "$reached_end" "$(probe_shell "$sh" "set -e; . '$work/rc-full'")" \
      "$sh: an rc under set -e survives the block with a populated SHELL_DIR"
    assert_eq "$reached_end" "$(probe_shell "$sh" "set -e; . '$work/rc-empty'")" \
      "$sh: an rc under set -e survives the block with an empty SHELL_DIR"
    assert_eq "$reached_end" "$(probe_shell "$sh" "set -e; . '$work/rc-missing'")" \
      "$sh: an rc under set -e survives the block with a missing SHELL_DIR"

    # Sourcing happens inside a function now. In both shells a `.` inside a
    # function still defines aliases, functions and undeclared variables
    # globally, so the loaded files behave exactly as they did before - and
    # none of the three names the block introduces may outlive it.
    #
    # fpnr is asked about as well as fp, because the shorthands are the
    # last thing in the sourced file: a file that stopped early would still
    # answer for fp. `--no-clipboard` because a real clipboard is not a
    # thing a test may assume, and this assertion is about the loader.
    set +e
    out=$("$sh" -c "cd '$work' || exit 9
. '$work/rc-full'
command -v fp   >/dev/null 2>&1 && printf 'fp defined\n'
command -v fpnr >/dev/null 2>&1 && printf 'fpnr defined\n'
fp --no-clipboard foo
printf 'leak_file=[%s]\n' \"\${_wd40_alias_file-unset}\"
printf 'leak_opt=[%s]\n'  \"\${_wd40_nomatch-unset}\"
command -v _wd40_load_aliases >/dev/null 2>&1 && printf 'helper survived\n'
printf 'end\n'" 2>&1)
    set -e
    assert_eq "$(printf 'rc-reached-end\nfp defined\nfpnr defined\n%s/foo\nleak_file=[unset]\nleak_opt=[unset]\nend' "$work")" \
      "$out" "$sh: the block defines the functions and leaves none of its own names behind"
  done

  # NO_MATCH is what makes the function wrapper necessary, and it exists
  # only in zsh, so these are the one group of assertions with no bash half.
  #
  # Every one of them asks the shell with `[[ -o nomatch ]]`. `setopt` with
  # no arguments does not list an option that is sitting at its default, so
  # grepping its output would report a correct implementation as broken.
  if [ "$SHELLS" = "bash" ]; then
    skip "the NO_MATCH assertions" "zsh is not on PATH"
  else
    report_nomatch='if [[ -o nomatch ]]; then printf "nomatch=on\n"; else printf "nomatch=off\n"; fi'

    set +e
    out=$(zsh -c ". '$work/rc-empty'
$report_nomatch" 2>&1)
    set -e
    assert_eq "$(printf 'rc-reached-end\nnomatch=on')" "$out" \
      "zsh: NO_MATCH is on by default and the block hands it back on"

    # And a user who turned it off keeps it off: the block restores what it
    # found, not what zsh ships with.
    set +e
    out=$(zsh -c "unsetopt nomatch
. '$work/rc-empty'
$report_nomatch" 2>&1)
    set -e
    assert_eq "$(printf 'rc-reached-end\nnomatch=off')" "$out" \
      "zsh: NO_MATCH that was already off stays off"

    # The reason local_options was rejected, stated as a test: a file the
    # loop sources sets an option on purpose, and it has to survive.
    xglob_dir="$work/xglob.d"
    mkdir -p "$xglob_dir"
    printf 'if [ -n "${ZSH_VERSION:-}" ]; then setopt extended_glob; fi\n' \
      > "$xglob_dir/00-xglob.sh"
    SHELL_DIR="$xglob_dir"; make_rc "$work/rc-xglob"; SHELL_DIR="$full_dir"
    set +e
    out=$(zsh -c ". '$work/rc-xglob'
if [[ -o extended_glob ]]; then printf 'extended_glob=on\n'; else printf 'extended_glob=off\n'; fi" 2>&1)
    set -e
    assert_eq "$(printf 'rc-reached-end\nextended_glob=on')" "$out" \
      "zsh: an option a sourced file set on purpose survives the block"
  fi

  # shell_dir_mentioned_in is the whole of the "is it wired up?" guess, and
  # it is now asked one rc file at a time: the answer is a property of a
  # shell's startup chain, not of the machine. Every case below is asked
  # about ~/.zshrc, so the chain is ~/.zshrc, ~/.zprofile and
  # ~/.zsh_aliases.
  mhome="$work/mhome"
  mkdir -p "$mhome"
  HOME="$mhome"
  SHELL_DIR="$work/searched-for"
  capture shell_dir_mentioned_in "$mhome/.zshrc"
  assert_empty "no startup file at all mentions nothing" "$CAPTURED"
  printf 'unrelated\n' > "$mhome/.zshrc"
  capture shell_dir_mentioned_in "$mhome/.zshrc"
  assert_empty "nor does one that says nothing about it" "$CAPTURED"
  printf 'sources %s nightly\n' "$SHELL_DIR" > "$mhome/.zprofile"
  assert_eq "$mhome/.zprofile" "$(shell_dir_mentioned_in "$mhome/.zshrc")" \
    "the file that does mention it is named"
  printf 'sources %s\n' "$SHELL_DIR" >> "$mhome/.zshrc"
  assert_eq "$mhome/.zshrc" "$(shell_dir_mentioned_in "$mhome/.zshrc")" \
    ".zshrc is searched before .zprofile"

  # A file on the other shell's chain is not an answer about this one. This
  # is the reversal the whole change turns on, asserted at the level of the
  # function that used to get it wrong: it read six files and gave one
  # answer for the machine, so ~/.bash_aliases could suppress zsh's block
  # and ~/.zsh_aliases could suppress bash's.
  rm -f "$mhome/.zshrc" "$mhome/.zprofile"
  printf 'sources %s\n' "$SHELL_DIR" > "$mhome/.bash_aliases"
  : > "$mhome/.zshrc"
  capture shell_dir_mentioned_in "$mhome/.zshrc"
  assert_empty "a file on bash's chain is not an answer about zsh" "$CAPTURED"
  assert_eq "$mhome/.bash_aliases" "$(shell_dir_mentioned_in "$mhome/.bashrc")" \
    "while it is the answer about bash"

  # grep -F, so the dots in a path like ~/.zsh_aliases.d are literal dots
  # and not single-character wildcards.
  SHELL_DIR="$work/a.b"
  rm -f "$mhome/.zprofile" "$mhome/.bash_aliases"
  printf 'mentions %s/aXb here\n' "$work" > "$mhome/.zshrc"
  capture shell_dir_mentioned_in "$mhome/.zshrc"
  assert_empty "the match is literal, not a regular expression" "$CAPTURED"

  section_report
)
section_end $?

section_begin 'fp contract'
(
  set -e
  section_reset
  # Said from in here, like every other skip: a note printed between the
  # header and the subshell is a note the section's own counts never saw.
  if [ "$SHELLS" = "bash" ]; then
    skip "the whole zsh half of this section" "zsh is not on PATH"
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  scratch=$(cd "$tmp" && pwd -P)

  # Every row of the contract table in the design, asserted verbatim.
  #
  # The columns are ARGSPEC|RC|OUT_LINES|OUT_FIRST|ERR_LINES|ERR_FIRST, and
  # the fields are split on '|' alone so that a value may contain spaces.
  # Do not pad this table with alignment spaces: they would be data.
  #
  # ARGSPEC is encoded rather than quoted because several of the rows are
  # about argument *shape* - "no argument at all", "one empty-string
  # argument", "two arguments", "options after `--`" - and none of those
  # survives being written as an ordinary field. @S@ stands in for the
  # scratch directory, which is not known until now.
  #
  # Every call carries `--no-clipboard`. This section is about the path,
  # and a machine with a working clipboard is not a thing a test may
  # assume it is running on; the section below this one is where the
  # clipboard is the subject.
  run_gp_table() {
    # run_gp_table SHELL
    local sh=$1 argspec rc outn out1 errn err1 call expected
    while IFS='|' read -r argspec rc outn out1 errn err1; do
      [ -n "$argspec" ] || continue
      case $argspec in
        @NONE@)   call='fp --no-clipboard' ;;
        @EMPTY@)  call="fp --no-clipboard ''" ;;
        @TWO@)    call='fp --no-clipboard a b' ;;
        @ENDOPT@) call='fp --no-clipboard -- --relative' ;;
        @SWAP@)   call='fp --relative --no-clipboard' ;;
        *)        call="fp --no-clipboard '$argspec'" ;;
      esac
      expected="rc=$rc out=$outn err=$errn out1=[${out1//@S@/$scratch}] err1=[$err1]"
      assert_eq "$expected" \
        "$(probe_shell "$sh" "cd '$scratch' || exit 9; . '$PATHS'; $call")" \
        "$sh: fp $argspec"
    done <<'TABLE'
@NONE@|0|1|@S@|0|
foo/bar|0|1|@S@/foo/bar|0|
./foo/bar|0|1|@S@/foo/bar|0|
.|0|1|@S@|0|
./|0|1|@S@|0|
../foo|0|1|@S@/../foo|0|
foo/|0|1|@S@/foo/|0|
/foo/bar|0|1|/foo/bar|0|
/|0|1|/|0|
-anything-else|0|1|@S@/-anything-else|0|
@ENDOPT@|0|1|@S@/--relative|0|
@SWAP@|0|1|.|0|
-h|0|15|usage: fp [OPTIONS] [--] [PATH]|0|
--help|0|15|usage: fp [OPTIONS] [--] [PATH]|0|
@EMPTY@|2|0||15|usage: fp [OPTIONS] [--] [PATH]
@TWO@|2|0||16|fp: too many arguments (expected at most one path)
TABLE
  }

  # --relative takes the current directory off the front and does nothing
  # else, so this is the table above read through that one rule.
  #
  # It is driven through `fpn` rather than through `fp --no-clipboard`,
  # which makes every row an assertion about a shorthand as well: one that
  # dropped "$@" would answer for the current directory, and only the rows
  # that pass an argument would notice.
  #
  # The last two rows are the ones the rule exists for. A target outside
  # the current directory keeps its absolute spelling instead of growing a
  # `../../` walk, and @S@X is the sibling trap: it begins with every
  # character of the scratch directory and is a different directory, which
  # only a pattern insisting on the separator can tell apart.
  run_gpr_table() {
    # run_gpr_table SHELL
    local sh=$1 argspec rc outn out1 errn err1 call expected
    while IFS='|' read -r argspec rc outn out1 errn err1; do
      [ -n "$argspec" ] || continue
      case $argspec in
        @NONE@) call='fpn --relative' ;;
        *)      call="fpn --relative '${argspec//@S@/$scratch}'" ;;
      esac
      expected="rc=$rc out=$outn err=$errn out1=[${out1//@S@/$scratch}] err1=[$err1]"
      assert_eq "$expected" \
        "$(probe_shell "$sh" "cd '$scratch' || exit 9; . '$PATHS'; $call")" \
        "$sh: fpn --relative $argspec"
    done <<'TABLE'
@NONE@|0|1|.|0|
foo/bar|0|1|foo/bar|0|
./foo/bar|0|1|foo/bar|0|
.|0|1|.|0|
./|0|1|.|0|
../foo|0|1|../foo|0|
foo/|0|1|foo/|0|
@S@/a/b|0|1|a/b|0|
@S@|0|1|.|0|
/|0|1|/|0|
/nowhere-near-the-scratch/x|0|1|/nowhere-near-the-scratch/x|0|
@S@X/x|0|1|@S@X/x|0|
TABLE
  }

  for sh in $SHELLS; do
    run_gp_table "$sh"
    run_gpr_table "$sh"

    # This file is sourced into a live interactive shell, so a `set -e` or
    # `set -o pipefail` escaping from it would make a typo at the prompt
    # fatal. Comparing the whole option table catches pipefail, which $-
    # does not report.
    assert_eq "rc=0 out=0 err=0 out1=[] err1=[]" \
      "$(probe_shell "$sh" "b=\$(set -o); . '$PATHS'; a=\$(set -o); [ \"\$b\" = \"\$a\" ]")" \
      "$sh: sourcing changes no shell option"

    # WHY THE SHORTHANDS ARE FUNCTIONS AND NOT ALIASES
    #
    # bash expands an alias only when `expand_aliases` is on, and it is off
    # in every non-interactive shell - which is every shell this suite
    # starts. An alias would be `command not found` here and would work at
    # a prompt, which is precisely the difference between the two shells
    # that this file promises it does not have. This assertion is what
    # turns that promise red if somebody rewrites the three as aliases.
    assert_eq "rc=0 out=1 err=0 out1=[$scratch/foo] err1=[]" \
      "$(probe_shell "$sh" "cd '$scratch' || exit 9; . '$PATHS'; fpn foo")" \
      "$sh: fpn reaches fp with its argument intact"

    # A shorthand prepends a flag, so a user who repeats that same flag by
    # hand sends it twice without ever seeing it twice. The parse sets a
    # variable rather than counting, which is what makes the repetition
    # mean nothing - and what stops an error message naming a word the
    # user did not write.
    assert_eq "rc=0 out=1 err=0 out1=[foo] err1=[]" \
      "$(probe_shell "$sh" "cd '$scratch' || exit 9; . '$PATHS'; fpnr --no-clipboard foo")" \
      "$sh: a flag a shorthand already supplied is not an error"

    # One command means one name in every message, whichever shorthand
    # routed there. That is the opposite of the rule this file used to
    # carry - two commands sharing an implementation had to be told apart -
    # and it is right for the same reason: the name in the message is the
    # name of the thing the user can read the help of, and `fpr --help`
    # prints fp's.
    assert_eq "rc=2 out=0 err=16 out1=[] err1=[fp: too many arguments (expected at most one path)]" \
      "$(probe_shell "$sh" "cd '$scratch' || exit 9; . '$PATHS'; fpr a b")" \
      "$sh: a shorthand's argument error names fp"
  done

  section_report
)
section_end $?

section_begin 'fp and the clipboard'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  scratch=$(cd "$tmp" && pwd -P)

  # A clipboard that can be read back afterwards. $WD40_CLIP holds a
  # command name and is invoked quoted, so a path to a script is exactly
  # what it wants; `command -v` accepts one.
  cap="$scratch/clipboard"
  clip_ok="$scratch/clip-ok"
  clip_fails="$scratch/clip-fails"
  printf '#!/bin/sh\ncat > "%s"\n' "$cap" > "$clip_ok"
  printf '#!/bin/sh\ncat > /dev/null\nexit 3\n'  > "$clip_fails"
  chmod +x "$clip_ok" "$clip_fails"

  # A cascade command that exists and then does not work. This is the
  # author's own failure mode - ~/.local/bin/pbcopy forwards over SSH and
  # there is nothing listening - and it is reached by name rather than
  # through WD40_CLIP, so it needs a directory of its own on PATH. The
  # real directories stay on PATH behind it: the stub still needs `cat`,
  # and a shim shadowing the rest of PATH is exactly the arrangement being
  # imitated.
  fakebin="$scratch/fakebin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\ncat > /dev/null\nexit 3\n' > "$fakebin/pbcopy"
  chmod +x "$fakebin/pbcopy"

  # And a PATH with none of the five on it, which is the one branch of the
  # cascade nothing had ever reached: the machine with no clipboard at all.
  # An empty directory is the whole of it - _wd40_clip runs no external
  # command on the way to giving up, and `fp` needs none either, so
  # there is nothing for the shell to fail to find.
  emptybin="$scratch/emptybin"
  mkdir -p "$emptybin"

  run_gp() {
    # run_gp SHELL ASSIGNMENT ARGS
    probe_shell "$1" "cd '$scratch' || exit 9; . '$PATHS'; $2 fp $3"
  }

  if [ "$SHELLS" = "bash" ]; then
    skip "the whole zsh half of this section" "zsh is not on PATH"
  fi
  for sh in $SHELLS; do
    # THE STREAM CONTRACT
    #
    # The path goes to stdout whether it was copied or not, and stderr
    # stays empty on the way through. The arrangement this replaces put
    # the path on stdout when it was printed and on stderr when it was
    # copied, which was defensible while those were two commands and is a
    # trap now that a flag chooses between them: `fp foo > file` and
    # `fpn foo > file` would have captured different things, and the
    # difference would have left no mark on the output.
    rm -f "$cap"
    assert_eq "rc=0 out=1 err=0 out1=[$scratch/foo] err1=[]" \
      "$(run_gp "$sh" "WD40_CLIP='$clip_ok'" foo)" \
      "$sh: the path goes to stdout and stderr stays empty"

    # A path with a newline on the end, pasted at a prompt, runs
    # immediately. Byte counts, because a trailing newline is exactly what
    # a string comparison would throw away.
    assert_eq "$scratch/foo" "$(cat "$cap")" "$sh: the clipboard got the path"
    assert_eq "$(printf '%s' "$scratch/foo" | wc -c | tr -d ' ')" \
      "$(wc -c < "$cap" | tr -d ' ')" \
      "$sh: the clipboard got it with no trailing newline"

    # --no-clipboard is the whole of the difference: same stdout, and a
    # clipboard that was never opened.
    rm -f "$cap"
    assert_eq "rc=0 out=1 err=0 out1=[$scratch/foo] err1=[]" \
      "$(run_gp "$sh" "WD40_CLIP='$clip_ok'" "--no-clipboard foo")" \
      "$sh: --no-clipboard prints the same path"
    assert_fail 1 "$sh: and leaves the clipboard alone" test -e "$cap"

    # --help is answered before anything is copied, or the usage text
    # itself would be what landed on the clipboard.
    rm -f "$cap"
    assert_eq "rc=0 out=15 err=0 out1=[usage: fp [OPTIONS] [--] [PATH]] err1=[]" \
      "$(run_gp "$sh" "WD40_CLIP='$clip_ok'" --help)" \
      "$sh: fp --help describes fp on stdout"
    assert_fail 1 "$sh: fp --help did not touch the clipboard" test -e "$cap"

    # A CLIPBOARD THAT FAILS DOES NOT COST THE CALLER THE PATH
    #
    # out=1 in all four of the failing rows below, and it is the half of
    # each assertion that is new. The path is printed first and the
    # clipboard is attempted after, so a machine with no clipboard on it
    # still answers the question that was asked - and still says, on
    # stderr and in the exit status, that the copy did not happen.
    #
    # The user said what they wanted; a WD40_CLIP that is not a command is
    # an error, not a reason to fall through to the cascade.
    rm -f "$cap"
    assert_eq "rc=1 out=1 err=1 out1=[$scratch/foo] err1=[wd40: WD40_CLIP names \"definitely-not-a-real-command\", which is not a command]" \
      "$(run_gp "$sh" "WD40_CLIP=definitely-not-a-real-command" foo)" \
      "$sh: an unfindable WD40_CLIP exits 1 and names it"
    assert_fail 1 "$sh: and copies nothing" test -e "$cap"

    # A clipboard command that runs and then fails used to be the one
    # failure nobody was told about: no receipt, no error, exit 1, and the
    # user left to work out that the missing receipt *was* the error.
    #
    # err=1 is the rest of the assertion. One line on stderr, naming the
    # command and its exit status. That the status survives at all proves
    # the pipeline's exit code is read correctly, which this file has to
    # manage without `set -o pipefail`.
    rm -f "$cap"
    assert_eq "rc=1 out=1 err=1 out1=[$scratch/foo] err1=[wd40: $clip_fails failed (exit 3); nothing was copied]" \
      "$(run_gp "$sh" "WD40_CLIP='$clip_fails'" foo)" \
      "$sh: a WD40_CLIP that fails names itself and its exit status"

    # The same for a command the cascade chose rather than one the user
    # named. Every branch that runs a command reports the same way, and
    # this is the branch a real machine actually reaches.
    rm -f "$cap"
    assert_eq "rc=1 out=1 err=1 out1=[$scratch/foo] err1=[wd40: pbcopy failed (exit 3); nothing was copied]" \
      "$(run_gp "$sh" "WD40_CLIP= PATH='$fakebin:/usr/bin:/bin'" foo)" \
      "$sh: a cascade command that fails names itself and its exit status"

    # An argument error is the one case with nothing on stdout: there is
    # no path to print, because none could be worked out. It copies
    # nothing on the way out either.
    rm -f "$cap"
    assert_eq "rc=2 out=0 err=16 out1=[] err1=[fp: too many arguments (expected at most one path)]" \
      "$(run_gp "$sh" "WD40_CLIP='$clip_ok'" "a b")" \
      "$sh: two arguments exit 2"
    assert_fail 1 "$sh: and copy nothing" test -e "$cap"

    rm -f "$cap"
    assert_eq "rc=2 out=0 err=15 out1=[] err1=[usage: fp [OPTIONS] [--] [PATH]]" \
      "$(run_gp "$sh" "WD40_CLIP='$clip_ok'" "''")" \
      "$sh: an empty argument exits 2"
    assert_fail 1 "$sh: and copies nothing either" test -e "$cap"

    # NO CLIPBOARD COMMAND AT ALL
    #
    # The bottom of the cascade: a machine with none of pbcopy, wl-copy,
    # xclip or xsel on it. Two lines on stderr, because the second is the
    # way out - naming WD40_CLIP is what turns "this does not work here"
    # into something the user can act on. And still out=1: on such a
    # machine `fp` is `fpn` with a diagnostic, which is a usable command
    # rather than a broken one.
    rm -f "$cap"
    assert_eq "rc=1 out=1 err=2 out1=[$scratch/foo] err1=[wd40: no clipboard command found (tried pbcopy, wl-copy, xclip, xsel)]" \
      "$(run_gp "$sh" "WD40_CLIP= PATH='$emptybin'" foo)" \
      "$sh: no clipboard command anywhere exits 1 and says which it looked for"
    assert_fail 1 "$sh: and copies nothing" test -e "$cap"

    # The second line is the half a first-line assertion cannot see.
    set +e
    "$sh" -c "cd '$scratch' || exit 9; . '$PATHS'; WD40_CLIP= PATH='$emptybin' fp foo" \
      >/dev/null 2>"$scratch/noclip.err"
    set -e
    assert_eq 'wd40: set WD40_CLIP to the name of a command that reads stdin' \
      "$(sed -n '2p' "$scratch/noclip.err")" \
      "$sh: and the second line says how to fix it"
  done

  section_report
)
section_end $?

section_begin 'wd40'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  # A HOME of its own, as everywhere that runs a real install: the runs
  # below leave BIN_DIR off PATH, and a startup file one of them wrote is
  # not allowed to decide the next one's result.
  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  WD40="$REPO/scripts/wd40.sh"

  line() { printf '%s\n' "$1" | sed -n "$2p"; }

  # A BARE `wd40`
  #
  # Usage on stdout and exit 0, because this is a discovery command and
  # somebody who types its name with nothing after it is asking what it
  # does rather than making a mistake. Everything the program does not
  # understand is the opposite case and is asserted below: stderr, and a
  # status that says so.
  set +e
  "$WD40" >"$work/bare.out" 2>"$work/bare.err"
  rc=$?
  set -e
  assert_eq "0" "$rc" "a bare wd40 exits 0"
  assert_eq 'Usage: wd40 <command>' "$(sed -n '1p' "$work/bare.out")" \
    "and prints its usage on stdout"
  capture cat "$work/bare.err"
  assert_empty "and writes nothing at all to stderr" "$CAPTURED"

  # Three spellings of one answer, compared byte for byte rather than by
  # their first line: three copies of a usage text is how two of them come
  # to be out of date.
  for spelling in help -h --help; do
    set +e
    "$WD40" "$spelling" >"$work/h.out" 2>"$work/h.err"
    rc=$?
    set -e
    assert_eq "0" "$rc" "wd40 $spelling exits 0"
    if cmp -s "$work/bare.out" "$work/h.out"; then
      pass "and wd40 $spelling prints exactly what a bare wd40 prints"
    else
      fail "and wd40 $spelling prints exactly what a bare wd40 prints"
    fi
    capture cat "$work/h.err"
    assert_empty "and wd40 $spelling writes nothing to stderr either" "$CAPTURED"
  done

  # THE USAGE TEXT
  #
  # The line count and every structural line are asserted exactly, for the
  # reason install.sh's usage is: two of these lines are the only written
  # statement of where an installed command is looked for, and a summary
  # assertion passes over exactly the character somebody edits. The
  # paragraph between them is prose and is asserted for what it says
  # rather than how, because it exists to answer two questions - which of
  # "this repository" and "this machine" `list` describes, and what a mark
  # on a line means - and those are the parts that may not quietly go.
  usage_text=$(cat "$work/bare.out")
  assert_eq "13" "$(printf '%s\n' "$usage_text" | wc -l | tr -d ' ')" "usage is thirteen lines"
  assert_eq 'Usage: wd40 <command>' "$(line "$usage_text" 1)" "line 1 names the command"
  assert_eq '  list                list every command this repository provides' \
    "$(line "$usage_text" 3)" "line 3 documents list"
  assert_eq '  help, -h, --help    show this help' \
    "$(line "$usage_text" 4)" "line 4 documents all three spellings of help"
  assert_eq 'Script directory precedence: $WD40_BIN_DIR > ~/.local/sbin' \
    "$(line "$usage_text" 12)" "line 12 states where an installed script is looked for"
  assert_eq 'Shell directory precedence:  $WD40_SHELL_DIR > ~/.zsh_aliases.d' \
    "$(line "$usage_text" 13)" "line 13 states the same for a shell file"
  case $usage_text in
    *"describes this repository and not this machine"*)
      pass "and the text says which of the two questions list answers" ;;
    *) fail "and the text says which of the two questions list answers" ;;
  esac
  case $usage_text in
    *"marked with a leading"*)
      pass "and what a mark on a line means" ;;
    *) fail "and what a mark on a line means" ;;
  esac

  # AN UNKNOWN SUBCOMMAND
  set +e
  "$WD40" lst >"$work/u.out" 2>"$work/u.err"
  rc=$?
  set -e
  assert_eq "1" "$rc" "an unknown subcommand exits 1"
  capture cat "$work/u.out"
  assert_empty "and writes nothing to stdout" "$CAPTURED"
  assert_eq 'Usage: wd40 <command>' "$(sed -n '1p' "$work/u.err")" \
    "and the usage it prints goes to stderr"
  assert_eq "Error: unknown argument 'lst'" "$(sed -n '$p' "$work/u.err")" \
    "and it names what was not understood"

  # `wd40 ''` is not a bare `wd40`. An empty argument is something the
  # user typed, and a mistake somebody can see in what they typed gets a
  # mistake's answer - the same distinction install.sh draws between
  # `--dir=` and a default that had no HOME to expand.
  set +e
  out=$("$WD40" '' 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "an empty argument is a mistake and not a bare invocation"
  case $out in
    *"unknown argument ''"*) pass "and is named as the empty argument it is" ;;
    *)                       fail "and is named as the empty argument it is" ;;
  esac

  # EXTRA ARGUMENTS
  #
  # Refused rather than passed over. `wd40 list --json` asks for something
  # this program does not do, and going quietly on would leave it looking
  # as though it had - which is also the door a real --json could never be
  # added through afterwards without changing what an old invocation
  # meant.
  set +e
  out=$("$WD40" list --json 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "an extra argument to list exits 1"
  case $out in
    *"wd40 list takes no arguments (got '--json')"*)
      pass "and names the command and the word it did not want" ;;
    *) fail "and names the command and the word it did not want" ;;
  esac

  # And the command is named as the user spelled it. Somebody who typed
  # `-h` must not be answered about `help`, which is the rule
  # shell_display_name keeps one file over.
  set +e
  out=$("$WD40" -h foo 2>&1)
  rc=$?
  set -e
  assert_eq "1" "$rc" "an extra argument to -h exits 1 too"
  case $out in
    *"wd40 -h takes no arguments (got 'foo')"*)
      pass "and answers about -h, which is what was typed" ;;
    *) fail "and answers about -h, which is what was typed" ;;
  esac

  # THROUGH THE INSTALLED SYMLINK
  #
  # The assertion the whole bootstrap exists for. `wd40` is invoked
  # through a link in ~/.local/sbin, so `dirname "$0"` is the install
  # directory: a wd40 that trusted it would look for scripts/ and shell/
  # beside somebody's PATH, find neither, and say so with complete
  # confidence. Only a real symlink can tell the difference - a copy would
  # pass whatever the code did - and the working directory is a third
  # place again, because a relative path that happened to work from inside
  # the repository would hide the same bug.
  linkdir="$work/sbin"
  elsewhere="$work/elsewhere"
  mkdir -p "$linkdir" "$elsewhere"
  ln -s "$WD40" "$linkdir/wd40"

  set +e
  out=$(cd "$elsewhere" && "$linkdir/wd40" list 2>/dev/null)
  rc=$?
  set -e
  assert_eq "0" "$rc" "wd40 through its symlink, from a third directory, exits 0"
  case $out in
    *smem-groups*) pass "and finds the repository it was linked from" ;;
    *)             fail "and finds the repository it was linked from" ;;
  esac
  case $out in
    *fpnr*) pass "and shell/ with it, which is a directory up and back down" ;;
    *)      fail "and shell/ with it, which is a directory up and back down" ;;
  esac

  # A chain, because this walk is resolve_path's walk with the diagnostics
  # taken out, and resolve_path's own tests have one: a loop that stopped
  # after a single hop would pass every assertion above this line.
  ln -s "$linkdir/wd40" "$linkdir/wd40-again"
  set +e
  out2=$(cd "$elsewhere" && "$linkdir/wd40-again" list 2>/dev/null)
  rc=$?
  set -e
  assert_eq "0" "$rc" "and through a two-hop chain of symlinks as well"
  assert_eq "$out" "$out2" "with the same answer"

  # INSTALLED BY THE EXISTING MECHANISM, NOT BY A SPECIAL CASE
  #
  # install.sh links everything under scripts/ that the allowlist takes,
  # so a new script needs no line anywhere. That no line was added is a
  # claim about install.sh, and this is the only way to make it: the file
  # never names this one.
  case $(cat "$INSTALL") in
    *wd40.sh*) fail "install.sh names wd40.sh nowhere" ;;
    *)         pass "install.sh names wd40.sh nowhere" ;;
  esac

  bin="$work/bin"
  sdir="$work/aliases.d"
  "$INSTALL" --dir "$bin" --shell-dir "$sdir" >/dev/null 2>&1
  assert_ok "and installs it all the same"          test -L "$bin/wd40"
  assert_eq "$REPO/scripts/wd40.sh" "$(readlink "$bin/wd40")" \
    "with the link pointing at the source script"
  assert_ok "and the installed link runs"           "$bin/wd40" list
  "$INSTALL" --dir "$bin" --shell-dir "$sdir" --uninstall >/dev/null 2>&1
  assert_fail 1 "and --uninstall takes it away again" test -e "$bin/wd40"

  section_report
)
section_end $?

section_begin 'wd40 list'
(
  set -e
  section_reset
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  work=$(cd "$tmp" && pwd -P)

  home="$work/home"
  mkdir -p "$home"
  HOME="$home"
  export HOME

  bin="$work/bin"
  sdir="$work/aliases.d"

  # Both directories are pinned for the whole section, so that what is
  # reported installed is decided by these fixtures and not by whatever
  # another section left in the sandboxed home. It is also the precedence
  # under test: `list` reads install.sh's own two variables, so setting
  # these is the only way to be sure it is looking where an install would
  # have put things.
  WD40_BIN_DIR="$bin"
  WD40_SHELL_DIR="$sdir"
  export WD40_BIN_DIR WD40_SHELL_DIR

  # A repository of this section's own, holding a copy of the installer
  # and a copy of wd40 - the same shape make_fixture builds for every
  # other end-to-end assertion here, and for the same reason: what `list`
  # prints must not depend on what this repository happens to hold today.
  fixture() {
    # fixture DIR
    make_fixture "$1"
    mkdir -p "$1/scripts" "$1/shell"
    cp "$REPO/scripts/wd40.sh" "$1/scripts/wd40.sh"
    chmod +x "$1/scripts/wd40.sh"
  }

  list_of() {
    # list_of REPO [ARG...]
    local r=$1
    shift
    set +e
    "$r/scripts/wd40.sh" list "$@" >"$work/out" 2>"$work/err"
    RC=$?
    set -e
    OUT=$(cat "$work/out")
    ERR=$(cat "$work/err")
  }

  fix="$work/repo"
  fixture "$fix"
  printf '#!/bin/sh\n# wd40: tool - do a thing\n:\n' > "$fix/scripts/tool.sh"
  {
    printf '# wd40: one - the first one\n'
    printf '# wd40: twotwotwo - the second one\n'
    printf 'one() { :; }\n'
    printf 'twotwotwo() { :; }\n'
  } > "$fix/shell/lib.sh"

  # THE WHOLE OF THE OUTPUT, WITH NOTHING INSTALLED
  #
  # Compared entire rather than line by line, because most of what is
  # claimed here is the relationship between the lines: the grouping, the
  # order inside a group, one column width across both groups - the
  # longest name is a shell function and the scripts above it are padded
  # to it - and a legend that appears once, after everything it explains.
  #
  # The mark is `!` in the first of the two columns the names are indented
  # by, so an installed line is exactly the line it would have been
  # without any of this, and a missing one can be found with a pipe:
  # `wd40 list | grep '^!'`. It is the character warn opens every
  # diagnostic in this repository with, and it is a character rather than
  # a colour because this output is read down a pipe at least as often as
  # on a terminal.
  list_of "$fix"
  expected=$(cat <<EXPECTED
scripts
! tool        do a thing
! wd40        list the commands this repository provides

shell functions
! one         the first one
! twotwotwo   the second one

! not installed in $bin
! not installed in $sdir
EXPECTED
)
  assert_eq "0" "$RC" "a repository that has never been installed still lists, and exits 0"
  assert_eq "$expected" "$OUT" "every command is marked, and both directories are named"
  capture cat "$work/err"
  assert_empty "and nothing is said on stderr" "$CAPTURED"

  # AND AFTER AN INSTALL
  #
  # The same output with every mark and the whole legend gone, which is
  # what makes the marking worth having: the clean case is not merely
  # quieter, it is silent.
  "$fix/install.sh" --dir "$bin" --shell-dir "$sdir" >/dev/null 2>&1
  list_of "$fix"
  expected=$(cat <<'EXPECTED'
scripts
  tool        do a thing
  wd40        list the commands this repository provides

shell functions
  one         the first one
  twotwotwo   the second one
EXPECTED
)
  assert_eq "$expected" "$OUT" "an installed repository is listed with no mark and no legend"

  # HALF INSTALLED
  #
  # The legend names the directory of the kind that is missing something,
  # and only that one. A single line naming both would send somebody to
  # look in the directory that is fine.
  rm -f "$sdir/lib.sh"
  list_of "$fix"
  case $OUT in
    *"! one "*) pass "removing a shell link marks the commands that file held" ;;
    *)          fail "removing a shell link marks the commands that file held" ;;
  esac
  case $OUT in
    *"! twotwotwo "*) pass "both of them, because the mark is per command" ;;
    *)                fail "both of them, because the mark is per command" ;;
  esac
  case $OUT in
    *"! tool"*) fail "while the scripts, which are still there, are not marked" ;;
    *)          pass "while the scripts, which are still there, are not marked" ;;
  esac
  case $OUT in
    *"! not installed in $sdir"*) pass "and the legend names the shell directory" ;;
    *)                            fail "and the legend names the shell directory" ;;
  esac
  case $OUT in
    *"! not installed in $bin"*) fail "and not the script directory, which is complete" ;;
    *)                           pass "and not the script directory, which is complete" ;;
  esac

  # A NAME IS NOT EVIDENCE
  #
  # Somebody's own `tool` on their PATH is not this repository's install,
  # and answering "did it take?" with a confident yes for a machine where
  # nothing of ours ever happened is the one wrong answer this feature can
  # give. Ownership is resolved, exactly as install_one and remove_one
  # resolve it.
  printf 'someone elses tool\n' > "$work/foreign"
  rm -f "$bin/tool"
  ln -s "$work/foreign" "$bin/tool"
  list_of "$fix"
  case $OUT in
    *"! tool"*) pass "a foreign symlink wearing our name is not our install" ;;
    *)          fail "a foreign symlink wearing our name is not our install" ;;
  esac

  # A CLONE WITH NO shell/
  #
  # No group, and no blank line where one would have been: a heading with
  # nothing under it reports something that is not there. The mark on the
  # one line left is the other half of the ownership rule - $bin/wd40 is a
  # real link of ours, but ours is the other fixture's, and this
  # repository is not that one.
  fixold="$work/repo-no-shell"
  fixture "$fixold"
  rm -rf "$fixold/shell"
  list_of "$fixold"
  expected=$(cat <<EXPECTED
scripts
! wd40   list the commands this repository provides

! not installed in $bin
EXPECTED
)
  assert_eq "0" "$RC" "a clone with no shell/ still lists"
  assert_eq "$expected" "$OUT" "with no shell group and no blank line standing in for one"

  # NO HOME, AND NO ENVIRONMENT VARIABLE EITHER
  #
  # There is then no directory to ask about, and "I could not look" is a
  # different claim from "there is nothing there". Marking these `!` would
  # be the second one made on the evidence for neither, so nothing is
  # marked and the reason is given once for each kind, naming HOME - which
  # is the shape every have_home branch in install.sh takes.
  set +e
  out=$(env -u HOME -u WD40_BIN_DIR -u WD40_SHELL_DIR \
    "$fix/scripts/wd40.sh" list 2>"$work/nohome.err")
  rc=$?
  set -e
  err=$(cat "$work/nohome.err")
  assert_eq "0" "$rc" "with no HOME and no WD40_BIN_DIR, list still lists and exits 0"
  case $out in
    *'!'*) fail "and marks nothing, having had nowhere to look" ;;
    *)     pass "and marks nothing, having had nowhere to look" ;;
  esac
  case $err in
    *"HOME is not set and neither is WD40_BIN_DIR"*)
      pass "and says why, naming HOME, for the scripts" ;;
    *) fail "and says why, naming HOME, for the scripts" ;;
  esac
  case $err in
    *"HOME is not set and neither is WD40_SHELL_DIR"*)
      pass "and separately for the shell functions, which are a different directory" ;;
    *) fail "and separately for the shell functions, which are a different directory" ;;
  esac

  # THE FIRST DRIFT ASSERTION
  #
  # An installable file that declares nothing is a command that exists and
  # is not listed, which is the silent drift the convention was written
  # against - so it is refused in the same shape install.sh refuses two
  # scripts claiming one name: loudly, naming the file, before anything is
  # printed.
  fixquiet="$work/repo-undeclared"
  fixture "$fixquiet"
  printf '#!/bin/sh\n# a script with nothing to say about itself\n:\n' \
    > "$fixquiet/scripts/quiet.sh"
  list_of "$fixquiet"
  assert_eq "1" "$RC" "a file that declares no command is refused"
  case $ERR in
    *"$fixquiet/scripts/quiet.sh declares no command"*)
      pass "and the file is named" ;;
    *) fail "and the file is named" ;;
  esac
  capture cat "$work/out"
  assert_empty "and no half-list is printed before the refusal" "$CAPTURED"

  # THE SECOND
  #
  # A declared name that is not the name the command has. For a script
  # that is a string comparison against install.sh's own link_name_for,
  # which is why it can be made here at all.
  fixtypo="$work/repo-misspelt"
  fixture "$fixtypo"
  printf '#!/bin/sh\n# wd40: tolo - a name nothing is installed under\n:\n' \
    > "$fixtypo/scripts/tool.sh"
  list_of "$fixtypo"
  assert_eq "1" "$RC" "a script declaring a name install.sh would not give it is refused"
  case $ERR in
    *"declares 'tolo', but install.sh installs it as 'tool'"*)
      pass "and both names are printed, because either of them could be the wrong one" ;;
    *) fail "and both names are printed, because either of them could be the wrong one" ;;
  esac

  # AND A SCRIPT IS ONE COMMAND
  #
  # It is installed under exactly one name, so a second declaration could
  # only be fiction. A shell file has no such limit, and the fixture above
  # relies on it: lib.sh is two commands, which is the whole reason this
  # lists commands rather than files.
  printf '#!/bin/sh\n# wd40: tool - one\n# wd40: tool2 - two\n:\n' \
    > "$fixtypo/scripts/tool.sh"
  list_of "$fixtypo"
  assert_eq "1" "$RC" "a script declaring two commands is refused"
  case $ERR in
    *"declares more than one command"*) pass "and told why one name is all it gets" ;;
    *)                                  fail "and told why one name is all it gets" ;;
  esac

  # BOTH OF THEM, ASKED OF THIS REPOSITORY
  #
  # The refusals above are the mechanism; these two are the claim. Every
  # installable file here declares a command - which is what a clean run
  # of `list` means, since one that did not would have stopped it - and
  # every name declared is a command that exists.
  assert_clean "every installable file in this repository declares a command" \
    "$REPO/scripts/wd40.sh" list

  # The half `list` cannot make for itself: a declared shell function has
  # to be defined once the file is sourced, and `list` may not source a
  # user's shell files to answer a question about them.
  #
  # The names come out of the real parser rather than a second copy of it,
  # so the two cannot drift apart either - and they are counted first,
  # because a loop over nothing asserts nothing while looking exactly like
  # a loop that passed.
  #
  # In bash only. What is checked here is that a header agrees with the
  # code under it, which is one reading of one file; that the code then
  # behaves the same under zsh is the claim the two sections above this
  # one spend a hundred assertions on.
  declared_names() {
    # declared_names KIND-HEADING
    "$REPO/scripts/wd40.sh" list | awk -v want="$1" '
      $0 == want { on = 1; next }
      /^$/       { on = 0 }
      on         { l = substr($0, 3); split(l, f, " "); print f[1] }'
  }
  names=$(declared_names 'shell functions')
  assert_eq "4" "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" \
    "shell/wd40-paths.sh declares four commands"
  while IFS= read -r name; do
    if bash -c '. "$1" >/dev/null 2>&1; command -v "$2" >/dev/null 2>&1' \
        wd40-declared "$REPO/shell/wd40-paths.sh" "$name"; then
      pass "and sourcing it defines $name"
    else
      fail "and sourcing it defines $name"
    fi
  done < <(printf '%s\n' "$names")

  # THE PARSER
  #
  # A declaration is read out of the header only - the run of blank and
  # comment lines before the first line of code. That rule does two jobs:
  # it keeps the declaration where it belongs, next to what it describes,
  # and it makes a declaration-shaped *string* impossible to mistake for a
  # declaration without this file having to learn to read shell. A line
  # holding a quoted string is code, so the header ended at or before it.
  #
  # test/smoke.sh's own portability guard has to carry the scanner this
  # avoids - eighty lines following quotes, escapes and here-documents -
  # and it has no choice, because it looks for constructs that can appear
  # anywhere in a file. This looks for a declaration, and a declaration
  # belongs in the header, so the cheaper rule is also the more accurate
  # one.
  fixp="$work/repo-parser"
  fixture "$fixp"

  probe() {
    # probe HEADER-LINE... - lay one script down and list its repository
    printf '#!/bin/sh\n' > "$fixp/scripts/probe.sh"
    while [ $# -gt 0 ]; do
      printf '%s\n' "$1" >> "$fixp/scripts/probe.sh"
      shift
    done
    printf '\n:\n' >> "$fixp/scripts/probe.sh"
    list_of "$fixp"
  }

  # The description for NAME, with the mark and the padding taken off, so
  # that these assertions are about the parser and not about the layout.
  described() {
    # described NAME
    printf '%s\n' "$OUT" | awk -v n="$1" '
      { l = substr($0, 3); split(l, f, " ")
        if (f[1] == n) { sub(/^[^[:space:]]+[[:space:]]+/, "", l); print l } }'
  }

  probe '#    wd40:     probe    -    a  description   with  gaps'
  assert_eq "0" "$RC" "a declaration survives any amount of space around its parts"
  assert_eq "a  description   with  gaps" "$(described probe)" \
    "and the spacing inside the description is left as it was written"

  probe '# wd40: probe - a - b - c'
  assert_eq "a - b - c" "$(described probe)" \
    "only the first hyphen separates, so a description may hold as many as it likes"

  probe '# wd40: probe -'
  assert_eq "1" "$RC" "a declaration with no description is refused"
  case $ERR in
    *"probe.sh, line 2, opens 'wd40:' and is not a declaration"*)
      pass "and the line is named rather than passed over" ;;
    *) fail "and the line is named rather than passed over" ;;
  esac

  probe '# wd40: probe'
  assert_eq "1" "$RC" "and so is one with no hyphen at all"

  probe '# wd40 list is how you would find this' '# wd40: probe - the real one'
  assert_eq "0" "$RC" "the words wd40 list written in prose are prose"
  assert_eq "the real one" "$(described probe)" \
    "and the declaration beside them is still read"

  # A comment below the first line of code. This is the header rule on its
  # own, with nothing else standing behind it - the case below is refused
  # by two things at once, and a rule that only ever fires alongside
  # another one is a rule nobody can tell has stopped working.
  cat <<'PROBE' > "$fixp/scripts/probe.sh"
#!/bin/sh
# wd40: probe - the real one

:
# wd40: late - declared after the code
PROBE
  list_of "$fixp"
  assert_eq "0" "$RC" "a declaration below the first line of code is not in the header"
  case $OUT in
    *late*) fail "and is not listed" ;;
    *)      pass "and is not listed" ;;
  esac

  # And a declaration inside a quoted string, which is the case the header
  # rule exists for. It is laid down as a shell file rather than a script,
  # so that a parser which read the string would be caught printing an
  # extra command rather than refusing the file for having two - a refusal
  # would be the right answer arrived at for the wrong reason, and would
  # hide what is actually being asked here. The probe script the case
  # above left behind goes for the same reason.
  rm -f "$fixp/scripts/probe.sh"
  cat <<'PROBE' > "$fixp/shell/probe.sh"
# wd40: sprobe - the real one

printf '# wd40: fake - not a command\n'
PROBE
  list_of "$fixp"
  assert_eq "0" "$RC" "a declaration-shaped string below the header is not a declaration"
  case $OUT in
    *fake*) fail "and the name inside it is not listed" ;;
    *)      pass "and the name inside it is not listed" ;;
  esac
  assert_eq "the real one" "$(described sprobe)" \
    "while the real declaration above it still is"

  section_report
)
section_end $?

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
