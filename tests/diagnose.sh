#!/bin/bash
# Bare minimum: create ONE window, try every position method, report back
DISPLAY="${DISPLAY:-:0}"
LOG="$HOME/splitscreen-diagnose.log"

echo "=== DIAGNOSE: $(date) ===" > "$LOG"
echo "DISPLAY=$DISPLAY" >> "$LOG"
xdpyinfo 2>/dev/null | grep -i "dimensions\|screen" >> "$LOG"

# Launch a simple window and get its WID
python3 -c "
import gi, os, sys, signal, time
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

win = Gtk.Window(title='DIAGWIN')
win.set_default_size(400, 300)
win.move(100, 100)
win.set_decorated(False)
win.realize()
label = Gtk.Label(label='DIAGNOSTIC WINDOW')
win.add(label)
win.show_all()

wid = win.get_window().get_xid()
print(f'WID={wid}')
sys.stdout.flush()

# Keep running until killed
signal.pause()
" &
PY_PID=$!
sleep 2

# Find the window
WID=$(DISPLAY=:0 xdotool search --pid "$PY_PID" 2>/dev/null | head -1)
echo "Python PID=$PY_PID" >> "$LOG"
echo "Found WID=$WID" >> "$LOG"

if [ -n "$WID" ]; then
    # Read current geometry
    echo "--- INITIAL GEOMETRY ---" >> "$LOG"
    xdotool getwindowgeometry "$WID" 2>&1 >> "$LOG"
    
    # Try windowmove
    echo "--- AFTER windowmove 200 200 ---" >> "$LOG"
    xdotool windowmove "$WID" 200 200 2>&1 >> "$LOG"
    sleep 1
    xdotool getwindowgeometry "$WID" 2>&1 >> "$LOG"
    
    # Try windowsize
    echo "--- AFTER windowsize 800 400 ---" >> "$LOG"
    xdotool windowsize "$WID" 800 400 2>&1 >> "$LOG"
    sleep 1
    xdotool getwindowgeometry "$WID" 2>&1 >> "$LOG"
    
    # Try override_redirect
    echo "--- AFTER override_redirect + move + size ---" >> "$LOG"
    xdotool windowunmap "$WID" 2>&1 >> "$LOG"
    sleep 0.5
    xdotool set_window --overrideredirect 1 "$WID" 2>&1 >> "$LOG"
    xdotool windowmove "$WID" 0 400 2>&1 >> "$LOG"
    xdotool windowsize "$WID" 640 400 2>&1 >> "$LOG"
    xdotool windowmap "$WID" 2>&1 >> "$LOG"
    sleep 1
    xdotool getwindowgeometry "$WID" 2>&1 >> "$LOG"
    
    # Check xprop
    echo "--- XPROP ---" >> "$LOG"
    xprop -id "$WID" 2>&1 | grep -i "override\|state\|geometry" >> "$LOG"
    
    echo "--- _NET_WM_STATE ---" >> "$LOG"
    xprop -id "$WID" -notype 32c _NET_WM_STATE 2>&1 >> "$LOG"
fi

echo "=== DONE ===" >> "$LOG"
kill $PY_PID 2>/dev/null || true
cat "$LOG"
