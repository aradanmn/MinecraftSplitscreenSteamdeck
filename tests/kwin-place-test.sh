#!/bin/bash
# =============================================================================
# kwin-place-test.sh — test the KWin-scripting positioner against a LIVE run
# =============================================================================
# Run this WHILE a multi-player test is up (e.g. `test 4`, during the observation
# delay). It positions windows via KWin's scripting API (modules/kwin_positioner.sh)
# instead of override_redirect, then runs wintree-capture to confirm the windows
# actually LAND and STICK (and are frameless — no ±1 decoration offset).
#
# Usage:
#   bash tests/kwin-place-test.sh                # re-tile ALL active slots to their grid
#   bash tests/kwin-place-test.sh 2              # slot 2 -> its quad top-right cell
#   bash tests/kwin-place-test.sh 2 640 0 640 360  # slot 2 -> explicit x y w h
#
# Over SSH:
#   ssh deck@... 'bash ~/.local/share/PolyMC/tests/kwin-place-test.sh 2'
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
MODULES="${MCSS_MODULES:-$HOME/.local/share/PolyMC/modules}"

# shellcheck source=/dev/null
source "$MODULES/kwin_positioner.sh" 2>/dev/null || source "$HERE/../modules/kwin_positioner.sh"

if ! kwin_positioner_available; then
    echo "!! KWin scripting not reachable (need a live Plasma 6 nested session + qdbus6)."
    exit 1
fi

# Screen resolution: from the nested XWayland if we can read it, else 1280x720.
SCREEN_W=1280; SCREEN_H=720
for p in $(pgrep -x java 2>/dev/null); do
    d=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
    a=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^XAUTHORITY=//p' | head -1)
    if [[ -n "$d" ]]; then
        dims=$(DISPLAY="$d" XAUTHORITY="${a:-}" xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
        [[ "$dims" =~ ([0-9]+)x([0-9]+) ]] && { SCREEN_W="${BASH_REMATCH[1]}"; SCREEN_H="${BASH_REMATCH[2]}"; }
        break
    fi
done
HALF_W=$(( SCREEN_W / 2 )); HALF_H=$(( SCREEN_H / 2 ))

# Active slots + their pids from state.
mapfile -t ACTIVE < <(jq -r '.slots|to_entries[]|select(.value.active==true)|.key' "$STATE" 2>/dev/null)
slot_pid() { jq -r ".slots[\"$1\"].pid // empty" "$STATE" 2>/dev/null; }
N=${#ACTIVE[@]}
echo "=== KWin-place test : ${N} active slots (${ACTIVE[*]:-none}) , screen ${SCREEN_W}x${SCREEN_H} ==="

# Cell geometry for a slot given the active count (mirrors compute_slot_geometry).
cell_for_slot() {
    local slot="$1" count="$2"
    if   (( count <= 1 )); then echo "0 0 $SCREEN_W $SCREEN_H"
    elif (( count == 2 )); then
        case "$slot" in
            1) echo "0 0 $SCREEN_W $HALF_H" ;;
            2) echo "0 $HALF_H $SCREEN_W $HALF_H" ;;
        esac
    else  # quad
        case "$slot" in
            1) echo "0 0 $HALF_W $HALF_H" ;;
            2) echo "$HALF_W 0 $HALF_W $HALF_H" ;;
            3) echo "0 $HALF_H $HALF_W $HALF_H" ;;
            4) echo "$HALF_W $HALF_H $HALF_W $HALF_H" ;;
        esac
    fi
}

specs=()
if [[ $# -ge 5 ]]; then
    # explicit: slot x y w h
    slot="$1"; pid=$(slot_pid "$slot")
    [[ -z "$pid" ]] && { echo "!! slot $slot has no pid in state"; exit 1; }
    specs=("$pid $2 $3 $4 $5")
    echo "  -> slot $slot (pid $pid) to explicit $2,$3 $4x$5"
elif [[ $# -ge 1 ]]; then
    # single slot to its computed cell
    slot="$1"; pid=$(slot_pid "$slot")
    [[ -z "$pid" ]] && { echo "!! slot $slot has no pid in state"; exit 1; }
    read -r x y w h <<< "$(cell_for_slot "$slot" "$N")"
    specs=("$pid $x $y $w $h")
    echo "  -> slot $slot (pid $pid) to cell $x,$y ${w}x${h}"
else
    # all active slots to their grid cells
    for slot in "${ACTIVE[@]}"; do
        pid=$(slot_pid "$slot"); [[ -z "$pid" ]] && continue
        read -r x y w h <<< "$(cell_for_slot "$slot" "$N")"
        specs+=("$pid $x $y $w $h")
        echo "  -> slot $slot (pid $pid) to cell $x,$y ${w}x${h}"
    done
fi

echo "=== placing via KWin scripting ==="
kwin_place_windows "${specs[@]}"
echo "    (KWin script report -> journalctl --user -t kwin_wayland | tail)"

sleep 1
echo
echo "=== verify (wintree-capture) — geometry should now MATCH and be frameless ==="
bash "$HERE/wintree-capture.sh" 2>&1 | sed -n '/per-slot/,/full window tree/p' | head -30
