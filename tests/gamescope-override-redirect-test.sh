#!/bin/bash
# =============================================================================
# gamescope-override-redirect-test.sh — Override redirect unmap/remap test
# =============================================================================
# Tests whether override_redirect + unmap/remap cycle works inside gamescope
# for window positioning. Designed to be run remotely via SSH or in Game Mode.
#
# Usage:
#   ./tests/gamescope-override-redirect-test.sh [--with-tinywm] [--with-dex]
#
# Modes:
#   --with-tinywm   Start TinyWM first, then create windows
#   --with-dex      Use DEX (Python ctypes X11) instead of xdotool
#   (default)       Plain xdotool override_redirect unmap/remap
#
# Results saved to: ~/splitscreen-override-redirect-test.txt
# =============================================================================

RESULT_FILE="$HOME/splitscreen-override-redirect-test.txt"
USE_TINYWM=false
USE_DEX=false
DISPLAY="${DISPLAY:-:0}"

for arg in "$@"; do
    case "$arg" in
        --with-tinywm) USE_TINYWM=true ;;
        --with-dex)    USE_DEX=true ;;
    esac
done

echo "=== Gamescope Override Redirect Test ===" | tee "$RESULT_FILE"
echo "DISPLAY=$DISPLAY" | tee -a "$RESULT_FILE"
echo "Date: $(date)" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# Source DEX if needed
if $USE_DEX; then
    SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
    source "$SCRIPT_DIR/modules/dex.sh"
    echo "Using DEX (Python ctypes X11)" | tee -a "$RESULT_FILE"
else
    if ! command -v xdotool >/dev/null 2>&1; then
        echo "ERROR: xdotool not found" | tee -a "$RESULT_FILE"
        exit 1
    fi
    echo "Using xdotool" | tee -a "$RESULT_FILE"
fi

RES=$(xdpyinfo -display "$DISPLAY" 2>/dev/null | awk '/dimensions:/{print $2}')
echo "Display resolution: ${RES:-unknown}" | tee -a "$RESULT_FILE"

W=${RES%%x*}
H=${RES##*x}
[[ -z "$W" || -z "$H" ]] && { W=1280; H=800; }

HALF_H=$(( H / 2 ))
HALF_W=$(( W / 2 ))

# Start TinyWM if requested
if $USE_TINYWM; then
    echo "" | tee -a "$RESULT_FILE"
    echo "=== Starting TinyWM ===" | tee -a "$RESULT_FILE"

    # Make a test state file
    TF="/tmp/or-test-state.json"
    cat > "$TF" << JSONEOF
{
    "mode": "docked",
    "slots": {
        "1": {"active": true, "wid": null, "x": 0, "y": 0, "w": $HALF_W, "h": $H, "event_node": null, "js_node": null, "bwrap_pid": null, "pid": null},
        "2": {"active": true, "wid": null, "x": $HALF_W, "y": 0, "w": $HALF_W, "h": $H, "event_node": null, "js_node": null, "bwrap_pid": null, "pid": null}
    }
}
JSONEOF

    SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
    DISPLAY="$DISPLAY" python3 "$SCRIPT_DIR/modules/tinywm.py" "$DISPLAY" "$TF" &
    TINYWM_PID=$!
    sleep 1
    if kill -0 "$TINYWM_PID" 2>/dev/null; then
        echo "TinyWM started (PID $TINYWM_PID)" | tee -a "$RESULT_FILE"
    else
        echo "ERROR: TinyWM failed to start" | tee -a "$RESULT_FILE"
        exit 1
    fi
fi

echo "" | tee -a "$RESULT_FILE"
echo "=== Phase 1: Create two fullscreen windows ===" | tee -a "$RESULT_FILE"

# Helper to spawn a window
spawn_window() {
    local title="$1" bg="$2" w="$3" h="$4" x="$5" y="$6"
    if command -v python3 >/dev/null 2>&1; then
        # Try GTK first (works on SteamOS)
        python3 -c "
import gi, signal
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size($w, $h)
win.move($x, $y)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA$bg)
win.set_title('$title')
win.show_all()
signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
Gtk.main()
" 2>/dev/null &
        echo $!
    else
        echo "ERROR: python3 not available" >&2
        echo -1
    fi
}

# Window 1: BLUE, fullscreen
W1_PID=$(spawn_window "OVER_REDIRECT_L" "(0.2, 0.2, 0.8, 1)" "$W" "$H" 0 0)
sleep 0.5

# Window 2: RED, fullscreen (will overlap W1 initially)
W2_PID=$(spawn_window "OVER_REDIRECT_R" "(0.8, 0.2, 0.2, 1)" "$W" "$H" 0 0)
sleep 1

