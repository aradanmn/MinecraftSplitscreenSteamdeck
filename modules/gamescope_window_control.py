#!/usr/bin/env python3
"""
gamescope_window_control.py — Gamescope-specific window positioning.

Controls Minecraft window layout inside gamescope's XWayland by:
  1. Setting the GAMESCOPECTRL_BASELAYER_WINDOW root property (xprop atom)
     so gamescope uses a specific window as its fullscreen base layer.
  2. Optionally setting GAMESCOPE_FORCE_WINDOW_FULLSCREEN root property
     to force a window to fullscreen.
  3. Setting override_redirect on overlay windows so they render in
     gamescope's overlay plane at their specified geometry.
  4. Reading/writing geometry via the X11 protocol directly (avoids
     xdotool unreliability in gamescope's XWayland).

Usage:
    # Set the base layer window (the main fullscreen Minecraft)
    python3 gamescope_window_control.py set-base-layer <window_id>

    # Mark a window as a gamescope overlay (STEAM_OVERLAY=1) — key approach
    python3 gamescope_window_control.py set-overlay-prop <window_id> [steam|external]

    # Set a window as override_redirect with specified geometry AND mark as overlay
    python3 gamescope_window_control.py set-overlay <window_id> <x> <y> <w> <h>

    # Same but as external overlay (zpos=2 instead of zpos=3)
    python3 gamescope_window_control.py set-external-overlay <window_id> <x> <y> <w> <h>

    # Set both base and overlay in one call
    python3 gamescope_window_control.py set-layout <base_wid> <overlay_wid> <x> <y> <w> <h>

    # Force gamescope to make all windows fullscreen (0=disable)
    python3 gamescope_window_control.py force-fullscreen <0|1>

    # Query current gamescope root window properties
    python3 gamescope_window_control.py query

    # Atomic reposition (unmap → override_redirect → move → remap)
    python3 gamescope_window_control.py atomic-reposition <wid> <x> <y> <w> <h>

Environment:
    DISPLAY — X display (default: :0)
    GAMESCOPE_VERBOSE=1 — verbose logging
"""
import ctypes
import ctypes.util
import os
import struct
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# X11 type definitions (same pattern as TinyWM)
# ---------------------------------------------------------------------------
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')

XOpenDisplay = lib.XOpenDisplay
XOpenDisplay.restype = ctypes.c_void_p

XDefaultRootWindow = lib.XDefaultRootWindow
XDefaultRootWindow.restype = ctypes.c_ulong
XDefaultRootWindow.argtypes = [ctypes.c_void_p]

XCloseDisplay = lib.XCloseDisplay
XCloseDisplay.argtypes = [ctypes.c_void_p]

XInternAtom = lib.XInternAtom
XInternAtom.restype = ctypes.c_ulong
XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

XChangeProperty = lib.XChangeProperty
XChangeProperty.restype = None
XChangeProperty.argtypes = [
    ctypes.c_void_p,  # display
    ctypes.c_ulong,   # window (root)
    ctypes.c_ulong,   # property atom
    ctypes.c_ulong,   # type atom
    ctypes.c_int,     # format (8, 16, 32)
    ctypes.c_int,     # mode (PropModeReplace=0)
    ctypes.c_void_p,  # data pointer
    ctypes.c_int,     # nelements
]

XGetWindowProperty = lib.XGetWindowProperty
XGetWindowProperty.restype = ctypes.c_int
XGetWindowProperty.argtypes = [
    ctypes.c_void_p,              # display
    ctypes.c_ulong,               # window
    ctypes.c_ulong,               # property atom
    ctypes.c_long,                # offset
    ctypes.c_long,                # length
    ctypes.c_int,                 # delete (False)
    ctypes.c_ulong,               # req type
    ctypes.POINTER(ctypes.c_ulong),  # actual_type
    ctypes.POINTER(ctypes.c_int),    # actual_format
    ctypes.POINTER(ctypes.c_ulong),  # nitems
    ctypes.POINTER(ctypes.c_ulong),  # bytes_after
    ctypes.POINTER(ctypes.c_void_p), # prop
]

XFree = lib.XFree
XFree.argtypes = [ctypes.c_void_p]

XDeleteProperty = lib.XDeleteProperty
XDeleteProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong]

