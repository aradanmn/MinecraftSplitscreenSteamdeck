#!/bin/bash
# =============================================================================
# DEX — Display EXecutive: xdotool replacement for SteamOS (no xdotool pkg)
# =============================================================================
# Uses python3 + ctypes + libX11.so.6 for all X11 window manipulation.
# libX11.so.6 is guaranteed present on any SteamOS with an X11 display.
#
# Public API (all output to stdout, errors to stderr):
#   dex_search --name <pattern>       — stdout: window IDs (one per line)
#   dex_search --pid <pid>            — stdout: window IDs (one per line)
#   dex_getgeometry <wid>             — stdout: "x y w h"
#   dex_move <wid> <x> <y>           — move window to (x,y)
#   dex_resize <wid> <w> <h>         — resize window to w×h
#   dex_move_resize <wid> <x> <y> <w> <h> — move and resize atomically
#   dex_raise <wid>                   — raise window
#   dex_set_name <wid> <name>        — set _NET_WM_NAME
#   dex_set_override_redirect <wid> <0|1> — set override-redirect flag
#   dex_set_fullscreen <wid> <0|1>   — set/clear _NET_WM_STATE_FULLSCREEN
#   dex_set_skip_taskbar <wid> <0|1> — set/clear _NET_WM_STATE_SKIP_TASKBAR
#   dex_get_root_wid                 — stdout: root window ID
#   dex_get_active_wid               — stdout: active window ID (_NET_ACTIVE_WINDOW)
#   dex_set_root_atom <atom_name> <value> — set property on root window
#   dex_get_wm_name <wid>            — stdout: window title
#   dex_list_windows                 — stdout: WID+name pairs for all windows
#   dex_wid_from_state <slot>        — stdout: WID from splitscreen_state.json
#   dex_find_minecraft_windows       — stdout: "WID SLOT" for each SplitscreenP{N}
#   dex_spawn_placeholder <slot> <x> <y> <w> <h> — GTK black placeholder window
#
# Environment:
#   DEX_DISPLAY — override DISPLAY (default: $DISPLAY or :0)
#   DEX_PY_SCRIPT — path to generated Python script (default: /tmp/dex_$$.py)
# =============================================================================

set -euo pipefail

DEX_DISPLAY="${DEX_DISPLAY:-${DISPLAY:-:0}}"
DEX_PY_SCRIPT="${DEX_PY_SCRIPT:-/tmp/dex_$$.py}"

