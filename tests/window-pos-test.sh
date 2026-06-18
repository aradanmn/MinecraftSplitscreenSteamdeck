#!/bin/bash
# Standalone window positioning test for gamescope
# No bwrap, no PolyMC, no TinyWM — just two test windows
set -euo pipefail

DISPLAY="${DISPLAY:-:0}"
LOG="$HOME/splitscreen-pos-test.log"
echo "$(date) === WINDOW POSITION TEST START ===" > "$LOG"

echo "DISPLAY=$DISPLAY" | tee -a "$LOG"
xdpyinfo 2>/dev/null | grep dimensions | tee -a "$LOG"

# Launch two colored GTK windows
# Window 1: RED — should be at top-left (0,0) 640x400
# Window 2: BLUE — should be at bottom-left (0,400) 640x400

echo "Launching test windows..." | tee -a "$LOG"

python3 -c "
import gi, sys, signal
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

W1, H1 = 640, 400
x1, y1 = 0, 0
x2, y2 = 0, 400

# Window 1 (RED top)
w1 = Gtk.Window(title='TESTTOP')
w1.set_default_size(W1, H1)
w1.move(x1, y1)
w1.set_resizable(False)
w1.set_decorated(False)
w1.realize()
l1 = Gtk.Label(label=f'TOP WINDOW\\nShould be at ({x1},{y1}) {W1}x{H1}\\nColor: RED')
l1.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1,0,0,1))
w1.add(l1)
w1.show_all()

# Window 2 (BLUE bottom)
w2 = Gtk.Window(title='TESTBOTTOM')
w2.set_default_size(W1, H1)
w2.move(x2, y2)
w2.set_resizable(False)
w2.set_decorated(False)
w2.realize()
l2 = Gtk.Label(label=f'BOTTOM WINDOW\\nShould be at ({x2},{y2}) {W1}x{H1}\\nColor: BLUE')
l2.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0,0,1,1))
w2.add(l2)
w2.show_all()

print(f'Windows created on DISPLAY={os.environ.get(\"DISPLAY\",\":0\")}')
print(f'TOP:     WID={w1.get_window().get_xid()} at ({x1},{y1}) {W1}x{H1}')
print(f'BOTTOM:  WID={w2.get_window().get_xid()} at ({x2},{y2}) {W1}x{H1}')

# Auto-close after 30 seconds
GLib.timeout_add_seconds(30, Gtk.main_quit)
Gtk.main()
" 2>&1 | tee -a "$LOG"

echo "=== TEST COMPLETE ===" | tee -a "$LOG"