XSync = lib.XSync
XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]

XMapWindow = lib.XMapWindow
XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

XUnmapWindow = lib.XUnmapWindow
XUnmapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

XMoveResizeWindow = lib.XMoveResizeWindow
XMoveResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]

XChangeWindowAttributes = lib.XChangeWindowAttributes
XChangeWindowAttributes.restype = ctypes.c_int
XChangeWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]

XSetErrorHandler = lib.XSetErrorHandler
XSetErrorHandler.argtypes = [ctypes.c_void_p]
XSetErrorHandler.restype = ctypes.c_void_p

XGetSelectionOwner = lib.XGetSelectionOwner
XGetSelectionOwner.restype = ctypes.c_ulong
XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

# ---------------------------------------------------------------------------
# X11 constants
# ---------------------------------------------------------------------------
PropModeReplace = 0
PropModePrepend = 1
PropModeAppend = 2

XA_CARDINAL = 6       # 32-bit unsigned integer
XA_WINDOW = 33        # XID type
XA_ATOM = 4           # Atom type

CWOverrideRedirect = 1 << 3  # bit 3 in XSetWindowAttributes mask

class XSetWindowAttributes(ctypes.Structure):
    _fields_ = [
        ('background_pixmap', ctypes.c_ulong),
        ('background_pixel', ctypes.c_ulong),
        ('border_pixmap', ctypes.c_ulong),
        ('border_pixel', ctypes.c_ulong),
        ('bit_gravity', ctypes.c_int),
        ('win_gravity', ctypes.c_int),
        ('backing_store', ctypes.c_int),
        ('backing_planes', ctypes.c_ulong),
        ('backing_pixel', ctypes.c_ulong),
        ('save_under', ctypes.c_int),
        ('event_mask', ctypes.c_long),
        ('do_not_propagate_mask', ctypes.c_long),
        ('override_redirect', ctypes.c_int),  # Bool
        ('colormap', ctypes.c_ulong),
        ('cursor', ctypes.c_ulong),
    ]