# ============================================================
# Generate the Python backend script once, then call it for each op.
# This avoids heredoc expansion issues and is more efficient.
# ============================================================
_dex_generate_backend() {
    cat > "$DEX_PY_SCRIPT" << 'DEXPYEOF'
#!/usr/bin/env python3
"""DEX Backend — X11 window manipulation via ctypes Xlib.
Usage: dex_backend.py <action> [args...]
Actions: root_wid, list, get_wm_name <wid>, search_name <pattern>,
         search_pid <pid>, getgeometry <wid>, move <wid> <x> <y>,
         resize <wid> <w> <h>, move_resize <wid> <x> <y> <w> <h>,
         raise <wid>, set_name <wid> <name>,
         set_override_redirect <wid> <0|1>,
         set_fullscreen <wid> <0|1>, set_skip_taskbar <wid> <0|1>,
         set_root_atom <name> <value>, get_active_wid,
         find_minecraft, spawn_placeholder <slot> <x> <y> <w> <h>
"""
import ctypes, ctypes.util, sys, os, struct, signal

# ---- Load X11 ----
_lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')

# ---- Types ----
Atom = ctypes.c_ulong
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

CWX = 1 << 0
CWY = 1 << 1
CWWidth = 1 << 2
CWHeight = 1 << 3
CWBorderWidth = 1 << 4

# ---- Open display ----
display_name = os.environ.get('DEX_DISPLAY', os.environ.get('DISPLAY', ':0'))
dpy = _lib.XOpenDisplay(display_name.encode() if isinstance(display_name, str) else display_name)
if not dpy:
    print(f"ERROR: Cannot open display '{display_name}'", file=sys.stderr)
    sys.exit(1)

root = _lib.XDefaultRootWindow(dpy)

# ---- Atom cache ----
_atom_cache = {}
def atom(name):
    if name not in _atom_cache:
        _lib.XInternAtom.restype = Atom
        _atom_cache[name] = _lib.XInternAtom(dpy, name.encode() if isinstance(name, str) else name, Bool(0))
    return _atom_cache[name]

# ---- XGetWindowProperty wrapper ----
XGetWindowProperty = _lib.XGetWindowProperty
XGetWindowProperty.restype = ctypes.c_int
XGetWindowProperty.argtypes = [Display, Window, Atom, ctypes.c_ulong, ctypes.c_ulong,
                                Bool, Atom, ctypes.POINTER(Atom), ctypes.POINTER(ctypes.c_int),
                                ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                ctypes.POINTER(ctypes.c_void_p)]

def get_prop(wid, atom_name):
    a = atom(atom_name)
    actual_type = Atom(0)
    actual_format = ctypes.c_int(0)
    nitems = ctypes.c_ulong(0)
    bytes_after = ctypes.c_ulong(0)
    prop = ctypes.c_void_p(None)
    status = XGetWindowProperty(dpy, Window(wid), a, ctypes.c_ulong(0), ctypes.c_ulong(1024),
                                 Bool(0), Atom(0), ctypes.byref(actual_type),
                                 ctypes.byref(actual_format), ctypes.byref(nitems),
                                 ctypes.byref(bytes_after), ctypes.byref(prop))
    if status != 0 or not prop or not nitems.value:
        return None
    fmt = actual_format.value
    n = nitems.value
    data_ptr = ctypes.cast(prop, ctypes.POINTER(ctypes.c_ubyte))
    result = bytes(data_ptr[:n * fmt // 8])
    _lib.XFree(prop)
    return result

def change_prop32(wid, atom_name, values):
    a = atom(atom_name)
    arr = (ctypes.c_uint32 * len(values))(*values)
    _lib.XChangeProperty(dpy, Window(wid), a, Atom(4), 32, 0,
                          ctypes.cast(arr, ctypes.POINTER(ctypes.c_ubyte)),
                          ctypes.c_int(len(values)))

def change_prop8(wid, atom_name, text):
    a = atom(atom_name)
    b = text.encode('utf-8') if isinstance(text, str) else text
    _lib.XChangeProperty(dpy, Window(wid), a, atom('UTF8_STRING'), 8, 0,
                          ctypes.cast(ctypes.create_string_buffer(b), ctypes.POINTER(ctypes.c_ubyte)),
                          ctypes.c_int(len(b)))

# ---- XQueryTree ----
def query_tree(wid):
    root_ret = Window(0)
    parent_ret = Window(0)
    children = ctypes.POINTER(Window)()
    nchildren = ctypes.c_int(0)
    _lib.XQueryTree(dpy, Window(wid),
                     ctypes.byref(root_ret), ctypes.byref(parent_ret),
                     ctypes.byref(children), ctypes.byref(nchildren))
    result = [children[i] for i in range(nchildren.value)]
    if children:
        _lib.XFree(children)
    return result

def get_wm_name(wid):
    prop = get_prop(wid, '_NET_WM_NAME')
    if prop:
        return prop.decode('utf-8', errors='replace')
    prop = get_prop(wid, 'WM_NAME')
    if prop:
        return prop.decode('utf-8', errors='replace')
    return ''

def get_pid(wid):
    prop = get_prop(wid, '_NET_WM_PID')
    if prop and len(prop) >= 4:
        return struct.unpack('<I', prop[:4])[0]
    return None

# ---- Actions ----
def action_root_wid():
    print(root)

def action_list():
    def recurse(w, depth=0):
        name = get_wm_name(w)
        print(f"{w}  {name}")
        for c in query_tree(w):
            recurse(c, depth+1)
    recurse(root)

def action_get_wm_name(args):
    print(get_wm_name(int(args[0])))

def action_search_name(args):
    pattern = args[0]
    def recurse(w):
        if pattern in get_wm_name(w):
            print(w)
        for c in query_tree(w):
            recurse(c)
    recurse(root)

def action_search_pid(args):
    target = int(args[0])
    def recurse(w):
        pid = get_pid(w)
        if pid == target:
            print(w)
        for c in query_tree(w):
            recurse(c)
    recurse(root)

def action_getgeometry(args):
    wid = int(args[0])
    attrs = XWindowAttributes()
    _lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(attrs))
    print(f"{attrs.x} {attrs.y} {attrs.width} {attrs.height}")

def action_move(args):
    wid, x, y = int(args[0]), int(args[1]), int(args[2])
    ch = XWindowChanges(x=x, y=y)
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(CWX | CWY), ctypes.byref(ch))
    _lib.XFlush(dpy)

def action_resize(args):
    wid, w, h = int(args[0]), int(args[1]), int(args[2])
    attrs = XWindowAttributes()
    _lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(attrs))
    ch = XWindowChanges(width=w, height=h)
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(CWWidth | CWHeight), ctypes.byref(ch))
    _lib.XFlush(dpy)

