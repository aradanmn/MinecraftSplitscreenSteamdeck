#!/bin/bash
# =============================================================================
# gamescope-xdotool-test.sh
# =============================================================================
# Tests whether xdotool windowmove/windowsize has any visual effect inside
# gamescope's XWayland. Run this from SSH while a Steam Game Mode session
# is active (DISPLAY=:0).
#
# Usage:
#   Run from the Steam Deck's desktop terminal or SSH while in Game Mode:
#     bash gamescope-xdotool-test.sh
#
# What it does:
#   1. Creates two overlapping GTK windows (red and blue) via python3
#   2. Records their initial geometry
#   3. Calls xdotool windowmove/windowsize to separate them side by side
#   4. Records post-move geometry
#   5. Launches a small tkinter overlay showing "PASS" or "FAIL"
#   6. Cleans up after 10 seconds
# =============================================================================

echo "=== Gamescope xdotool Geometry Test ==="
echo "DISPLAY=${DISPLAY:-:0}"

# Check prerequisites
if ! command -v xdotool >/dev/null 2>&1; then
    echo "ERROR: xdotool not found"
    exit 1
fi

# Check we can talk to the display
if ! xdpyinfo -display "${DISPLAY:-:0}" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to display ${DISPLAY:-:0}"
    echo "This test must be run while a gamescope session is active (Steam Game Mode)."
    exit 1
fi

RES=$(xdpyinfo -display "${DISPLAY:-:0}" 2>/dev/null | awk '/dimensions:/{print $2}')
echo "Display resolution: ${RES:-unknown}"

# Create window 1 (red, top-left half)
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
root.after(15000, root.destroy)
root.mainloop()
" &
W1_PID=$!

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
root.after(15000, root.destroy)
root.mainloop()
" &
W2_PID=$!

sleep 1

echo ""
echo "=== Initial Geometry ==="
echo "Window 1 (red, should be behind):"
W1_INIT=$(xdotool search --name "XDOXDO_TEST_W1" 2>/dev/null | head -1)
W2_INIT=$(xdotool search --name "XDOXDO_TEST_W2" 2>/dev/null | head -1)

if [[ -z "$W1_INIT" || -z "$W2_INIT" ]]; then
    echo "ERROR: Could not find test windows"
    kill $W1_PID $W2_PID 2>/dev/null || true
    exit 1
fi

echo "  W1 WID: $W1_INIT"
xdotool getwindowgeometry "$W1_INIT" 2>/dev/null || echo "  (query failed)"
echo ""
echo "Window 2 (blue, should be on top):"
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
echo ""

# Extract positions from xdotool output
W1_POS=$(echo "$W1_POST" | grep Position | grep -oP '\d+,\d+' || echo "?,?")
W2_POS=$(echo "$W2_POST" | grep Position | grep -oP '\d+,\d+' || echo "?,?")
W1_SIZE=$(echo "$W1_POST" | grep Geometry | grep -oP '\d+x\d+' || echo "?x?")
W2_SIZE=$(echo "$W2_POST" | grep Geometry | grep -oP '\d+x\d+' || echo "?x?")

echo "W1 position: $W1_POS  size: $W1_SIZE"
echo "W2 position: $W2_POS  size: $W2_SIZE"

if [[ "$W1_POS" == "0,0" && "$W2_POS" == "960,0" ]]; then
    echo ""
    echo "*** xdotool GEOMETRY WORKS in gamescope! ***"
    echo "The xdotool windowmove/windowsize commands changed the window positions."
    echo "This means apply_layout() should work for splitscreen positioning."
    echo ""
    # Show a PASS overlay
    python3 -c "
import tkinter as tk
root = tk.Tk()
root.title('XDOXDO_RESULT')
root.configure(bg='green')
root.overrideredirect(True)
root.geometry('400x100+760+490')
lbl = tk.Label(root, text='xdotool WORKS in gamescope!', fg='white', bg='green', font=('Arial', 18))
lbl.pack(expand=True, fill='both')
root.after(5000, root.destroy)
root.mainloop()
" &
    RESULT=0
else
    echo ""
    echo "*** xdotool GEOMETRY DOES NOT WORK in gamescope! ***"
    echo "The xdotool commands did not change the window positions."
    echo "Need Xephyr or alternative window positioning approach."
    echo ""
    python3 -c "
import tkinter as tk
root = tk.Tk()
root.title('XDOXDO_RESULT')
root.configure(bg='red')
root.overrideredirect(True)
root.geometry('400x100+760+490')
lbl = tk.Label(root, text='xdotool FAILS in gamescope!', fg='white', bg='red', font=('Arial', 18))
lbl.pack(expand=True, fill='both')
root.after(5000, root.destroy)
root.mainloop()
" &
    RESULT=1
fi

echo "Cleaning up in 10 seconds..."
sleep 10
kill $W1_PID $W2_PID 2>/dev/null || true

# Kill any tkinter windows that might still be showing
pkill -f "XDOXDO_TEST" 2>/dev/null || true

exit $RESULT
