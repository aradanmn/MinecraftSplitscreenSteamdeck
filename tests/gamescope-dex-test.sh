#!/bin/bash
# =============================================================================
# gamescope-dex-test.sh — Direct X11 ctypes positioning test for gamescope
# =============================================================================
# Uses Python ctypes-X11 calls (not xdotool) to test window positioning inside
# gamescope's XWayland compositor. Tests multiple strategies:
#
#   1. XMoveResizeWindow (high-level Xlib)
#   2. XConfigureWindow (standard dex.sh approach)
#   3. XConfigureWindow + override_redirect (bypass WM)
#   4. SendEvent with ConfigureRequest (emulate WM-request path)
#
# HOW TO USE (Steam Deck Game Mode — SSH access):
#   1. Ensure Steam Deck is in Game Mode with display connected
#   2. SSH in: ssh deck@steamdeck.home
#   3. Run: bash tests/gamescope-dex-test.sh
#   4. Two colored windows appear (red left, blue right)
#   5. After ~5 seconds, a summary is printed
#   6. Full log: ~/splitscreen-dex-result.txt
#
# HOW TO USE (Steam shortcut in Game Mode):
#   1. In Steam, edit "Minecraft Splitscreen" shortcut → LAUNCH OPTIONS
#   2. Add: --dex-test
#   3. Launch from Game Mode — result overlay appears after test
#   4. Read ~/splitscreen-dex-result.txt for full log
# =============================================================================

set -euo pipefail

RESULT_FILE="$HOME/splitscreen-dex-result.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export DEX_DISPLAY="${DEX_DISPLAY:-${DISPLAY:-:0}}"
export DISPLAY="${DEX_DISPLAY}"

echo "=== Gamescope DEX Geometry Test ===" | tee "$RESULT_FILE"
echo "DISPLAY=${DISPLAY}" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

RES=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}' || echo "unknown")
echo "Display resolution: ${RES}" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# ============================================================
# Phase 1: Launch two GTK test windows
# ============================================================
echo "=== Phase 1: Launching test windows ===" | tee -a "$RESULT_FILE"

# Window 1 — Red
python3 -c "
import gi, sys
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(640, 800)
win.move(0, 0)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1, 0, 0, 1))
win.set_title('DEXTEST_W1')
win.show_all()
Gtk.main()
" &
W1_PID=$!
sleep 0.5

# Window 2 — Blue
python3 -c "
import gi, sys
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(640, 800)
win.move(640, 0)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 1, 1))
win.set_title('DEXTEST_W2')
win.show_all()
Gtk.main()
" &
W2_PID=$!
sleep 1.0

# Source dex.sh to search for windows
source "$SCRIPT_DIR/modules/dex.sh"

W1_WID=$(dex_search --name "DEXTEST_W1" 2>/dev/null | head -1)
W2_WID=$(dex_search --name "DEXTEST_W2" 2>/dev/null | head -1)

echo "W1 PID: $W1_PID" | tee -a "$RESULT_FILE"
echo "W2 PID: $W2_PID" | tee -a "$RESULT_FILE"
echo "W1 WID: ${W1_WID:-(not found)}" | tee -a "$RESULT_FILE"
echo "W2 WID: ${W2_WID:-(not found)}" | tee -a "$RESULT_FILE"

if [[ -z "$W1_WID" || -z "$W2_WID" ]]; then
    echo "ERROR: Could not find test windows via dex_search" | tee -a "$RESULT_FILE"
    echo "Trying xdotool fallback..." | tee -a "$RESULT_FILE"
    if command -v xdotool >/dev/null 2>&1; then
        W1_WID=$(xdotool search --name "DEXTEST_W1" 2>/dev/null | head -1)
        W2_WID=$(xdotool search --name "DEXTEST_W2" 2>/dev/null | head -1)
        echo "xdotool W1: ${W1_WID:-(not found)}" | tee -a "$RESULT_FILE"
        echo "xdotool W2: ${W2_WID:-(not found)}" | tee -a "$RESULT_FILE"
    fi
    if [[ -z "$W1_WID" || -z "$W2_WID" ]]; then
        kill $W1_PID $W2_PID 2>/dev/null || true
        exit 1
    fi
