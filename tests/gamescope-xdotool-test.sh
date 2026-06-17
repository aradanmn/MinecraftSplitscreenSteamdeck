#!/bin/bash
# =============================================================================
# gamescope-xdotool-test.sh — xdotool geometry test for gamescope
# =============================================================================
# Tests whether xdotool windowmove/windowsize has any visual effect inside
# gamescope's XWayland compositor.
#
# HOW TO USE (Steam Deck Game Mode — no terminal needed):
#   1. In Steam, edit "Minecraft Splitscreen" shortcut → LAUNCH OPTIONS
#   2. Add: --xdotool-test
#   3. Launch from Game Mode with display + controllers connected
#   4. Two colored windows appear (red left, blue right)
#   5. After 5 seconds, a result window appears for 15 seconds
#      showing PASS (green) or FAIL (red) + xdotool geometry readback
#   6. After the test, exit the game/session (Steam+B)
#   7. Read ~/splitscreen-xdotool-result.txt for the full log
#
# WHAT THE COLORS MEAN:
#   - You see RED on the left and BLUE on the right side-by-side
#     → xdotool WORKS in gamescope (PASS ✓)
#   - You see only ONE color covering the full screen
#     → xdotool is IGNORED in gamescope (FAIL ✗)
#   - You see the PASS/FAIL overlay window after 5 seconds
#     → Read the text for exact geometry data
# =============================================================================

RESULT_FILE="$HOME/splitscreen-xdotool-result.txt"

echo "=== Gamescope xdotool Geometry Test ===" | tee "$RESULT_FILE"
echo "DISPLAY=${DISPLAY:-:0}" | tee -a "$RESULT_FILE"

if ! command -v xdotool >/dev/null 2>&1; then
    echo "ERROR: xdotool not found" | tee -a "$RESULT_FILE"
    exit 1
fi

RES=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
echo "Display resolution: ${RES:-unknown}" | tee -a "$RESULT_FILE"

# Create window 1 (red, fullscreen)
python3 -c "
import tkinter as tk, os
root = tk.Tk()
root.title('XDOXDO_TEST_W1')
root.configure(bg='red')
root.overrideredirect(True)
root.geometry('1920x1080+0+0')
print('[W1] Created red fullscreen window', flush=True)
root.after(30000, root.destroy)
root.mainloop()
" &
W1_PID=$!
sleep 0.3

# Create window 2 (blue, fullscreen — will overlap W1)
python3 -c "
import tkinter as tk, os
root = tk.Tk()
root.title('XDOXDO_TEST_W2')
root.configure(bg='blue')
root.overrideredirect(True)
root.geometry('1920x1080+0+0')
print('[W2] Created blue fullscreen window', flush=True)
root.after(30000, root.destroy)
root.mainloop()
" &
W2_PID=$!
sleep 1.5

echo "" | tee -a "$RESULT_FILE"
echo "=== Initial Geometry ===" | tee -a "$RESULT_FILE"
W1_INIT=$(xdotool search --name "XDOXDO_TEST_W1" 2>/dev/null | head -1)
W2_INIT=$(xdotool search --name "XDOXDO_TEST_W2" 2>/dev/null | head -1)

if [[ -z "$W1_INIT" || -z "$W2_INIT" ]]; then
    echo "ERROR: Could not find test windows" | tee -a "$RESULT_FILE"
    kill $W1_PID $W2_PID 2>/dev/null || true
    exit 1
fi

echo "  W1 WID: $W1_INIT" | tee -a "$RESULT_FILE"
xdotool getwindowgeometry "$W1_INIT" 2>/dev/null | tee -a "$RESULT_FILE"
echo "  W2 WID: $W2_INIT" | tee -a "$RESULT_FILE"
xdotool getwindowgeometry "$W2_INIT" 2>/dev/null | tee -a "$RESULT_FILE"

echo "" | tee -a "$RESULT_FILE"
echo "=== Applying xdotool windowmove/windowsize ===" | tee -a "$RESULT_FILE"
echo "Moving W1 to left half (0, 0, 960x1080)..." | tee -a "$RESULT_FILE"
xdotool windowmove "$W1_INIT" 0 0 2>/dev/null || echo "  windowmove FAILED" | tee -a "$RESULT_FILE"
xdotool windowsize "$W1_INIT" 960 1080 2>/dev/null || echo "  windowsize FAILED" | tee -a "$RESULT_FILE"

echo "Moving W2 to right half (960, 0, 960x1080)..." | tee -a "$RESULT_FILE"
xdotool windowmove "$W2_INIT" 960 0 2>/dev/null || echo "  windowmove FAILED" | tee -a "$RESULT_FILE"
xdotool windowsize "$W2_INIT" 960 1080 2>/dev/null || echo "  windowsize FAILED" | tee -a "$RESULT_FILE"

sleep 0.5

echo "" | tee -a "$RESULT_FILE"
echo "=== Post-Move Geometry ===" | tee -a "$RESULT_FILE"
W1_POST=$(xdotool getwindowgeometry "$W1_INIT" 2>/dev/null || echo "FAILED")
W2_POST=$(xdotool getwindowgeometry "$W2_INIT" 2>/dev/null || echo "FAILED")
echo "W1: $W1_POST" | tee -a "$RESULT_FILE"
echo "W2: $W2_POST" | tee -a "$RESULT_FILE"

W1_POS=$(echo "$W1_POST" | grep Position | grep -oP '\d+,\d+' || echo "?,?")
W2_POS=$(echo "$W2_POST" | grep Position | grep -oP '\d+,\d+' || echo "?,?")
W1_SIZE=$(echo "$W1_POST" | grep Geometry | grep -oP '\d+x\d+' || echo "?x?")
W2_SIZE=$(echo "$W2_POST" | grep Geometry | grep -oP '\d+x\d+' || echo "?x?")

echo "" | tee -a "$RESULT_FILE"
if [[ "$W1_POS" == "0,0" && "$W2_POS" == "960,0" ]]; then
    echo "*** PASS: xdotool GEOMETRY WORKS in gamescope! ***" | tee -a "$RESULT_FILE"
    echo "apply_layout() should work for splitscreen positioning." | tee -a "$RESULT_FILE"
    RESULT=0
    RESULT_TEXT="PASS: xdotool works in gamescope!  W1 at $W1_POS $W1_SIZE  W2 at $W2_POS $W2_SIZE"
    RESULT_COLOR="green"
else
    echo "*** FAIL: xdotool GEOMETRY DOES NOT WORK in gamescope! ***" | tee -a "$RESULT_FILE"
    echo "W1 at $W1_POS $W1_SIZE, W2 at $W2_POS $W2_SIZE" | tee -a "$RESULT_FILE"
    echo "Expected W1 at 0,0 960x1080, W2 at 960,0 960x1080" | tee -a "$RESULT_FILE"
    RESULT=1
    RESULT_TEXT="FAIL: xdotool ignored in gamescope  W1=$W1_POS $W1_SIZE  W2=$W2_POS $W2_SIZE"
    RESULT_COLOR="red"
fi

# Show the result as a big on-screen overlay for 15 seconds
# This is how you read the result in Game Mode with no terminal
python3 -c "
import tkinter as tk
root = tk.Tk()
root.title('XDOXDO_RESULT')
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

sleep 15

kill $W1_PID $W2_PID 2>/dev/null || true
pkill -f "XDOXDO_TEST\|XDOXDO_RESULT" 2>/dev/null || true

echo "" | tee -a "$RESULT_FILE"
echo "=== Result saved to $RESULT_FILE ===" | tee -a "$RESULT_FILE"

exit $RESULT
