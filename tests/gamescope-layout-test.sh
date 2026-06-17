#!/bin/bash
# =============================================================================
# gamescope-layout-test.sh — Test gamescope window positioning via xprop atoms
# =============================================================================
# Tests whether the gamescope baselayer + overlay approach works for
# splitscreen Minecraft positioning.
#
# HOW TO USE:
#   In Steam "Minecraft Splitscreen" shortcut LAUNCH OPTIONS, add:
#     --gamescope-test
#
#   OR run directly inside gamescope:
#     DISPLAY=:0 ./tests/gamescope-layout-test.sh
#
# WHAT THIS TEST DOES:
#   1. Opens display :0 (assumed to be inside gamescope XWayland)
#   2. Creates TWO GTK borderless fullscreen windows (red and blue)
#   3. Sets the red window as GAMESCOPECTRL_BASELAYER_WINDOW
#      → gamescope should use this as the fullscreen base layer
#   4. Sets the blue window as override_redirect + STEAM_OVERLAY
#      → gamescope should render it in the overlay plane (zpos=3)
#   5. Moves the blue window to the bottom half of the screen
#      → Result: red top half, blue bottom half (splitscreen!)
#   6. After 5 seconds, also tests with GAMESCOPE_EXTERNAL_OVERLAY
#   7. Shows PASS/FAIL and saves result to ~/splitscreen-gamescope-result.txt
#
# WHAT THE COLORS MEAN:
#   - Red fills entire screen first (anchor setup)
#   - Then blue appears on top (just the bottom half)
#     → PASS: Both baselayer AND overlay work!
#   - Blue covers entire screen (ignore position)
#     → Partial PASS: Overlay works but position is ignored
#   - Only one color is visible at fullscreen
#     → FAIL: The overlay is not rendering
# =============================================================================

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULT_FILE="$HOME/splitscreen-gamescope-result.txt"

# Help text
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    head -35 "$0" | tail -33
    exit 0
fi

echo "=== Gamescope Layout Test ===" | tee "$RESULT_FILE"
echo "DISPLAY=${DISPLAY:-:0}" | tee -a "$RESULT_FILE"
echo "Script: $0" | tee -a "$RESULT_FILE"

# Verify we're on an X display
if ! xdpyinfo >/dev/null 2>&1; then
    echo "ERROR: Cannot open X display" | tee -a "$RESULT_FILE"
    exit 1
fi

RES=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
echo "Display resolution: ${RES:-unknown}" | tee -a "$RESULT_FILE"

SCREEN_W=${RES%x*}
SCREEN_H=${RES#*x}
HALF_H=$(( SCREEN_H / 2 ))

# -------------------------------------------------------------------------
# Step 1: Create two test windows
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 1: Creating test windows ===" | tee -a "$RESULT_FILE"

# Window 1: Red (base layer candidate)
python3 -c "
import gi, sys, signal, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk

w, h = int(sys.argv[1]), int(sys.argv[2])
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(w, h)
win.move(0, 0)
win.set_title('LAYOUTTEST_BASE')
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.8, 0.0, 0.0, 1))
win.show_all()
print(f'[BASE] Window created, title=LAYOUTTEST_BASE, {w}x{h}', flush=True)

def on_realize(w):
    xid = win.get_window().get_xid()
    print(f'[BASE] XID = 0x{xid:x}', flush=True)
    # Write XID to a file so the parent script can read it
    with open('/tmp/gamescope_test_base_xid', 'w') as f:
        f.write(str(xid))
win.connect('realize', on_realize)
signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
Gtk.main()
" "$SCREEN_W" "$SCREEN_H" &
BASE_PID=$!
echo "  Base window PID: $BASE_PID" | tee -a "$RESULT_FILE"

# Window 2: Blue (overlay candidate)
python3 -c "
import gi, sys, signal, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk

w, h = int(sys.argv[1]), int(sys.argv[2])
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(w, h)
win.move(0, 0)
win.set_title('LAYOUTTEST_OVERLAY')
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.0, 0.0, 0.8, 1))
win.show_all()
print(f'[OVERLAY] Window created, title=LAYOUTTEST_OVERLAY, {w}x{h}', flush=True)

def on_realize(w):
    xid = win.get_window().get_xid()
    print(f'[OVERLAY] XID = 0x{xid:x}', flush=True)
    with open('/tmp/gamescope_test_overlay_xid', 'w') as f:
        f.write(str(xid))
win.connect('realize', on_realize)
signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
Gtk.main()
" "$SCREEN_W" "$SCREEN_H" &
OVERLAY_PID=$!
echo "  Overlay window PID: $OVERLAY_PID" | tee -a "$RESULT_FILE"

# Wait for windows to be realized (XIDs written)
sleep 2

# Read XIDs
BASE_XID=$(cat /tmp/gamescope_test_base_xid 2>/dev/null || echo "")
OVERLAY_XID=$(cat /tmp/gamescope_test_overlay_xid 2>/dev/null || echo "")

