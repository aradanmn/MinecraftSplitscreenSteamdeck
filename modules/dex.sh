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
#   dex_move_resize_remap <wid> <x> <y> <w> <h> — unmap/reparent/remap move,
#                                        stdout: "x y w h" readback
#   dex_set_name <wid> <name>        — set _NET_WM_NAME
#   dex_set_decorations <wid> <0|1>  — toggle WM decorations
#   dex_is_viewable <wid>            — stdout: viewable|unmapped|gone
#   dex_map_raise <wid>              — map + raise, no unmap/reparent cycle
#   dex_list_windows                 — stdout: WID+name pairs for all windows
#
# Fix #90: dex_move/dex_resize/dex_raise/dex_get_root_wid/dex_get_active_wid/
# dex_set_root_atom/dex_get_wm_name/dex_find_minecraft_windows deleted — zero
# references in runtime modules or tests/ (verified by repo-wide grep before
# deleting). dex_move_resize/dex_move_resize_force/dex_set_override_redirect
# are test-only (gamescope-*-test.sh) — kept, not part of the runtime API
# above, see each wrapper's comment near its definition.
#
# Environment:
#   DEX_DISPLAY — override DISPLAY (default: $MCSS_DISPLAY, then $DISPLAY, then :0)
#   DEX_PY_SCRIPT — path to generated Python script
#                   (default: $XDG_RUNTIME_DIR/dex_$$.py, falling back to /tmp/dex_$$.py)
#
# Globals CONSUMED (set elsewhere, read here):
#   MCSS_DISPLAY   — from mcss_set_display (runtime_context.sh), call-time
#   DEX_DISPLAY, DEX_PY_SCRIPT — env overrides, documented above
#
# Inputs:  libX11.so.6 via python3+ctypes, the X11 display.
# Outputs: window IDs / geometry to stdout; usage/arg errors to stderr
#          UNPREFIXED (no `[dex] ` tag — deviates from the §7.10 module
#          logging convention; comments-only scope, flagged, not fixed here);
#          the generated Python script under $XDG_RUNTIME_DIR (or /tmp).
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.4 2026-07-17  Fix #90: API trim — 8 zero-reference dex_* wrappers gone
#   v1.3 2026-07-09  #45: no source-time DISPLAY capture; helper off /tmp
#   v1.2 2026-07-06  #19/#28: backend temp-file lifecycle; Java-25/MC-26.x
#   v1.1 2026-06-23  Windowing fixes: reparent-to-root move, borderless toggle
#   v1.0 2026-06-17  Initial ctypes X11 backend (xdotool replacement)
# =============================================================================

set -euo pipefail

# #45: NO source-time DISPLAY capture (latent bug: dex sources before the
# nested Xwayland exists, freezing :0/stale DISPLAY into every later call).
# Resolution happens at call time in _dex_run: explicit DEX_DISPLAY override,
# else MCSS_DISPLAY (set by mcss_set_display once the nested X socket is
# confirmed up), else the ambient DISPLAY, else :0.
# Prefer $XDG_RUNTIME_DIR (per-session tmpfs, auto-removed by systemd on logout) over
# /tmp so the generated backend doesn't leak on crash — the cleanup is not EXIT-trapped
# by design (the script must survive across many dex invocations in one shell). M7.
# #19: stable per-UID name (was per-PID dex_$$.py) — every sourcing process
# minted its own file and nothing reaped the /tmp fallback copies (EXIT traps
# are off-limits here, see _dex_cleanup). One shared file per user, written
# atomically, regenerated on every source and on demand if a cleanup removed it.
DEX_PY_SCRIPT="${DEX_PY_SCRIPT:-${XDG_RUNTIME_DIR:-/tmp}/dex_backend_${UID}.py}"