def action_move_resize(args):
    wid, x, y, w, h = int(args[0]), int(args[1]), int(args[2]), int(args[3]), int(args[4])
    ch = XWindowChanges(x=x, y=y, width=w, height=h, border_width=0)
    mask = CWX | CWY | CWWidth | CWHeight | CWBorderWidth
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(mask), ctypes.byref(ch))
    _lib.XFlush(dpy)

def action_move_resize_force(args):
    \"\"\"Try multiple approaches to position a window in gamescope's XWayland.
    Strategy:
    1. XMoveResizeWindow (high-level, may bypass some filters)
    2. XConfigureWindow with override_redirect set (bypass WM)
    3. XConfigureWindow (standard dex.sh approach, always works on KWin)
    Returns the approach number that succeeded, or 0 if all failed.
    \"\"\"
    wid, x, y, w, h = int(args[0]), int(args[1]), int(args[2]), int(args[3]), int(args[4])

    def _read_geo():
        \"\"\"Read actual window geometry via XGetWindowAttributes.\"\"\"
        attrs = XWindowAttributes()
        ret = _lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(attrs))
        if ret == 0:
            return None
        return (attrs.x, attrs.y, attrs.width, attrs.height)

    def _geo_ok():
        \"\"\"Check if the window is now at the target geometry (within tolerance).\"\"\"
        g = _read_geo()
        if g is None:
            return False
        gx, gy, gw, gh = g
        # Allow 1-pixel tolerance for rounding
        return (abs(gx - x) <= 1 and abs(gy - y) <= 1 and
                abs(gw - w) <= 1 and abs(gh - h) <= 1)

    # Strategy 1: XMoveResizeWindow (higher-level Xlib call)
    _lib.XMoveResizeWindow(dpy, Window(wid), x, y, w, h)
    _lib.XFlush(dpy)
    _lib.XSync(dpy, 0)
    if _geo_ok():
        print(1)
        return

    # Strategy 2: Set override_redirect, then XConfigureWindow
    class XSetWA(ctypes.Structure):
        _fields_ = [('override_redirect', Bool)]
    attrs = XSetWA(override_redirect=Bool(1))
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(1 << 3), ctypes.byref(attrs))
    _lib.XFlush(dpy)

    ch = XWindowChanges(x=x, y=y, width=w, height=h, border_width=0)
    mask = CWX | CWY | CWWidth | CWHeight | CWBorderWidth
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(mask), ctypes.byref(ch))
    _lib.XFlush(dpy)
    _lib.XSync(dpy, 0)
    if _geo_ok():
        print(2)
        return

    # Strategy 3: XConfigureWindow without overrideredirect (standard)
    # Clear override_redirect first
    attrs2 = XSetWA(override_redirect=Bool(0))
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(1 << 3), ctypes.byref(attrs2))
    _lib.XFlush(dpy)

    ch = XWindowChanges(x=x, y=y, width=w, height=h, border_width=0)
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(mask), ctypes.byref(ch))
    _lib.XFlush(dpy)
    _lib.XSync(dpy, 0)
    if _geo_ok():
        print(3)
        return

    # All failed
    print(0)

def action_raise_win(args):
    wid = int(args[0])
    _lib.XRaiseWindow(dpy, Window(wid))
    _lib.XFlush(dpy)

def action_set_name(args):
    wid, name = int(args[0]), args[1]
    change_prop8(wid, '_NET_WM_NAME', name)
    change_prop8(wid, 'WM_NAME', name)
    _lib.XFlush(dpy)

