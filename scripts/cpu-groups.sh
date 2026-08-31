#!/bin/bash
#
# cpu-groups.sh - list top CPU-consuming processes grouped by root ancestor.
#
# wd40: cpu-groups - list top CPU consumers grouped by their root ancestor process
#
# `ps`/`top` show one line per process, which turns one build job into
# dozens of unrelated-looking `java`/`javac`/`ninja` lines. This script
# takes the top N processes by %CPU, walks each one's parent chain up to
# its root ancestor (PID 1 by default, or a shallower stop via --depth),
# and groups by that root - so "docker run ... build" shows up as one
# group with 47 member PIDs instead of 47 separate lines.
#
# Usage:
#   ./cpu-groups.sh                  # top 10 groups, all users
#   ./cpu-groups.sh -n 20            # top 20 groups
#   ./cpu-groups.sh -u jfujiok       # only this user's processes
#   ./cpu-groups.sh -d 3             # stop climbing after 3 hops
#   ./cpu-groups.sh -s mem           # sort groups by %MEM instead of %CPU
#
# Exit codes: 1 = invalid argument.

set -euo pipefail

TOP_N=10
FILTER_USER=""
MAX_DEPTH=""
SORT_SPEC="cpu"

usage() {
  cat <<'USAGE'
Usage: cpu-groups.sh [options]

  -n N             Top N groups to show (default: 10)
  -u USER          Only this user's processes (default: all users)
  -d, --depth N    Max hops to climb toward the root ancestor
                   (default: unlimited, i.e. climb to PID 1)
  -s, --sort SPEC  Sort key: cpu, mem, name (default: cpu)
  -h               Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n)
      [ $# -ge 2 ] || { echo "Error: -n requires an argument" >&2; exit 1; }
      case "$2" in
        ''|*[!0-9]*)
          echo "Error: -n requires a positive integer (got '$2')" >&2
          exit 1 ;;
      esac
      TOP_N="$2"; shift 2 ;;
    -u)
      [ $# -ge 2 ] || { echo "Error: -u requires an argument" >&2; exit 1; }
      FILTER_USER="$2"; shift 2 ;;
    -d|--depth)
      [ $# -ge 2 ] || { echo "Error: $1 requires an argument" >&2; exit 1; }
      case "$2" in
        ''|*[!0-9]*)
          echo "Error: $1 requires a positive integer (got '$2')" >&2
          exit 1 ;;
      esac
      MAX_DEPTH="$2"; shift 2 ;;
    -s|--sort)
      [ $# -ge 2 ] || { echo "Error: $1 requires an argument" >&2; exit 1; }
      SORT_SPEC="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage >&2
      exit 1 ;;
  esac
done

case "$SORT_SPEC" in
  cpu|mem|name) ;;
  *)
    echo "Error: unknown sort key '$SORT_SPEC'. Valid keys: cpu, mem, name" >&2
    exit 1 ;;
esac

# WHY -e VS -A: GNU ps (Linux) accepts -e for "every process". BSD ps
# (macOS/Darwin) does not recognize -e and requires -A instead. Both accept
# the same -o field-list syntax, so detecting the right "all processes"
# flag is the only branch needed - same portability shape as
# smem-groups.sh's -U passthrough, but decided once here instead of at
# every call site.
ps_all_flag() {
  if ps -e >/dev/null 2>&1; then
    printf '%s\n' "-e"
  else
    printf '%s\n' "-A"
  fi
}

# Prints "PID PPID PCPU PMEM COMM ARGS" - one line per process, snapshotted
# once. COMM and ARGS are always the last two fields (in that order) so a
# downstream `awk '{print $1,$2,$3,$4,$5}'`-style split on 5 fields captures
# the whole remainder of the line as field 5, without needing to guess how
# many words the command line itself contains.
ps_snapshot() {
  all_flag="$(ps_all_flag)"
  if [ -n "$FILTER_USER" ]; then
    ps "$all_flag" -o pid=,ppid=,pcpu=,pmem=,comm=,args= -U "$FILTER_USER"
  else
    ps "$all_flag" -o pid=,ppid=,pcpu=,pmem=,comm=,args=
  fi
}
