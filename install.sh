#!/usr/bin/env bash
#
# install.sh - symlink wd40's two kinds of artefact into place.
#
# scripts/ holds files that are executed, and lands in a directory on your
# PATH with the extension stripped. shell/ holds files that are sourced by
# an interactive shell, and lands in a directory of alias files with the
# extension kept. The two are independent: neither knows about the other,
# and a run that installs one still installs the other.
#
# Targets bash 3.2 and BSD userland: macOS still ships bash 3.2 as
# /bin/bash, and this repository is public, so it gets cloned onto stock
# machines. That rules out associative arrays, ${var,,}, mapfile, globstar,
# `readlink -f`, and `realpath`. See docs in the repo for the reasoning.
#
# Usage: ./install.sh --help

set -eu

REPO_ROOT=$(cd "$(dirname "$0")" && pwd -P)

warn() { printf '!  %s\n' "$1" >&2; }

die() {
  # die MESSAGE [CODE]
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Resolve a path to an absolute, symlink-free location. Prints the answer
# on stdout, or says why on stderr and returns 1.
#
# `readlink -f` and `realpath` are GNU extensions absent from stock macOS,
# so the chain is walked by hand with flagless `readlink`. The 40-hop cap
# matches the kernel's own ELOOP limit and stops a symlink cycle from
# hanging the installer.
#
# The final component is not required to exist; its parent directory is.
#
# A failure is a returned status, never a `die`. Every caller reads this as
# `current=$(resolve_path "$dest")`, and an exit inside a command
# substitution kills the substitution and nothing else - so the caller used
# to carry on with an empty $current and announce
# `symlink points outside this repo ()`, the empty parenthesis being the
# whole of the evidence. Once errexit was live the same die took the entire
# run down instead, which is honest and still wrong: one destination this
# installer cannot make sense of is no reason to abandon the others.
resolve_path() {
  local target=$1 link dir base hops=0

  while [ -L "$target" ] && [ "$hops" -lt 40 ]; do
    link=$(readlink "$target")
    case $link in
      /*) target=$link ;;
      *)  target=$(dirname "$target")/$link ;;
    esac
    hops=$((hops + 1))
  done

  if [ -L "$target" ]; then
    warn "symlink cycle detected resolving '$1'"
    return 1
  fi

  dir=$(dirname "$target")
  base=$(basename "$target")
  if [ ! -d "$dir" ]; then
    warn "cannot resolve '$1': '$dir' is not a directory"
    return 1
  fi
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

# Extensions this installer is willing to link, as a closed allowlist.
# Anything else — .md, .txt, .ps1, or no extension at all — is ignored, so
# a stray README under scripts/ never becomes a command on your PATH.
#
# .ps1/.bat/.cmd are deliberately absent: they belong to a Windows
# installer that does not exist yet.
is_installable() {
  case $1 in
    *.sh|*.py) return 0 ;;
    *)         return 1 ;;
  esac
}

discover_scripts() {
  local root=${1:-$REPO_ROOT} f
  [ -d "$root/scripts" ] || return 0
  find "$root/scripts" -type f | LC_ALL=C sort | while IFS= read -r f; do
    if is_installable "$f"; then printf '%s\n' "$f"; fi
  done
}

discover_ignored() {
  local root=${1:-$REPO_ROOT} f
  [ -d "$root/scripts" ] || return 0
  find "$root/scripts" -type f | LC_ALL=C sort | while IFS= read -r f; do
    if is_installable "$f"; then :; else printf '%s\n' "$f"; fi
  done
}

# Every symlink under scripts/ or shell/.
#
# A symlink is neither installed nor followed, and the two halves have
# different reasons. Not installed, because `find -type f` asks for regular
# files. Not followed, because ownership here is decided by resolving a
# destination back into REPO_ROOT, and a link under scripts/ that pointed
# outside this repository would install a file the installer does not own
# under a name saying it does - the uninstaller would then refuse to take
# it away again, for the same rule read the other way round. Following one
# would defeat the whole scheme to save a contributor a `cp`.
#
# What was wrong was the silence. Discovery skipped it and so did the
# report of what was ignored, so the file produced no link, no line and no
# error: the only evidence was a command that never appeared. This is the
# half that changes - passed over, and said so.
#
# One function for both directories, and not one per kind like the
# allowlists, because the rule refusing a symlink does not depend on which
# allowlist would have judged it. That is the shape detect_newline_names
# already has, for the same reason.
#
# `-type l` also catches a symlink to a *directory*, which matters more:
# find does not descend into one, so every file underneath it would be
# invisible as well and this line is the only notice there can be.
detect_symlinks() {
  local root=${1:-$REPO_ROOT} d
  for d in scripts shell; do
    [ -d "$root/$d" ] || continue
    find "$root/$d" -type l
  done | LC_ALL=C sort
}

# Every path under scripts/ or shell/ whose name contains a newline.
#
# Discovery is `find | while read`, and `read` splits on newlines, so such
# a name arrives as two half-paths and neither of them is the file. What
# happens next depends only on what the halves happen to look like: the
# second half `lines.sh` passes the allowlist, and if something of that
# name exists relative to the working directory the run announces
# `link .../bin/lines -> lines.sh`, exits 0, and leaves a relative symlink
# on PATH that is dangling from every directory but one. The uninstaller
# then refuses to take it away, because a relative target does not resolve
# inside this repository - so the broken command is permanent. When the
# halves are less lucky the run dies instead with
# `cannot make lines.sh executable`, naming a file that does not exist and
# never naming the one that does.
#
# Reading such a name properly needs `find -print0` and a NUL-safe `read`,
# and bash 3.2 and POSIX `read` do not have that between them. Refusing is
# the honest half of the choice; a permanent broken command on PATH is not.
#
# `-name` rather than `-type f`, so that a *directory* with a newline in
# its name is caught as well: find prints the directory itself, and every
# file underneath it inherits the newline in its path.
#
# The newline is built with a sentinel because `$(printf '\n')` is the one
# thing command substitution is guaranteed to throw away.
detect_newline_names() {
  local root=${1:-$REPO_ROOT} d nl
  nl=$(printf '\nX')
  nl=${nl%X}
  for d in scripts shell; do
    [ -d "$root/$d" ] || continue
    find "$root/$d" -name "*${nl}*"
  done
}

# Refuse the whole run over one, before anything has been linked or
# removed.
#
# Called from do_install and do_uninstall rather than from discovery, which
# is where the refusal belongs and is the one place it cannot be made:
# every caller reads discovery through `< <(...)` or a pipe, and a die in
# there kills the subshell, hands the loop an early EOF, and leaves the run
# looking like a repository with fewer files in it. This is the same
# position, and the same shape, as detect_collisions - a property of the
# repository, answered once, before any of it is acted on.
refuse_newline_names() {
  local bad
  bad=$(detect_newline_names)
  [ -n "$bad" ] || return 0
  warn "a file name contains a newline:"
  printf '%s\n' "$bad" >&2
  die "rename it; a newline splits the path in two and neither half is the file" 1
}

# scripts/smem-groups.sh -> smem-groups
# Only the final extension is stripped, so my.tool.sh -> my.tool.
link_name_for() {
  local base
  base=$(basename "$1")
  case $base in
    *.*) printf '%s\n' "${base%.*}" ;;
    *)   printf '%s\n' "$base" ;;
  esac
}

# Print every link name claimed by more than one installable file, given
# the function that enumerates the files and the one that names them.
#
# Those two are parameters rather than two near-identical copies of this
# function, because the duplicate-detection itself is the part that must
# never differ between the kinds: whichever kind collides, the caller has
# to hear about it in the same way.
collisions_for() {
  local discover=$1 namer=$2 root=$3 f
  "$discover" "$root" | while IFS= read -r f; do
    "$namer" "$f"
  done | LC_ALL=C sort | uniq -d
}

# Two scripts landing on the same name is a defect in this repository, not
# a user problem, so the caller fails loudly rather than picking a winner.
# prune.sh and prune.ps1 never reach here together: the allowlist already
# dropped the .ps1, which is exactly how a cross-platform pair is meant to
# behave.
detect_collisions() {
  collisions_for discover_scripts link_name_for "${1:-$REPO_ROOT}"
}

# $HOME is read as ${HOME:-} here and everywhere else in this file.
#
# These two lines are evaluated before a single argument has been read, so
# under `set -u` an unset HOME aborted the run with
# `install.sh: line 174: HOME: unbound variable` even when both directories
# had been given explicitly and no home directory was wanted for anything.
# cron, systemd units, `env -i` and Docker layers routinely have no HOME,
# and a bash trace carrying a line number is not a diagnostic.
#
# `${HOME:+...}` rather than `${HOME:-}/...`, so that with no HOME these
# expand to nothing at all. They used to expand to /.local/sbin and
# /.zsh_aliases.d - a root-relative path that read like a deliberate
# destination and was nothing of the kind. Unprivileged it failed honestly,
# at the mkdir, naming a directory it could not create; as root with no
# HOME - `env -i` in CI, some container layers - it would have *created*
# /.local/sbin, which is precisely the litter that refusing `--dir=` exists
# to prevent, arriving through a different door.
#
# Nothing is a destination, so nothing is refused: see require_destinations
# below, which is where every origin of an empty value meets one check. The
# one step that genuinely needs a home directory is finding the file a
# shell reads at startup, and that step names HOME as the problem itself;
# see have_home below.
BIN_DIR=${WD40_BIN_DIR:-${HOME:+$HOME/.local/sbin}}
RC_DIR=${WD40_RC_DIR:-${HOME:+$HOME/.config/wd40}}
DRY_RUN=0
FORCE=0
MODE=install

# Whether each directory's value was typed on the command line.
#
# An empty value has more than one origin and only one of them is a flag,
# and the two want different sentences: `--dir=` is a mistake the user can
# see in what they typed, while a default that expanded to nothing is an
# absent HOME, which they cannot. Recording which produced the value is the
# only way for one check to say either.
BIN_DIR_FROM_FLAG=0
RC_DIR_FROM_FLAG=0

# The rc files this run will write to, one per line, when --rc was given.
#
# Empty means "use the default target set", which is every known rc file
# that exists - see rc_targets below. A --rc replaces that set outright
# rather than adding to it, because the flag exists for the user who knows
# where their configuration lives and wants this run to go there and
# nowhere else.
#
# One string with newlines in it, rather than an array, because that is the
# idiom this file already uses for every list it builds - discover_scripts,
# spellings_for and rc_chain_for all print one path per line and every
# caller reads them with `while IFS= read -r`. A --rc whose value contains a
# newline therefore splits into halves, and require_rc_files rejects it a
# moment later because neither half is a file that exists: the failure mode
# is a refusal naming the halves, not a silent write to the wrong place.
RC_FILES=
RC_FROM_FLAG=0

# What the two halves of a run counted, and whether anything went wrong.
#
# main used to ask `if do_install; then`, and a compound command in an `if`
# condition is exempt from errexit - an exemption that reaches through the
# whole body of the function it calls. Every mkdir, chmod and ln -s failure
# inside do_install was therefore discarded, so a run aimed at an unwritable
# directory announced two symlinks it had not created and exited 0. Counting
# into a variable is what lets do_install be called on a line of its own,
# where a failure is a failure as it is anywhere else.
#
# SHELL_LINKED is the same mechanism answering a narrower question, and it
# predates the fix: the loader must not be wired up by a run that installed
# nothing but scripts, and bash 3.2 has no way to return a second value.
#
# LAST_LINKED and LAST_REMOVED carry the single-call answer that install_one
# and remove_one may no longer give as an exit status, for exactly the
# reason their callers may no longer ask for one.
LINKED=0
RC_LINKED=0
LAST_LINKED=0
LAST_REMOVED=0

# A filesystem operation that should have worked and did not.
#
# Recorded rather than acted on at once, because scripts/ and shell/ are
# independent: a destination that cannot be created is no reason to abandon
# the other one, and a run that can only do half its job should still do
# that half. main turns this into the exit status once both halves are done.
FAILED=0

# Link one script. LAST_LINKED says whether a link was made.
#
# Ownership is decided by resolving the existing symlink, never by its
# name: a user's unrelated `smem-groups` on their PATH must survive.
#
# Leaving a destination alone and linking it are both successful outcomes,
# which is why neither is an exit status any more. The outcome that is not
# successful is a filesystem operation that failed, and that leaves through
# die rather than through a return value nobody was reading.
install_one() {
  local src=$1 dest=$2 current

  LAST_LINKED=0

  if [ -L "$dest" ]; then
    if current=$(resolve_path "$dest"); then
      case $current in
        "$REPO_ROOT"/*)
          : ;;  # ours already - replacing it is what makes re-runs idempotent
        *)
          if [ "$FORCE" != "1" ]; then
            warn "skipping $(basename "$dest"): symlink points outside this repo ($current)"
            warn "  use --force to replace it"
            return 0
          fi ;;
      esac
    else
      # resolve_path has already said what went wrong, and this says what
      # is being done about it. A destination whose target cannot be
      # established is not a destination that is ours, and it gets the
      # treatment one that is not ours gets: left alone by default,
      # replaceable with --force, and counting for nothing - so a run in
      # which it was the only candidate still ends in "nothing was
      # installed". The old code claimed the opposite in the same breath as
      # proving it could not know: `points outside this repo ()`.
      if [ "$FORCE" != "1" ]; then
        warn "cannot resolve $(basename "$dest"); leaving it alone"
        warn "  use --force to replace it"
        return 0
      fi
    fi
  elif [ -e "$dest" ]; then
    if [ "$FORCE" != "1" ]; then
      warn "skipping $(basename "$dest"): a regular file is already there"
      warn "  use --force to replace it"
      return 0
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '   link %s -> %s\n' "$dest" "$src"
    LAST_LINKED=1
    return 0
  fi

  # Each of the three operations below is reported by name. Errexit is
  # finally live in here, but it is not the user-facing mechanism: a bash
  # trace carrying a line number is not a diagnostic. A filesystem
  # operation that should have worked and did not is a new outcome, and it
  # takes die's default exit 1.
  chmod +x "$src" || die "cannot make $src executable"
  # Not `ln -sfn`: BSD and GNU disagree on what -n means. Removing first
  # and creating fresh behaves identically everywhere.
  rm -f "$dest" || die "cannot replace $dest"
  # `ln` says why on its own stderr, and its exit status is not the
  # evidence - the filesystem is. Asking the link where it points is what
  # earns the right to print the line below, which used to be printed
  # whether the link had been created or not.
  ln -s "$src" "$dest" || :
  if [ ! -L "$dest" ] || [ "$(readlink "$dest")" != "$src" ]; then
    die "could not link $dest -> $src"
  fi

  LAST_LINKED=1
  printf '   link %s -> %s\n' "$dest" "$src"
}

# Under --dry-run, say when a destination could not have been created.
#
# A dry run runs no mkdir, so no mkdir fails, so the preview promised two
# links into a directory the run could never have made and exited 0. That
# is correct under the contract - a dry run changes nothing - and the
# preview was still a lie, which is the one thing a preview may not be.
#
# Walking up to the nearest ancestor that exists and asking whether it is
# writable is as close as a run that touches nothing can get to the answer
# mkdir would have given. It is not the same answer: a full disk, an
# immutable bit, a read-only mount and a container's own idea of
# permissions are all invisible from here. So this is advice and not a
# verdict - nothing is created, and the exit status is what it would have
# been anyway.
#
# The walk stops when dirname stops moving, which is `/` on every system
# this runs on and is what keeps a relative path from looping.
warn_if_not_creatable() {
  # warn_if_not_creatable DIR KIND
  local dir=$1 kind=$2 probe parent

  [ -d "$dir" ] && return 0

  # A path that exists and is not a directory is not going to become one,
  # and mkdir -p says so in exactly those terms.
  if [ -e "$dir" ]; then
    warn "the $kind directory $dir cannot be created: it is not a directory"
    return 0
  fi

  probe=$dir
  while [ ! -e "$probe" ]; do
    parent=$(dirname "$probe")
    [ "$parent" = "$probe" ] && break
    probe=$parent
  done

  if [ ! -d "$probe" ]; then
    warn "the $kind directory $dir cannot be created: $probe is not a directory"
  elif [ ! -w "$probe" ]; then
    warn "the $kind directory $dir cannot be created: $probe is not writable"
  fi
}

do_install() {
  local dupes f name rc_file bin_ok=1 rc_ok=1

  refuse_newline_names

  dupes=$(detect_collisions)
  if [ -n "$dupes" ]; then
    warn "two scripts claim the same command name:"
    printf '%s\n' "$dupes" >&2
    die "rename one of them; refusing to guess" 1
  fi

  rc_file="$REPO_ROOT/shell/wd40rc"

  if [ "$DRY_RUN" = "1" ]; then
    printf 'Dry run. Nothing will be changed.\n'
    report_ignored
    warn_if_not_creatable "$BIN_DIR" script
    if [ -f "$rc_file" ]; then
      warn_if_not_creatable "$RC_DIR" config
    fi
  else
    warn_about_symlinks
    if ! mkdir -p "$BIN_DIR"; then
      warn "cannot create the script directory $BIN_DIR"
      bin_ok=0
      FAILED=1
    fi
    if [ -f "$rc_file" ]; then
      if ! mkdir -p "$RC_DIR"; then
        warn "cannot create the config directory $RC_DIR"
        rc_ok=0
        FAILED=1
      fi
    fi
  fi

  # Process substitution, not a pipe: in bash 3.2 a piped `while read` body
  # runs in a subshell and the counts would always come back 0.
  if [ "$bin_ok" = "1" ]; then
    while IFS= read -r f; do
      name=$(link_name_for "$f")
      install_one "$f" "$BIN_DIR/$name"
      LINKED=$((LINKED + LAST_LINKED))
    done < <(discover_scripts)
  fi

  if [ "$rc_ok" = "1" ] && [ -f "$rc_file" ]; then
    install_one "$rc_file" "$RC_DIR/wd40rc"
    LINKED=$((LINKED + LAST_LINKED))
    RC_LINKED=$((RC_LINKED + LAST_LINKED))
  fi
}

# Remove one link, but only when it is ours. LAST_REMOVED says whether one
# went.
#
# Ownership is resolution-based, exactly as it is when installing: a link
# goes only when it resolves to a path inside REPO_ROOT. A regular file,
# or a symlink to somebody else's tool, survives even when it carries one
# of our names. That rule earns its keep far more in SHELL_DIR than in
# BIN_DIR - SHELL_DIR is a directory of the user's own alias files, where
# a name like `git.sh` is theirs long before it is ever ours.
#
# --force has no meaning here and is ignored.
#
# Removing a link and leaving somebody else's alone are both successes, so
# neither is an exit status any more: do_uninstall used to ask
# `if remove_one ...`, and that exemption cost it every check inside.
remove_one() {
  local dest=$1 current

  LAST_REMOVED=0

  [ -L "$dest" ] || return 0

  # Fail-safe in exactly the way install_one is: a link whose target cannot
  # be established has not been shown to be ours, and this function removes
  # nothing it cannot show is ours. resolve_path has already said why on
  # stderr; --force has no meaning here and does not change it.
  if ! current=$(resolve_path "$dest"); then
    warn "cannot resolve $(basename "$dest"); leaving it alone"
    return 0
  fi

  case $current in
    "$REPO_ROOT"/*) ;;
    *) warn "leaving $(basename "$dest") alone: it points outside this repo ($current)"; return 0 ;;
  esac

  if [ "$DRY_RUN" != "1" ]; then
    # As in install_one: rm's status is not the evidence, the filesystem
    # is. die's default exit 1 for a removal that did not happen.
    rm -f "$dest" || :
    if [ -L "$dest" ] || [ -e "$dest" ]; then
      die "could not remove $dest"
    fi
  fi

  LAST_REMOVED=1
  printf '   remove %s\n' "$dest"
}

do_uninstall() {
  local f dest removed=0

  # Before anything is removed, and for the same reason install refuses:
  # a half-path is not a name this repository ever claimed, and an
  # uninstall that acted on one would be removing something on the strength
  # of a string it misread.
  refuse_newline_names

  if [ -d "$BIN_DIR" ]; then
    while IFS= read -r f; do
      dest="$BIN_DIR/$(link_name_for "$f")"
      remove_one "$dest"
      removed=$((removed + LAST_REMOVED))
    done < <(discover_scripts)
  fi

  if [ -d "$RC_DIR" ]; then
    remove_one "$RC_DIR/wd40rc"
    removed=$((removed + LAST_REMOVED))
  fi

  [ "$removed" -gt 0 ] || printf 'Nothing to remove in %s or %s.\n' "$BIN_DIR" "$RC_DIR"
}

# ~/.local/sbin is deliberate — these scripts stay separate from
# ~/.local/bin — but no shell puts it on PATH for you, on macOS or Linux.
# Saying so with the exact line to paste is the difference between a
# working install and a user wondering why the command is not found.
#
# The condition is named here, and only here. add_to_shell_rc is handed a
# user who has already been told what is wrong, so every branch of it says
# only what is being done about it. Both of them saying it produced two
# consecutive lines opening with the same eight words, which reads like
# two programs talking rather than one.
# warn_if_aliases_not_loaded and add_loader_to_shell_rc are the same pair
# under the same rule.
#
# WHY THE LIVE $PATH NO LONGER DECIDES WHETHER TO ACT
#
# This function used to open with the live $PATH and return early when it
# already held BIN_DIR. That is the same defect as picking an rc file from
# $SHELL, wearing different clothes, and it was reproduced on the author's
# machine: run the installer from a bash whose .bashrc had already put
# ~/.local/sbin on PATH, and the entire PATH step vanished - zsh was never
# even considered, and the shell he actually works in kept a broken
# install.
#
# $PATH here is a property of *this process*. The whole point of the step
# is to make *future* shells work. Those are two different questions, and
# the short-circuit answered only the first.
#
# So the two questions are separated. Whether to write is decided per rc
# file, from file evidence alone: does this shell's own startup chain name
# the directory? On the author's machine the live $PATH was "on" precisely
# *because* ~/.bashrc says so - the same fact arriving twice, once
# reliably through the file and once unreliably through the environment,
# and the reliable one is the one kept.
#
# The live $PATH survives in exactly one place: the silence below. When
# nothing is pending and this shell can already see the directory, there
# is nothing to do and nothing worth saying, and a message there would be
# noise on every re-run of a working install.
#
# The cost is accepted deliberately. A PATH set by /etc/profile or
# /etc/environment is named by no file this searches, so such a machine
# gains a block it did not need. It is harmless - the block is guarded on
# $PATH at shell-start time, which is the whole reason the guard is there -
# and the search is not extended to system files to chase it. Being wrong
# that way costs a redundant no-op; being wrong the other way costs half an
# install, silently, which is what was actually happening.
warn_if_not_on_path() {
  local t pending=0 handled=0

  # Counted before anything is said, because the sentence that opens the
  # report depends on how the whole set came out. A per-target headline
  # would be four monologues where the user asked one question.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -n "$(mentioned_in_chain "$t" "$BIN_DIR")" ]; then
      handled=$((handled + 1))
    else
      pending=$((pending + 1))
    fi
  done < <(rc_targets)

  if [ "$pending" -eq 0 ]; then
    case ":$PATH:" in
      *":$BIN_DIR:"*) return 0 ;;
    esac
  fi

  # On stderr, with the warning it spaces. The blank lines that space the
  # generated blocks went to stdout with them; this one belongs to a
  # diagnostic, so it goes where diagnostics go - otherwise a stdout
  # redirected on its own collects a blank line for a message it never saw.
  printf '\n' >&2
  if [ "$handled" -eq 0 ]; then
    # Nothing names it, which includes the machine with no rc file at all.
    #
    # This says only what was checked: no rc chain mentions BIN_DIR. It
    # used to claim "$BIN_DIR is not in your PATH", a statement about the
    # *live* PATH of this process, which this branch never looked at - see
    # WHY THE LIVE $PATH NO LONGER DECIDES WHETHER TO ACT above the top of
    # this function. On a machine where BIN_DIR reaches PATH some other
    # way - /etc/profile is the accepted edge case that comment already
    # names - the old sentence was false while this one stays true, because
    # it never claims anything about the live session at all.
    warn "$BIN_DIR is not in any shell's startup files."
  elif [ "$pending" -eq 0 ]; then
    # Every startup file is already right and this shell has not read one
    # of them yet, which is what the closing line of the report is for.
    warn "$BIN_DIR is already in your startup files."
  else
    warn "$BIN_DIR is not in every shell's startup files."
  fi
  add_to_shell_rc
}

# Under --dry-run, say which files were passed over. A script named
# `foo.bash` or `foo.txt` would otherwise vanish with no explanation, and
# so would a `foo.py` under shell/, where the allowlist is narrower than
# the one next door and the omission is that much easier to misread as a
# bug in the installer.
#
# Two stanzas rather than one list, because there are two reasons and a
# reader who cannot tell which applies to which file has been told nothing.
# An extension skip is at least guessable from the name; nothing about
# `linked.sh` says why it was passed over. Nothing appears in both, either:
# `find -type f` cannot see a symlink, so the extension stanza and this one
# can never claim the same path.
report_ignored() {
  local f any=0
  while IFS= read -r f; do
    [ "$any" = "1" ] || { printf '\nIgnored (extension not installable here):\n'; any=1; }
    printf '   %s\n' "$f"
  done < <(discover_ignored)

  any=0
  while IFS= read -r f; do
    [ "$any" = "1" ] || { printf '\nIgnored (a symlink, which is not followed):\n'; any=1; }
    printf '   %s\n' "$f"
  done < <(detect_symlinks)
}

# Outside --dry-run, say the same thing on stderr.
#
# report_ignored is the preview's business and a real run has no preview,
# which for an extension skip is tolerable - the name carries the rule - and
# for a symlink is not. The contributor who adds one has no reason to reach
# for --dry-run: as far as they can tell the install succeeded, and the only
# evidence that it did not is a command that never appears. So the anomaly
# leaves through the stream anomalies leave through.
#
# Silence when there is nothing to report, which is every ordinary run: a
# report that fires unconditionally teaches its reader to skip it.
#
# Nothing is said at uninstall time. A symlink was never linked, so there is
# nothing to remove and nothing to say, and repeating it there would be a
# second voice on a subject the install has already closed.
warn_about_symlinks() {
  local links
  links=$(detect_symlinks)
  [ -n "$links" ] || return 0
  warn "these are symlinks, and are not installed:"
  printf '%s\n' "$links" >&2
  warn "a symlink's target is not resolved, so it could name a file outside this repository"
}

# Is there a home directory to work from?
#
# The whole of this installer's need for one. Everything else works from
# the two directories it was handed, which is why $HOME is read as
# ${HOME:-} throughout: a run given both of them explicitly has no business
# aborting over a variable it never uses. Finding the file a shell reads at
# startup is the exception, because there is nowhere else to look - so the
# rc-wiring step, and only the rc-wiring step, turns an absent HOME into a
# diagnostic that names it.
have_home() {
  [ -n "${HOME:-}" ]
}

# Join LIST and ITEM with a newline, skipping the separator on the first.
#
# A list this file builds is a string with newlines in it, and every reader
# of one is a `while IFS= read -r`. Starting with the empty string and
# appending unconditionally would put a leading blank line in front of the
# first element, which every such reader would then hand back as an empty
# path.
append_line() {
  # append_line LIST ITEM
  if [ -z "$1" ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n%s\n' "$1" "$2"
  fi
}

# append_line, unless LIST already holds ITEM.
#
# Two rc targets that share a startup chain are answered by the same file
# whenever that file is the one already naming the directory:
# `--rc ~/.bashrc --rc ~/.bash_profile` both come back as ~/.bashrc,
# because rc_chain_for gives them the same four files to search and
# mentioned_in_chain stops at the first hit. A list being built for a
# sentence must not carry it twice, or the sentence offers the user a
# choice between a file and itself.
#
# restart_advice uses this for its closing line, and add_to_shell_rc and
# add_loader_to_shell_rc use it the same way for their per-target
# "already mentions it" line - both dedupe a fact keyed on the file that
# answered it, not on the target that asked. The lists that decide what
# to *write* are built from rc_targets, where each entry is a distinct
# file by construction, and deduplicating those would hide a repeated
# --rc rather than report it.
append_unique() {
  # append_unique LIST ITEM
  local f
  while IFS= read -r f; do
    if [ "$f" = "$2" ]; then
      printf '%s\n' "$1"
      return 0
    fi
  done < <(printf '%s\n' "$1")
  append_line "$1" "$2"
}

# The shells this installer is willing to name, as a closed allowlist.
#
# Same shape and same reason as is_installable: the question "is this the
# name of a shell?" has no general answer, and a guess that says yes to
# `make` or to a CI runner would put that word in a sentence telling the
# user to restart it.
is_shell_name() {
  case $1 in
    bash|zsh|sh|dash|ash|ksh|ksh93|mksh|pdksh|fish|tcsh|csh|busybox) return 0 ;;
    *) return 1 ;;
  esac
}

# The name of the shell that invoked this installer, or nothing.
#
# $SHELL is the *login* shell out of the password database, and this
# repository exists because that is the wrong question. The author logs in
# with bash and works in zsh, so $SHELL said bash, the installer wired up
# ~/.bashrc, and his zsh - which never reads it - was left without half the
# install. The process that ran this script is the shell he was actually
# sitting in, and $PPID names it.
#
# `ps -o comm= -p PID` is POSIX and works on Linux and BSD alike. Four
# things can go wrong with it and none of them may end the run:
#
#   - the parent is not a shell at all. `make`, a CI runner, another
#     script. is_shell_name is the closed allowlist that says so, and the
#     caller falls back to $SHELL.
#   - the name carries a leading `-`, which is how a login shell is
#     conventionally invoked. Stripped.
#   - the name is versioned - `bash-5.2`, `zsh-5.9`. The suffix is taken
#     off from the first `-` that is followed by a digit, so `ksh93` (no
#     dash) is left alone.
#   - `ps` is absent, or restricted enough to refuse. Both leave through
#     `|| :`, because a command substitution that fails under `set -e` would
#     otherwise take the whole install down over a cosmetic detail.
#
# macOS prints the full path in `comm`, Linux prints the bare name, so the
# result goes through basename either way. The `tr` is the trim: `ps` pads
# the column on some systems, and a shell's name has no space in it.
#
# This never decides where to write. It decides what to *call* a shell in a
# sentence, and which file to suggest sourcing - a guess is good enough for
# a sentence and would not be good enough for a write.
parent_shell_name() {
  local raw name
  raw=$(ps -o comm= -p "$PPID" 2>/dev/null || :)
  [ -n "$raw" ] || return 0

  name=$(printf '%s' "$raw" | tr -d ' \t')
  # The dash comes off before basename and not after, because `basename`
  # reads a leading `-` as a flag bundle: `basename -zsh` is an error, not
  # the word `zsh`. It is the same fault `mentions_dir` documents about
  # `grep -F -- "-x"`, met again one utility further along, and the answer
  # here is to make sure the argument never starts with a dash rather than
  # to rely on `basename --`, which is not on every BSD.
  case $name in
    -*) name=${name#-} ;;
  esac
  name=$(basename "$name")
  case $name in
    *-[0-9]*) name=${name%%-[0-9]*} ;;
  esac

  is_shell_name "$name" || return 0
  printf '%s\n' "$name"
}

# What to call the user's shell, best evidence first.
#
# The parent process is the shell they are sitting in; $SHELL is the one
# the password database says they log in with. The second is a worse
# answer to the question and is still better than no answer, so it is the
# fallback rather than the source.
interactive_shell_name() {
  local name
  name=$(parent_shell_name)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  name=$(basename "${SHELL:-}")
  [ -n "$name" ] || return 0
  printf '%s\n' "$name"
}

# The startup files RC_FILE's own shell reads, one per line.
#
# This is what makes "already configured" a per-shell question instead of a
# global one. The old code searched six files and answered yes or no for
# the whole machine, which is wrong in a way that matters here: the
# author's ~/.zsh_aliases sources the aliases directory, so the global
# answer was "already handled" and bash would never have got the loader -
# the exact mirror of the defect this change exists to fix.
#
# A file this installer does not recognise is its own chain, and nothing
# else. --rc names a file explicitly, and inferring a whole startup chain
# from a path like ~/.config/fish/config.fish would be the same guessing
# that has just been taken out of the common path, re-entering through the
# one door the user opened deliberately. Scoping it to itself is the
# answer that assumes nothing.
#
# Recognising by basename is what makes `--rc ~/.bashrc` behave exactly as
# the default ~/.bashrc target does. A flag that named the same file the
# defaults would have chosen, and then treated it differently, would be a
# trap.
#
# ~/.profile is on bash's chain and not on zsh's: zsh does not read it
# outside sh-emulation, so counting it for zsh would suppress a block zsh
# genuinely needs.
rc_chain_for() {
  # rc_chain_for RC_FILE
  local base f
  base=$(basename "$1")
  if have_home; then
    case $base in
      .bashrc|.bash_profile|.bash_aliases|.profile)
        for f in .bashrc .bash_profile .bash_aliases .profile; do
          printf '%s/%s\n' "$HOME" "$f"
        done
        return 0 ;;
      .zshrc|.zprofile|.zsh_aliases)
        for f in .zshrc .zprofile .zsh_aliases; do
          printf '%s/%s\n' "$HOME" "$f"
        done
        return 0 ;;
    esac
  fi
  printf '%s\n' "$1"
}

# Which shell RC_FILE belongs to, for a sentence. Nothing when unrecognised.
#
# The report puts this in front of each line it writes, because two blocks
# across two files is four outcomes in one run and a reader who cannot tell
# which shell a line is about has been told very little. A --rc file this
# installer does not recognise gets no label rather than a guessed one.
shell_for_rc() {
  case $(basename "$1") in
    .bashrc|.bash_profile|.bash_aliases|.profile) printf 'bash\n' ;;
    .zshrc|.zprofile|.zsh_aliases)                printf 'zsh\n'  ;;
    *) : ;;
  esac
}

# Every rc file this run will write to, one per line.
#
# The heuristic is gone from the common path. There is no choosing of one
# file out of two any more: both known rc files are targets, and each that
# exists is written to. On a machine with bash and zsh both installed, both
# shells end up working - which is what a user means by "install it".
#
# Existence is the filter and not a thing to fix. Creating ~/.zshrc on a
# machine with no zsh would leave a file nobody asked for, and the block to
# paste by hand is what a machine with no rc file at all gets instead.
#
# --rc replaces the set outright. require_rc_files has already established
# that every file in it exists, so the same "each that exists" rule holds
# for both origins without being applied twice.
rc_targets() {
  local f
  if [ "$RC_FROM_FLAG" = "1" ]; then
    printf '%s\n' "$RC_FILES"
    return 0
  fi
  have_home || return 0
  for f in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
  return 0
}

# A --rc that names a file which is not there is refused, not created.
#
# The flag says "write to this file", and the one thing it must not do is
# quietly write somewhere else - or bring a startup file into existence
# that the user's shell may not even read. A typo is the likeliest cause
# and naming the path is the whole of the fix.
require_rc_files() {
  local f
  [ "$RC_FROM_FLAG" = "1" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || die "--rc file does not exist: $f" 1
  done < <(printf '%s\n' "$RC_FILES")
}

# The first file in RC_FILE's own chain that names DIR, or nothing.
#
# mentions_dir does the reading, so all four spellings - the expanded path,
# `~`, `$HOME` and `${HOME}` - count here exactly as they counted before.
# What has changed is only which files are asked.
#
# The file that matched is printed rather than a yes or no, because that is
# the file the user has to be told about: on the author's machine ~/.zshrc
# names ~/.zsh_aliases and it is *that* file which names the aliases
# directory, so "your configuration already handles it" is only useful with
# a path attached.
mentioned_in_chain() {
  # mentioned_in_chain RC_FILE DIR
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if mentions_dir "$f" "$2"; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(rc_chain_for "$1")
  return 0
}

# Take the trailing slashes off DIR. Root keeps its own.
#
# A directory is one path, and `/x/y/` and `/x/y` are the same one, but
# nothing downstream of here treats them as the same string.
# `--shell-dir ~/.zsh_aliases.d/` - which is what shell tab-completion
# hands you, for free, without your meaning anything by it - made
# spellings_for offer `~/x/`, `$HOME/x/` and `${HOME}/x/` to a search of an
# rc file that writes `~/x`. Every spelling missed, the installer concluded
# that nothing sourced the directory, and appended a second loader to a
# configuration that already worked: the false negative this design names
# as its worst outcome, bought with one keystroke. The PATH test has the
# same shape and the same fault - `*":$BIN_DIR:"*` cannot see `/x/bin` on
# PATH when BIN_DIR says `/x/bin/`.
#
# `/` is left as it is, because stripping its slash leaves the empty
# string, which is not a path at all; a value that is nothing but slashes
# is `/` for the same reason. An empty value stays empty and is refused
# elsewhere, by the code whose job that is.
strip_trailing_slashes() {
  local dir=$1
  while [ "${dir%/}" != "$dir" ] && [ -n "${dir%/}" ]; do
    dir=${dir%/}
  done
  printf '%s\n' "$dir"
}

# Return DIR as $HOME/... when it is under $HOME, otherwise unchanged.
#
# Used when writing blocks to rc files: the user's existing blocks all use
# the $HOME form and the generated block should match that style. It also
# avoids baking the current user's expanded home path into a file that may
# be shared or restored on a machine with a different username.
home_rel() {
  local dir=$1
  [ -n "${HOME:-}" ] || { printf '%s\n' "$dir"; return 0; }
  case $dir in
    "${HOME}"/*) printf '$HOME%s\n' "${dir#$HOME}" ;;
    *)           printf '%s\n' "$dir" ;;
  esac
}

# Print every spelling a startup file might plausibly use for DIR.
#
# A directory is one path and four strings. The author's ~/.zsh_aliases
# writes ~/.zsh_aliases.d, and a search for the expanded
# /home/user/.zsh_aliases.d finds nothing in it - the same confident false
# negative that the wider file list below was introduced to prevent, moved
# from the wrong file to the wrong spelling. Both are answered the same
# way: search for all of them.
#
# The prefix strip is a `case` on "$HOME"/*, not a substring test.
# /home/user2/x begins with every character of /home/user and belongs to
# somebody else; only a pattern that insists on the separator can tell the
# two apart. A directory that is not under $HOME - including $HOME itself,
# which is a path rather than a prefix of one - has exactly one spelling,
# and so does every directory when $HOME is empty, unset, or `/`, because
# then there is no home directory to abbreviate against.
#
# These are for searching only. What the installer writes stays expanded:
# a tilde is not expanded inside the quotes the generated blocks use, and
# a block that wrote $HOME would resolve against whichever shell later
# read it rather than against the directory this run installed into.
spellings_for() {
  # spellings_for DIR
  local dir=$1 home rest
  printf '%s\n' "$dir"

  # $HOME gets the same treatment BIN_DIR and SHELL_DIR get after parsing,
  # and for the same reason: a HOME of /home/user/ would leave every `rest`
  # below missing its leading separator, so `~x/y` is what a startup file
  # would have been searched for. It is stripped here rather than at the
  # top of the file because $HOME is the user's, not ours to normalise for
  # anything but our own comparisons.
  home=$(strip_trailing_slashes "${HOME:-}")
  case $home in
    ''|/) return 0 ;;
  esac

  case $dir in
    "$home"/*) rest=${dir#"$home"} ;;
    *)         return 0 ;;
  esac

  printf '~%s\n'       "$rest"
  printf '$HOME%s\n'   "$rest"
  printf '${HOME}%s\n' "$rest"
}

# Does FILE name DIR, by any of the ways DIR can be spelled?
#
# The loop lives here rather than in each of the three places that ask,
# for the reason collisions_for gives about duplicate detection: what
# counts as "already configured" is precisely the part that must never
# differ between them, and three copies of it is three chances to drift.
#
# -F on every pass, because these are strings to find and not patterns to
# match: `$`, `{` and `}` carry no meaning here, and the dots in a name
# like .zsh_aliases.d are dots rather than any-character wildcards.
#
# `--` for the same reason one word further on. A directory whose name
# begins with `-` makes a spelling that begins with `-`, and grep reads
# that as a flag bundle: `grep -F "-x" file` is `grep -F -x file`, which
# quietly takes the *file* as the pattern and then blocks on stdin. The
# same fault was found in this suite's own portability guard, where it had
# made one of the twenty-two rows unable to fire at all.
mentions_dir() {
  # mentions_dir FILE DIR
  local file=$1 spelling
  while IFS= read -r spelling; do
    if grep -F -- "$spelling" "$file" >/dev/null 2>&1; then
      return 0
    fi
  done < <(spellings_for "$2")
  return 1
}

# What to call the user's shell in a sentence.
#
# `basename ''` prints an empty line, so an unset or empty $SHELL made
# shell_name the empty string, and the unsupported-shell branch of both
# functions below said `I don't know how to configure  automatically` -
# two spaces with a hole between them where the name should have been. The
# branch was the right branch and the reason was the right reason; only the
# sentence was wrong.
#
# A shell whose name this installer does not have is still the user's
# shell, and saying so is both true and useful. A name it does have is
# printed as it is: the substitution is for the hole and for nothing else,
# and calling every unsupported shell `your shell` would throw away the one
# word in the sentence that tells the user which of theirs is meant.
shell_display_name() {
  # shell_display_name NAME
  if [ -n "$1" ]; then
    printf '%s\n' "$1"
  else
    printf 'your shell\n'
  fi
}

# Print the PATH block for BIN_DIR, every line prefixed with INDENT.
#
# One copy, three callers, for the reason print_loader_block gives about
# its own block: what a user pastes by hand has to be what the installer
# would have written, and the surest way to guarantee that is for there to
# be only one of it. The paste-by-hand branches used to print a bare
# `export PATH=...` while the file got the guarded form, so the two could
# drift and the user with the harder job got the weaker block.
#
# The guard is the same pattern rustup and cargo append: it re-reads $PATH
# at shell-start time, so the block is a no-op in a shell that already has
# the directory - which is what makes a redundant copy harmless.
print_path_block() {
  local indent=$1 rel
  rel=$(home_rel "$BIN_DIR")
  printf '%s# added by wd40 install.sh\n' "$indent"
  printf '%sif [[ ! "$PATH" == *"%s"* ]]; then\n' "$indent" "$rel"
  printf '%s  export PATH="%s:${PATH:+${PATH}:}"\n' "$indent" "$rel"
  printf '%sfi\n' "$indent"
}

# One closing line of advice, naming the files the user has to act on.
#
# WHAT THE LINE IS FOR, AND WHY IT TAKES TWO LISTS
#
# It is the only line in the report that tells the user to *do* something,
# so the files it names have to be the files that make the difference.
# WRITTEN is what this run changed. HANDLED is what needed no change,
# because some file in that shell's own startup chain already named the
# directory.
#
# These used to arrive as one list, and the advice picked out of it
# whichever entry belonged to the shell the installer happened to be
# invoked from. On the author's machine that produced a report which added
# a PATH block to ~/.zshrc, touched ~/.bashrc not at all, and then said
# `source ~/.bashrc` - advice that appears to work and changes nothing.
# The two facts had been flattened into one list and the difference
# between them was no longer recoverable, so no amount of better picking
# could have fixed it. Keeping them apart is the fix.
#
# WRITTEN WINS OUTRIGHT
#
# If anything was written, that is the whole of the answer. A file that
# needed nothing is not worth naming beside one that did: sourcing it
# changes nothing, and offering it as an alternative to the file that
# matters invites the user to pick the one that will not help.
#
# WHEN NOTHING WAS WRITTEN, EVERY FILE THAT ALREADY HANDLES IT IS NAMED
#
# The old code named one of them. Naming one out of several is the $SHELL
# heuristic this installer exists to remove, wearing different clothes: it
# picks a shell on the user's behalf and hides the other, and the user with
# two working shells is precisely the user this repository was written for.
# Naming both costs one clause and cannot be wrong.
#
# WHY EACH NAME CARRIES ITS SHELL WHEN THERE IS MORE THAN ONE
#
# `source ~/.bashrc or source ~/.zshrc` is a line a user can act on
# wrongly, and expensively: a real ~/.zshrc read by bash is a page of
# syntax errors, and the reverse is no better. The label is what makes the
# alternative choosable - the user takes the clause with their shell's name
# on it, and needs to edit nothing. A single name carries no label, because
# there is nothing to choose between. A --rc file this installer does not
# recognise has no label to give and gets none, which is the same answer
# shell_for_rc gives the per-target lines above.
#
# WHY A DRY RUN STILL PRINTS THE LINE, AND WHY IT CHANGES TENSE
#
# A dry run wrote nothing, so `source ~/.zshrc` is not advice: the block is
# not in the file, and following it does nothing. Printing nothing at all
# was considered and rejected. The point of a dry run is to answer "what
# would this do?", and "you would then have to source this file" is part of
# the answer - the part a user is most likely to be caught by, since it is
# the only step the installer cannot take for them. So the line is printed,
# in the subjunctive, and only over WRITTEN.
#
# The HANDLED branch stays in the present tense in both modes, and that is
# not an oversight: the files it names really do hold what they need to,
# today, and sourcing one of them right now does exactly what the line
# says it does. A dry run changes what is true of WRITTEN and changes
# nothing about HANDLED, so only WRITTEN changes tense.
#
# Both lists empty is silence. Nothing was done and nothing already does
# it, so there is nothing to advise, and a successful install with nothing
# to say must say nothing - which is the silence assert_clean defends.
#
# WRITTEN and HANDLED are newline-separated lists, as every list in this
# file is.
restart_advice() {
  # restart_advice WRITTEN HANDLED
  local list f label clause line= names= count=0 before subjunctive=0

  if [ -n "$1" ]; then
    list=$1
    if [ "$DRY_RUN" = "1" ]; then
      subjunctive=1
    fi
  else
    list=$2
  fi
  [ -n "$list" ] || return 0

  # Counted as the duplicates come out, because whether a name carries its
  # shell depends on how many names there are, and that is not known until
  # the last of them has been seen.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    before=$names
    names=$(append_unique "$names" "$f")
    if [ "$names" != "$before" ]; then
      count=$((count + 1))
    fi
  done < <(printf '%s\n' "$list")

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    clause="source $f"
    if [ "$count" -gt 1 ]; then
      label=$(shell_for_rc "$f")
      [ -z "$label" ] || clause="$clause ($label)"
    fi
    if [ -z "$line" ]; then
      line=$clause
    else
      line="$line or $clause"
    fi
  done < <(printf '%s\n' "$names")

  if [ "$subjunctive" = "1" ]; then
    warn "After a real run: restart your shell, or run: $line"
  else
    warn "Restart your shell, or run: $line"
  fi
}

# Add BIN_DIR to PATH for future shells, in every rc file this run targets.
#
# Appends a guarded block instead of a bare export, and skips a target
# whose own startup chain already names BIN_DIR - in any of its spellings,
# and not limited to our own block, so an
# `export PATH="$HOME/.local/sbin:$PATH"` the user wrote by hand also
# counts. That check is per shell now, not per machine: see rc_chain_for.
#
# Every branch says only what is being done, never why: warn_if_not_on_path
# has already named the condition. The one line that says more is the
# already-mentions line, and only because it detects something of its own -
# which file in the chain matched - so it is the one that names a path.
#
# The lines are indented under the headline and carry the shell they are
# about, because two blocks across two files is four outcomes in one run
# and they have to read as one report rather than four monologues.
add_to_shell_rc() {
  local t found label written= handled= any=0 reported= before

  # reported tracks which files this loop has already announced as
  # "already mentions it", keyed on $found itself - the file
  # mentioned_in_chain named, not on $t. Two --rc targets on the same
  # chain (--rc ~/.bashrc --rc ~/.bash_profile) are answered by the same
  # $found the moment that file is the one naming BIN_DIR, and the report
  # must say so once, not once per target: each line is individually true
  # and the report as a whole is not, which is the same fault
  # append_unique already exists to fix in restart_advice's closing line.
  #
  # Two targets on the *same* chain can never disagree here - the chain is
  # searched as a whole by mentioned_in_chain, so every target sharing a
  # chain gets the same $found or none at all - so there is no case of
  # identical $found with different wording to reconcile, only identical
  # $found with identical wording, which this collapses to one line. Two
  # targets on *different* shells' chains cannot share a $found either:
  # rc_chain_for's bash and zsh chains are disjoint file sets, so a bash
  # target and a zsh target reporting the same fact still print two lines,
  # one per shell - which is the case this must not regress.

  # The rc-wiring step is the one thing here that cannot be done without a
  # home directory, so it is the one place that says so. Everything the
  # user needs is still printed; only the offer to write it for them is
  # withdrawn. A --rc names its files outright and needs no home directory
  # to find them, so it is not caught by this.
  if ! have_home && [ "$RC_FROM_FLAG" != "1" ]; then
    warn "HOME is not set, so I cannot find your shell's startup file. Add this"
    warn "to it by hand:"
    print_path_block '       '
    printf '\n'
    return 0
  fi

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    any=1
    label=$(shell_for_rc "$t")
    [ -z "$label" ] || label="$label: "
    found=$(mentioned_in_chain "$t" "$BIN_DIR")

    if [ -n "$found" ]; then
      handled=$(append_line "$handled" "$found")
      before=$reported
      reported=$(append_unique "$reported" "$found")
      if [ "$reported" != "$before" ]; then
        warn "   $label$found already mentions it"
      fi
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      # The report line before the block, for the reason report_ignored is
      # printed before the link lines: the caveat is read before the
      # promise it qualifies. In a real run it can only come after the
      # append, because "was added" is a claim about something that has to
      # have happened first.
      warn "   ${label}a PATH block would be added to $t"
      printf 'Would add this block to %s:\n' "$t"
      print_path_block '   '
      printf '\n'
    else
      {
        printf '\n'
        print_path_block ''
      } >> "$t"
      warn "   ${label}a PATH block was added to $t"
    fi
    written=$(append_line "$written" "$t")
  done < <(rc_targets)

  # No rc file anywhere, which on a fresh machine is the ordinary case.
  # Naming a shell needs a better signal than $SHELL, and the process that
  # invoked this installer is it.
  if [ "$any" = "0" ]; then
    warn "I found no startup file for $(shell_display_name "$(interactive_shell_name)"). Add this"
    warn "to your shell's startup file:"
    print_path_block '       '
    printf '\n'
    return 0
  fi

  restart_advice "$written" "$handled"
}


# Print the source block for wd40rc, every line prefixed with INDENT.
#
# One copy, three callers: the block appended to an rc file, the block
# shown under --dry-run, and the block printed for a shell this installer
# cannot configure. What a user pastes by hand has to be what the
# installer would have written.
#
# The path is written as $HOME/... so the block is portable across
# machines with different usernames, and matches the style of the PATH
# blocks already in the user's rc files.
print_source_block() {
  local indent=$1 rel
  rel=$(home_rel "$RC_DIR")
  printf '%s# added by wd40 install.sh\n' "$indent"
  printf '%sif [ -r "%s/wd40rc" ]; then\n' "$indent" "$rel"
  printf '%s  . "%s/wd40rc"\n' "$indent" "$rel"
  printf '%sfi\n' "$indent"
}

# Warn when wd40rc is not yet sourced by the user's startup files, then
# offer to wire it up.
warn_if_not_sourced() {
  local t pending=0 handled=0 rc_path

  rc_path="$RC_DIR/wd40rc"

  if ! have_home && [ "$RC_FROM_FLAG" != "1" ]; then
    printf '\n' >&2
    warn "HOME is not set, so I cannot tell whether anything already sources $rc_path."
    add_source_to_shell_rc
    return 0
  fi

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -n "$(mentioned_in_chain "$t" "$rc_path")" ]; then
      handled=$((handled + 1))
    else
      pending=$((pending + 1))
    fi
  done < <(rc_targets)

  printf '\n' >&2
  if [ "$handled" -eq 0 ]; then
    warn "nothing in your startup files sources $rc_path."
  elif [ "$pending" -eq 0 ]; then
    warn "$rc_path is already sourced by your startup files."
  else
    warn "$rc_path is not sourced by every shell's startup files."
  fi
  add_source_to_shell_rc
}

# Append the source block to every rc file this run targets.
add_source_to_shell_rc() {
  local t found label written= handled= any=0 reported= before rc_path

  rc_path="$RC_DIR/wd40rc"

  if ! have_home && [ "$RC_FROM_FLAG" != "1" ]; then
    warn "HOME is not set, so I cannot find your shell's startup file. Add this"
    warn "to it by hand:"
    print_source_block '       '
    printf '\n'
    return 0
  fi

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    any=1
    label=$(shell_for_rc "$t")
    [ -z "$label" ] || label="$label: "
    found=$(mentioned_in_chain "$t" "$rc_path")

    if [ -n "$found" ]; then
      handled=$(append_line "$handled" "$found")
      before=$reported
      reported=$(append_unique "$reported" "$found")
      if [ "$reported" != "$before" ]; then
        warn "   $label$found already sources $rc_path - nothing to do"
      fi
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      warn "   ${label}a source block would be added to $t"
      printf 'Would add this block to %s:\n' "$t"
      print_source_block '   '
      printf '\n'
    else
      {
        printf '\n'
        print_source_block ''
      } >> "$t"
      warn "   ${label}a source block was added to $t"
    fi
    written=$(append_line "$written" "$t")
  done < <(rc_targets)

  if [ "$any" = "0" ]; then
    warn "I found no startup file for $(shell_display_name "$(interactive_shell_name)"). Add this"
    warn "to your shell's startup file:"
    print_source_block '       '
    printf '\n'
    return 0
  fi

  restart_advice "$written" "$handled"
}

# Refuse a destination that is the empty string, whatever produced it.
#
# Asked once, after parsing, rather than in the arms of the case below,
# because an empty value arrives by four doors - the spaced flag, the
# =-joined flag, the environment variable and the default - and the old
# code stood at one of them. `--dir=` was refused; `--dir ""` satisfies
# `[ $# -ge 2 ]` and walked straight through, and so did a default with no
# HOME to expand. Both produced the same run: `link /tool`, and under sudo
# litter at the root of the filesystem.
#
# The two sentences are the two causes, and each names the one the user can
# act on. A user who typed `--dir=` needs to hear about `--dir`; a user who
# typed nothing at all and has no home directory needs to hear about HOME,
# because being told `--dir requires an argument` would send them looking
# at an option they never used.
#
# Both directories are named in the same breath when both are missing:
# supplying one and being stopped again by the other is two round trips for
# one condition.
require_destinations() {
  local what vars

  if [ -z "$BIN_DIR" ] && [ "$BIN_DIR_FROM_FLAG" = "1" ]; then
    die "--dir requires an argument" 1
  fi
  if [ -z "$RC_DIR" ] && [ "$RC_DIR_FROM_FLAG" = "1" ]; then
    die "--rc-dir requires an argument" 1
  fi

  # Anything still empty was left to a default that had no HOME to expand,
  # which is the only origin left once the flags above have been answered.
  [ -z "$BIN_DIR" ] || [ -z "$RC_DIR" ] || return 0

  if [ -z "$BIN_DIR" ] && [ -z "$RC_DIR" ]; then
    what='--dir DIR and --rc-dir DIR'
    vars='WD40_BIN_DIR and WD40_RC_DIR'
  elif [ -z "$BIN_DIR" ]; then
    what='--dir DIR'
    vars='WD40_BIN_DIR'
  else
    what='--rc-dir DIR'
    vars='WD40_RC_DIR'
  fi

  warn "HOME is not set, so the default install directory has no ~ to expand."
  die "pass $what (or set $vars)" 1
}

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

  -d, --dir DIR        directory for script symlinks (default: ~/.local/sbin)
  -r, --rc-dir DIR     directory for wd40rc symlink (default: ~/.config/wd40)
      --rc FILE        startup file to configure; repeatable, replaces the
                       default set of ~/.bashrc and ~/.zshrc. A FILE this
                       installer does not recognise is searched only for
                       itself, not as part of any shell's startup chain
  -n, --dry-run        print what would happen; change nothing
  -f, --force          overwrite existing files that are not ours
  -u, --uninstall      remove this repository's symlinks
  -h, --help           show this help

Script directory precedence: --dir    > $WD40_BIN_DIR > ~/.local/sbin
Config directory precedence: --rc-dir > $WD40_RC_DIR  > ~/.config/wd40
Startup files: every one of ~/.bashrc and ~/.zshrc that exists, unless --rc
USAGE
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      -d|--dir)
        [ $# -ge 2 ] || die "$1 requires an argument" 1
        BIN_DIR=$2; BIN_DIR_FROM_FLAG=1; shift 2 ;;
      # `--dir=` with nothing after it is the same mistake as `--dir` with
      # nothing after it, so it gets the same sentence. It used to be taken
      # as a real directory: the run announced `link /smem-groups` and,
      # unprivileged, failed at the symlink - under sudo it would have left
      # litter at the root of the filesystem. The refusal itself has moved
      # to require_destinations, because this arm was never the only door;
      # what is recorded here is that a flag was typed, which is what lets
      # that one check still name the option in its spaced spelling - the
      # one the usage text documents, rather than the bare `--dir=` in $1.
      --dir=*)
        BIN_DIR=${1#--dir=}; BIN_DIR_FROM_FLAG=1
        shift ;;
      -r|--rc-dir)
        [ $# -ge 2 ] || die "$1 requires an argument" 1
        RC_DIR=$2; RC_DIR_FROM_FLAG=1; shift 2 ;;
      --rc-dir=*)
        RC_DIR=${1#--rc-dir=}; RC_DIR_FROM_FLAG=1
        shift ;;
      # An empty value is refused here rather than in a check after parsing,
      # which is where --dir and --shell-dir refuse theirs. The reason those
      # two had to move is that an empty value reaches them by four doors -
      # two flag spellings, an environment variable and a default - and only
      # one check downstream of all four can name the right cause. --rc has
      # neither an environment variable nor a default, so both of its doors
      # are here, and refusing at the door is what keeps the empty string out
      # of a list whose elements are separated by newlines.
      --rc)
        [ $# -ge 2 ] || die "$1 requires an argument" 1
        [ -n "$2" ] || die "--rc requires an argument" 1
        RC_FILES=$(append_line "$RC_FILES" "$2"); RC_FROM_FLAG=1; shift 2 ;;
      --rc=*)
        [ -n "${1#--rc=}" ] || die "--rc requires an argument" 1
        RC_FILES=$(append_line "$RC_FILES" "${1#--rc=}"); RC_FROM_FLAG=1
        shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -f|--force)   FORCE=1; shift ;;
      -u|--uninstall) MODE=uninstall; shift ;;
      -h|--help)    usage; return 0 ;;
      *) usage >&2; die "unknown argument '$1'" 1 ;;
    esac
  done

  # Answered before either mode runs, and before the normalisation below,
  # which has nothing to say about the empty string: a destination that is
  # nothing is refused whichever door it came through, and an uninstall
  # needs the answer as much as an install does - an empty BIN_DIR would
  # have it looking for `/smem-groups`.
  require_destinations

  # Asked here rather than in the --rc arm, because a run may name several
  # and being stopped once per file is one round trip per typo. A file that
  # is not there is refused rather than created: the flag says "write to
  # this file", and bringing a startup file into existence that the user's
  # shell may never read is not the same request.
  require_rc_files

  # Both directories are normalised here, once, immediately after parsing
  # and before anything reads them - so every comparison downstream is
  # between one path and one spelling of it, whether the value came from a
  # flag, from the environment, or from the defaults above.
  BIN_DIR=$(strip_trailing_slashes "$BIN_DIR")
  RC_DIR=$(strip_trailing_slashes "$RC_DIR")

  if [ "$MODE" = "uninstall" ]; then
    do_uninstall
    return 0
  fi

  do_install

  # Answered before anything else, and not as an `if do_install` any more.
  # A filesystem operation that should have worked and did not is a new
  # outcome, distinct from "there was nothing to do": a run that could not
  # do what it was asked has no business offering to append to the user's
  # startup files, which is precisely what the old shape went on to do for
  # directories it had failed to create. die's default exit 1.
  if [ "$FAILED" = "1" ]; then
    die "not everything could be installed"
  fi

  if [ "$LINKED" -gt 0 ]; then
    # Neither of these is gated on DRY_RUN. Appending to a startup file is
    # the most invasive thing this installer does, and a dry run exists to
    # answer "what would this do?" - staying quiet about the one step the
    # user most needs to see would be the wrong silence. Both functions
    # already have a DRY_RUN branch that prints the block instead of
    # writing it, so a dry run still leaves the disk untouched.
    warn_if_not_on_path
    if [ "$RC_LINKED" -gt 0 ]; then
      warn_if_not_sourced
    fi
    return 0
  fi

  warn "nothing was installed"
  return 2
}

# Sourced by test/smoke.sh with WD40_SOURCE_ONLY=1 to unit-test individual
# functions. Without this guard, sourcing would run a real install.
if [ "${WD40_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