def log(msg):
    """Print to stderr if GAMESCOPE_VERBOSE is set."""
    if os.environ.get('GAMESCOPE_VERBOSE', ''):
        print(f'[gamescope_wc] {msg}', file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Gamescope-specific atoms
# ---------------------------------------------------------------------------

def get_gamescope_atoms(dpy):
    """
    Intern all known gamescope-specific atoms.
    Returns a dict of name -> atom.
    """
    atoms = {}
    atom_names = [
        # The primary atom: set this to an XID (32-bit) of the window
        # you want gamescope to use as the composited base layer.
        b'GAMESCOPECTRL_BASELAYER_WINDOW',

        # Alternative: set baselayer by Steam AppID
        b'GAMESCOPECTRL_BASELAYER_APPID',

        # Force all windows to fullscreen (CARDINAL, 0=off, 1=on)
        b'GAMESCOPE_FORCE_WINDOWS_FULLSCREEN',

        # Additional gamescope atoms
        b'GAMESCOPE_LIMITER_DISPLAY_FPS',
        b'GAMESCOPE_LIMITER_OUTPUT_FPS',
        b'GAMESCOPE_SCALING_MODE',
        b'GAMESCOPE_INTEGER_SCALING',
        b'GAMESCOPE_FILTER',
        b'GAMESCOPE_FOCUSED_WINDOW',
        b'GAMESCOPE_FOCUSED_APP_GFX',
        b'GAMESCOPE_INPUT_COUNTER',
        b'GAMESCOPE_FOCUS_DISPLAY',
        b'GAMESCOPE_MOUSE_FOCUS_DISPLAY',
        b'GAMESCOPE_KEYBOARD_FOCUS_DISPLAY',

        # Window-level atoms (set on the window, not root)
        # These TWO are the most important for overlay positioning:
        b'STEAM_OVERLAY',              # Set on a window → goes to overlay plane (zpos=3)
        b'GAMESCOPE_EXTERNAL_OVERLAY', # Set on a window → goes to external overlay (zpos=2)
    ]
    for name in atom_names:
        atoms[name] = XInternAtom(dpy, name, False)
        log(f'Atom {name.decode()}: {atoms[name]}')
    return atoms


def get_window_atom(dpy):
    """Intern the WINDOW atom (XA_WINDOW)."""
    return XInternAtom(dpy, b'WINDOW', False)


# ---------------------------------------------------------------------------
# API functions
# ---------------------------------------------------------------------------

def set_baselayer_window(dpy, root, wid):
    """
    Set GAMESCOPECTRL_BASELAYER_WINDOW on the root window.
    This tells gamescope to use `wid` as the base compositing layer
    (fullscreen, behind all overlays).

    Args:
        dpy: X11 display pointer
        root: Root window XID
        wid: Window XID to set as the base layer (or 0 to clear)
    """
    atoms = get_gamescope_atoms(dpy)
    atom = atoms.get(b'GAMESCOPECTRL_BASELAYER_WINDOW')
    if atom == 0:
        # Interning as False (don't create) -- try again with create=True
        atom = XInternAtom(dpy, b'GAMESCOPECTRL_BASELAYER_WINDOW', False)
        if atom == 0:
            print('[gamescope_wc] ERROR: GAMESCOPECTRL_BASELAYER_WINDOW atom not found', file=sys.stderr)
            return False

    # Format 32, type WINDOW (XA_WINDOW)  — 32-bit XID
    wid_c = ctypes.c_ulong(wid)
    XChangeProperty(dpy, root, atom, XA_WINDOW, 32,
                    PropModeReplace,
                    ctypes.byref(wid_c), 1)
    XSync(dpy, False)
    print(f'[gamescope_wc] Set GAMESCOPECTRL_BASELAYER_WINDOW = 0x{wid:x}', file=sys.stderr)
    return True


def clear_baselayer_window(dpy, root):
    """Clear the GAMESCOPECTRL_BASELAYER_WINDOW property (set to 0)."""
    return set_baselayer_window(dpy, root, 0)


def set_window_property(dpy, wid, atom_name, value):
    """
    Set a WINDOW-level property (32-bit integer) on a specific window.
    Used to set STEAM_OVERLAY, GAMESCOPE_EXTERNAL_OVERLAY, etc.

    Args:
        dpy: X11 display pointer
        wid: Window XID
        atom_name: bytes, e.g. b'STEAM_OVERLAY'
        value: 32-bit value (0 or 1 typically)

    Returns:
        True on success, False on failure.
    """
    atom = XInternAtom(dpy, atom_name, False)
    if atom == 0:
        print(f'[gamescope_wc] ERROR: Atom {atom_name.decode()} not found', file=sys.stderr)
        return False

    # For boolean overlays, format 32, type CARDINAL
    val_c = ctypes.c_ulong(value)
    XChangeProperty(dpy, wid, atom, XA_CARDINAL, 32,
                    PropModeReplace,
                    ctypes.byref(val_c), 1)
    XSync(dpy, False)
    print(f'[gamescope_wc] Set {atom_name.decode()}={value} on 0x{wid:x}', file=sys.stderr)
    return True


def set_window_as_overlay(dpy, wid):
    """
    Mark a window as a gamescope overlay by setting STEAM_OVERLAY=1 on it.
    Gamescope will render this window at zpos=g_zposOverlay (3) on top of
    the base layer, without scale/fit constraints — it uses the window's
    own geometry.

    This is the KEY approach for splitscreen: set one window as the
    GAMESCOPECTRL_BASELAYER_WINDOW (fullscreen base), and the other as
    STEAM_OVERLAY (free-positioned overlay on top).
    """
    return set_window_property(dpy, wid, b'STEAM_OVERLAY', 1)


def set_window_as_external_overlay(dpy, wid):
    """
    Mark a window as a gamescope external overlay by setting
    GAMESCOPE_EXTERNAL_OVERLAY=1 on it.
    Gamescope will render this window at zpos=g_zposExternalOverlay (2)
    — between override layers and normal overlays.

    External overlays are meant for non-Steam overlays that should appear
    above the game but below Steam overlays.
    """
    return set_window_property(dpy, wid, b'GAMESCOPE_EXTERNAL_OVERLAY', 1)


def force_window_fullscreen(dpy, root, wid):
    """
    Set GAMESCOPE_FORCE_WINDOWS_FULLSCREEN on the root window.
    This tells gamescope to force ALL windows to fullscreen.
    Set to 0 to disable.

    Note: This is a global toggle (ALL windows), not per-window.
    For per-window control, use GAMESCOPECTRL_BASELAYER_WINDOW instead.
    """
    atoms = get_gamescope_atoms(dpy)
    atom = atoms.get(b'GAMESCOPE_FORCE_WINDOWS_FULLSCREEN')
    if atom == 0:
        atom = XInternAtom(dpy, b'GAMESCOPE_FORCE_WINDOWS_FULLSCREEN', False)
        if atom == 0:
            print('[gamescope_wc] ERROR: GAMESCOPE_FORCE_WINDOWS_FULLSCREEN atom not found', file=sys.stderr)
            return False

    val_c = ctypes.c_ulong(wid)
    XChangeProperty(dpy, root, atom, XA_CARDINAL, 32,
                    PropModeReplace,
                    ctypes.byref(val_c), 1)
    XSync(dpy, False)
    print(f'[gamescope_wc] Set GAMESCOPE_FORCE_WINDOWS_FULLSCREEN = {wid}', file=sys.stderr)
    return True


def set_override_redirect(dpy, wid, enable=True):
    """
    Set or clear override_redirect on a window via the X11 protocol directly.

    This is more reliable than xdotool set_window --overrideredirect because
    we go through the actual X11 library rather than shelling out. For
    gamescope's XWayland, override_redirect windows render in the overlay
    plane where they can be freely positioned.

    Args:
        dpy: X11 display pointer
        wid: Window XID
        enable: True to set override_redirect, False to clear it
    """
    attrs = XSetWindowAttributes()
    attrs.override_redirect = 1 if enable else 0

    # Save old error handler and set a no-op one to suppress BadWindow errors
    # (which happen if the window doesn't exist yet or was already destroyed)
    old_handler = XSetErrorHandler(None)

    result = XChangeWindowAttributes(dpy, wid, CWOverrideRedirect, ctypes.byref(attrs))
    XSync(dpy, False)

    # Restore error handler
    if old_handler:
        XSetErrorHandler(old_handler)

    if result != 0:
        state = 'enabled' if enable else 'disabled'
        print(f'[gamescope_wc] override_redirect {state} on 0x{wid:x}', file=sys.stderr)
        return True
    else:
        state = 'enable' if enable else 'disable'
        print(f'[gamescope_wc] WARNING: Failed to {state} override_redirect on 0x{wid:x}', file=sys.stderr)
        return False


def move_resize_window(dpy, wid, x, y, w, h):
    """
    Move and resize a window via the X11 protocol directly.
    More reliable than xdotool in gamescope's XWayland.

    Args:
        dpy: X11 display pointer
        wid: Window XID
        x, y: Position
        w, h: Size
    """
    XMoveResizeWindow(dpy, wid, x, y, w, h)
    XSync(dpy, False)
    print(f'[gamescope_wc] Moved/resized 0x{wid:x} to {x},{y} {w}x{h}', file=sys.stderr)
    return True


def atomic_reposition(dpy, wid, x, y, w, h, use_override_redirect=True):
    """
    Atomic reposition: unmap → set override_redirect → move/resize → remap.

    This is the most reliable sequence for positioning windows inside
    gamescope's XWayland where KWin (or the compositor) would otherwise
    override our positioning.

    Args:
        dpy: X11 display pointer
        wid: Window XID
        x, y: Target position
        w, h: Target size
        use_override_redirect: Whether to set override_redirect (default: True)
    """
    # Step 1: Unmap
    XUnmapWindow(dpy, wid)
    XSync(dpy, False)
    time.sleep(0.05)

    # Step 2: Set override_redirect (so the WM won't touch it on remap)
    if use_override_redirect:
        set_override_redirect(dpy, wid, True)

    # Step 3: Position and size
    move_resize_window(dpy, wid, x, y, w, h)

    # Step 4: Remap
    XMapWindow(dpy, wid)
    XSync(dpy, False)

    print(f'[gamescope_wc] Atomic reposition: 0x{wid:x} → {x},{y} {w}x{h} (override={use_override_redirect})', file=sys.stderr)
    return True


def set_as_overlay(dpy, root, wid, x, y, w, h):
    """
    Set a window as a gamescope overlay at the given geometry.

    This combines:
      1. Setting override_redirect on the window (so it goes to overlay plane)
      2. Moving/sizing it to the desired geometry
      3. Mapping it (in case it was unmapped)

    The window will render on top of the base layer window at the specified
    position and size, without any compositor interference.
    """
    # Make sure the window is visible first
    XMapWindow(dpy, wid)
    XSync(dpy, False)

    # Do the unmap → override_redirect → move → remap dance
    result = atomic_reposition(dpy, wid, x, y, w, h, use_override_redirect=True)

    # In some gamescope versions, setting the window as override_redirect
    # makes it go to the overlay plane. Verify by checking if the property
    # was applied.
    XSync(dpy, False)
    return result


def set_fullscreen_base(dpy, root, wid, screen_w, screen_h):
    """
    Set a window as the fullscreen base layer in gamescope.

    This:
      1. Moves/resizes the window to fill the screen
      2. Sets GAMESCOPECTRL_BASELAYER_WINDOW root property to this window's XID
      3. Does NOT set override_redirect (the base layer should be managed)

    The result is that gamescope composites this window as the fullscreen
    base, and any override_redirect windows render on top as overlays.
    """
    # Position as fullscreen first
    XMapWindow(dpy, wid)
    XSync(dpy, False)

    # Don't use override_redirect for the base layer in the layout approach.
    # The base layer should be managed; overlays should be override_redirect.
    move_resize_window(dpy, wid, 0, 0, screen_w, screen_h)

    # Set as the baselayer window
    set_baselayer_window(dpy, root, wid)

    return True


def query_gamescope_properties(dpy):
    """
    Read and display all gamescope-specific root window properties.
    Useful for debugging what gamescope currently sees.

    Also reads GAMESCOPECTRL_BASELAYER_WINDOW to see which window (if any)
    is set as the base layer.
    """
    root = XDefaultRootWindow(dpy)
    atoms = get_gamescope_atoms(dpy)

    print('=== Gamescope Root Window Properties ===', file=sys.stderr)
    print(f'  Root window: 0x{root:x}', file=sys.stderr)

    # Atoms that are set on ROOT window (not per-window)
    root_atoms = [
        b'GAMESCOPECTRL_BASELAYER_WINDOW',
        b'GAMESCOPECTRL_BASELAYER_APPID',
        b'GAMESCOPE_FORCE_WINDOWS_FULLSCREEN',
        b'GAMESCOPE_LIMITER_DISPLAY_FPS',
        b'GAMESCOPE_LIMITER_OUTPUT_FPS',
        b'GAMESCOPE_SCALING_MODE',
        b'GAMESCOPE_INTEGER_SCALING',
        b'GAMESCOPE_FILTER',
        b'GAMESCOPE_FOCUSED_WINDOW',
        b'GAMESCOPE_FOCUSED_APP_GFX',
        b'GAMESCOPE_INPUT_COUNTER',
        b'GAMESCOPE_FOCUS_DISPLAY',
        b'GAMESCOPE_MOUSE_FOCUS_DISPLAY',
        b'GAMESCOPE_KEYBOARD_FOCUS_DISPLAY',
    ]

    for name in root_atoms:
        atom = atoms.get(name)
        if atom == 0:
            print(f'  {name.decode():40s} NOT SUPPORTED by this X server', file=sys.stderr)
            continue

        # Try to read the property
        actual_type = ctypes.c_ulong()
        actual_format = ctypes.c_int()
        nitems = ctypes.c_ulong()
        bytes_after = ctypes.c_ulong()
        prop_data = ctypes.c_void_p()

        status = XGetWindowProperty(
            dpy, root, atom, 0, 1,
            False,  # don't delete
            XA_WINDOW,  # try WINDOW type first
            ctypes.byref(actual_type),
            ctypes.byref(actual_format),
            ctypes.byref(nitems),
            ctypes.byref(bytes_after),
            ctypes.byref(prop_data),
        )

        if status == 0 and prop_data and actual_format != 0 and nitems.value > 0:
            # Read as 32-bit value
            data_ptr = ctypes.cast(prop_data, ctypes.POINTER(ctypes.c_ulong))
            value = data_ptr[0]
            XFree(prop_data)
            print(f'  {name.decode():40s} 0x{value:x} ({value})', file=sys.stderr)
        else:
            # Maybe it's a CARDINAL or not set
            if status == 0 and prop_data:
                XFree(prop_data)

            # Try as CARDINAL
            status2 = XGetWindowProperty(
                dpy, root, atom, 0, 1,
                False, XA_CARDINAL,
                ctypes.byref(actual_type),
                ctypes.byref(actual_format),
                ctypes.byref(nitems),
                ctypes.byref(bytes_after),
                ctypes.byref(prop_data),
            )
            if status2 == 0 and prop_data and actual_format != 0 and nitems.value > 0:
                data_ptr = ctypes.cast(prop_data, ctypes.POINTER(ctypes.c_ulong))
                value = data_ptr[0]
                XFree(prop_data)
                print(f'  {name.decode():40s} {value} (CARDINAL)', file=sys.stderr)
            else:
                if prop_data:
                    XFree(prop_data)
                print(f'  {name.decode():40s} <not set>', file=sys.stderr)

    # Also list all root window properties (for discovery)
    print(file=sys.stderr)
    print('=== All root window properties (via xprop -root) ===', file=sys.stderr)
    subprocess.run(
        ['xprop', '-root', '-display', os.environ.get('DISPLAY', ':0')],
        capture_output=False, check=False
    )

    return True


def get_screen_dimensions(dpy):
    """Get screen dimensions via X11."""
    screen_w = 1280
    screen_h = 800
    try:
        XDefaultScreen = lib.XDefaultScreen
        XDefaultScreen.restype = ctypes.c_int
        XDefaultScreen.argtypes = [ctypes.c_void_p]

        XDisplayWidth = lib.XDisplayWidth
        XDisplayWidth.restype = ctypes.c_int
        XDisplayWidth.argtypes = [ctypes.c_void_p, ctypes.c_int]

        XDisplayHeight = lib.XDisplayHeight
        XDisplayHeight.restype = ctypes.c_int
        XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]

        screen = XDefaultScreen(dpy)
        screen_w = XDisplayWidth(dpy, screen)
        screen_h = XDisplayHeight(dpy, screen)
    except Exception as e:
        print(f'[gamescope_wc] Could not get screen size: {e}', file=sys.stderr)
    return screen_w, screen_h