fi

# ============================================================
# Phase 2: Run the direct ctypes test script
# ============================================================
echo "" | tee -a "$RESULT_FILE"
echo "============================================================" | tee -a "$RESULT_FILE"
echo "Phase 2: Testing direct X11 ctypes positioning" | tee -a "$RESULT_FILE"
echo "============================================================" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# Generate the DEX Python backend fresh (to pick up any changes)
DEX_PY_SCRIPT="/tmp/dex_test_$$.py"
export DEX_PY_SCRIPT

# Remove stale backend so it gets regenerated
rm -f "${DEX_PY_SCRIPT}" 2>/dev/null || true

# Source shenanigans — we need the backend generated
source "$SCRIPT_DIR/modules/dex.sh"

# ============================================================
# TEST: dex_move_resize_force (multi-strategy)
# ============================================================
echo "--- Test: dex_move_resize_force ---" | tee -a "$RESULT_FILE"
echo "Moving W1 to (0, 0, 640x800)..." | tee -a "$RESULT_FILE"
STRAT_W1=$(dex_move_resize_force "$W1_WID" 0 0 640 800 2>/dev/null || echo "fail")
echo "  Strategy used: $STRAT_W1 (1=XMoveResize, 2=OverrideRedirect+XConfigure, 3=Standard, 0=all failed)" | tee -a "$RESULT_FILE"

echo "Moving W2 to (640, 0, 640x800)..." | tee -a "$RESULT_FILE"
STRAT_W2=$(dex_move_resize_force "$W2_WID" 640 0 640 800 2>/dev/null || echo "fail")
echo "  Strategy used: $STRAT_W2" | tee -a "$RESULT_FILE"

sleep 0.3

# Read back geometry
echo "" | tee -a "$RESULT_FILE"
echo "--- Geometry readback (via dex_getgeometry) ---" | tee -a "$RESULT_FILE"
G1=$(dex_getgeometry "$W1_WID" 2>/dev/null || echo "FAILED")
G2=$(dex_getgeometry "$W2_WID" 2>/dev/null || echo "FAILED")
echo "W1: $G1" | tee -a "$RESULT_FILE"
echo "W2: $G2" | tee -a "$RESULT_FILE"

# ============================================================
# TEST: Individual strategies via direct python
# ============================================================
echo "" | tee -a "$RESULT_FILE"
echo "--- Test: Individual X11 strategies ---" | tee -a "$RESULT_FILE"

# Run the comprehensive strategy comparison
cat > /tmp/dex_strategy_test.py << 'PYEND'
import sys, os, ctypes, ctypes.util, struct, time

lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')

Window = ctypes.c_ulong
Bool = ctypes.c_int
Display = ctypes.c_void_p

class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int), ('depth', ctypes.c_int),
        ('visual', ctypes.c_void_p), ('root', Window),
        ('class_', ctypes.c_int), ('bit_gravity', ctypes.c_int),
        ('win_gravity', ctypes.c_int), ('backing_store', ctypes.c_int),
        ('backing_planes', ctypes.c_ulong), ('backing_pixel', ctypes.c_ulong),
        ('save_under', Bool), ('map_installed', Bool),
        ('map_state', ctypes.c_int),
        ('all_event_masks', ctypes.c_ulong), ('your_event_masks', ctypes.c_ulong),
        ('do_not_propagate_mask', ctypes.c_ulong),
        ('override_redirect', Bool), ('screen', ctypes.c_void_p),
        ('colormap', ctypes.c_ulong),
    ]

class XWindowChanges(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int),
        ('sibling', Window), ('stack_mode', ctypes.c_int),
    ]

