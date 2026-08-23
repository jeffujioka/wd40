#!/usr/bin/env bash
#
# install.sh - symlink wd40 scripts into a directory on your PATH.
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

# Resolve a path to an absolute, symlink-free location.
#
# `readlink -f` and `realpath` are GNU extensions absent from stock macOS,
# so the chain is walked by hand with flagless `readlink`. The 40-hop cap
# matches the kernel's own ELOOP limit and stops a symlink cycle from
# hanging the installer.
#
# The final component is not required to exist; its parent directory is.
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

  dir=$(dirname "$target")
  base=$(basename "$target")
  [ -d "$dir" ] || die "cannot resolve '$1': '$dir' is not a directory"
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

# Print every link name claimed by more than one installable script.
#
# Two scripts landing on the same name is a defect in this repository, not
# a user problem, so the caller fails loudly rather than picking a winner.
# prune.sh and prune.ps1 never reach here together: the allowlist already
# dropped the .ps1, which is exactly how a cross-platform pair is meant to
# behave.
detect_collisions() {
  local root=${1:-$REPO_ROOT} f
  discover_scripts "$root" | while IFS= read -r f; do
    link_name_for "$f"
  done | LC_ALL=C sort | uniq -d
}

BIN_DIR=${WD40_BIN_DIR:-$HOME/.local/sbin}
DRY_RUN=0
FORCE=0
MODE=install

# Link one script. Returns 1 when the destination was left untouched.
#
# Ownership is decided by resolving the existing symlink, never by its
# name: a user's unrelated `smem-groups` on their PATH must survive.
install_one() {
  local src=$1 dest=$2 current

  if [ -L "$dest" ]; then
    current=$(resolve_path "$dest")
    case $current in
      "$REPO_ROOT"/*)
        : ;;  # ours already - replacing it is what makes re-runs idempotent
      *)
        if [ "$FORCE" != "1" ]; then
          warn "skipping $(basename "$dest"): symlink points outside this repo ($current)"
          warn "  use --force to replace it"
          return 1
        fi ;;
    esac
  elif [ -e "$dest" ]; then
    if [ "$FORCE" != "1" ]; then
      warn "skipping $(basename "$dest"): a regular file is already there"
      warn "  use --force to replace it"
      return 1
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '   link %s -> %s\n' "$dest" "$src"
    return 0
  fi

  chmod +x "$src"
  # Not `ln -sfn`: BSD and GNU disagree on what -n means. Removing first
  # and creating fresh behaves identically everywhere.
  rm -f "$dest"
  ln -s "$src" "$dest"
  printf '   link %s -> %s\n' "$dest" "$src"
  return 0
}

do_install() {
  local dupes f name linked=0

  dupes=$(detect_collisions)
  if [ -n "$dupes" ]; then
    warn "two scripts claim the same command name:"
    printf '%s\n' "$dupes" >&2
    die "rename one of them; refusing to guess" 1
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf 'Dry run. Nothing will be changed.\n'
  else
    mkdir -p "$BIN_DIR"
  fi

  # Process substitution, not a pipe: in bash 3.2 a piped `while read` body
  # runs in a subshell and `linked` would always come back 0.
  while IFS= read -r f; do
    name=$(link_name_for "$f")
    if install_one "$f" "$BIN_DIR/$name"; then
      linked=$((linked + 1))
    fi
  done < <(discover_scripts)

  [ "$linked" -gt 0 ]
}

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

  -d, --dir DIR    directory to place symlinks in (default: ~/.local/sbin)
  -n, --dry-run    print what would happen; change nothing
  -f, --force      overwrite existing files that are not ours
  -u, --uninstall  remove this repository's symlinks
  -h, --help       show this help

Directory precedence: --dir > $WD40_BIN_DIR > ~/.local/sbin
USAGE
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      -d|--dir)
        [ $# -ge 2 ] || die "$1 requires an argument" 1
        BIN_DIR=$2; shift 2 ;;
      --dir=*)      BIN_DIR=${1#--dir=}; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -f|--force)   FORCE=1; shift ;;
      -u|--uninstall) MODE=uninstall; shift ;;
      -h|--help)    usage; return 0 ;;
      *) usage >&2; die "unknown argument '$1'" 1 ;;
    esac
  done

  if [ "$MODE" = "install" ]; then
    if do_install; then
      return 0
    else
      warn "nothing was installed"
      return 2
    fi
  fi
}

# Sourced by test/smoke.sh with WD40_SOURCE_ONLY=1 to unit-test individual
# functions. Without this guard, sourcing would run a real install.
if [ "${WD40_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