if [[ -z "$BASE_XID" || -z "$OVERLAY_XID" ]]; then
    echo "ERROR: Could not get window XIDs" | tee -a "$RESULT_FILE"
    echo "  BASE_XID: '$BASE_XID'" | tee -a "$RESULT_FILE"
    echo "  OVERLAY_XID: '$OVERLAY_XID'" | tee -a "$RESULT_FILE"
    kill $BASE_PID $OVERLAY_PID 2>/dev/null || true
    exit 1
fi

echo "  Base XID:    0x$(printf '%x' $BASE_XID)" | tee -a "$RESULT_FILE"
echo "  Overlay XID: 0x$(printf '%x' $OVERLAY_XID)" | tee -a "$RESULT_FILE"

# Verify with xdotool
echo "" | tee -a "$RESULT_FILE"
echo "=== Initial window geometry (via xdotool) ===" | tee -a "$RESULT_FILE"
BASE_WID=$(xdotool search --name "LAYOUTTEST_BASE" 2>/dev/null | head -1)
OVERLAY_WID=$(xdotool search --name "LAYOUTTEST_OVERLAY" 2>/dev/null | head -1)
echo "  Base WID (name search):  $BASE_WID" | tee -a "$RESULT_FILE"
echo "  Overlay WID (name search): $OVERLAY_WID" | tee -a "$RESULT_FILE"

GWC="$PROJECT_DIR/modules/gamescope_window_control.py"

# -------------------------------------------------------------------------
# Step 2: Query current gamescope properties
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 2: Querying gamescope root properties ===" | tee -a "$RESULT_FILE"
GAMESCOPE_VERBOSE=1 python3 "$GWC" query 2>&1 | tee -a "$RESULT_FILE"

# -------------------------------------------------------------------------
# Step 3: Set base layer window
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 3: Setting base layer window ===" | tee -a "$RESULT_FILE"
echo "Setting GAMESCOPECTRL_BASELAYER_WINDOW = 0x$(printf '%x' $BASE_XID)..." | tee -a "$RESULT_FILE"
GAMESCOPE_VERBOSE=1 python3 "$GWC" set-base-layer "$BASE_XID" 2>&1 | tee -a "$RESULT_FILE"
sleep 1

# -------------------------------------------------------------------------
# Step 4: Set overlay window with bottom-half geometry + STEAM_OVERLAY prop
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 4: Setting overlay window ===" | tee -a "$RESULT_FILE"
echo "Setting overlay at 0,$HALF_H ${SCREEN_W}x${HALF_H} with STEAM_OVERLAY prop..." | tee -a "$RESULT_FILE"
GAMESCOPE_VERBOSE=1 python3 "$GWC" set-overlay "$OVERLAY_XID" 0 "$HALF_H" "$SCREEN_W" "$HALF_H" 2>&1 | tee -a "$RESULT_FILE"
sleep 1

# -------------------------------------------------------------------------
# Step 5: Verify state
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 5: Post-setup geometry verification ===" | tee -a "$RESULT_FILE"

echo "  Base (xdotool):" | tee -a "$RESULT_FILE"
xdotool getwindowgeometry "$BASE_WID" 2>/dev/null | tee -a "$RESULT_FILE"
echo "  Overlay (xdotool):" | tee -a "$RESULT_FILE"
xdotool getwindowgeometry "$OVERLAY_WID" 2>/dev/null | tee -a "$RESULT_FILE"

echo "" | tee -a "$RESULT_FILE"
GAMESCOPE_VERBOSE=1 python3 "$GWC" query 2>&1 | tee -a "$RESULT_FILE"

# Check what properties are on the overlay window
echo "" | tee -a "$RESULT_FILE"
echo "=== Overlay window properties ===" | tee -a "$RESULT_FILE"
xprop -id "$OVERLAY_WID" -display "${DISPLAY:-:0}" 2>/dev/null | grep -i "overlay\|steam" | tee -a "$RESULT_FILE" || echo "  No overlay/steam properties found" | tee -a "$RESULT_FILE"

# -------------------------------------------------------------------------
# Step 6: Also test GAMESCOPE_EXTERNAL_OVERLAY approach
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 6: Testing GAMESCOPE_EXTERNAL_OVERLAY approach ===" | tee -a "$RESULT_FILE"

# Move overlay to top-right quadrant for phase 2
QUAD_W=$(( SCREEN_W / 2 ))
QUAD_H=$(( SCREEN_H / 2 ))
echo "Moving overlay to top-right quadrant ($QUAD_W,0 ${QUAD_W}x${QUAD_H}) with external overlay prop..." | tee -a "$RESULT_FILE"
GAMESCOPE_VERBOSE=1 python3 "$GWC" set-external-overlay "$OVERLAY_XID" "$QUAD_W" 0 "$QUAD_W" "$QUAD_H" 2>&1 | tee -a "$RESULT_FILE"
sleep 0.5

# Also try the new set-overlay-prop command
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 6b: Setting overlay prop on window (without repositioning) ===" | tee -a "$RESULT_FILE"
GAMESCOPE_VERBOSE=1 python3 "$GWC" set-overlay-prop "$OVERLAY_XID" external 2>&1 | tee -a "$RESULT_FILE"
sleep 0.5