CWX = 1 << 0; CWY = 1 << 1; CWWidth = 1 << 2; CWHeight = 1 << 3
CWBorderWidth = 1 << 4; CWOverrideRedirect = 1 << 3

display_name = os.environ.get('DISPLAY', ':0')
dpy = lib.XOpenDisplay(display_name.encode() if isinstance(display_name, str) else display_name)
if not dpy:
    print("ERROR: Cannot open display")
    sys.exit(1)

root = lib.XDefaultRootWindow(dpy)

w1 = int(sys.argv[1]); w2 = int(sys.argv[2])
res = str(sys.argv[3]) if len(sys.argv) > 3 else "/dev/null"

def log(msg):
    with open(res, 'a') as f:
        f.write(msg + '\n')
    print(msg)

def read_geo(wid, label):
    attrs = XWindowAttributes()
    ret = lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(attrs))
    if ret == 0:
        log(f"  {label}: FAILED to read geometry")
        return None
    log(f"  {label}: ({attrs.x},{attrs.y}) {attrs.width}x{attrs.height}")
    return (attrs.x, attrs.y, attrs.width, attrs.height)

def reset_both():
    ch = XWindowChanges(x=0, y=0, width=1920, height=1080, border_width=0)
    mask = CWX|CWY|CWWidth|CWHeight|CWBorderWidth
    lib.XConfigureWindow(dpy, Window(w1), ctypes.c_uint(mask), ctypes.byref(ch))
    lib.XConfigureWindow(dpy, Window(w2), ctypes.c_uint(mask), ctypes.byref(ch))
    lib.XFlush(dpy)
    time.sleep(0.2)

log(f"=== Strategy Comparison for gamescope XWayland ===")
log(f"Target: W1=(0,0 640x800)  W2=(640,0 640x800)")
log("")

# STRATEGY A: XMoveResizeWindow
log("--- Strategy A: XMoveResizeWindow ---")
reset_both()
lib.XMoveResizeWindow(dpy, Window(w1), 0, 0, 640, 800)
lib.XMoveResizeWindow(dpy, Window(w2), 640, 0, 640, 800)
lib.XFlush(dpy); lib.XSync(dpy, 0)
time.sleep(0.3)
g1a = read_geo(w1, "W1")
g2a = read_geo(w2, "W2")
a_ok = g1a and g1a[0]==0 and g1a[1]==0 and g2a and g2a[0]==640 and g2a[1]==0
log(f"  RESULT: {'PASS' if a_ok else 'FAIL'}")
log("")

# STRATEGY B: override_redirect + XConfigureWindow
log("--- Strategy B: OR + XConfigureWindow ---")
reset_both()
class XSetWA(ctypes.Structure):
    _fields_ = [('override_redirect', Bool)]
wa = XSetWA(override_redirect=Bool(1))
lib.XChangeWindowAttributes(dpy, Window(w1), ctypes.c_ulong(CWOverrideRedirect), ctypes.byref(wa))
lib.XChangeWindowAttributes(dpy, Window(w2), ctypes.c_ulong(CWOverrideRedirect), ctypes.byref(wa))
lib.XFlush(dpy); time.sleep(0.1)
ch = XWindowChanges(x=0, y=0, width=640, height=800, border_width=0)
mask = CWX|CWY|CWWidth|CWHeight|CWBorderWidth
lib.XConfigureWindow(dpy, Window(w1), ctypes.c_uint(mask), ctypes.byref(ch))
ch2 = XWindowChanges(x=640, y=0, width=640, height=800, border_width=0)
lib.XConfigureWindow(dpy, Window(w2), ctypes.c_uint(mask), ctypes.byref(ch2))
lib.XFlush(dpy); lib.XSync(dpy, 0)
time.sleep(0.3)
g1b = read_geo(w1, "W1")
g2b = read_geo(w2, "W2")
b_ok = g1b and g1b[0]==0 and g1b[1]==0 and g2b and g2b[0]==640 and g2b[1]==0
log(f"  RESULT: {'PASS' if b_ok else 'FAIL'}")
log("")

