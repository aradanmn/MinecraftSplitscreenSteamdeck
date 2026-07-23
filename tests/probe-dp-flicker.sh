#!/bin/bash
# =============================================================================
# probe-dp-flicker.sh — how long does the Deck's DP transient last, and does
#                       ANY other connector attribute disagree with it? (#133)
# =============================================================================
# #133 debounces DISPLAY_MODE_CHANGE by requiring a candidate mode to hold for
# N consecutive reads. Both N and the spacing are currently a GUESS: HW-2 caught
# the killer blip with a single 3s-interval poll read, which bounds the
# transient at "under 3s" and nothing tighter.
#
# That guess is the whole argument. Response-time research (Miller 1968;
# Nielsen) puts ~1s as the limit for keeping a user's flow of thought and ~0.1s
# for "instantaneous" — and a dock/undock is a USER-INITIATED action, so the
# clock starts when they pull the cable. A 2s confirm window is squarely in
# "did it hang?" territory. The window has to be as short as the physics allow.
#
# So this probe answers two questions, not one:
#
#   Q1 HOW LONG is a real transient? If blips are ~100ms, a ~300ms confirm
#      window kills them and nobody ever perceives it. The tension between
#      "safe" and "responsive" simply evaporates. Measure before designing.
#
#   Q2 Does anything CORROBORATE the status flip? A connector carries more than
#      `status`: `enabled`, `dpms`, `edid` and `modes`. A real undock should
#      drop the EDID and empty the mode list; a spurious status read plausibly
#      does not. If some attribute reliably disagrees during a flicker but
#      agrees during a real undock, we can emit IMMEDIATELY when every signal
#      agrees and debounce ONLY the ambiguous case — near-zero latency in the
#      common case, which is the real fix for the responsiveness problem.
#
# This probe samples all of those attributes together at up to ~50Hz.
#
# READ-ONLY. Nothing but sysfs reads; safe to run beside a live session.
#
# USAGE (on the Deck, docked, Desktop or Game Mode terminal):
#   bash tests/probe-dp-flicker.sh [SECONDS] [--rate-ms N]
#
#   1. Dock the Deck; confirm the external display is working.
#   2. Start the probe (default 120s; Ctrl+C stops early and still summarizes).
#   3. Provoke the flicker. At HW-2 the trigger was a dock POWER-CYCLE, and
#      #133 recorded DP-1 flapping across power states — so power-cycle the
#      dock and/or the display a few times, and also leave it idle a while to
#      catch spontaneous blips.
#   4. THEN do a real, deliberate undock (pull the cable and leave it out) so
#      the log contains a known-good undock signature to compare against.
#
#   A real undock appears as a `disconnected` episode that never ends — the
#   summary marks it ONGOING and excludes it from the transient statistics.
# =============================================================================
set -uo pipefail

DURATION_S="${1:-120}"
[[ "$DURATION_S" =~ ^[0-9]+$ ]] || DURATION_S=120
RATE_MS=20
if [[ "${2:-}" == "--rate-ms" && "${3:-}" =~ ^[0-9]+$ ]]; then RATE_MS="$3"; fi

DRM_PATH="${DOCK_DETECTION_DRM_PATH:-/sys/class/drm}"

# Deck work files stay under the repo's .workdir/ so one wipe clears them.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(cd "$HERE/.." && pwd)/.workdir"
mkdir -p "$WORKDIR"
LOG="$WORKDIR/dp-flicker-$(date +%Y%m%d-%H%M%S).log"

# --- fork-free timing ------------------------------------------------------
# At a 20ms interval, forking /bin/sleep and date(1) per iteration would add
# jitter comparable to the interval itself and blur exactly the short
# transients we are here to measure. $EPOCHREALTIME is a builtin variable and
# a timed `read` on an fd nobody writes to is a builtin sleep.
NOW_MS=0
_stamp_ms() { local e="$EPOCHREALTIME"; NOW_MS=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }

_nap_fifo="$(mktemp -u)"
mkfifo "$_nap_fifo" || { echo "cannot create nap fifo" >&2; exit 1; }
exec 9<>"$_nap_fifo"
rm -f "$_nap_fifo"
_nap_s="$(awk "BEGIN{printf \"%.3f\", $RATE_MS/1000}")"
_nap() { read -r -t "$_nap_s" -u 9 _ 2>/dev/null || true; }

# --- sampling --------------------------------------------------------------
# One composite record per connector. `-s` is a builtin test, so probing EDID
# and the mode list stays fork-free (and we never read the binary EDID blob).
_read_conn() {   # $1 = connector dir name; sets REC
    local d="$DRM_PATH/$1" st="?" en="?" dp="?" ed="no" md="no"
    read -r st < "$d/status"  2>/dev/null || st="?"
    read -r en < "$d/enabled" 2>/dev/null || en="?"
    read -r dp < "$d/dpms"    2>/dev/null || dp="?"
    [[ -s "$d/edid"  ]] && ed="yes"
    [[ -s "$d/modes" ]] && md="yes"
    REC="status=$st enabled=$en dpms=$dp edid=$ed modes=$md"
}

declare -a CONN=()
for d in "$DRM_PATH"/card*-*/; do
    [[ -f "${d}status" ]] || continue
    CONN+=( "$(basename "$d")" )
