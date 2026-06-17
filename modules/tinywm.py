#!/usr/bin/env python3
"""
TinyWM — Minimal window manager for gamescope Minecraft splitscreen.

Subscribes to SubstructureRedirectMask to become the sole window manager
on the given X display. When windows map, positions them according to a
pre-arranged slot layout communicated via a simple JSON state file.

Designed specifically for use inside gamescope's XWayland where KWin is
not the compositing window manager and xdotool overrideredirect tricks
don't persist.

Usage:
    python3 /path/to/tinywm.py [display] [state_file] [fifo]

    display    — X display to manage (default: :0)
    state_file — path to splitscreen_state.json (default: ~/.local/share/PolyMC/splitscreen_state.json)
    fifo       — path to splitscreen FIFO for notifications (optional)
"""
import ctypes
import ctypes.util
import json
import os
import signal
import struct
import sys
import time
import errno

# ---------------------------------------------------------------------------
# X11 type definitions
# ---------------------------------------------------------------------------
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')

XOpenDisplay = lib.XOpenDisplay
XOpenDisplay.restype = ctypes.c_void_p

XDefaultRootWindow = lib.XDefaultRootWindow
XDefaultRootWindow.restype = ctypes.c_ulong
XDefaultRootWindow.argtypes = [ctypes.c_void_p]

XSelectInput = lib.XSelectInput
XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]

XNextEvent = lib.XNextEvent
XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

XMoveResizeWindow = lib.XMoveResizeWindow
XMoveResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]

XResizeWindow = lib.XResizeWindow
XResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_uint, ctypes.c_uint]

XMoveWindow = lib.XMoveWindow
XMoveWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int]

XMapWindow = lib.XMapWindow
XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

XMapRaised = lib.XMapRaised
XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

XFlush = lib.XFlush
XFlush.argtypes = [ctypes.c_void_p]

XSetErrorHandler = lib.XSetErrorHandler
XSetErrorHandler.argtypes = [ctypes.c_void_p]
XSetErrorHandler.restype = ctypes.c_void_p

XSync = lib.XSync
XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]

XChangeProperty = lib.XChangeProperty
XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                            ctypes.c_void_p, ctypes.c_int]

XInternAtom = lib.XInternAtom
XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
XInternAtom.restype = ctypes.c_ulong

XGetWindowProperty = lib.XGetWindowProperty
XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long,
                               ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                               ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                               ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
XGetWindowProperty.restype = ctypes.c_int

XFree = lib.XFree
XFree.argtypes = [ctypes.c_void_p]

SubstructureRedirectMask  = 1 << 16
SubstructureNotifyMask    = 1 << 17
StructureNotifyMask       = 1 << 17
ColormapChangeMask        = 1 << 21
PropertyChangeMask        = 1 << 6

CreateNotify       = 17
MapRequest         = 20
ConfigureRequest   = 22
DestroyNotify      = 17
PropertyNotify     = 28
ClientMessage      = 33

class XAnyEvent(ctypes.Structure):
    _fields_ = [
        ('type', ctypes.c_int),
        ('serial', ctypes.c_ulong),
        ('send_event', ctypes.c_int),
        ('display', ctypes.c_void_p),
        ('window', ctypes.c_ulong),
    ]

class XMapRequestEvent(ctypes.Structure):
    _fields_ = [
        ('type', ctypes.c_int),
        ('serial', ctypes.c_ulong),
        ('send_event', ctypes.c_int),
        ('display', ctypes.c_void_p),
        ('parent', ctypes.c_ulong),
        ('window', ctypes.c_ulong),
    ]

class XConfigureRequestEvent(ctypes.Structure):
    _fields_ = [
        ('type', ctypes.c_int),
        ('serial', ctypes.c_ulong),
        ('send_event', ctypes.c_int),
        ('display', ctypes.c_void_p),
        ('parent', ctypes.c_ulong),
        ('window', ctypes.c_ulong),
        ('x', ctypes.c_int), ('y', ctypes.c_int),
        ('width', ctypes.c_int), ('height', ctypes.c_int),
        ('border_width', ctypes.c_int),
        ('above', ctypes.c_ulong),
        ('detail', ctypes.c_int),
        ('value_mask', ctypes.c_ulong),
    ]

