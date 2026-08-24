#!/usr/bin/env bash
#
# wd40-paths.sh - fp, for use at an interactive prompt.
#
# wd40: fp - print the absolute path of a file or directory, and copy it to the clipboard
# wd40: fpr - fp --relative, for a path relative to the current directory
# wd40: fpn - fp --no-clipboard, for a path that is printed and not copied
# wd40: fpnr - fp --no-clipboard --relative, for both at once
#
# This file is sourced into a live shell and is never executed. The
# shebang is here anyway: install.sh sets the executable bit (the author's
# loader sources a file only when it is executable), and the line is what
# tells editors and shellcheck which language they are looking at.
#
# Nothing here changes a shell option - no `set -e`, no `set -u`, no
# `set -o pipefail`, no `setopt`, no `shopt`. Those settings would leak
# into the caller's interactive shell, where a typo at the prompt would
# then be fatal.
#
# Targets bash 3.2 (stock macOS) and zsh, and must behave identically in
# both. So every expansion is quoted - bash word-splits an unquoted one
# and zsh does not - and nothing below uses arrays, [[ ]], ${var,,},
# ${=var}, declare, $FUNCNAME, or $funcstack. `echo` is avoided too: the
# shells disagree about backslashes, and a path may legitimately hold one.
#
# Every variable is `local`, and every one is also prefixed `_wd40_`. The
# prefix is not decoration: zsh ties some plain names to shell state, and
# `local path` there rebinds $PATH for the whole function, so the next
# external command is not found. `status`, `cdpath`, and `fpath` are the
# same trap. A prefix sidesteps the entire class of them, now and for
# whatever zsh makes special next. A sourced file that damages the shell
# it lands in is a bug in the sourced file.
#
# WHY THE THREE SHORTHANDS ARE FUNCTIONS AND NOT ALIASES
#
# An alias is the obvious spelling and it cannot keep the claim above.
# bash expands aliases only when `expand_aliases` is on, which it is in an
# interactive shell and is not in any other: `bash -c '. this; fpr .'`
# answers `fpr: command not found`, and `command -v fpr` answers nothing
# at all. zsh expands them everywhere. So an alias behaves differently in
# the two shells by construction - and it would also be invisible to
# test/smoke.sh, which checks that every name declared above is really
# defined by sourcing this file from a non-interactive bash. The obvious
# repair, `shopt -s expand_aliases`, is itself a bash-only builtin and is
# on the list of constructs that suite refuses.
#
# A function costs the same line and has none of that. It also composes:
# `fpr --no-clipboard x` reaches fp as `--relative --no-clipboard x`,
# which is what somebody typing it meant.

# Print the usage text.
#
# One command means one usage text, and the name is written out rather
# than handed in: $FUNCNAME is bash-only and $funcstack is zsh-only, so a
# literal is the only spelling that works in both. The three shorthands
# are functions that call fp, so a user who typed `fpr --help` is reading
# about the command that is actually running - which is why they are
# listed here rather than answered separately.
#
# The options are listed because --help is the only place anybody looks
# for them, `-h` included, even though decades of habit would find it
# whether it was written down or not.
#
# Nothing else is listed, because nothing else is an option: every other
# argument is a path, which is the rule stated at fp and the reason a file
# named -x is still reachable.
_wd40_usage() {
  printf 'usage: fp [OPTIONS] [--] [PATH]\n'
  printf 'Print the absolute path of PATH (default: the current directory) and\n'
  printf 'copy it to the system clipboard.\n'
  printf 'The path is joined as text: it is not resolved and need not exist.\n'
  printf '\n'
  printf 'Options:\n'
  printf '      --relative      print the path relative to the current directory\n'
  printf '      --no-clipboard  print the path and leave the clipboard alone\n'
  printf '      --              end the options; the next word is a path\n'
  printf '  -h, --help          show this help\n'
  printf '\n'
  printf 'Shorthands:\n'
  printf '  fpr    fp --relative\n'
  printf '  fpn    fp --no-clipboard\n'
  printf '  fpnr   fp --no-clipboard --relative\n'
}