# STRATEGY C: XConfigureWindow (standard, no OR)
log("--- Strategy C: XConfigureWindow (standard) ---")
reset_both()
ch = XWindowChanges(x=0, y=0, width=640, height=800, border_width=0)
lib.XConfigureWindow(dpy, Window(w1), ctypes.c_uint(mask), ctypes.byref(ch))
ch2 = XWindowChanges(x=640, y=0, width=640, height=800, border_width=0)
lib.XConfigureWindow(dpy, Window(w2), ctypes.c_uint(mask), ctypes.byref(ch2))
lib.XFlush(dpy); lib.XSync(dpy, 0)
time.sleep(0.3)
g1c = read_geo(w1, "W1")
g2c = read_geo(w2, "W2")
c_ok = g1c and g1c[0]==0 and g1c[1]==0 and g2c and g2c[0]==640 and g2c[1]==0
log(f"  RESULT: {'PASS' if c_ok else 'FAIL'}")
log("")

# SUMMARY
log("=" * 50)
log("STRATEGY COMPARISON SUMMARY")
log(f"A (XMoveResizeWindow):          {'✓ PASS' if a_ok else '✗ FAIL'}")
log(f"B (OR + XConfigureWindow):      {'✓ PASS' if b_ok else '✗ FAIL'}")
log(f"C (XConfigureWindow standard):  {'✓ PASS' if c_ok else '✗ FAIL'}")

if any([a_ok, b_ok, c_ok]):
    working = [n for n, ok in [("A", a_ok), ("B", b_ok), ("C", c_ok)] if ok]
    log(f"\nWorking strategies: {', '.join(working)}")
    log("dex_move_resize_force() in dex.sh tries them in order: A → B → C")
    log("First working strategy is used, no need to configure.")
else:
    log("\nALL STRATEGIES FAILED in gamescope XWayland.")
    log("Nested KWin approach (see WINDOWING-SPEC.md) is required for Game Mode.")
log("=" * 50)

lib.XCloseDisplay(dpy)
PYEND

python3 /tmp/dex_strategy_test.py "$W1_WID" "$W2_WID" "$RESULT_FILE" 2>/dev/null || \
    echo "Strategy test script failed" | tee -a "$RESULT_FILE"

# ============================================================
# Final result
# ============================================================
echo "" | tee -a "$RESULT_FILE"
echo "=== Summary ===" | tee -a "$RESULT_FILE"
grep -E '(PASS|FAIL|Working strategies|ALL STRATEGIES|dex_move_resize_force)' "$RESULT_FILE" 2>/dev/null | tail -20 | tee -a "$RESULT_FILE"

# Check if any strategy passed
if grep -q '✓ PASS' "$RESULT_FILE" 2>/dev/null; then
    echo "" | tee -a "$RESULT_FILE"
    echo "RECOMMENDATION: Direct X11 ctypes positioning works in gamescope." | tee -a "$RESULT_FILE"
    echo "Update window_manager.sh to use dex_move_resize_force instead of xdotool." | tee -a "$RESULT_FILE"
else
    echo "" | tee -a "$RESULT_FILE"
    echo "RECOMMENDATION: All direct approaches failed in gamescope." | tee -a "$RESULT_FILE"
    echo "Use nested KWin approach (WINDOWING-SPEC.md Cycle 3) for Game Mode." | tee -a "$RESULT_FILE"
    echo "In Desktop Mode (KWin), standard dex_move_resize works fine." | tee -a "$RESULT_FILE"
fi

# Cleanup
kill $W1_PID $W2_PID 2>/dev/null || true
pkill -f "DEXTEST_" 2>/dev/null || true

echo "" | tee -a "$RESULT_FILE"
echo "=== Test complete ===" | tee -a "$RESULT_FILE"
echo "Full log: $RESULT_FILE" | tee -a "$RESULT_FILE"