echo "W1 PID=$W1_PID, W2 PID=$W2_PID" | tee -a "$RESULT_FILE"

# Find WIDs
if $USE_DEX; then
    W1_WID=$(dex_search --name "OVER_REDIRECT_L" | head -1)
    W2_WID=$(dex_search --name "OVER_REDIRECT_R" | head -1)
else
    W1_WID=$(xdotool search --name "OVER_REDIRECT_L" 2>/dev/null | head -1)
    W2_WID=$(xdotool search --name "OVER_REDIRECT_R" 2>/dev/null | head -1)
fi

if [[ -z "$W1_WID" || -z "$W2_WID" ]]; then
    echo "ERROR: Could not find test windows (W1=$W1_WID, W2=$W2_WID)" | tee -a "$RESULT_FILE"
    kill $W1_PID $W2_PID $TINYWM_PID 2>/dev/null || true
    exit 1
fi

echo "W1 WID: $W1_WID" | tee -a "$RESULT_FILE"
echo "W2 WID: $W2_WID" | tee -a "$RESULT_FILE"

# Log initial geometry
echo "" | tee -a "$RESULT_FILE"
echo "=== Initial Geometry (before any manipulation) ===" | tee -a "$RESULT_FILE"
if $USE_DEX; then
    echo "W1: $(dex_getgeometry "$W1_WID")" | tee -a "$RESULT_FILE"
    echo "W2: $(dex_getgeometry "$W2_WID")" | tee -a "$RESULT_FILE"
else
    echo "W1:" | tee -a "$RESULT_FILE"
    xdotool getwindowgeometry "$W1_WID" 2>/dev/null | tee -a "$RESULT_FILE"
    echo "W2:" | tee -a "$RESULT_FILE"
    xdotool getwindowgeometry "$W2_WID" 2>/dev/null | tee -a "$RESULT_FILE"
fi

echo "" | tee -a "$RESULT_FILE"
echo "=== Phase 2: Test override_redirect only (no unmap/remap) ===" | tee -a "$RESULT_FILE"

if $USE_DEX; then
    dex_set_override_redirect "$W2_WID" 1
    dex_move_resize "$W2_WID" "$HALF_W" 0 "$HALF_W" "$H"
else
    xdotool set_window --overrideredirect 1 "$W2_WID" 2>/dev/null || true
    xdotool windowmove "$W2_WID" "$HALF_W" 0 2>/dev/null || true
    xdotool windowsize "$W2_WID" "$HALF_W" "$H" 2>/dev/null || true
fi
sleep 0.5

echo "W2 after OR-only:" | tee -a "$RESULT_FILE"
if $USE_DEX; then
    echo "  $(dex_getgeometry "$W2_WID")" | tee -a "$RESULT_FILE"
else
    xdotool getwindowgeometry "$W2_WID" 2>/dev/null | tee -a "$RESULT_FILE"
fi

echo "" | tee -a "$RESULT_FILE"
echo "=== Phase 3: Test unmap → OR → move/size → remap (W1) ===" | tee -a "$RESULT_FILE"

# The key technique: unmap, set override_redirect, move/resize, then remap
if $USE_DEX; then
    python3 -c "
import ctypes, ctypes.util, os
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display')
    exit(1)

# Unmap
lib.XUnmapWindow(dpy, $W1_WID)
lib.XFlush(dpy)
import time; time.sleep(0.2)

# Set override_redirect via XChangeWindowAttributes
class XSetWA(ctypes.Structure):
    _fields_ = [('override_redirect', ctypes.c_int)]
attrs = XSetWA(override_redirect=ctypes.c_int(1))
lib.XChangeWindowAttributes(dpy, $W1_WID, 1 << 3, ctypes.byref(attrs))

# Move and resize
lib.XMoveResizeWindow(dpy, $W1_WID, 0, 0, $HALF_W, $H)
lib.XFlush(dpy)
time.sleep(0.1)

# Remap
lib.XMapWindow(dpy, $W1_WID)
lib.XFlush(dpy)

# Raise
lib.XRaiseWindow(dpy, $W1_WID)
lib.XFlush(dpy)
time.sleep(0.3)

# Check geometry
attrs2 = ctypes.create_string_buffer(40)
# Actually use XGetWindowAttributes
class XWindowAttrs(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int), ('depth', ctypes.c_int),
        ('visual', ctypes.c_void_p), ('root', ctypes.c_ulong),
    ]
