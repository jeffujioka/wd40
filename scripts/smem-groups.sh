#!/bin/bash
#
# smem-groups.sh - aggregate `smem -tk` output by process group.
#
# `smem` lists one line per process, which is useless once you have 100+
# processes. This script sums Swap/USS/PSS/RSS per category (vscode-server,
# opencode, claude, shells, ...) and shows the footprint (PSS+Swap column).
#
# Remember: USS/PSS/RSS do NOT include what got swapped out. A process can
# show up with 5 MB of PSS and have 400 MB sitting on disk. That's what the
# PSS+SWAP column is for.
#
# Usage:
#   ./smem-groups.sh                       # runs `smem -tk` and aggregates
#   ./smem-groups.sh -f dump.txt           # aggregates a saved dump
#   ./smem-groups.sh -f -                  # reads from stdin
#   ./smem-groups.sh -u other_user         # passes -U through to smem
#   ./smem-groups.sh -s swap               # sort by swap instead of the default
#   ./smem-groups.sh --sort=rss,name       # sort by rss, ties broken by name
#
#   # capture on the server, analyze elsewhere:
#   ssh build-server 'smem -tk' > dump.txt && ./smem-groups.sh -f dump.txt
#
# To edit the categories, look for the CLASSIFICATION block inside the awk.
#
# Exit codes: 1 = invalid input/arguments, 2 = totals did not match smem's
# own totals line (parsing bug - see the self-check at the bottom).

set -euo pipefail

DUMP=""
SMEM_USER=""
SORT_SPEC="pss,swap"   # default: real RAM (PSS) first, swap breaks ties

usage() {
  cat <<'USAGE'
Usage: smem-groups.sh [options]

  -f FILE          Read smem output from FILE. Use "-" for stdin.
  -u USER          Pass -U USER through to smem (default: your own processes).
  -s, --sort SPEC  Comma-separated sort keys (default: pss,swap).
                   Valid keys: pss, rss, uss, swap, n, name
                   Numeric keys sort descending (heaviest first); name sorts
                   ascending (A-Z). Example: --sort=rss,name
  -h               Show this help.

Without -f, runs `smem -tk`.
USAGE
}

# Maps a lowercase sort key to "COLUMN:NUMERIC" for the group table printed
# below (1=name 2=n 3=swap 4=uss 5=pss 6=rss). Written as a case instead of
# an associative array on purpose: macOS ships bash 3.2 as /bin/bash, which
# predates `declare -A` (bash 4+). This keeps the script portable to both.
sort_col_for() {
  case "$1" in
    name) echo "1:0" ;;
    n)    echo "2:1" ;;
    swap) echo "3:1" ;;
    uss)  echo "4:1" ;;
    pss)  echo "5:1" ;;
    rss)  echo "6:1" ;;
    *)    return 1 ;;
  esac
}

# Turns "pss,swap" into a `sort -k5,5rn -k3,3rn` command line. Splitting on
# IFS=',' instead of bash4 string ops (${x,,} etc.) for the same 3.2 reason.
build_sort_cmd() {
  local spec="$1" key entry col numeric result="" old_ifs
  old_ifs="$IFS"
  IFS=','
  set -- $spec
  IFS="$old_ifs"

  for key in "$@"; do
    key="$(printf '%s' "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$key" ] || continue
    entry="$(sort_col_for "$key")" || {
      echo "Error: unknown sort key '$key'. Valid keys: pss, rss, uss, swap, n, name" >&2
      exit 1
    }
    col="${entry%%:*}"; numeric="${entry##*:}"
    if [ "$numeric" = "1" ]; then
      result="$result -k${col},${col}rn"
    else
      result="$result -k${col},${col}"
    fi
  done

  if [ -z "$result" ]; then
    echo "Error: -s/--sort requires at least one key (got '$spec')" >&2
    exit 1
  fi
  echo "sort$result"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f)
      [ $# -ge 2 ] || { echo "Error: -f requires an argument" >&2; exit 1; }
      DUMP="$2"; shift 2 ;;
    -u)
      [ $# -ge 2 ] || { echo "Error: -u requires an argument" >&2; exit 1; }
      SMEM_USER="$2"; shift 2 ;;
    -s|--sort)
      [ $# -ge 2 ] || { echo "Error: $1 requires an argument" >&2; exit 1; }
      SORT_SPEC="$2"; shift 2 ;;
    --sort=*)
      SORT_SPEC="${1#--sort=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage >&2; exit 1 ;;
  esac
done

SORT_CMD="$(build_sort_cmd "$SORT_SPEC")"

# --- where the input comes from -------------------------------------------
# No guessing from tty: with no tty (cron, docker, ssh without -t) the
# "does stdin have a pipe?" heuristic false-positives and the script reads
# an empty stdin instead of running smem.
if [ "$DUMP" = "-" ]; then
  INPUT_CMD=(cat)
elif [ -n "$DUMP" ]; then
  [ -f "$DUMP" ] || { echo "Error: file '$DUMP' not found" >&2; exit 1; }
  INPUT_CMD=(cat "$DUMP")
else
  command -v smem >/dev/null 2>&1 || {
    echo "Error: smem not found. Install it (apt install smem), or capture" >&2
    echo "       it on a host that has it and run: $0 -f dump.txt" >&2
    exit 1
  }
  if [ -n "$SMEM_USER" ]; then
    INPUT_CMD=(smem -tk -U "$SMEM_USER")
  else
    INPUT_CMD=(smem -tk)
  fi
fi

