#!/bin/bash
# =============================================================================
# wintree-capture.sh — diagnostic for the "wrong-WID re-tile" bug (Issue A)
# =============================================================================
# Run this DURING a multi-player splitscreen run (e.g. `test 3` / `test 4`),
# while several Minecraft windows are on screen (the observation-delay window is
# ideal). It detects the nested XWayland display, then for each active slot
# compares the WID we store/move in splitscreen_state.json against the ACTUAL
# top-level window(s) the slot's Minecraft PID owns.
#
# THE TELL: if a slot's PID owns a window that is NOT the stored WID — e.g. a
# full-width window stuck at the old half-grid position — then we are moving the
# wrong window, and that other window is the one the player actually sees.
#
# Usage:  bash tests/wintree-capture.sh        (no args; auto-detects everything)
#         ssh deck@... 'bash ~/.local/share/PolyMC/tests/wintree-capture.sh'
# =============================================================================
set -uo pipefail
STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"

# 1. Detect the nested XWayland display from a running Minecraft (java) instance.
NDISP=""
for p in $(pgrep -x java 2>/dev/null); do
    d=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
    [[ -n "$d" ]] && { NDISP="$d"; break; }
done
if [[ -z "$NDISP" ]]; then
    echo "!! No running java instance with a DISPLAY found."
    echo "   Run this WHILE a test is mid-flight (instances up)."
    exit 1
fi
export DISPLAY="$NDISP"
echo "=== nested display: $NDISP   resolution: $(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')"
echo

# Geometry + map-state for a window id, as "WxH+X+Y map=<state>".
_geo() {
    xwininfo -id "$1" 2>/dev/null | awk '
        /Absolute upper-left X/{x=$NF} /Absolute upper-left Y/{y=$NF}
        /Width:/{w=$NF} /Height:/{h=$NF} /Map State/{m=$NF}
        END{ if (w=="") print "<no geometry>"; else printf "%sx%s+%s+%s map=%s", w, h, x, y, m }'
}

# 2. State view.
echo "=== splitscreen_state.json (active slots) ==="
jq -r '.slots | to_entries[] | select(.value.active==true)
       | "  slot \(.key): wid=\(.value.wid)  pid=\(.value.pid)  bwrap=\(.value.bwrap_pid)"' \
   "$STATE" 2>/dev/null
echo

# 3. Per active slot: stored WID vs EVERY window owned by the slot's PID.
echo "=== per-slot: STORED wid  vs  ALL windows owned by the slot's Minecraft PID ==="
for slot in $(jq -r '.slots|to_entries[]|select(.value.active==true)|.key' "$STATE" 2>/dev/null); do
    wid=$(jq -r ".slots[\"$slot\"].wid // empty" "$STATE" 2>/dev/null)
    pid=$(jq -r ".slots[\"$slot\"].pid // empty" "$STATE" 2>/dev/null)
    echo "--- slot $slot (pid=${pid:-?}) ---"
    if [[ -n "$wid" && "$wid" != "null" ]]; then
        echo "  STORED wid $wid : $(_geo "$wid")"
    else
        echo "  STORED wid : <none>"
    fi
    if [[ -n "$pid" && "$pid" != "null" ]]; then
        found=0
        for w in $(xdotool search --pid "$pid" 2>/dev/null); do
            nm=$(xdotool getwindowname "$w" 2>/dev/null)
            marker=""; [[ "$w" == "$wid" ]] && marker="   <== STORED"
            echo "    win $w : $(_geo "$w")  name='$nm'$marker"
            found=1
        done
        [[ "$found" == 0 ]] && echo "    (xdotool found no windows for pid $pid — _NET_WM_PID may be unset)"
    fi
done
echo
echo "=== full window tree (id : name) for reference ==="
xwininfo -root -tree 2>/dev/null | grep -aoE '0x[0-9a-f]+ "[^"]*"' | head -40
echo
echo "READ: a slot whose PID owns a window OTHER than the STORED wid (esp. one at a"
echo "      stale full-width geometry) = the wrong-WID bug: we're moving the wrong window."