real_attrs = XWindowAttrs()
lib.XGetWindowAttributes(dpy, $W1_WID, ctypes.byref(real_attrs))
print(f'RESULT: W1 position={real_attrs.x},{real_attrs.y} size={real_attrs.width}x{real_attrs.height}')
lib.XCloseDisplay(dpy)
" 2>&1 | tee -a "$RESULT_FILE"
else
    # xdotool version
    xdotool windowunmap "$W1_WID" 2>/dev/null || true
    sleep 0.2
    xdotool set_window --overrideredirect 1 "$W1_WID" 2>/dev/null || true
    xdotool windowmove "$W1_WID" 0 0 2>/dev/null || true
    xdotool windowsize "$W1_WID" "$HALF_W" "$H" 2>/dev/null || true
    xdotool windowmap "$W1_WID" 2>/dev/null || true
    sleep 0.3
    xdotool windowraise "$W1_WID" 2>/dev/null || true
    echo "W1 after unmap/OR/remap:" | tee -a "$RESULT_FILE"
    xdotool getwindowgeometry "$W1_WID" 2>/dev/null | tee -a "$RESULT_FILE"
fi

sleep 0.3

echo "" | tee -a "$RESULT_FILE"
echo "=== Phase 4: Test DEX approach (W2 fully with DEX move_resize) ===" | tee -a "$RESULT_FILE"

if $USE_DEX; then
    python3 -c "
import ctypes, ctypes.util, os, time
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display')
    exit(1)

# Full unmap/OR/remap cycle for W2
lib.XUnmapWindow(dpy, $W2_WID)
lib.XFlush(dpy)
time.sleep(0.2)

class XSetWA(ctypes.Structure):
    _fields_ = [('override_redirect', ctypes.c_int)]
attrs = XSetWA(override_redirect=ctypes.c_int(1))
lib.XChangeWindowAttributes(dpy, $W2_WID, 1 << 3, ctypes.byref(attrs))

# Move to right half
lib.XMoveResizeWindow(dpy, $W2_WID, $HALF_W, 0, $HALF_W, $H)
lib.XFlush(dpy)
time.sleep(0.1)

lib.XMapWindow(dpy, $W2_WID)
lib.XFlush(dpy)
lib.XRaiseWindow(dpy, $W2_WID)
lib.XFlush(dpy)
time.sleep(0.3)

class XWindowAttrs(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int), ('depth', ctypes.c_int),
        ('visual', ctypes.c_void_p), ('root', ctypes.c_ulong),
    ]
real_attrs = XWindowAttrs()
lib.XGetWindowAttributes(dpy, $W2_WID, ctypes.byref(real_attrs))
print(f'RESULT: W2 position={real_attrs.x},{real_attrs.y} size={real_attrs.width}x{real_attrs.height}')
lib.XCloseDisplay(dpy)
" 2>&1 | tee -a "$RESULT_FILE"
fi

# Also do DEX approach for W2 if not already done
if ! $USE_DEX; then
    python3 -c "
import ctypes, ctypes.util, os, time
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display')
    exit(1)

lib.XUnmapWindow(dpy, $W2_WID)
lib.XFlush(dpy)
time.sleep(0.2)

class XSetWA(ctypes.Structure):
    _fields_ = [('override_redirect', ctypes.c_int)]
attrs = XSetWA(override_redirect=ctypes.c_int(1))
lib.XChangeWindowAttributes(dpy, $W2_WID, 1 << 3, ctypes.byref(attrs))

lib.XMoveResizeWindow(dpy, $W2_WID, $HALF_W, 0, $HALF_W, $H)
lib.XFlush(dpy)
time.sleep(0.1)

lib.XMapWindow(dpy, $W2_WID)
lib.XFlush(dpy)
lib.XRaiseWindow(dpy, $W2_WID)
lib.XFlush(dpy)
time.sleep(0.3)

class XWindowAttrs(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int), ('depth', ctypes.c_int),
        ('visual', ctypes.c_void_p), ('root', ctypes.c_ulong),
    ]
real_attrs = XWindowAttrs()
lib.XGetWindowAttributes(dpy, $W2_WID, ctypes.byref(real_attrs))
print(f'RESULT: W2 position={real_attrs.x},{real_attrs.y} size={real_attrs.width}x{real_attrs.height}')
lib.XCloseDisplay(dpy)
" 2>&1 | tee -a "$RESULT_FILE"
fi

sleep 0.3

echo "" | tee -a "$RESULT_FILE"
echo "=== Final Geometry ===" | tee -a "$RESULT_FILE"
if $USE_DEX; then
    echo "W1: $(dex_getgeometry "$W1_WID")" | tee -a "$RESULT_FILE"
    echo "W2: $(dex_getgeometry "$W2_WID")" | tee -a "$RESULT_FILE"
