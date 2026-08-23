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
      -h|--help) usage; return 0 ;;
      *) usage >&2; die "unknown argument '$1'" 1 ;;
    esac
  done
  return 0
}

# Sourced by test/smoke.sh with WD40_SOURCE_ONLY=1 to unit-test individual
# functions. Without this guard, sourcing would run a real install.
if [ "${WD40_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