def set_layout(base_wid, overlay_wid, overlay_x, overlay_y, overlay_w, overlay_h, use_overlay_atom=True):
    """
    Complete layout setup for two-window splitscreen.

    1. Opens display
    2. Gets root window
    3. Gets screen dimensions
    4. Sets the base window fullscreen
    5. Sets the overlay window as override_redirect at the specified geometry
    6. Sets GAMESCOPECTRL_BASELAYER_WINDOW to the base window
    7. Optionally sets STEAM_OVERLAY or GAMESCOPE_EXTERNAL_OVERLAY on the overlay
       window so gamescope renders it in the overlay plane (zpos=3 or zpos=2)

    This is the main entry point for the gamescope splitscreen approach.
    """
    dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
    if not dpy:
        print('[gamescope_wc] ERROR: Cannot open display', file=sys.stderr)
        return False

    try:
        root = XDefaultRootWindow(dpy)
        screen_w, screen_h = get_screen_dimensions(dpy)
        print(f'[gamescope_wc] Screen: {screen_w}x{screen_h}', file=sys.stderr)

        # Step 1: Set base window fullscreen
        print(f'[gamescope_wc] Setting base window 0x{base_wid:x} to fullscreen', file=sys.stderr)
        set_fullscreen_base(dpy, root, base_wid, screen_w, screen_h)

        # Small delay for gamescope to register the baselayer change
        time.sleep(0.2)

        # Step 2: Set overlay window as override_redirect at target geometry
        print(f'[gamescope_wc] Setting overlay window 0x{overlay_wid:x} to {overlay_x},{overlay_y} {overlay_w}x{overlay_h}', file=sys.stderr)
        set_as_overlay(dpy, root, overlay_wid, overlay_x, overlay_y, overlay_w, overlay_h)

        # Step 3: Mark the overlay window as a gamescope overlay so it renders
        # in the overlay plane (on top of the base) at its own geometry.
        if use_overlay_atom:
            print(f'[gamescope_wc] Marking overlay window 0x{overlay_wid:x} as STEAM_OVERLAY', file=sys.stderr)
            set_window_as_overlay(dpy, overlay_wid)

        print(f'[gamescope_wc] Layout applied successfully', file=sys.stderr)
        return True

    finally:
        XCloseDisplay(dpy)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]

    if command == 'query':
        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            print('[gamescope_wc] ERROR: Cannot open display', file=sys.stderr)
            sys.exit(1)
        try:
            query_gamescope_properties(dpy)
        finally:
            XCloseDisplay(dpy)
        sys.exit(0)

    elif command == 'set-base-layer':
        if len(sys.argv) < 3:
            print('Usage: gamescope_window_control.py set-base-layer <window_id>', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            root = XDefaultRootWindow(dpy)
            set_baselayer_window(dpy, root, wid)
        finally:
            XCloseDisplay(dpy)

    elif command == 'set-overlay':
        if len(sys.argv) < 7:
            print('Usage: gamescope_window_control.py set-overlay <wid> <x> <y> <w> <h>', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)
        x, y, w, h = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            root = XDefaultRootWindow(dpy)
            set_as_overlay(dpy, root, wid, x, y, w, h)
            # Also mark as STEAM_OVERLAY
            set_window_as_overlay(dpy, wid)
        finally:
            XCloseDisplay(dpy)

    elif command == 'set-overlay-prop':
        if len(sys.argv) < 3:
            print('Usage: gamescope_window_control.py set-overlay-prop <wid> [type]', file=sys.stderr)
            print('  type: "steam" (default), "external"', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)
        overlay_type = sys.argv[3] if len(sys.argv) > 3 else 'steam'

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            if overlay_type == 'external':
                set_window_as_external_overlay(dpy, wid)
            else:
                set_window_as_overlay(dpy, wid)
        finally:
            XCloseDisplay(dpy)

    elif command == 'set-external-overlay':
        if len(sys.argv) < 7:
            print('Usage: gamescope_window_control.py set-external-overlay <wid> <x> <y> <w> <h>', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)
        x, y, w, h = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            root = XDefaultRootWindow(dpy)
            set_as_overlay(dpy, root, wid, x, y, w, h)
            # Mark as external overlay instead of Steam overlay
            set_window_as_external_overlay(dpy, wid)
        finally:
            XCloseDisplay(dpy)

    elif command == 'set-layout':
        if len(sys.argv) < 8:
            print('Usage: gamescope_window_control.py set-layout <base_wid> <overlay_wid> <x> <y> <w> <h>', file=sys.stderr)
            sys.exit(1)
        base_wid = int(sys.argv[2], 0)
        overlay_wid = int(sys.argv[3], 0)
        x, y, w, h = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])

        set_layout(base_wid, overlay_wid, x, y, w, h)

    elif command == 'force-fullscreen':
        if len(sys.argv) < 3:
            print('Usage: gamescope_window_control.py force-fullscreen <window_id>', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            root = XDefaultRootWindow(dpy)
            force_window_fullscreen(dpy, root, wid)
        finally:
            XCloseDisplay(dpy)

    elif command == 'atomic-reposition':
        if len(sys.argv) < 7:
            print('Usage: gamescope_window_control.py atomic-reposition <wid> <x> <y> <w> <h>', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)
        x, y, w, h = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            atomic_reposition(dpy, wid, x, y, w, h)
        finally:
            XCloseDisplay(dpy)

    elif command == 'override-redirect':
        if len(sys.argv) < 3:
            print('Usage: gamescope_window_control.py override-redirect <wid> [0|1]', file=sys.stderr)
            sys.exit(1)
        wid = int(sys.argv[2], 0)
        enable = True
        if len(sys.argv) > 3:
            enable = sys.argv[3] not in ('0', 'false', 'off')

        dpy = XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
        if not dpy:
            sys.exit(1)
        try:
            set_override_redirect(dpy, wid, enable)
        finally:
            XCloseDisplay(dpy)

    elif command == 'help':
        print(__doc__, file=sys.stderr)

    else:
        print(f'[gamescope_wc] Unknown command: {command}', file=sys.stderr)
        print('Commands: query | set-base-layer | set-overlay | set-external-overlay | set-overlay-prop | set-layout | force-fullscreen | atomic-reposition | override-redirect', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