def action_set_override_redirect(args):
    wid, val = int(args[0]), int(args[1])
    class XSetWA(ctypes.Structure):
        _fields_ = [('override_redirect', Bool)]
    attrs = XSetWA(override_redirect=Bool(val))
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(1 << 3), ctypes.byref(attrs))
    _lib.XFlush(dpy)

def _send_client_msg(wid, msg_type, data0, data1, data2, data3, data4):
    """Send a ClientMessage event to the root window."""
    # Use raw ctypes to build the event
    buf = ctypes.create_string_buffer(60)  # sizeof(XClientMessageEvent) = 60
    # type (int) at offset 0
    ctypes.memmove(buf, ctypes.byref(ctypes.c_int(33)), 4)
    # serial (ulong) at offset 4 (ignored)
    # send_event (Bool) at offset 8+4 depending on alignment
    # window (Window=ulong) at offset... depends on arch
    # Simpler: use XSendEvent with properly packed data
    ev_buf = struct.pack(
        '=i4xI' + ('I' if ctypes.sizeof(ctypes.c_ulong) == 4 else 'Q') + '4x5I',
        33,  # type = ClientMessage
        0,   # serial (unused)
        wid,  # window
        msg_type, data0, data1, data2, data3, data4
    )
    # Actually let's just use the simple approach - XChangeProperty instead
    # of ClientMessage for _NET_WM_STATE
    pass

def action_set_fullscreen(args):
    wid, val = int(args[0]), int(args[1])
    state_atom = atom('_NET_WM_STATE_FULLSCREEN')
    net_wm_state = atom('_NET_WM_STATE')
    action = 1 if val else 0  # _NET_WM_STATE_ADD or _NET_WM_STATE_REMOVE
    # Write via XChangeProperty on the window
    arr = (ctypes.c_uint32 * 5)(action, state_atom, 0, 0, 0)
    _lib.XChangeProperty(dpy, Window(wid), net_wm_state, Atom(4), 32, 0,
                          ctypes.cast(arr, ctypes.POINTER(ctypes.c_ubyte)),
                          ctypes.c_int(1))  # just 1 element
    _lib.XFlush(dpy)

def action_set_skip_taskbar(args):
    wid, val = int(args[0]), int(args[1])
    state_atom = atom('_NET_WM_STATE_SKIP_TASKBAR')
    net_wm_state = atom('_NET_WM_STATE')
    action = 1 if val else 0
    arr = (ctypes.c_uint32 * 5)(action, state_atom, 0, 0, 0)
    _lib.XChangeProperty(dpy, Window(wid), net_wm_state, Atom(4), 32, 0,
                          ctypes.cast(arr, ctypes.POINTER(ctypes.c_ubyte)),
                          ctypes.c_int(1))
    _lib.XFlush(dpy)

def action_set_root_atom(args):
    name, value = args[0], int(args[1])
    change_prop32(root, name, [value])
    _lib.XFlush(dpy)

def action_get_active_wid(args):
    prop = get_prop(root, '_NET_ACTIVE_WINDOW')
    if prop and len(prop) >= 4:
        wid = struct.unpack('<I' if ctypes.sizeof(ctypes.c_ulong) == 4 else '<Q', prop[:8])[0]
        if wid:
            print(wid)

def action_find_minecraft(args):
    def recurse(w):
        name = get_wm_name(w)
        for slot in ['1','2','3','4']:
            if f'SplitscreenP{slot}' in name:
                print(f"{w} {slot}")
        for c in query_tree(w):
            recurse(c)
    recurse(root)

def action_spawn_placeholder(args):
    """Spawn a GTK black placeholder window. Runs in foreground."""
    slot, x, y, w, h = args[0], int(args[1]), int(args[2]), int(args[3]), int(args[4])
    # Fork a child to run GTK
    pid = os.fork()
    if pid == 0:
        # Child: spawn GTK window
        try:
            import gi
            gi.require_version('Gtk', '3.0')
            from gi.repository import Gtk, Gdk, GLib
            win = Gtk.Window()
            win.set_decorated(False)
            win.set_default_size(w, h)
            win.move(x, y)
            win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0, 1))
            win.set_title(f'SplitscreenBlack{slot}')
            win.show_all()
            Gtk.main()
        except Exception as e:
            print(f"GTK placeholder failed: {e}", file=sys.stderr)
            os._exit(1)
        os._exit(0)
    else:
        # Parent: print the PID so caller can track it
        print(pid)