# _dex_generate_backend: (Re)write the generated Python backend script once,
# so each dex_* call just invokes it — avoids heredoc-expansion issues and is
# more efficient than regenerating per-call.
# NOTE: do NOT edit inside the DEXPYEOF heredoc below (runtime Python data).
# Inputs: Globals: DEX_PY_SCRIPT (read/write — the destination path)
# Outputs:
#   return — 0 on success, 1 if mktemp fails
#   side effects — atomically (mktemp+mv) (re)writes+chmods DEX_PY_SCRIPT
_dex_generate_backend() {
    # #19: atomic — a concurrent _dex_run keeps reading the old inode.
    local _tmp
    _tmp=$(mktemp "${DEX_PY_SCRIPT}.XXXXXX") || return 1
    cat > "$_tmp" << 'DEXPYEOF'
#!/usr/bin/env python3
"""DEX Backend — X11 window manipulation via ctypes Xlib.
Usage: dex_backend.py <action> [args...]
Actions: list, search_name <pattern>, search_pid <pid>, getgeometry <wid>,
         move_resize_remap <wid> <x> <y> <w> <h>, set_name <wid> <name>,
         set_decorations <wid> <0|1>, is_viewable <wid>, map_raise <wid>.
         move_resize <wid> <x> <y> <w> <h>, move_resize_force <wid> <x> <y>
         <w> <h>, and set_override_redirect <wid> <0|1> also exist but are
         test-only (see gamescope-*-test.sh) — not part of the runtime API.
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

# override_redirect is the 13th field of XSetWindowAttributes (NOT the first), and
# its change-mask bit is CWOverrideRedirect (1<<9). The old code used a 1-field
# struct + mask 1<<3 (CWBorderPixel), so it never actually changed override_redirect.
CWOverrideRedirect = 1 << 9

class XSetWindowAttributes(ctypes.Structure):
    _fields_ = [
        ('background_pixmap', ctypes.c_ulong), ('background_pixel', ctypes.c_ulong),
        ('border_pixmap', ctypes.c_ulong),     ('border_pixel', ctypes.c_ulong),
        ('bit_gravity', ctypes.c_int),         ('win_gravity', ctypes.c_int),
        ('backing_store', ctypes.c_int),       ('backing_planes', ctypes.c_ulong),
        ('backing_pixel', ctypes.c_ulong),     ('save_under', Bool),
        ('event_mask', ctypes.c_long),         ('do_not_propagate_mask', ctypes.c_long),
        ('override_redirect', Bool),           ('colormap', ctypes.c_ulong),
        ('cursor', ctypes.c_ulong),
    ]

# ---- Open display ----
# CRITICAL: ctypes defaults every C return value to 32-bit c_int. On 64-bit that
# truncates the Display* from XOpenDisplay into a garbage pointer, so every X call
# then operates on junk and silently no-ops — this is why dex "didn't work". Set
# restype=c_void_p and wrap dpy as a typed pointer instance so it passes 64-bit-safe
# to every call (the call sites already wrap their other args as Window()/byref()).
display_name = os.environ.get('DEX_DISPLAY', os.environ.get('DISPLAY', ':0'))
_lib.XOpenDisplay.restype = ctypes.c_void_p
_dpy = _lib.XOpenDisplay(display_name.encode() if isinstance(display_name, str) else display_name)
if not _dpy:
    print(f"ERROR: Cannot open display '{display_name}'", file=sys.stderr)
    sys.exit(1)
dpy = ctypes.c_void_p(_dpy)

_lib.XDefaultRootWindow.restype = Window
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
    # Xlib treats format-32 property data as an array of C `long` (8 bytes on
    # 64-bit), NOT 32-bit ints — it reads sizeof(long) per element. A c_uint32
    # array (4-byte stride) under-allocates and lands each value in the wrong
    # half-word. Use c_long so the stride matches what XChangeProperty reads. N9.
    arr = (ctypes.c_long * len(values))(*values)
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
# Fix #90: action_root_wid/action_get_wm_name removed (backed dex_get_root_wid
# /dex_get_wm_name, both zero-reference). The plain get_wm_name() helper stays
# — action_list/action_search_name still use it.
def action_list(args=None):
    def recurse(w, depth=0):
        name = get_wm_name(w)
        print(f"{w}  {name}")
        for c in query_tree(w):
            recurse(c, depth+1)
    recurse(root)

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

# Fix #90: action_move/action_resize removed (backed dex_move/dex_resize,
# both zero-reference). action_move_resize stays — test-only, see the
# dex_move_resize wrapper comment below.
def action_move_resize(args):
    wid, x, y, w, h = int(args[0]), int(args[1]), int(args[2]), int(args[3]), int(args[4])
    ch = XWindowChanges(x=x, y=y, width=w, height=h, border_width=0)
    mask = CWX | CWY | CWWidth | CWHeight | CWBorderWidth
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(mask), ctypes.byref(ch))
    _lib.XFlush(dpy)

def action_move_resize_force(args):
    """Try multiple approaches to position a window in gamescope's XWayland.
    Strategy:
    1. XMoveResizeWindow (high-level, may bypass some filters)
    2. XConfigureWindow with override_redirect set (bypass WM)
    3. XConfigureWindow (standard dex.sh approach, always works on KWin)
    Returns the approach number that succeeded, or 0 if all failed.
    """
    wid, x, y, w, h = int(args[0]), int(args[1]), int(args[2]), int(args[3]), int(args[4])

    def _read_geo():
        """Read actual window geometry via XGetWindowAttributes."""
        attrs = XWindowAttributes()
        ret = _lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(attrs))
        if ret == 0:
            return None
        return (attrs.x, attrs.y, attrs.width, attrs.height)

    def _geo_ok():
        """Check if the window is now at the target geometry (within tolerance)."""
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
    attrs = XSetWindowAttributes(override_redirect=1)
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(CWOverrideRedirect), ctypes.byref(attrs))
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
    attrs2 = XSetWindowAttributes(override_redirect=0)
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(CWOverrideRedirect), ctypes.byref(attrs2))
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

def action_move_resize_remap(args):
    """Place a (WM-managed) window as override_redirect and actually MOVE it:
    unmap -> set override_redirect -> REPARENT to root at (x,y) -> size/re-assert ->
    map -> raise -> re-assert move/resize -> readback.

    Why reparent-to-root (the fix for "the move doesn't take"): KWin reparents
    managed windows into a decoration frame.  Unmapping + setting override_redirect
    does NOT pull the client back out of that frame, so a plain XConfigureWindow's
    x/y are interpreted relative to the (stale) frame and don't move the window on
    screen — only same-position resizes appeared to work, while any re-tile that
    changed x/y (slot 2 half-bottom -> quad top-right, or a survivor going fullscreen
    on scale-down) silently no-op'd.  XReparentWindow(root, x, y) detaches the client
    from KWin's frame AND positions it at root coordinates, so the move takes.  Set
    override_redirect FIRST so KWin won't re-manage it after the reparent; the
    post-map XMoveResizeWindow re-asserts geometry as insurance.  Readback (now
    parent==root) is true screen coordinates."""
    wid, x, y, w, h = int(args[0]), int(args[1]), int(args[2]), int(args[3]), int(args[4])
    # 1. Unmap so KWin releases management.
    _lib.XUnmapWindow(dpy, Window(wid))
    _lib.XSync(dpy, 0)
    # 2. Become override_redirect (unmanaged) so KWin won't re-frame/re-manage it.
    attrs = XSetWindowAttributes(override_redirect=1)
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(CWOverrideRedirect), ctypes.byref(attrs))
    _lib.XSync(dpy, 0)
    # 3. Detach from KWin's decoration frame and place at root (x, y).  THE FIX:
    #    frame-relative x/y from XConfigureWindow were being clobbered; reparenting
    #    to root with the target coords makes the window actually move.
    _lib.XReparentWindow(dpy, Window(wid), root, x, y)
    _lib.XSync(dpy, 0)
    # 4. Set size (and re-assert position) while unmapped, now that parent == root.
    ch = XWindowChanges(x=x, y=y, width=w, height=h, border_width=0)
    mask = CWX | CWY | CWWidth | CWHeight | CWBorderWidth
    _lib.XConfigureWindow(dpy, Window(wid), ctypes.c_uint(mask), ctypes.byref(ch))
    _lib.XSync(dpy, 0)
    # 5. Remap (unmanaged, at root) + raise.
    _lib.XMapWindow(dpy, Window(wid))
    _lib.XRaiseWindow(dpy, Window(wid))
    _lib.XSync(dpy, 0)
    # 6. Re-assert geometry once mapped (insurance against any map-time reset).
    _lib.XMoveResizeWindow(dpy, Window(wid), x, y, w, h)
    _lib.XSync(dpy, 0)
    # 7. Geometry readback for the caller (root-relative == true screen coords now).
    a = XWindowAttributes()
    if _lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(a)) != 0:
        print(f"{a.x} {a.y} {a.width} {a.height}")

# Fix #90: action_raise_win removed (backed dex_raise, zero-reference).
def action_set_name(args):
    wid, name = int(args[0]), args[1]
    change_prop8(wid, '_NET_WM_NAME', name)
    change_prop8(wid, 'WM_NAME', name)
    _lib.XFlush(dpy)

def action_set_override_redirect(args):
    wid, val = int(args[0]), int(args[1])
    attrs = XSetWindowAttributes(override_redirect=val)
    _lib.XChangeWindowAttributes(dpy, Window(wid), ctypes.c_ulong(CWOverrideRedirect), ctypes.byref(attrs))
    _lib.XFlush(dpy)

# Fix #90: action_set_root_atom/action_get_active_wid/action_find_minecraft
# removed (backed dex_set_root_atom/dex_get_active_wid/
# dex_find_minecraft_windows, all zero-reference).

def action_set_decorations(args):
    """Toggle WM decorations (title bar/border) via _MOTIF_WM_HINTS.
    args: <wid> <0|1>  (0 = borderless / no decorations, 1 = decorated).
    This is the standard X way to request borderless. KWin honours the property
    change in its normal event loop (no synchronous decoration recreate), so unlike
    KWin-scripting w.noBorder it does NOT block/hang the caller. _MOTIF_WM_HINTS is
    5 longs [flags, functions, decorations, input_mode, status];
    flags = MWM_HINTS_DECORATIONS (1<<1 = 2)."""
    wid = int(args[0])
    decorated = int(args[1]) if len(args) > 1 else 0
    a = atom('_MOTIF_WM_HINTS')
    # format-32 data is read by Xlib as C `long` (8 bytes on 64-bit). A c_uint32
    # array (4-byte stride) made XChangeProperty over-read 20 bytes past the buffer
    # and scattered [flags, 0, decorations, 0, 0] across the wrong MWM fields. Use
    # c_long so the 5-long payload [flags=2, 0, decorations, 0, 0] lands correctly. N9.
    vals = [2, 0, (1 if decorated else 0), 0, 0]
    arr = (ctypes.c_long * 5)(*vals)
    _lib.XChangeProperty(dpy, Window(wid), a, a, 32, 0,
                         ctypes.cast(arr, ctypes.POINTER(ctypes.c_ubyte)), ctypes.c_int(5))
    _lib.XFlush(dpy)

def action_is_viewable(args):
    """Print the window's visibility: 'viewable' (mapped + on screen), 'unmapped'
    (never mapped or mapped-away), or 'gone' (window no longer exists). map_state:
    0=IsUnmapped, 1=IsUnviewable, 2=IsViewable. Used by the map-keeper (#57) to spot a
    window the game unmapped during its own late startup so it can be re-shown."""
    wid = int(args[0])
    a = XWindowAttributes()
    if _lib.XGetWindowAttributes(dpy, Window(wid), ctypes.byref(a)) == 0:
        print("gone")            # XGetWindowAttributes failed → window destroyed
        return
    print("viewable" if a.map_state == 2 else "unmapped")

def action_map_raise(args):
    """Plain XMapWindow + XRaiseWindow — the gentle 'just show it' with no unmap /
    override_redirect / reparent cycle. Used by the map-keeper to re-show a window the
    game unmapped AFTER apply_layout already positioned it (#57), without disturbing the
    geometry already set."""
    wid = int(args[0])
    _lib.XMapWindow(dpy, Window(wid))
    _lib.XRaiseWindow(dpy, Window(wid))
    _lib.XSync(dpy, 0)

# ---- Dispatch ----
# Fix #90: root_wid/get_wm_name/move/resize/raise/set_root_atom/
# get_active_wid/find_minecraft removed — their dex_* shell wrappers had
# zero references anywhere in the repo. move_resize/move_resize_force/
# set_override_redirect stay (test-only, see the dex_* wrapper comments
# below); everything else here backs a runtime-used dex_* function.
ACTIONS = {
    'list': action_list,
    'search_name': action_search_name,
    'search_pid': action_search_pid,
    'getgeometry': action_getgeometry,
    'move_resize': action_move_resize,
    'move_resize_force': action_move_resize_force,
    'move_resize_remap': action_move_resize_remap,
    'set_name': action_set_name,
    'set_override_redirect': action_set_override_redirect,
    'set_decorations': action_set_decorations,
    'is_viewable': action_is_viewable,
    'map_raise': action_map_raise,
}

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <action> [args...]", file=sys.stderr)
    print(f"Actions: {', '.join(sorted(ACTIONS.keys()))}", file=sys.stderr)
    sys.exit(1)

action_name = sys.argv[1]
action_args = sys.argv[2:]

if action_name in ACTIONS:
    # Central guard for the whole action family: a short arg list (IndexError) or a
    # non-numeric wid/coord (ValueError) becomes a clean usage error + nonzero exit
    # instead of an opaque Python traceback (audit H2 / L3). Callers already tolerate
    # nonzero dex exits (|| true), so this fails safe.
    try:
        ACTIONS[action_name](action_args)
    except (IndexError, ValueError) as e:
        print(f"dex: bad or missing arguments for '{action_name}': {e}", file=sys.stderr)
        sys.exit(2)
else:
    print(f"Unknown action: {action_name}", file=sys.stderr)
    sys.exit(1)

_lib.XCloseDisplay(dpy)
DEXPYEOF
    chmod +x "$_tmp"
    mv -f "$_tmp" "$DEX_PY_SCRIPT"
}

# Always (re)generate at source time: the path is shared per-UID, so a stale
# copy from an older code version must not survive an update (#19). The write
# is atomic (mktemp+mv in _dex_generate_backend), so concurrent sourcing is safe.
_dex_generate_backend

# _dex_run: Invoke the generated Python backend for one action, resolving
# DISPLAY at CALL TIME (never source time — see the module header's #45 note).
# Inputs:
#   $@ — action name + its args, forwarded to dex_backend.py
#   Globals: DEX_DISPLAY, MCSS_DISPLAY, DISPLAY (read, in override order)
# Outputs: stdout/return — whatever the invoked action produces (see the
#          module header's Public API table for each action's contract)
_dex_run() {
    # #19: the per-UID backend is shared; another run's cleanup may have removed it.
    [[ -f "$DEX_PY_SCRIPT" ]] || _dex_generate_backend
    DEX_DISPLAY="${DEX_DISPLAY:-${MCSS_DISPLAY:-${DISPLAY:-:0}}}" python3 "$DEX_PY_SCRIPT" "$@"
}

# ============================================================
# Public API Functions
# ============================================================

# dex_search: Search windows by name substring or owning PID.
# Inputs: $1 — "--name" or "--pid"; $2 — pattern or PID value
# Outputs: stdout — matching window IDs, one per line; return 1 on bad usage
dex_search() {
    local mode="$1" value="$2"
    case "$mode" in
        --name) _dex_run search_name "$value" ;;
        --pid)  _dex_run search_pid "$value"  ;;
        *)      echo "Usage: dex_search --name <pattern> | --pid <pid>" >&2; return 1 ;;
    esac
}

# dex_getgeometry: stdout — "$1"'s geometry as "x y w h".
dex_getgeometry() { _dex_run getgeometry "$1"; }
# Fix #90: dex_move/dex_resize/dex_raise/dex_get_root_wid/dex_get_active_wid/
# dex_set_root_atom/dex_get_wm_name/dex_find_minecraft_windows deleted —
# zero references anywhere in the repo (runtime modules or tests/), verified
# by grep before deleting. Their python backend actions are deleted below too.
#
# dex_move_resize: Move+resize $1 to ($2,$3,$4,$5) via XConfigureWindow (no
# unmap/reparent cycle). stdout: none.
# test-only (see tests/gamescope-override-redirect-test.sh,
# tests/gamescope-dex-test.sh); not part of the runtime surface (#90).
dex_move_resize(){ _dex_run move_resize "$1" "$2" "$3" "$4" "$5"; }
# dex_move_resize_force: Try 3 progressively more forceful strategies to move
# $1 to ($2,$3,$4,$5). stdout: the strategy number that succeeded, or 0.
# test-only (see tests/gamescope-dex-test.sh); not part of the runtime
# surface (#90).
dex_move_resize_force(){ _dex_run move_resize_force "$1" "$2" "$3" "$4" "$5"; }
# dex_move_resize_remap: unmap/override_redirect/reparent-to-root/remap move
# of $1 to ($2,$3,$4,$5) — see action_move_resize_remap for why. stdout:
# post-move readback "x y w h".
dex_move_resize_remap(){ _dex_run move_resize_remap "$1" "$2" "$3" "$4" "$5"; }
# Fix #57: is-mapped probe + gentle map/raise for the map-keeper.
# dex_is_viewable: stdout — "viewable"|"unmapped"|"gone" for $1.
dex_is_viewable() { _dex_run is_viewable "$1"; }
# dex_map_raise: Map + raise $1 (no unmap/reparent cycle). stdout: none.
dex_map_raise()   { _dex_run map_raise "$1"; }
# dex_set_name: Set $1's _NET_WM_NAME/WM_NAME to $2.
dex_set_name()   { _dex_run set_name "$1" "$2"; }
# dex_set_override_redirect: Set $1's override_redirect attribute to $2 (0|1).
# test-only (see tests/gamescope-override-redirect-test.sh); not part of the
# runtime surface (#90).
dex_set_override_redirect() { _dex_run set_override_redirect "$1" "$2"; }
# dex_set_decorations: Toggle WM decorations on $1 ($2: 0=borderless
# default, 1=decorated) via _MOTIF_WM_HINTS.
dex_set_decorations() { _dex_run set_decorations "$1" "${2:-0}"; }
# dex_list_windows: stdout — "<wid>  <name>" pairs for every window.
dex_list_windows() { _dex_run list; }

# (dex_wid_from_state deleted — Fix #51 (D12): it was a fallback-less copy of
# window_manager's _get_wid_from_state with zero callers; the state read now
# lives in instance_lifecycle's get_window_id accessor.)

# _dex_cleanup: Remove the generated backend script (DEX_PY_SCRIPT).
# NOTE: deliberately NOT auto-trapped on EXIT. dex.sh is sourced as a library by
# the orchestrator (minecraftSplitscreen.sh), and `trap ... EXIT` here would
# REPLACE the sourcing script's own EXIT trap (kwin teardown + session-env
# restore), reintroducing the black-screen/leak bugs. The backend lives at a
# per-PID path under /tmp and is reaped on reboot; callers may invoke
# _dex_cleanup manually if they want to remove it sooner.
_dex_cleanup() {
    rm -f "$DEX_PY_SCRIPT"
}

# If run directly, show help
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "DEX — Display EXecutive (xdotool replacement)"
    echo "Source this file: source modules/dex.sh"
    echo "Then use: dex_search, dex_getgeometry, dex_move_resize_remap, etc."
    echo ""
    echo "For direct backend access: DEX_DISPLAY=:0 python3 \$XDG_RUNTIME_DIR/dex_backend_\$UID.py <action> [args...]"
fi