# --- aggregation ------------------------------------------------------------
# `smem -tk` columns: PID User Command Swap USS PSS RSS
# Command contains spaces, so the 4 numbers are always the last 4 fields.
"${INPUT_CMD[@]}" | awk -v SORTCMD="$SORT_CMD" '
function tokb(v,   n, u) {
  if (v == "0" || v == "")  return 0
  u = substr(v, length(v), 1)
  n = substr(v, 1, length(v) - 1) + 0
  if (u == "K") return n
  if (u == "M") return n * 1024
  if (u == "G") return n * 1024 * 1024
  return v + 0          # no suffix: smem without -k already returns kB
}

# Processes one already-assembled record (continuation lines already joined).
function emit(rec,   n, f, swap, uss, pss, rss, cmd, i, cat) {
  if (rec == "") return
  # Trimming both ends is mandatory: smem lines end with trailing whitespace,
  # and split() with an explicit regex produces a trailing empty field,
  # which shifts every column by one position.
  sub(/^[ \t]+/, "", rec)
  sub(/[ \t]+$/, "", rec)
  n = split(rec, f, /[ \t]+/)
  if (n < 7) return

  swap = tokb(f[n-3]); uss = tokb(f[n-2])
  pss  = tokb(f[n-1]); rss = tokb(f[n])

  cmd = ""
  for (i = 3; i <= n - 4; i++) cmd = cmd f[i] " "

  # --- CLASSIFICATION (edit here) ---------------------------------------
  # Order matters: the first matching rule wins.
  if      (cmd ~ /vscode-serve/)                        cat = "vscode-server"
  else if (cmd ~ /^opencode/)                           cat = "opencode"
  else if (cmd ~ /claude|\.local\/bin\/cl/)             cat = "claude"
  else if (cmd ~ /^zsh|^-?bash|^\/?(bin\/)?sh( |$)/)    cat = "shells"
  else if (cmd ~ /node |npm exec|mcp-remote/)           cat = "node-npm-mcp"
  else                                                  cat = "other"
  # ----------------------------------------------------------------------

  S[cat] += swap; U[cat] += uss; P[cat] += pss; R[cat] += rss; C[cat]++
  ts += swap; tu += uss; tp += pss; tr += rss; tc++
}

# Line of dashes: end of the process section.
# Do NOT use /^-{10,}/ here: mawk (Ubuntu default awk) ignores {n,m} interval
# expressions without -W repetitions, so the line would fall through to the
# continuation rule and get appended to the previous record, shifting every
# column over. Requiring the whole line to be dashes also avoids matching
# "-bash".
/^-+[ \t]*$/ { emit(buf); buf = ""; next }

# smem totals line (PID and Count are both numeric, 6 fields).
# Kept so we can check at the end whether our parsing agrees with smem.
$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF == 6 {
  emit(buf); buf = ""
  smem_n = $1
  smem_swap = tokb($3); smem_uss = tokb($4)
  smem_pss  = tokb($5); smem_rss = tokb($6)
  next
}

# Header line.
$1 == "PID" { emit(buf); buf = ""; next }

# Start of a new record: first field is a PID.
$1 ~ /^[0-9]+$/ { emit(buf); buf = $0; next }

# Anything else is the continuation of a command that had a newline in it
# (smem prints the raw command line). Without this, those processes vanish.
{ if (buf != "") buf = buf " " $0 }

END {
  emit(buf)

  if (tc == 0) {
    print "No process line recognized. Is the input really `smem -tk`?" > "/dev/stderr"
    exit 1
  }

  printf "%-16s %5s %10s %10s %10s %10s %12s %7s\n", \
    "GROUP", "N", "SWAP(MB)", "USS(MB)", "PSS(MB)", "RSS(MB)", "PSS+SWAP", "%PSS"
  print  "--------------------------------------------------------------------------------------"

  for (k in P)
    printf "%-16s %5d %10.1f %10.1f %10.1f %10.1f %12.1f %6.1f%%\n", \
      k, C[k], S[k]/1024, U[k]/1024, P[k]/1024, R[k]/1024, \
      (P[k]+S[k])/1024, 100*P[k]/tp | SORTCMD
  close(SORTCMD)

  print  "--------------------------------------------------------------------------------------"
  printf "%-16s %5d %10.1f %10.1f %10.1f %10.1f %12.1f %6.1f%%\n", \
    "TOTAL", tc, ts/1024, tu/1024, tp/1024, tr/1024, (tp+ts)/1024, 100

  printf "\n"
  printf "Footprint (PSS+Swap)     : %.2f GB  <- what you actually occupy\n", (tp+ts)/1048576
  printf "  resident (PSS)         : %.2f GB\n", tp/1048576
  printf "  swapped out            : %.2f GB\n", ts/1048576
  printf "RSS-PSS (double counting): %7.1f MB  <- the error from summing RSS\n", (tr-tp)/1024
  printf "PSS-USS (actually shared): %7.1f MB  (%.1f%% of resident)\n", (tp-tu)/1024, 100*(tp-tu)/tp

  # --- self-check against the smem totals line ----------------------------
  # Catches a parsing bug instead of silently returning confident-looking
  # wrong numbers.
  if (smem_n > 0) {
    bad = 0
    if (tc != smem_n) {
      printf "\nWARNING: counted %d processes, smem reported %d (%d lost during parsing)\n", \
        tc, smem_n, smem_n - tc > "/dev/stderr"
      bad = 1
    }
    delta = (tp > smem_pss) ? tp - smem_pss : smem_pss - tp
    if (smem_pss > 0 && delta / smem_pss > 0.01) {
      printf "WARNING: summed PSS = %.1f MB, smem reported %.1f MB\n", \
        tp/1024, smem_pss/1024 > "/dev/stderr"
      bad = 1
    }
    if (bad) exit 2
  } else {
    print "\n(dump has no smem totals line - self-check skipped)"
  }
}
'
