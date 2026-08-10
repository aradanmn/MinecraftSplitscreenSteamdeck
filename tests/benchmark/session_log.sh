#!/bin/bash
# =============================================================================
# Session-level wall-clock checkpoint logging for benchmark sittings.
# =============================================================================
# Companion to tests/benchmark/RUNBOOK.md. NOT the same thing as
# sampler.sh's `mark` — sampler.sh's marks are segment boundaries *within
# one scored cycle* (settle, S1_idle, S2_flight…), scoped to that cycle's
# own `$OUT` directory, and exist to slice FPS/CPU/GPU samples. This script
# tracks the SITTING-level overhead sampler.sh never sees at all — setup,
# positioning, troubleshooting, teardown, the gaps between attempts — so a
# retrospective on "how long did this actually take" can be answered from
# real numbers instead of reconstructed after the fact from sampler.csv
# timestamps (which was the only data available for the 2026-08-09 sitting
# that prompted this script — see benchmark-70-campaign-status memory).
#
# Usage:
#   session_log.sh mark <label> [note]   append a checkpoint to
#                                        $BENCH/session_log.csv (created
#                                        with a header on first use)
#   session_log.sh show                  print the log human-readably with
#                                        elapsed-since-previous deltas
#
# Suggested labels (not enforced — any string works): session_start,
# setup_done, attempt_start, attempt_end (put the outcome — accepted /
# discarded:<reason> — in the note), teardown_done, session_end.
#
# Env:
#   BENCH   required. Same directory sampler.sh/summarize.sh use.
#
# Version history:
#   v1.0 2026-08-09  #70: added after a sitting whose actual length could
#                    only be reconstructed after the fact from sampler.csv
#                    timestamps — this closes that gap going forward.
# =============================================================================
set -euo pipefail

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
    exit 2
}

: "${BENCH:?BENCH must be set (same convention as sampler.sh/summarize.sh)}"
LOGFILE="$BENCH/session_log.csv"

cmd_mark() {
    local label="$1" note="${2:-}"
    mkdir -p "$BENCH"
    if [[ ! -f "$LOGFILE" ]]; then
        printf 'unix_ts|iso_local|label|note\n' > "$LOGFILE"
    fi
    # Pipe-delimited, not comma — notes are freeform prose and WILL contain
    # commas ("discarded: cloud rendering, RX drift"); a naive comma-CSV
    # silently truncates/misaligns on those. '|' is vanishingly unlikely in
    # a note; if one ever needs it, it'll just show up literally on read.
    local ts iso
    ts="$(date +%s)"
    iso="$(date -d "@$ts" +'%Y-%m-%d %H:%M:%S')"
    printf '%s|%s|%s|%s\n' "$ts" "$iso" "$label" "$note" >> "$LOGFILE"
    echo "[session_log] ${iso} — ${label}${note:+ (${note})}" >&2
}

cmd_show() {
    [[ -f "$LOGFILE" ]] || { echo "[session_log] no log yet at $LOGFILE" >&2; exit 1; }
    awk -F'|' 'NR==1 {next}
        {
            if (prev != "") {
                delta = $1 - prev
                printf "%s  %-20s %s   (+%ds since previous)\n", $2, $3, $4, delta
            } else {
                printf "%s  %-20s %s\n", $2, $3, $4
            }
            prev = $1
        }' "$LOGFILE"
}

[[ $# -ge 1 ]] || usage
case "$1" in
    mark) [[ $# -eq 2 || $# -eq 3 ]] || usage; cmd_mark "$2" "${3:-}" ;;
    show) [[ $# -eq 1 ]] || usage; cmd_show ;;
    *)    usage ;;
esac