else
    echo "W1:" | tee -a "$RESULT_FILE"
    xdotool getwindowgeometry "$W1_WID" 2>/dev/null | tee -a "$RESULT_FILE"
    echo "W2:" | tee -a "$RESULT_FILE"
    xdotool getwindowgeometry "$W2_WID" 2>/dev/null | tee -a "$RESULT_FILE"
fi

# Check if windows have override_redirect set
echo "" | tee -a "$RESULT_FILE"
echo "=== Override Redirect verification ===" | tee -a "$RESULT_FILE"
python3 -c "
import ctypes, ctypes.util, os, sys
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display')
    sys.exit(1)

class XWindowAttrs(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int), ('depth', ctypes.c_int),
        ('visual', ctypes.c_void_p), ('root', ctypes.c_ulong),
        ('class_', ctypes.c_int), ('bit_gravity', ctypes.c_int),
        ('win_gravity', ctypes.c_int), ('backing_store', ctypes.c_int),
        ('backing_planes', ctypes.c_ulong), ('backing_pixel', ctypes.c_ulong),
        ('save_under', ctypes.c_int), ('map_installed', ctypes.c_int),
        ('map_state', ctypes.c_int),
        ('all_event_masks', ctypes.c_ulong), ('your_event_masks', ctypes.c_ulong),
        ('do_not_propagate_mask', ctypes.c_ulong),
        ('override_redirect', ctypes.c_int), ('screen', ctypes.c_void_p),
    ]

for wid_name, wid in [('W1', $W1_WID), ('W2', $W2_WID)]:
    attrs = XWindowAttrs()
    lib.XGetWindowAttributes(dpy, wid, ctypes.byref(attrs))
    print(f'{wid_name}: override_redirect={attrs.override_redirect} map_state={attrs.map_state} pos={attrs.x},{attrs.y} size={attrs.width}x{attrs.height}')

lib.XCloseDisplay(dpy)
" 2>&1 | tee -a "$RESULT_FILE"

# Determine pass/fail
echo "" | tee -a "$RESULT_FILE"
echo "=== RESULT ===" | tee -a "$RESULT_FILE"

# We check via Python
python3 -c "
import ctypes, ctypes.util, os, sys
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy: sys.exit(2)

class XWindowAttrs(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int), ('depth', ctypes.c_int),
        ('visual', ctypes.c_void_p), ('root', ctypes.c_ulong),
        ('class_', ctypes.c_int), ('bit_gravity', ctypes.c_int),
        ('win_gravity', ctypes.c_int), ('backing_store', ctypes.c_int),
        ('backing_planes', ctypes.c_ulong), ('backing_pixel', ctypes.c_ulong),
        ('save_under', ctypes.c_int), ('map_installed', ctypes.c_int),
        ('map_state', ctypes.c_int),
        ('all_event_masks', ctypes.c_ulong), ('your_event_masks', ctypes.c_ulong),
        ('do_not_propagate_mask', ctypes.c_ulong),
        ('override_redirect', ctypes.c_int), ('screen', ctypes.c_void_p),
    ]

try:
    a1 = XWindowAttrs()
    lib.XGetWindowAttributes(dpy, $W1_WID, ctypes.byref(a1))
    a2 = XWindowAttrs()
    lib.XGetWindowAttributes(dpy, $W2_WID, ctypes.byref(a2))
    
    w1_ok = a1.width == $HALF_W or a1.x == 0
    w2_ok = a2.x >= $HALF_W - 10 or a2.width == $HALF_W
    
    if w1_ok and w2_ok:
        result = 'PASS'
    else:
        result = 'FAIL'
    
    print(f'{result}: W1=({a1.x},{a1.y} {a1.width}x{a1.height}) W2=({a2.x},{a2.y} {a2.width}x{a2.height}) Expected W1=(0,0 ${HALF_W}x$H) W2=($HALF_W,0 ${HALF_W}x$H)')
except Exception as e:
    print(f'FAIL: check error: {e}')

lib.XCloseDisplay(dpy)
" 2>&1 | tee -a "$RESULT_FILE"

# Keep the result window visible for 30s when in Game Mode (no terminal)
export RESULT_TEXT=$(tail -1 "$RESULT_FILE")
echo "" | tee -a "$RESULT_FILE"
echo "=== Result written to $RESULT_FILE ===" | tee -a "$RESULT_FILE"
echo "Result: $RESULT_TEXT" | tee -a "$RESULT_FILE"

# Cleanup
sleep 1
kill $W1_PID $W2_PID 2>/dev/null || true
if $USE_TINYWM && [[ -n "$TINYWM_PID" ]]; then
    kill "$TINYWM_PID" 2>/dev/null || true
fi
pkill -f "OVER_REDIRECT_L\|OVER_REDIRECT_R" 2>/dev/null || true