class XPropertyEvent(ctypes.Structure):
    _fields_ = [
        ('type', ctypes.c_int),
        ('serial', ctypes.c_ulong),
        ('send_event', ctypes.c_int),
        ('display', ctypes.c_void_p),
        ('window', ctypes.c_ulong),
        ('atom', ctypes.c_ulong),
        ('time', ctypes.c_ulong),
        ('state', ctypes.c_int),  # 0=NewValue, 1=Deleted
    ]

class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ('type', ctypes.c_int),
        ('serial', ctypes.c_ulong),
        ('send_event', ctypes.c_int),
        ('display', ctypes.c_void_p),
        ('window', ctypes.c_ulong),
        ('message_type', ctypes.c_ulong),
        ('format', ctypes.c_int),
        ('data', ctypes.c_char * 20),
    ]

class XEvent(ctypes.Union):
    _fields_ = [
        ('type', ctypes.c_int),
        ('xany', XAnyEvent),
        ('xmaprequest', XMapRequestEvent),
        ('xconfigurerequest', XConfigureRequestEvent),
        ('xproperty', XPropertyEvent),
        ('xclient', XClientMessageEvent),
        ('pad', ctypes.c_long * 24),
    ]


# ---------------------------------------------------------------------------
# Layout manager
# ---------------------------------------------------------------------------
class LayoutManager:
    """Reads slot geometry from the splitscreen state file."""

    def __init__(self, state_file, display_name, default_w=1280, default_h=800):
        self.state_file = state_file
        self.display_name = display_name
        self.default_w = default_w
        self.default_h = default_h
        self._last_mtime = 0
        self._cache = {}               # slot -> (x, y, w, h, active)
        self._window_slot_map = {}      # wid -> slot
        self._slot_windows = {}         # slot -> [wid, ...]

    def _parse_geometry(self):
        """Read state file and return dict of slot->geometry."""
        result = {}
        try:
            with open(self.state_file, 'r') as f:
                state = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return result

        # Get screen dimensions from the first active slot or full screen
        screen_w = self.default_w
        screen_h = self.default_h

        slots = state.get('slots', {})
        active_slot_nums = []
        for snum in ('1', '2', '3', '4'):
            s = slots.get(snum, {})
            if s.get('active', False):
                active_slot_nums.append(int(snum))

        if not active_slot_nums:
            # No active slots — maybe launching, use defaults
            return result

        # Determine grid mode
        highest = max(active_slot_nums)
        if highest <= 1:
            grid = 'full'
        elif highest == 2:
            grid = 'half'
        else:
            grid = 'quad'

        # Compute geometry for all 4 slots
        for snum in ('1', '2', '3', '4'):
            s = int(snum)
            is_active = s in active_slot_nums
            if grid == 'full':
                result[snum] = (0, 0, screen_w, screen_h, is_active)
            elif grid == 'half':
                half_h = screen_h // 2
                if s == 1:
                    result[snum] = (0, 0, screen_w, half_h, is_active)
                elif s == 2:
                    result[snum] = (0, half_h, screen_w, half_h, is_active)
                else:
                    result[snum] = (0, 0, screen_w, screen_h, is_active)
            elif grid == 'quad':
                half_w = screen_w // 2
                half_h = screen_h // 2
                if s == 1:
                    result[snum] = (0, 0, half_w, half_h, is_active)
                elif s == 2:
                    result[snum] = (half_w, 0, half_w, half_h, is_active)
                elif s == 3:
                    result[snum] = (0, half_h, half_w, half_h, is_active)
                else:
                    result[snum] = (half_w, half_h, half_w, half_h, is_active)

        return result

    def reload_if_changed(self):
        """Reload state if file mtime changed. Returns True if changed."""
        try:
            mtime = os.path.getmtime(self.state_file)
        except OSError:
            return False

        if mtime <= self._last_mtime:
            return False

        self._last_mtime = mtime
        self._cache = self._parse_geometry()
        return True

    def get_geometry_for(self, wid, win_name):
        """Get target geometry for a window. Returns (x, y, w, h) or None."""
        # Try slot from window_slot_map
        slot = self._window_slot_map.get(wid)

        # Try slot from cache slot->windows reverse map
        if slot is None:
            for s, wids in self._slot_windows.items():
                if wid in wids:
                    slot = s
                    break

        # Try to determine slot from window name
        if slot is None and win_name:
            for snum in ('1', '2', '3', '4'):
                if f'P{snum}' in win_name or f'Slot{snum}' in win_name:
                    slot = snum
                    break
            if slot is None:
                for s in ('1', '2', '3', '4'):
                    if s in win_name:
                        slot = s
                        break

        if slot and slot in self._cache:
            geo = self._cache[slot]
            return (geo[0], geo[1], geo[2], geo[3])

        # Unknown window — just return something reasonable
        return None

    def get_window_name(self, dpy, wid):
        """Get WM_NAME (or _NET_WM_NAME) for a window."""
        try:
            # Try _NET_WM_NAME first
            utf8_string = XInternAtom(dpy, b'UTF8_STRING', False)
            net_wm_name = XInternAtom(dpy, b'_NET_WM_NAME', False)

            actual_type = ctypes.c_ulong()
            actual_format = ctypes.c_int()
            nitems = ctypes.c_ulong()
            bytes_after = ctypes.c_ulong()
            prop_data = ctypes.c_void_p()

            XGetWindowProperty(dpy, wid, net_wm_name, 0, 1024,
                               False, utf8_string,
                               ctypes.byref(actual_type),
                               ctypes.byref(actual_format),
                               ctypes.byref(nitems),
                               ctypes.byref(bytes_after),
                               ctypes.byref(prop_data))

            if actual_format != 0 and prop_data:
                name = ctypes.string_at(prop_data, nitems.value)
                XFree(prop_data)
                return name.decode('utf-8', errors='replace')

            # Fallback to WM_NAME
            xa_string = XInternAtom(dpy, b'STRING', False)
            wm_name = XInternAtom(dpy, b'WM_NAME', False)

            XGetWindowProperty(dpy, wid, wm_name, 0, 1024,
                               False, xa_string,
                               ctypes.byref(actual_type),
                               ctypes.byref(actual_format),
                               ctypes.byref(nitems),
                               ctypes.byref(bytes_after),
                               ctypes.byref(prop_data))

            if actual_format != 0 and prop_data:
                name = ctypes.string_at(prop_data, nitems.value)
                XFree(prop_data)
                return name.decode('utf-8', errors='replace')
        except Exception:
            pass
        return ''

    def register_window(self, wid, slot=None):
        """Remember the slot assignment for a window."""
        if slot:
            self._window_slot_map[wid] = slot
            if slot not in self._slot_windows:
                self._slot_windows[slot] = []
            if wid not in self._slot_windows[slot]:
                self._slot_windows[slot].append(wid)

    def unregister_window(self, wid):
        """Forget a window that was destroyed."""
        self._window_slot_map.pop(wid, None)
        for slot, wids in list(self._slot_windows.items()):
            if wid in wids:
                wids.remove(wid)
                if not wids:
                    del self._slot_windows[slot]
                break