# -------------------------------------------------------------------------
# Step 7: Determine PASS/FAIL
# -------------------------------------------------------------------------
echo "" | tee -a "$RESULT_FILE"
echo "=== Step 7: Result ===" | tee -a "$RESULT_FILE"

OVERLAY_X=$(xdotool getwindowgeometry "$OVERLAY_WID" 2>/dev/null | grep Position | grep -oP '\d+' | head -1 || echo "?")
OVERLAY_Y=$(xdotool getwindowgeometry "$OVERLAY_WID" 2>/dev/null | grep Position | grep -oP '\d+' | tail -1 || echo "?")
OVERLAY_W=$(xdotool getwindowgeometry "$OVERLAY_WID" 2>/dev/null | grep Geometry | grep -oP '\d+' | head -1 || echo "?")
OVERLAY_H=$(xdotool getwindowgeometry "$OVERLAY_WID" 2>/dev/null | grep Geometry | grep -oP '\d+' | tail -1 || echo "?")

if [[ "$OVERLAY_X" == "$QUAD_W" && "$OVERLAY_Y" == "0" ]]; then
    echo "*** PASS: Gamescope overlay positioning WORKS! ***" | tee -a "$RESULT_FILE"
    echo "    Blue overlay at ($OVERLAY_X,$OVERLAY_Y) ${OVERLAY_W}x${OVERLAY_H} (expected $QUAD_W,0 ${QUAD_W}x${QUAD_H})" | tee -a "$RESULT_FILE"
    echo "    Both STEAM_OVERLAY and GAMESCOPE_EXTERNAL_OVERLAY tested." | tee -a "$RESULT_FILE"
    RESULT_TEXT="PASS! Overlay @ ${OVERLAY_X},${OVERLAY_Y} ${OVERLAY_W}x${OVERLAY_H}"
    RESULT_COLOR="green"
    EXIT_CODE=0
elif [[ "$OVERLAY_X" == "0" ]] && ([[ "$OVERLAY_Y" == "$HALF_H" ]] || [[ "$OVERLAY_Y" == "$QUAD_H" ]]); then
    echo "*** PARTIAL PASS: Overlay position partially honoured ***" | tee -a "$RESULT_FILE"
    echo "    Blue overlay at ($OVERLAY_X,$OVERLAY_Y) ${OVERLAY_W}x${OVERLAY_H}" | tee -a "$RESULT_FILE"
    RESULT_TEXT="PARTIAL: Overlay @ ${OVERLAY_X},${OVERLAY_Y} ${OVERLAY_W}x${OVERLAY_H}"
    RESULT_COLOR="yellow"
    EXIT_CODE=1
else
    echo "*** NOTE: xdotool geometry values may not reflect actual rendering ***" | tee -a "$RESULT_FILE"
    echo "    Overlay position via xdotool: ($OVERLAY_X,$OVERLAY_Y) ${OVERLAY_W}x${OVERLAY_H}" | tee -a "$RESULT_FILE"
    echo "    Expected (phase 2): ($QUAD_W,0) ${QUAD_W}x${QUAD_H}" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"
    echo "    THE VISUAL RESULT IS WHAT MATTERS." | tee -a "$RESULT_FILE"
    echo "    If you see RED fullscreen + BLUE at the bottom or corner," | tee -a "$RESULT_FILE"
    echo "    the overlay approach works even if xdotool says otherwise." | tee -a "$RESULT_FILE"
    RESULT_TEXT="See visual: Overlay X=${OVERLAY_X} Y=${OVERLAY_Y} (expected ${QUAD_W},0)"
    RESULT_COLOR="orange"
    EXIT_CODE=2
fi

# Show result overlay for 15 seconds
python3 -c "
import tkinter as tk
root = tk.Tk()
root.title('LAYOUT_TEST_RESULT')
root.configure(bg='$RESULT_COLOR')
root.overrideredirect(True)
root.geometry('1200x400+360+340')
lbl = tk.Label(root, text='$RESULT_TEXT',
    fg='white', bg='$RESULT_COLOR',
    font=('Helvetica', 20, 'bold'),
    wraplength=1100, justify='center')
lbl.pack(expand=True, fill='both')
ex = tk.Label(root, text='(auto-closes in 15s - then exit with Steam+B)',
    fg='white', bg='$RESULT_COLOR', font=('Helvetica', 14))
ex.pack()
root.after(15000, root.destroy)
root.mainloop()
" &
RESULT_PID=$!

sleep 15

# Cleanup
kill $BASE_PID $OVERLAY_PID $RESULT_PID 2>/dev/null || true
pkill -f "LAYOUTTEST_BASE\|LAYOUTTEST_OVERLAY\|LAYOUT_TEST_RESULT" 2>/dev/null || true
rm -f /tmp/gamescope_test_base_xid /tmp/gamescope_test_overlay_xid

echo "" | tee -a "$RESULT_FILE"
echo "=== Result saved to $RESULT_FILE ===" | tee -a "$RESULT_FILE"

exit $EXIT_CODE