# Choose the system clipboard command, run it on this function's stdin,
# and say if it failed.
#
# pbcopy is probed first because it is macOS's native command and also the
# conventional name for a hand-rolled shim on Linux - the author's own
# forwards over SSH. Preferring it means somebody who has already solved
# their clipboard problem keeps their solution. xclip and xsel are given
# explicit selection flags because both default to PRIMARY and every
# caller here means CLIPBOARD.
#
# The cascade runs on every call rather than being resolved once when this
# file is sourced, so a shell that outlives a change in its environment -
# an SSH session starting, Wayland replacing X11 - notices.
#
# $WD40_CLIP holds a command name, not a command line, and is invoked
# quoted. Splitting it into words would need `eval` or ${=var}, and the
# two shells disagree about unquoted expansions, so the portable choices
# were a shell-specific branch or a documented restriction; anyone needing
# arguments points WD40_CLIP at a two-line wrapper script. When it names
# something that is not a command, that is an error and not a reason to
# fall through to the cascade - the user said what they wanted.
#
# Every way of failing says so, and the status is read in one place, after
# one call, which is what makes a command that was found and then failed
# exactly as loud as one that was never there - and that case is not the
# exotic one: a pbcopy shim forwarding to a listener that is not running is
# the likeliest failure of the five, and it used to be the only silent
# one.
_wd40_clip() {
  local _wd40_status

  # ${WD40_CLIP:-} rather than $WD40_CLIP: the caller's shell may run with
  # `set -u` of its own, and this file must not be what trips it.
  if [ -n "${WD40_CLIP:-}" ]; then
    if command -v "$WD40_CLIP" >/dev/null 2>&1; then
      set -- "$WD40_CLIP"
    else
      printf 'wd40: WD40_CLIP names "%s", which is not a command\n' "$WD40_CLIP" >&2
      return 1
    fi
  elif command -v pbcopy >/dev/null 2>&1; then
    set -- pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then
    set -- wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    set -- xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    set -- xsel --clipboard --input
  else
    printf 'wd40: no clipboard command found (tried pbcopy, wl-copy, xclip, xsel)\n' >&2
    printf 'wd40: set WD40_CLIP to the name of a command that reads stdin\n' >&2
    return 1
  fi

  "$@"
  _wd40_status=$?

  if [ "$_wd40_status" -ne 0 ]; then
    printf 'wd40: %s failed (exit %s); nothing was copied\n' "$1" "$_wd40_status" >&2
  fi
  return "$_wd40_status"
}

