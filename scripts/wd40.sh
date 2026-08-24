#!/usr/bin/env bash
#
# wd40.sh - what this repository provides, and whether it is installed.
#
# wd40: wd40 - list the commands this repository provides
#
# Meta-commands only, and it never runs another command for you. A
# dispatcher - `wd40 sbin smem` - was considered and rejected: a namespace
# by implementation makes a user work out whether a thing is a script or a
# shell function before they can call it, which is the one distinction the
# two halves of this repository exist to keep out of their way, and with
# three commands a namespace level is ceremony.
#
# A bare `wd40` prints the usage text on stdout and exits 0. This is a
# discovery command, and somebody who types its name with nothing after it
# is asking what it does rather than making a mistake. An unknown argument
# is a mistake and gets a mistake's treatment: usage on stderr, exit 1.
#
# Targets bash 3.2 and BSD userland, for the reason install.sh gives at
# more length: this repository is public, so it gets cloned onto stock
# machines, and macOS still ships bash 3.2 as /bin/bash.
#
# Usage: wd40 help

set -eu

# WHERE THIS REPOSITORY IS
#
# `wd40` is normally invoked through a symlink in ~/.local/sbin, so
# `dirname "$0"` names the install directory rather than the repository -
# and everything below would then look for scripts/ and shell/ next door
# to somebody's PATH. The symlink chain has to be walked instead.
#
# This is resolve_path's loop with its diagnostics taken out, and it is
# the one part of install.sh this file may not borrow: install.sh cannot
# be sourced until its path is known, and its path is what this computes.
# Everything after these lines is borrowed rather than copied.
#
# The 40-hop cap is the kernel's own ELOOP limit, and it is what stops a
# symlink cycle from hanging a command whose entire job is to answer a
# question.
#
# The three refusals below print for themselves rather than through die,
# because die belongs to install.sh and install.sh is what has not been
# reached yet.
wd40_self=$0
wd40_hops=0
while [ -L "$wd40_self" ] && [ "$wd40_hops" -lt 40 ]; do
  wd40_link=$(readlink "$wd40_self")
  case $wd40_link in
    /*) wd40_self=$wd40_link ;;
    *)  wd40_self=$(dirname "$wd40_self")/$wd40_link ;;
  esac
  wd40_hops=$((wd40_hops + 1))
done

if [ -L "$wd40_self" ]; then
  printf 'Error: cannot find this repository: %s is a symlink cycle\n' "$0" >&2
  exit 1
fi

WD40_REPO=$(cd "$(dirname "$wd40_self")/.." && pwd -P) || {
  printf 'Error: cannot find this repository from %s\n' "$0" >&2
  exit 1
}

WD40_INSTALL="$WD40_REPO/install.sh"
if [ ! -f "$WD40_INSTALL" ]; then
  printf 'Error: %s is missing, so this is not a wd40 checkout\n' "$WD40_INSTALL" >&2
  exit 1
fi

# WHAT SOURCING install.sh BRINGS WITH IT
#
# install.sh already owns the discovery functions, the two naming rules,
# the ownership test and the BIN_DIR/SHELL_DIR precedence, and it is
# already built to be sourced - WD40_SOURCE_ONLY exists for exactly this.
# Two copies of "what does this repository install, and where does it
# land" is the drift the whole of this effort has been about, so this file
# borrows and does not copy.
#
# What comes with it was checked rather than assumed:
#
#   * `set -eu` runs at source time and is inherited. This file sets both
#     itself anyway, so that it reads correctly on its own.
#   * REPO_ROOT is computed from `dirname "$0"`, and $0 is still this
#     file - so through the installed symlink REPO_ROOT names
#     ~/.local/sbin, and through a direct call it names scripts/. It is
#     wrong both ways and is never read: every discovery function takes
#     its root as an argument, and WD40_REPO is the argument given.
#   * BIN_DIR and SHELL_DIR are assigned at source time, by the same
#     precedence an install would use. That is the point of borrowing
#     them: "installed" has to mean the directory install.sh would have
#     used, or the answer is about somewhere nobody asked about. They
#     expand to nothing when HOME is unset and the environment variable is
#     not set, which is said out loud below rather than guessed at.
#   * There are no traps to inherit. install.sh sets none.
#   * The positional parameters are inherited by the sourced file, and the
#     WD40_SOURCE_ONLY guard is what stops it running an install with
#     them.
#
# Every function defined here is prefixed wd40_, because a sourced file is
# a shared namespace: install.sh defines usage, main, warn and die, and an
# unprefixed usage() written here would be silently replaced by
# install.sh's on the next line.
WD40_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$WD40_INSTALL"

# The directories an install would use, spelled as install.sh spells them.
#
# Taken from install.sh's own two variables rather than worked out again,
# so that `wd40 list` cannot come to disagree with the installer about
# where a command belongs. Stripping the trailing slashes is the one part
# install.sh does in main() rather than at the top of the file, so it is
# the one part repeated here - and repeated by calling install.sh's
# function, not by writing a second one.
WD40_BIN=$(strip_trailing_slashes "$BIN_DIR")
WD40_SHELL=$(strip_trailing_slashes "$SHELL_DIR")

# A literal tab, which is what separates the fields of a record below.
#
# A tab rather than a `|` or a `:`, because a description is prose written
# by whoever wrote the command and may hold either of those; and built
# with a command substitution without ceremony, because a tab - unlike the
# newline detect_newline_names has to build around - survives one.
WD40_TAB=$(printf '\t')

# One line per command, as KIND, NAME, MARK and DESCRIPTION.
#
# A variable rather than a temporary file, so there is no scratch
# directory to create and no trap to remove it. The list is four lines
# long today and would have to reach thousands before the difference was
# measurable.
WD40_RECORDS=''

wd40_usage() {
  cat <<'USAGE'
Usage: wd40 <command>

  list                list every command this repository provides
  help, -h, --help    show this help

list describes this repository and not this machine: the commands are
read from the repository's own files, so the answer is the same wherever
it is read from. Whether each one is installed does depend on the
machine, and a command whose symlink is missing is marked with a leading
`!` and the directory it is missing from.

Script directory precedence: $WD40_BIN_DIR > ~/.local/sbin
Shell directory precedence:  $WD40_SHELL_DIR > ~/.zsh_aliases.d
USAGE
}

# Refuse an argument to a command that takes none.
#
# `wd40 list --json` asks for something this program does not do, and
# passing the word over would leave it looking as though it had. That is
# install.sh's rule about an unknown flag, applied one level down.
#
# The command is named as the user spelled it, so that somebody who typed
# `-h` is not answered about `help`.
wd40_no_args() {
  # wd40_no_args COMMAND [ARG...]
  local cmd=$1
  shift
  if [ $# -eq 0 ]; then
    return 0
  fi
  wd40_usage >&2
  die "wd40 $cmd takes no arguments (got '$1')" 1
}

# Print FILE's declarations, one per line, as ok<TAB>NAME<TAB>DESCRIPTION,
# or as bad<TAB>LINE<TAB>TEXT for a header line that opens `wd40:` and is
# not a declaration.
#
# WHY ONLY THE HEADER
#
# The header is the run of blank and comment lines at the top of the file,
# and it ends at the first line of code. That rule is what makes a
# declaration-shaped string somewhere further down - `printf 'wd40: fake -
# not a command\n'` - impossible to mistake for a declaration, without
# this file having to know how to read shell. A line holding a quoted
# string is code, so the header ended at or before it.
#
# The alternative was the scanner test/smoke.sh's portability guard has to
# carry, which follows quotes, escapes and here-documents for eighty
# lines. That one has no choice: it is looking for constructs that appear
# anywhere in a file. This is looking for a declaration, and a declaration
# belongs in the header, so the cheaper rule is also the more accurate
# one.
#
# WHY A `bad` RECORD RATHER THAN A DIAGNOSTIC FROM awk
#
# So that every sentence the user reads comes out of the shell, through
# warn and die, in one voice and one format. awk reports where the
# trouble is; it does not get to phrase it.
wd40_declaration_lines() {
  # wd40_declaration_lines FILE
  awk '
    $0 ~ /^[[:space:]]*$/ { next }
    $0 !~ /^[[:space:]]*#/ { exit }
    {
      body = $0
      sub(/^[[:space:]]*#+[[:space:]]*/, "", body)
      if (body !~ /^wd40:/) next
      sub(/^wd40:[[:space:]]*/, "", body)
      sub(/[[:space:]]+$/, "", body)

      # A name, a hyphen with space on both sides, and at least one
      # character of description. The hyphen has to be a word of its own
      # or smem-groups could not be named; and only the first one is a
      # separator, so a description may hold as many more as it likes.
      if (!match(body, /^[^[:space:]]+[[:space:]]+-[[:space:]]+[^[:space:]]/)) {
        print "bad\t" NR "\t" $0
        next
      }
      match(body, /^[^[:space:]]+/)
      name = substr(body, 1, RLENGTH)
      sub(/^[^[:space:]]+[[:space:]]+-[[:space:]]+/, "", body)
      gsub(/\t/, " ", body)
      print "ok\t" name "\t" body
    }
  ' "$1"
}

