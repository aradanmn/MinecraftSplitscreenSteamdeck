#!/bin/bash
# =============================================================================
# gamescope-xdotool-test.sh — xdotool geometry test for gamescope
# =============================================================================
# Tests whether xdotool windowmove/windowsize has any visual effect inside
# gamescope's XWayland compositor.
#
# IMPORTANT: This test CANNOT be run from SSH because SSH has no access to
# gamescope's X display (DISPLAY=:0). It must be launched one of these ways:
#
# Option A — Via Steam shortcut launch options:
#   1. In Steam's "Minecraft Splitscreen" shortcut properties → LAUNCH OPTIONS:
#      SPLITSCREEN_XDOTOOL_TEST=1 %command%
#   2. This will run the test via the standard orchestrator before Minecraft
#      instances launch (note: only works if the script sources the test).
#
# Option B — Standalone from Desktop Mode terminal:
#   1. Switch to Desktop Mode
#   2. Open Konsole, run:
#      DISPLAY=:0 bash tests/gamescope-xdotool-test.sh
#   3. The windows appear on the desktop, not in gamescope — xdotool WILL
#      work there. This tells you nothing about gamescope.
#   4. ⚠️ This does NOT test gamescope's behavior.
#
# Option C — Via the launcher's --xdotool-test flag:
#   1. In Steam's shortcut → LAUNCH OPTIONS add: --xdotool-test
#   2. The orchestrator detects this flag and runs the test before Minecraft
#      launches (inside gamescope where DISPLAY=:0 is set by Steam).
#   3. This is the ONLY reliable way to test.
#
# Option D — Via cronit / steam deck tools:
#   1. Use Decky Loader's "cron" plugin or a systemd user timer
#   2. Not recommended for this one-off test.
#
# What it does:
#   1. Creates two overlapping tkinter windows (red and blue)
#   2. Records their initial geometry via xdotool
#   3. Calls xdotool windowmove/windowsize to separate them side by side
#   4. Records post-move geometry
#   5. Logs PASS or FAIL to stdout (captured in session log)
#   6. Cleans up after 15 seconds
# =============================================================================

echo "=== Gamescope xdotool Geometry Test ==="

# Fail early if we can't reach a display
if ! xdpyinfo "${DISPLAY:+ -display $DISPLAY}" >/dev/null 2>&1; then
    echo "WARNING: xdpyinfo cannot reach DISPLAY=${DISPLAY:-:0}."
    echo "This test MUST run inside a gamescope session."
    echo "From Steam, use: --xdotool-test flag in launch options."
    echo "Expected display: DISPLAY=:0 (gamescope's XWayland)"
fi

echo "DISPLAY=${DISPLAY:-:0}"

# Check xdotool
if ! command -v xdotool >/dev/null 2>&1; then
    echo "ERROR: xdotool not found"
    exit 1
fi

# Get display resolution
RES=$(xdpyinfo "${DISPLAY:+ -display $DISPLAY}" 2>/dev/null | awk '/dimensions:/{print $2}')
echo "Display resolution: ${RES:-unknown (will use 1920x1080 fallback)}"

# Create window 1 (red, fullscreen)
python3 -c "
import tkinter as tk
import os
d = os.environ.get('DISPLAY', ':0')
root = tk.Tk()
root.title('XDOXDO_TEST_W1')
root.configure(bg='red')
root.overrideredirect(True)
root.geometry('1920x1080+0+0')
print(f'[W1] Created on {d}', flush=True)
root.after(20000, root.destroy)
root.mainloop()
" &
W1_PID=$!
sleep 0.3

# Create window 2 (blue, fullscreen — will overlap W1)
python3 -c "
import tkinter as tk
import os
d = os.environ.get('DISPLAY', ':0')
root = tk.Tk()
root.title('XDOXDO_TEST_W2')
root.configure(bg='blue')
root.overrideredirect(True)
root.geometry('1920x1080+0+0')
print(f'[W2] Created on {d}', flush=True)
root.after(20000, root.destroy)
root.mainloop()
" &
W2_PID=$!
sleep 1