# Print PATH joined onto $PWD, and put it on the clipboard.
#
# WHAT IS NEVER DONE TO THE RESULT
#
# It is never validated: existence is not checked, `..` is not collapsed,
# symlinks are not resolved. The common use is handing a path to another
# person or another machine, where a build output that does not exist yet
# is a perfectly good argument, and where the symlinked path the caller is
# standing in is usually the answer they wanted. Resolution answers a
# different question, and `realpath` and `readlink -f` are GNU extensions
# that stock macOS does not ship.
#
# `.` and one leading `./` are the exception, and they strip noise rather
# than resolve anything: they are how a shell spells "right here", and
# $PWD/./foo is nobody's intent. A leading `../` is left alone, because
# $PWD/../foo still reaches the right file and collapsing it would mean
# knowing whether $PWD crosses a symlink. A trailing slash the caller
# typed survives for the same reason - it is how one says "this had better
# be a directory", and dropping it would be normalisation.
#
# THE STREAM CONTRACT
#
# The path goes to stdout, always, whether it was copied or not. The
# alternative was the one this file used to have, where the printing
# command wrote to stdout and the copying command wrote a receipt to
# stderr - defensible while they were two commands, and a trap now that
# they are one: `fp foo > file` and `fpn foo > file` would capture
# different things, and the difference would be a flag that leaves no mark
# on the output. One command, one stream. Seeing the path on the terminal
# is the receipt.
#
# The clipboard gets the same path with no trailing newline. A path with a
# newline on the end, pasted at a shell prompt, runs immediately, and the
# clipboard is a hand-off to a consumer we know nothing about. stdout
# keeps its newline because this is a filter and behaves like one.
#
# A clipboard that fails does not cost the caller the path: it is printed
# first, and the failure leaves through the exit status with _wd40_clip's
# own diagnostic on stderr. Nothing is printed about it here - _wd40_clip
# has already named the command and its exit status on all of its failure
# paths, and a second voice saying the same thing less precisely is one
# that eventually drifts.
#
# THE OPTIONS, AND WHY THE LIST IS CLOSED
#
# --relative, --no-clipboard, -h, --help and `--`. Everything else is a
# path, even when it starts with `-`, because a file named -x is rarer
# than a bug in flag parsing but not rare enough to make unreachable. A
# closed list of five words is a rule a reader can hold, and "everything
# else" is what keeps the rest of the filesystem addressable - with `--`
# as the door back to the five names the list itself just took away.
#
# A repeated flag is the same flag: the parse sets a variable rather than
# counting, so `--relative --relative` and `--relative` cannot be told
# apart. That is not indifference. The shorthands below are functions that
# prepend a flag, so `fpnr --no-clipboard` reaches here as
# `--no-clipboard --relative --no-clipboard` - a repetition the user did
# not write and cannot see. Refusing it would be an error message naming a
# word that is not on their command line.
#
# More than one path is refused rather than guessed at: a multi-argument
# form is plausible but speculative, and accepting one now would make
# removing it a breaking change.
#
# Usage that was asked for goes to stdout; usage provoked by a bad
# argument goes to stderr, where it cannot be mistaken for a result.
fp() {
  local _wd40_rel=0 _wd40_copy=1 _wd40_end=0 _wd40_have=0
  local _wd40_arg _wd40_path='' _wd40_base _wd40_abs _wd40_out

  while [ "$#" -gt 0 ]; do
    _wd40_arg="$1"

    # Skipped once `--` has been seen, which is the whole of what `--`
    # does: after it, the five names below are ordinary words again.
    if [ "$_wd40_end" -eq 0 ]; then
      case "$_wd40_arg" in
        -h|--help)      _wd40_usage; return 0 ;;
        --relative)     _wd40_rel=1;  shift; continue ;;
        --no-clipboard) _wd40_copy=0; shift; continue ;;
        --)             _wd40_end=1;  shift; continue ;;
      esac
    fi

    if [ "$_wd40_have" -eq 1 ]; then
      printf 'fp: too many arguments (expected at most one path)\n' >&2
      _wd40_usage >&2
      return 2
    fi

    # The empty string is not a path and is not "no path": it is a
    # variable that was meant to hold one and did not, which is the
    # likeliest way to arrive here by accident. `_wd40_have` is what keeps
    # the two apart, since the value it records is indistinguishable from
    # the initial one.
    if [ -z "$_wd40_arg" ]; then
      _wd40_usage >&2
      return 2
    fi

    _wd40_path="$_wd40_arg"
    _wd40_have=1
    shift
  done

  # $PWD is `/` only at the filesystem root, and there it already ends in
  # the separator: the usual `$PWD/$path` would spell `//foo`, and a path
  # beginning with exactly two slashes is left implementation-defined by
  # POSIX. A root $PWD therefore contributes no separator of its own.
  #
  # This is also the prefix --relative strips, which is why it is worked
  # out once here rather than twice below.
  _wd40_base="$PWD"
  case "$_wd40_base" in
    /) _wd40_base='' ;;
  esac

  if [ "$_wd40_have" -eq 0 ]; then
    _wd40_abs="$PWD"
  else
    case "$_wd40_path" in
      /*) _wd40_abs="$_wd40_path" ;;
      *)
        # `.` has no trailing slash to consume, so it needs its own arm;
        # both arms leave the empty string, which is the "right here" case
        # just below.
        case "$_wd40_path" in
          .)   _wd40_path='' ;;
          ./*) _wd40_path="${_wd40_path#./}" ;;
        esac

        if [ -z "$_wd40_path" ]; then
          _wd40_abs="$PWD"
        else
          _wd40_abs="$_wd40_base/$_wd40_path"
        fi
        ;;
    esac
  fi

  _wd40_out="$_wd40_abs"

  # --relative takes the current directory off the front, and does nothing
  # else. It is a text operation on the answer already computed, so it
  # inherits every promise above: nothing is resolved, and the result
  # names the same file the absolute form does.
  #
  # A target that is not under $PWD keeps its absolute spelling rather
  # than growing a `../../` walk. Such a walk is the only version of this
  # flag that appears to work in every case, and it is the only one that
  # can be *wrong*: it is correct only once `..` has been collapsed and
  # symlinks resolved, and this file refuses to do either. Handing back a
  # relative path that does not reach the file is a worse answer than
  # handing back an absolute one that does.
  #
  # The prefix test is a `case` on "$_wd40_base"/*, not a substring test.
  # /home/user2/x begins with every character of /home/user and belongs to
  # somebody else; only a pattern that insists on the separator can tell
  # the two apart. The pattern is quoted so that a directory name holding
  # a glob character is matched as the text it is.
  #
  # $PWD itself is `.` rather than the empty string, because `.` is how a
  # shell spells "here" and the empty string is not a path at all. That
  # arm is first because $PWD does not match "$_wd40_base"/* - there is no
  # separator left to match - so without it the answer would stay
  # absolute.
  if [ "$_wd40_rel" -eq 1 ]; then
    if [ "$_wd40_abs" = "$PWD" ]; then
      _wd40_out='.'
    else
      case "$_wd40_abs" in
        "$_wd40_base"/*) _wd40_out="${_wd40_abs#"$_wd40_base"/}" ;;
      esac
    fi
  fi

  printf '%s\n' "$_wd40_out"

  [ "$_wd40_copy" -eq 1 ] || return 0

  printf '%s' "$_wd40_out" | _wd40_clip
  # $? after a pipeline is the exit status of its *last* command in both
  # bash and zsh. _wd40_clip is last, so the clipboard's verdict arrives
  # here intact without `set -o pipefail`, which this file must not touch.
  if [ "$?" -ne 0 ]; then
    return 1
  fi
  return 0
}

# The three shorthands, each prepending its flag and passing the rest
# through. "$@" and not $* : the caller's one argument is one argument
# however many spaces are in it.
fpr()  { fp --relative "$@"; }
fpn()  { fp --no-clipboard "$@"; }
fpnr() { fp --no-clipboard --relative "$@"; }