# ---------------------------------------------------------------------------
# Main event loop
# ---------------------------------------------------------------------------
def main():
    display_name = sys.argv[1] if len(sys.argv) > 1 else ':0'
    state_file = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser(
        '~/.local/share/PolyMC/splitscreen_state.json')
    fifo_path = sys.argv[3] if len(sys.argv) > 3 else ''

    # Open display
    dpy = XOpenDisplay(display_name.encode())
    if not dpy:
        print(f"TinyWM: Error: cannot open display {display_name}", file=sys.stderr)
        sys.exit(1)

    root = XDefaultRootWindow(dpy)
    print(f"TinyWM: Running on {display_name}, root=0x{root:x}", file=sys.stderr)

    # Get screen dimensions
    display = dpy  # opaque, we can't query directly
    # Use width/height from state file defaults — XDisplayWidth/Height not needed
    screen_w = 1280
    screen_h = 800
    # Try to detect via get_geometry_of_root
    try:
        # Use XDefaultScreen and XDisplayWidth/Height via X11
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
        print(f"TinyWM: Screen is {screen_w}x{screen_h}", file=sys.stderr)
    except Exception:
        print(f"TinyWM: Could not get screen size, using {screen_w}x{screen_h}", file=sys.stderr)

    # Select for SubstructureRedirect — we ARE the window manager
    XSelectInput(dpy, root,
                 SubstructureRedirectMask | SubstructureNotifyMask | ColormapChangeMask)
    XSync(dpy, False)

    # Set error handler (ignore nonfatal errors gracefully)
    def xerror_handler(dpy_ptr, ev_ptr):
        return 0
    error_cb = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)(xerror_handler)
    XSetErrorHandler(error_cb)

    # Layout manager
    layout = LayoutManager(state_file, display_name, screen_w, screen_h)
    layout.reload_if_changed()

    # Signal handling
    running = True
    def handle_signal(sig, frame):
        nonlocal running
        running = False
        print("TinyWM: Shutting down...", file=sys.stderr)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    print("TinyWM: Ready, entering event loop.", file=sys.stderr)

    # Track pending map requests (window -> timestamp) to handle ConfigureRequest
    # events that arrive after MapRequest but before the window is actually mapped.
    pending_map = {}

    while running:
        event = XEvent()
        try:
            XNextEvent(dpy, ctypes.byref(event))
        except Exception as e:
            if running:
                print(f"TinyWM: XNextEvent error: {e}", file=sys.stderr)
            continue

        etype = event.type

        if etype == MapRequest:
            win = event.xmaprequest.window
            parent = event.xmaprequest.parent

            # Get window name (may not have one yet)
            win_name = layout.get_window_name(dpy, win)
            print(f"TinyWM: MapRequest window=0x{win:x} parent=0x{parent:x} name='{win_name}'", file=sys.stderr)

            # Reload layout from state file
            layout.reload_if_changed()

            # Determine geometry
            geo = layout.get_geometry_for(win, win_name)
            if geo:
                x, y, w, h = geo
                print(f"TinyWM: Positioning 0x{win:x} at {x},{y} {w}x{h}", file=sys.stderr)
                XMoveResizeWindow(dpy, win, x, y, w, h)
                XSync(dpy, False)
            else:
                # Unknown window — map at 0,0 with reasonable size
                # (likely the anchor window or a placeholder)
                print(f"TinyWM: No slot geometry for 0x{win:x}, mapping at 0,0", file=sys.stderr)

            # Map it
            XMapWindow(dpy, win)
            XFlush(dpy)

        elif etype == ConfigureRequest:
            ev = event.xconfigurerequest
            win = ev.window
            value_mask = ev.value_mask

            x = ev.x
            y = ev.y
            w = ev.width if ev.width > 0 else 640
            h = ev.height if ev.height > 0 else 800

            # Reload layout
            changed = layout.reload_if_changed()
            win_name = layout.get_window_name(dpy, win)

            # If layout changed or this is a known slot window, apply our geometry
            # instead of what the window requested. This is critical inside gamescope
            # where it sends ConfigureRequest events to force windows to fullscreen on
            # focus — we must override those to maintain our splitscreen layout.
            geo = layout.get_geometry_for(win, win_name) if (changed or win_name) else None
            if geo:
                x, y, w, h = geo
                print(f"TinyWM: Overriding ConfigureRequest 0x{win:x} -> {x},{y} {w}x{h} (was {ev.x},{ev.y} {ev.width}x{ev.height})", file=sys.stderr)
                XMoveResizeWindow(dpy, win, x, y, w, h)
                XFlush(dpy)
                continue

            # Otherwise let it have its requested geometry
            if value_mask & (1 << 0) or value_mask & (1 << 1) or value_mask & (1 << 2) or value_mask & (1 << 3):
                # Only actually move/resize if the request has position/size bits
                cw = value_mask & ((1 << 0) | (1 << 1) | (1 << 2) | (1 << 3))
                if cw:
                    print(f"TinyWM: ConfigureRequest 0x{win:x} -> {x},{y} {w}x{h} (mask=0x{value_mask:x})", file=sys.stderr)
                    if (value_mask & (1 << 8)) or (value_mask & (1 << 9)):
                        # Has width/height bits
                        XMoveResizeWindow(dpy, win, x, y, w, h)
                    else:
                        XMoveWindow(dpy, win, x, y)
                    XFlush(dpy)

        elif etype == PropertyNotify:
            ev = event.xproperty
            if ev.state == 0:  # NewValue
                win = ev.window
                atom = ev.atom
                # If _NET_WM_NAME or WM_NAME changed, check if this is a Minecraft window
                net_wm_name = XInternAtom(dpy, b'_NET_WM_NAME', False)
                wm_name = XInternAtom(dpy, b'WM_NAME', False)
                if atom == net_wm_name or atom == wm_name:
                    win_name = layout.get_window_name(dpy, win)
                    if win_name:
                        print(f"TinyWM: PropertyNotify name='{win_name}' on 0x{win:x}", file=sys.stderr)

        elif etype == CreateNotify:
            # A window was created — we don't need to do anything here
            # MapRequest will catch it when it wants to be shown
            pass

        else:
            # Other events are ignored
            pass

    print("TinyWM: Exited cleanly", file=sys.stderr)


if __name__ == '__main__':
    main()