# ---- Dispatch ----
ACTIONS = {
    'root_wid': action_root_wid,
    'list': action_list,
    'get_wm_name': action_get_wm_name,
    'search_name': action_search_name,
    'search_pid': action_search_pid,
    'getgeometry': action_getgeometry,
    'move': action_move,
    'resize': action_resize,
    'move_resize': action_move_resize,
    'move_resize_force': action_move_resize_force,
    'raise': action_raise_win,
    'set_name': action_set_name,
    'set_override_redirect': action_set_override_redirect,
    'set_fullscreen': action_set_fullscreen,
    'set_skip_taskbar': action_set_skip_taskbar,
    'set_root_atom': action_set_root_atom,
    'get_active_wid': action_get_active_wid,
    'find_minecraft': action_find_minecraft,
    'spawn_placeholder': action_spawn_placeholder,
}

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <action> [args...]", file=sys.stderr)
    print(f"Actions: {', '.join(sorted(ACTIONS.keys()))}", file=sys.stderr)
    sys.exit(1)

action_name = sys.argv[1]
action_args = sys.argv[2:]

if action_name in ACTIONS:
    ACTIONS[action_name](action_args)
else:
    print(f"Unknown action: {action_name}", file=sys.stderr)
    sys.exit(1)

_lib.XCloseDisplay(dpy)
DEXPYEOF
    chmod +x "$DEX_PY_SCRIPT"
}

# Ensure backend exists
if [[ ! -f "$DEX_PY_SCRIPT" ]]; then
    _dex_generate_backend
fi

# ---- Run an action ----
_dex_run() {
    DEX_DISPLAY="$DEX_DISPLAY" python3 "$DEX_PY_SCRIPT" "$@"
}

# ============================================================
# Public API Functions
# ============================================================

dex_search() {
    local mode="$1" value="$2"
    case "$mode" in
        --name) _dex_run search_name "$value" ;;
        --pid)  _dex_run search_pid "$value"  ;;
        *)      echo "Usage: dex_search --name <pattern> | --pid <pid>" >&2; return 1 ;;
    esac
}

dex_getgeometry() { _dex_run getgeometry "$1"; }
dex_move()       { _dex_run move "$1" "$2" "$3"; }
dex_resize()     { _dex_run resize "$1" "$2" "$3"; }
dex_move_resize(){ _dex_run move_resize "$1" "$2" "$3" "$4" "$5"; }
dex_move_resize_force(){ _dex_run move_resize_force "$1" "$2" "$3" "$4" "$5"; }
dex_raise()      { _dex_run raise "$1"; }
dex_set_name()   { _dex_run set_name "$1" "$2"; }
dex_set_override_redirect() { _dex_run set_override_redirect "$1" "$2"; }
dex_set_fullscreen() { _dex_run set_fullscreen "$1" "$2"; }
dex_set_skip_taskbar() { _dex_run set_skip_taskbar "$1" "$2"; }
dex_get_root_wid() { _dex_run root_wid; }
dex_get_active_wid() { _dex_run get_active_wid; }
dex_set_root_atom() { _dex_run set_root_atom "$1" "$2"; }
dex_get_wm_name() { _dex_run get_wm_name "$1"; }
dex_list_windows() { _dex_run list; }
dex_find_minecraft_windows() { _dex_run find_minecraft; }
dex_spawn_placeholder() {
    local slot="$1" x="$2" y="$3" w="$4" h="$5"
    _dex_run spawn_placeholder "$slot" "$x" "$y" "$w" "$h"
}

dex_wid_from_state() {
    local slot="$1"
    local sf="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    if [[ -f "$sf" ]] && command -v jq >/dev/null 2>&1; then
        jq -r ".slots[\"${slot}\"].wid // empty" "$sf" 2>/dev/null || true
    fi
}

# Cleanup generated script on exit
_dex_cleanup() {
    rm -f "$DEX_PY_SCRIPT"
}
trap _dex_cleanup EXIT

# If run directly, show help
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "DEX — Display EXecutive (xdotool replacement)"
    echo "Source this file: source modules/dex.sh"
    echo "Then use: dex_search, dex_move, dex_resize, dex_move_resize, etc."
    echo ""
    echo "For direct backend access: DEX_DISPLAY=:0 python3 /tmp/dex_backend.py <action> [args...]"
fi
