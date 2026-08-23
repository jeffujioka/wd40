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