done
if (( ${#CONN[@]} == 0 )); then
    echo "[probe] no DRM connectors under $DRM_PATH — nothing to sample" >&2
    exit 1
fi

REC=""
declare -A STATE=() SINCE=() EPISODES=()
_stamp_ms; START_MS=$NOW_MS
for c in "${CONN[@]}"; do
    _read_conn "$c"; STATE[$c]="$REC"; SINCE[$c]=$START_MS; EPISODES[$c]=""
done

{
    echo "=== probe-dp-flicker — $(date -Is) ==="
    echo "drm_path=$DRM_PATH  duration=${DURATION_S}s  rate=${RATE_MS}ms"
    # Which watch path production takes decides the LATENCY BUDGET, and it is
    # not knowable from this repo: without inotify-tools, watch_display_mode
    # polls every DOCK_DETECTION_POLL_INTERVAL_S(=3) and that 3s dominates any
    # debounce window we choose. Record it here so the run is self-describing.
    if command -v inotifywait >/dev/null 2>&1; then
        echo "watch path: INOTIFY (event-driven; ~0.5s settle + confirm window)"
    else
        echo "watch path: POLL (inotifywait ABSENT -> up to 3s detection latency"
        echo "            BEFORE any confirm window; the poll interval, not the"
        echo "            #133 debounce, is then the dominant delay)"
    fi
    echo ""
    for c in "${CONN[@]}"; do echo "initial  $c  ${STATE[$c]}"; done
    echo ""
} | tee "$LOG"

# Progress must distinguish "working" from "waiting on you" — TTY only, on
# stderr, so piping this probe's output stays clean.
_tty=0; [[ -t 2 ]] && _tty=1
_spin='-\|/'; _spin_i=0
_progress() {
    (( _tty )) || return 0
    _spin_i=$(( (_spin_i + 1) % 4 ))
    printf '\r[probe] sampling %s  %ss left  (transitions: %s)   ' \
        "${_spin:$_spin_i:1}" "$2" "$1" >&2
}

TRANSITIONS=0
_finish() {
    (( _tty )) && printf '\r%*s\r' 64 '' >&2
    _stamp_ms; local end=$NOW_MS
    {
        echo ""
        echo "=== summary ==="
        local worst=0 worst_c="" worst_rec=""
        local c
        for c in "${CONN[@]}"; do
            echo "--- $c"
            EPISODES[$c]+=$'\n'"ONGOING|$(( end - SINCE[$c] ))|${STATE[$c]}"
            while IFS='|' read -r tag ms rec; do
                [[ -n "$tag" ]] || continue
                printf '    %-8s %7s ms   %s\n' "$tag" "$ms" "$rec"
                # A *transient* is a COMPLETED disconnected episode on an
                # external connector — precisely what must never reach the FIFO.
                if [[ "$tag" == "done" && "$rec" == *"status=disconnected"* && "$c" != *eDP* ]]; then
                    (( ms > worst )) && { worst=$ms; worst_c="$c"; worst_rec="$rec"; }
                fi
            done <<< "${EPISODES[$c]}"
        done
        echo ""
        echo "total transitions: $TRANSITIONS"
        echo ""
        if (( worst > 0 )); then
            echo "Q1  LONGEST completed external 'disconnected' transient:"
            echo "      ${worst} ms on $worst_c"
            echo "      during it: $worst_rec"
            echo ""
            echo "    #133 confirm window must exceed ${worst} ms with margin."
            echo "    A 3x margin => window ~$(( worst * 3 )) ms, i.e."
            echo "      DOCK_DETECTION_CONFIRM_SAMPLES=3"
            echo "      DOCK_DETECTION_CONFIRM_INTERVAL_S=0.$(( (worst * 3 / 2) / 100 + 1 ))"
            if (( worst * 3 < 500 )); then
                echo "    => under the ~500ms 'did it hang?' bar. No latency problem."
            else
                echo "    => AT OR OVER the ~500ms bar. Debounce alone cannot be both"
                echo "       safe and imperceptible here; see Q2."
            fi
        else
            echo "Q1  NO completed external 'disconnected' transient observed."
            echo "    Either the flicker did not reproduce, or it is shorter than"
            echo "    the ${RATE_MS}ms sample interval. Re-run with --rate-ms 5"
            echo "    before concluding the Deck does not flicker."
        fi
        echo ""
        echo "Q2  Compare the attribute record of the TRANSIENT episodes above"
        echo "    against the ONGOING one left by the deliberate undock. Any"
        echo "    field that differs (edid=, modes=, enabled=, dpms=) is a"
        echo "    corroborating signal: if a real undock always drops it and a"
        echo "    flicker never does, dock_detection can emit IMMEDIATELY when"
        echo "    all signals agree and debounce only the ambiguous case."
        echo ""
        echo "log: $LOG"
    } | tee -a "$LOG"
}
trap '_finish; exit 0' INT TERM

END_MS=$(( START_MS + DURATION_S * 1000 ))
_tick=0
while :; do
    _stamp_ms
    (( NOW_MS >= END_MS )) && break
    for c in "${CONN[@]}"; do
        _read_conn "$c"
        if [[ "$REC" != "${STATE[$c]}" ]]; then
            dur=$(( NOW_MS - SINCE[$c] ))
            EPISODES[$c]+=$'\n'"done|${dur}|${STATE[$c]}"
            TRANSITIONS=$(( TRANSITIONS + 1 ))
            printf '[%8d ms] %-14s held %6d ms : %s\n' \
                "$(( NOW_MS - START_MS ))" "$c" "$dur" "${STATE[$c]}" | tee -a "$LOG"
            printf '                %-14s   now    : %s\n' "$c" "$REC" | tee -a "$LOG"
            STATE[$c]="$REC"; SINCE[$c]=$NOW_MS
        fi
    done
    _tick=$(( _tick + 1 ))
    (( _tick % 10 == 0 )) && _progress "$TRANSITIONS" "$(( (END_MS - NOW_MS) / 1000 ))"
    _nap
done

_finish