# Is DEST a link this repository put there?
#
# Prints 1 for yes, 0 for no, and ? for a question that could not be
# asked because there is no directory to ask it about.
#
# Ownership is resolution-based, exactly as it is in install_one and
# remove_one: a name is not evidence. Somebody's own `smem-groups` on
# their PATH is not this repository's install, and reporting it as one
# would answer "did the install take?" with a confident yes for a
# machine where nothing had happened.
#
# resolve_path says on stderr when it cannot resolve a link, and that
# line is left to reach the user. A link that dangles - a repository
# moved after installing - is worth a sentence, and it can only appear
# for a destination that is about to be marked `!` anyway.
wd40_install_mark() {
  # wd40_install_mark DIR DEST
  local dir=$1 dest=$2 target
  if [ -z "$dir" ]; then
    printf '?\n'
    return 0
  fi
  if [ ! -L "$dest" ]; then
    printf '0\n'
    return 0
  fi
  if target=$(resolve_path "$dest"); then
    case $target in
      "$WD40_REPO"/*) printf '1\n'; return 0 ;;
    esac
  fi
  printf '0\n'
}

# Turn one installable file into one record per command it declares.
#
# THE TWO REFUSALS
#
# A file that declares nothing, and a script that declares a name
# install.sh would not give it, are both defects in this repository rather
# than problems with the user's machine - so they are refused loudly here,
# in the same shape and for the same reason install.sh refuses two scripts
# claiming one command name. The alternative is a command that exists and
# is not listed, or a listing that names a command nobody can run, and
# both of those are the silent drift this convention was written to stop.
#
# The name check is a string comparison and belongs here, where it costs
# nothing. Its other half - that a declared shell function is really
# defined - needs the file sourced, and `wd40 list` may not source a
# user's shell files to answer a question about them; test/smoke.sh owns
# that half.
#
# A script gets one command and no more, because a script is installed
# under exactly one name and a second declaration could only be fiction.
# A shell file has no such limit: wd40-paths.sh is two commands, which is
# the whole reason this lists commands rather than files.
wd40_collect() {
  # wd40_collect KIND FILE LINKNAME DIR
  local kind=$1 file=$2 linkname=$3 dir=$4
  local what first rest declared=0 mark

  # Process substitution, not a pipe: a pipeline's `while read` body runs
  # in a subshell in bash 3.2, and a die in there would take the subshell
  # and leave the run reporting a repository with fewer commands in it.
  # That is resolve_path's old defect in a different costume.
  while IFS="$WD40_TAB" read -r what first rest; do
    [ -n "$what" ] || continue

    if [ "$what" = bad ]; then
      warn "$file, line $first, opens 'wd40:' and is not a declaration:"
      warn "  $rest"
      die "a declaration reads: wd40: NAME - DESCRIPTION" 1
    fi

    declared=$((declared + 1))

    if [ "$kind" = scripts ]; then
      if [ "$declared" -gt 1 ]; then
        die "$file declares more than one command, but a script is installed under one name" 1
      fi
      if [ "$first" != "$linkname" ]; then
        die "$file declares '$first', but install.sh installs it as '$linkname'" 1
      fi
    fi

    mark=$(wd40_install_mark "$dir" "$dir/$linkname")
    WD40_RECORDS="$WD40_RECORDS$kind$WD40_TAB$first$WD40_TAB$mark$WD40_TAB$rest
"
  done < <(wd40_declaration_lines "$file")

  if [ "$declared" -eq 0 ]; then
    die "$file declares no command; add a header line reading: wd40: NAME - DESCRIPTION" 1
  fi
}

# Print every command, grouped by kind, aligned, and marked.
#
# The mark is `!` in the first of the two columns the names are indented
# by, so an installed line is exactly the line it would have been without
# any of this and a missing one is greppable: `wd40 list | grep '^!'`. It
# is the same `!` warn opens every diagnostic in this repository with, and
# it is a character rather than a colour because this output is read down
# a pipe at least as often as on a terminal.
#
# The legend appears only when something is missing, and it names the
# directory, because "not installed" without a "where" is half an answer
# on a machine where WD40_BIN_DIR is set to somewhere unexpected. It goes
# to stdout with the marks it explains: on stderr it would be lost from
# `wd40 list > commands.txt`, leaving a file full of marks and no key.
#
# One column width across both groups rather than one per group, so the
# descriptions line up down the whole output and not just within a
# paragraph of it.
#
# Nothing here is a failure. A checkout that has never been installed is
# an ordinary thing to be standing in, and `wd40 list` reports it and
# exits 0.
wd40_format() {
  awk -v bindir="$WD40_BIN" -v shelldir="$WD40_SHELL" '
    BEGIN { FS = "\t" }
    {
      kind[NR] = $1; name[NR] = $2; mark[NR] = $3; desc[NR] = $4
      if (length($2) > width) width = length($2)
      last = NR
    }
    END {
      label["scripts"] = "scripts"
      label["shell"]   = "shell functions"
      dir["scripts"]   = bindir
      dir["shell"]     = shelldir
      split("scripts shell", order, " ")

      printed = 0
      for (g = 1; g <= 2; g++) {
        k = order[g]
        any = 0
        for (i = 1; i <= last; i++) if (kind[i] == k) { any = 1; break }
        if (!any) continue

        if (printed) print ""
        printed = 1
        print label[k]

        for (i = 1; i <= last; i++) {
          if (kind[i] != k) continue
          printf "%s%-*s   %s\n", (mark[i] == "0" ? "! " : "  "), width, name[i], desc[i]
          if (mark[i] == "0") missing[k] = 1
        }
      }

      legend = 1
      for (g = 1; g <= 2; g++) {
        k = order[g]
        if (!(k in missing)) continue
        if (legend) { print ""; legend = 0 }
        printf "! not installed in %s\n", dir[k]
      }
    }
  '
}

wd40_list() {
  wd40_no_args list "$@"

  local f

  while IFS= read -r f; do
    wd40_collect scripts "$f" "$(link_name_for "$f")" "$WD40_BIN"
  done < <(discover_scripts "$WD40_REPO")

  while IFS= read -r f; do
    wd40_collect shell "$f" "$(shell_link_name_for "$f")" "$WD40_SHELL"
  done < <(discover_shell_files "$WD40_REPO")

  # Discovery finding nothing means the repository was not found, because
  # this file is itself one of the things it looks for. Saying so beats
  # printing an empty list, which reads like a repository that provides
  # nothing.
  if [ -z "$WD40_RECORDS" ]; then
    die "no installable files under $WD40_REPO" 1
  fi

  # Said before the list rather than after it, as install.sh says what it
  # ignored before it says what it linked: a caveat is read before the
  # thing it qualifies or it is not a caveat.
  #
  # An empty directory has one cause and one only - no environment
  # variable and no HOME for the default to expand against - so the
  # sentence can name it exactly. "I could not look" and "there is nothing
  # there" are different claims, and marking these `!` would be the second
  # one made on the evidence for neither.
  if [ -z "$WD40_BIN" ]; then
    warn "HOME is not set and neither is WD40_BIN_DIR, so I cannot tell whether"
    warn "the scripts below are installed."
  fi
  if [ -z "$WD40_SHELL" ] && [ -n "$(discover_shell_files "$WD40_REPO")" ]; then
    warn "HOME is not set and neither is WD40_SHELL_DIR, so I cannot tell whether"
    warn "the shell functions below are installed."
  fi

  printf '%s' "$WD40_RECORDS" | wd40_format
}

# A bare `wd40` is answered before the case below, so that `wd40 ''` is
# not. An empty argument is something the user typed, and a mistake
# somebody can see in what they typed gets a mistake's answer - which is
# the distinction install.sh draws between `--dir=` and a default with no
# HOME to expand.
if [ $# -eq 0 ]; then
  wd40_usage
  exit 0
fi

wd40_command=$1
shift

case $wd40_command in
  list)
    wd40_list "$@" ;;
  help|-h|--help)
    wd40_no_args "$wd40_command" "$@"
    wd40_usage ;;
  *)
    wd40_usage >&2
    die "unknown argument '$wd40_command'" 1 ;;
esac