echo ""
echo "=== Initial Geometry ==="
W1_INIT=$(xdotool search --name "XDOXDO_TEST_W1" 2>/dev/null | head -1)
W2_INIT=$(xdotool search --name "XDOXDO_TEST_W2" 2>/dev/null | head -1)

if [[ -z "$W1_INIT" || -z "$W2_INIT" ]]; then
    echo "ERROR: Could not find test windows via xdotool search"
    echo "  W1 search result: '${W1_INIT:-<empty>}'"
    echo "  W2 search result: '${W2_INIT:-<empty>}'"
    kill $W1_PID $W2_PID 2>/dev/null || true
    exit 1
fi

echo "  W1 WID: $W1_INIT"
xdotool getwindowgeometry "$W1_INIT" 2>/dev/null || echo "  (query failed)"
echo ""
echo "  W2 WID: $W2_INIT"
xdotool getwindowgeometry "$W2_INIT" 2>/dev/null || echo "  (query failed)"

echo ""
echo "=== Applying xdotool windowmove/windowsize ==="
echo "Moving W1 to left half (0, 0, 960x1080)..."
xdotool windowmove "$W1_INIT" 0 0 2>/dev/null || echo "  windowmove FAILED"
xdotool windowsize "$W1_INIT" 960 1080 2>/dev/null || echo "  windowsize FAILED"

echo "Moving W2 to right half (960, 0, 960x1080)..."
xdotool windowmove "$W2_INIT" 960 0 2>/dev/null || echo "  windowmove FAILED"
xdotool windowsize "$W2_INIT" 960 1080 2>/dev/null || echo "  windowsize FAILED"

sleep 0.5

echo ""
echo "=== Post-Move Geometry ==="
W1_POST=$(xdotool getwindowgeometry "$W1_INIT" 2>/dev/null || echo "FAILED")
W2_POST=$(xdotool getwindowgeometry "$W2_INIT" 2>/dev/null || echo "FAILED")
echo "W1: $W1_POST"
echo "W2: $W2_POST"

echo ""
echo "=== Analysis ==="
echo "Expected: W1 at 0,0 960x1080; W2 at 960,0 960x1080"

# Extract positions
W1_POS=$(echo "$W1_POST" | grep Position | grep -oP '\d+,\d+' || echo "?,?")
W2_POS=$(echo "$W2_POST" | grep Position | grep -oP '\d+,\d+' || echo "?,?")
W1_SIZE=$(echo "$W1_POST" | grep Geometry | grep -oP '\d+x\d+' || echo "?x?")
W2_SIZE=$(echo "$W2_POST" | grep Geometry | grep -oP '\d+x\d+' || echo "?x?")

echo "W1 position: $W1_POS  size: $W1_SIZE"
echo "W2 position: $W2_POS  size: $W2_SIZE"

if [[ "$W1_POS" == "0,0" && "$W2_POS" == "960,0" ]]; then
    echo ""
    echo "*** PASS: xdotool GEOMETRY WORKS in gamescope! ***"
    echo "apply_layout() should work for splitscreen positioning."
    RESULT=0
else
    echo ""
    echo "*** FAIL: xdotool GEOMETRY DOES NOT WORK in gamescope! ***"
    echo "Need Xephyr or alternative window positioning approach."
    RESULT=1
fi

echo ""
echo "=== Test complete (result=$RESULT, cleanup in 15s) ==="
echo "If you can see two colored windows side-by-side, xdotool works."
echo "If only one color is visible (stacked), xdotool does not work."
sleep 15

# Cleanup
kill $W1_PID $W2_PID 2>/dev/null || true
pkill -f "XDOXDO_TEST" 2>/dev/null || true
echo "=== Cleanup done ==="

exit $RESULT
