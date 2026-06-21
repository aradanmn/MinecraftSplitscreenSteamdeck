#!/bin/bash
# =============================================================================
# GAMESCOPE WINDOWING MODULE  —  DEAD / UNUSED (kept for reference only)
# =============================================================================
# NOT SOURCED by minecraftSplitscreen.sh or any module. Every caller guards with
# `command -v gamescope_windowing_apply_layout` / `type`, which is always false
# because this file is never loaded, so they fall back to window_manager's
# apply_layout (which now positions via the verified dex.sh X11 layer).
#
# It also still contains the OLD ctypes bugs (XOpenDisplay with no restype →
# 64-bit pointer truncation; valuemask 1<<3 = CWBorderPixel instead of 1<<9).
# Do NOT wire this in as-is. If a bare-gamescope (no nested KWin) overlay-plane
# approach is ever revived, port these operations onto dex.sh rather than
# resurrecting this inline ctypes.
#
# Original description below.
# -----------------------------------------------------------------------------
# Pure xdotool/Python-ctypes approach for positioning Minecraft windows inside
# gamescope's XWayland compositor (Steam Deck Game Mode).
#
# THEORY OF OPERATION:
#   Gamescope composites X11 windows in layers:
#     zpos=1: Base layer (focused/game window — always fullscreen)
#     zpos=2: Override-redirect plane (popups/dropdowns — respects geometry)
#     zpos=3: STEAM_OVERLAY plane (Steam overlay — respects geometry)
#     zpos=4: External overlay (mangoapp, etc.)
#
#   The PROBLEM: gamescope forces the focused/game window to fullscreen.
#   xdotool windowmove/windowsize is IGNORED for the focused window.
#
#   The SOLUTION:
#     1. Launch an EMPTY anchor window as GAMESCOPECTRL_BASELAYER_WINDOW
#        — this becomes the "base layer" (fullscreen black background)
#     2. For EACH Minecraft window:
#        a. Strip STEAM_GAME atom (so gamescope doesn't treat it as "the game")
#        b. Strip _NET_WM_STATE_FULLSCREEN (prevent fullscreen resizing)
#        c. Set override_redirect=1 (enter the OR compositing plane)
#        d. Set STEAM_OVERLAY=1 (ensure GPU-accelerated overlay compositing)
#        e. Position via xdotool windowmove/windowsize (geometry IS respected
#           in the OR/overlay plane)
#     3. Result: P1 and P2 render as OR/overlay windows at their specified
#        positions, composited on top of the black anchor background.
#
#   Key insight: The override_redirect UNMAP/REMAP cycle (via Python ctypes)
#   is essential. xdotool alone fails because gamescope intercepts the
#   ConfigureRequest and re-fullscreens the window. The unmap→set OR→remap
#   cycle lets us set attributes BEFORE gamescope's WM logic kicks in.
#
#   ALTERNATIVE (fallback): Set GAMESCOPE_EXTERNAL_OVERLAY instead of
#   STEAM_OVERLAY. External overlays render at zpos=2 (between base and
#   Steam overlay), which may avoid Steam overlay interaction issues.
#
# Public API:
#   gamescope_windowing_init()         — Start the anchor window, set up atoms
#   gamescope_window_setup(wid, x, y, w, h) — Configure one MC window for overlay rendering
#   gamescope_windowing_apply_layout(active_slots, screen_w, screen_h) — Apply full layout
#   gamescope_windowing_cleanup()      — Tear down anchor, clean atoms
#
# Dependencies:
#   - python3 with ctypes (libX11.so.6)
#   - xdotool (for window search / geometry verification)
#   - modules/dex.sh (optional, for some X11 ops)
# =============================================================================

set -euo pipefail

# --- Constants ---
readonly GAMESCOPE_WINDOWING_ANCHOR_TITLE="SplitscreenAnchor"
readonly GAMESCOPE_WINDOWING_DEFAULT_W=1280
readonly GAMESCOPE_WINDOWING_DEFAULT_H=800

# --- Internal state ---
_GW_ANCHOR_PID=""
_GW_ANCHOR_WID=""
_GW_SCREEN_W=""
_GW_SCREEN_H=""

# gamescope_windowing_init: Start the anchor window and detect screen size.
# The anchor is a fullscreen black GTK window that becomes the
# GAMESCOPECTRL_BASELAYER_WINDOW — the ONLY base-layer game window
# gamescope sees. All Minecraft windows will be overlay/OR windows.
#
# Sets _GW_ANCHOR_PID, _GW_ANCHOR_WID, _GW_SCREEN_W, _GW_SCREEN_H.
# Output: nothing (errors to stderr).
gamescope_windowing_init() {
    echo "[gamescope_windowing] Initializing gamescope windowing system..." >&2

    # 1. Detect screen resolution
    _GW_SCREEN_W="${SPLITSCREEN_SCREEN_W:-}"
    _GW_SCREEN_H="${SPLITSCREEN_SCREEN_H:-}"
    if [[ -z "$_GW_SCREEN_W" || -z "$_GW_SCREEN_H" ]]; then
        local res
        res=$(xdpyinfo -display "${DISPLAY:-:0}" 2>/dev/null | awk '/dimensions:/{print $2}')
        if [[ -n "$res" ]]; then
            _GW_SCREEN_W="${res%%x*}"
            _GW_SCREEN_H="${res##*x}"
        else
            _GW_SCREEN_W="$GAMESCOPE_WINDOWING_DEFAULT_W"
            _GW_SCREEN_H="$GAMESCOPE_WINDOWING_DEFAULT_H"
        fi
    fi
    echo "[gamescope_windowing] Screen: ${_GW_SCREEN_W}x${_GW_SCREEN_H}" >&2

    # 2. Launch the anchor window (black GTK window, borderless, fullscreen)
    echo "[gamescope_windowing] Launching gamescope anchor window..." >&2
    local anchor_py="/tmp/splitscreen_anchor_$$.py"
    python3 - "$_GW_SCREEN_W" "$_GW_SCREEN_H" << 'PYEOF' &
import sys, signal, os
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk

w, h = int(sys.argv[1]), int(sys.argv[2])
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(w, h)
win.move(0, 0)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0, 1))
win.set_title('SplitscreenAnchor')
win.show_all()

def on_realize(widget):
    xid = win.get_window().get_xid()
    # Set this window as gamescope's base layer so Steam's loading
    # overlay is dismissed AND this becomes the only fullscreen layer
    import subprocess
    subprocess.run([
        'xprop', '-root', '-display', os.environ.get('DISPLAY', ':0'),
        '-f', 'GAMESCOPECTRL_BASELAYER_WINDOW', '32c',
        '-set', 'GAMESCOPECTRL_BASELAYER_WINDOW', str(xid)
    ], capture_output=True)
    import sys as _sys
    _sys.stderr.write(f'[gamescope_windowing] Anchor WID = {hex(xid)}\n')
    _sys.stderr.write(f'[gamescope_windowing] GAMESCOPECTRL_BASELAYER_WINDOW = {hex(xid)}\n')
    _sys.stderr.flush()

win.connect('realize', on_realize)
signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
Gtk.main()
PYEOF

    _GW_ANCHOR_PID=$!
    echo "[gamescope_windowing] Anchor PID: $_GW_ANCHOR_PID" >&2

    # 3. Wait for the anchor to realize and capture its WID
    sleep 0.5
    _GW_ANCHOR_WID=$(xdotool search --pid "$_GW_ANCHOR_PID" 2>/dev/null | head -1 || echo "")
    if [[ -z "$_GW_ANCHOR_WID" ]]; then
        _GW_ANCHOR_WID=$(xdotool search --name "SplitscreenAnchor" 2>/dev/null | head -1 || echo "")
    fi

    if [[ -n "$_GW_ANCHOR_WID" ]]; then
        echo "[gamescope_windowing] Anchor WID: $_GW_ANCHOR_WID" >&2
        # Force the anchor to correct geometry via OR-cycle (same technique
        # that worked in the override_redirect cycle approach)
        _gw_force_anchor_geometry "$_GW_ANCHOR_WID" 0 0 "$_GW_SCREEN_W" "$_GW_SCREEN_H"
    else
        echo "[gamescope_windowing] WARNING: Could not find anchor WID" >&2
    fi

    # 4. Wait a moment for gamescope to process the anchor
    sleep 0.3

    echo "[gamescope_windowing] Initialization complete" >&2
}

# _gw_force_anchor_geometry: Use Python ctypes OR-cycle to force anchor
# window to the correct fullscreen geometry. The anchor needs to cover
# the entire screen so no gamescope "desktop" background shows through.
_gw_force_anchor_geometry() {
    local wid="$1" x="$2" y="$3" w="$4" h="$5"

    python3 -c "
import ctypes, ctypes.util, os, time
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if dpy:
    wid = $wid
    # Unmap
    lib.XUnmapWindow(dpy, wid)
    lib.XFlush(dpy)
    time.sleep(0.15)
    # Set override_redirect so gamescope doesn't interfere
    class XSetWA(ctypes.Structure):
        _fields_ = [('override_redirect', ctypes.c_int)]
    attrs = XSetWA(override_redirect=ctypes.c_int(1))
    lib.XChangeWindowAttributes(dpy, wid, 1 << 3, ctypes.byref(attrs))
    # Move and resize to fullscreen
    lib.XMoveResizeWindow(dpy, wid, $x, $y, $w, $h)
    lib.XFlush(dpy)
    time.sleep(0.1)
    # Remap
    lib.XMapWindow(dpy, wid)
    lib.XFlush(dpy)
    lib.XRaiseWindow(dpy, wid)
    lib.XFlush(dpy)
    # Clear override_redirect after mapping so gamescope can
    # recognize it as the base layer window
    attrs2 = XSetWA(override_redirect=ctypes.c_int(0))
    lib.XChangeWindowAttributes(dpy, wid, 1 << 3, ctypes.byref(attrs2))
    lib.XFlush(dpy)
    print(f'Anchor geometry forced: {hex(wid)} at {x},{y} {w}x{h}')
    lib.XCloseDisplay(dpy)
" 2>&1 || true
}

# _gw_strip_steam_game: Remove the STEAM_GAME atom from a window.
# This prevents gamescope from treating the window as "the game"
# and force-resizing it to fullscreen on every focus event.
# $1 = window ID (decimal or hex)
_gw_strip_steam_game() {
    local wid="$1"
    echo "[gamescope_windowing] Stripping STEAM_GAME from window $wid" >&2
    python3 -c "
import ctypes, ctypes.util, os, sys
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display', file=sys.stderr)
    sys.exit(1)
wid = $wid
# Delete STEAM_GAME property entirely
from ctypes import c_uint32, c_int, c_ulong, c_void_p, byref, POINTER, c_ubyte, c_char_p

XInternAtom = lib.XInternAtom
XInternAtom.restype = c_ulong
steam_game_atom = XInternAtom(dpy, b'STEAM_GAME', c_int(0))

# Set it to 0 (PropModeReplace, 32-bit, 1 element of 0)
XChangeProperty = lib.XChangeProperty
value = c_uint32(0)
XChangeProperty(dpy, c_ulong(wid), steam_game_atom, c_ulong(4), 32, 0,
                ctypes.cast(byref(value), POINTER(c_ubyte)), c_int(1))
lib.XFlush(dpy)

# Also strip _NET_WM_STATE_FULLSCREEN if present
net_wm_state = XInternAtom(dpy, b'_NET_WM_STATE', c_int(0))
net_wm_state_fs = XInternAtom(dpy, b'_NET_WM_STATE_FULLSCREEN', c_int(0))
# Read current state
actual_type = c_ulong(0)
actual_format = c_int(0)
nitems = c_ulong(0)
bytes_after = c_ulong(0)
prop = c_void_p(None)
XGetWindowProperty = lib.XGetWindowProperty
status = XGetWindowProperty(dpy, c_ulong(wid), net_wm_state, 0, 1024,
                             c_int(0), c_ulong(0), byref(actual_type),
                             byref(actual_format), byref(nitems),
                             byref(bytes_after), byref(prop))
if status == 0 and prop:
    # Remove the FULLSCREEN atom from the state list
    arr = (c_uint32 * 2)(0, 0)  # _NET_WM_STATE_REMOVE, FULLSCREEN atom
    XChangeProperty(dpy, c_ulong(wid), net_wm_state, c_ulong(4), 32, 0,
                    ctypes.cast(arr, POINTER(c_ubyte)), c_int(1))
    lib.XFlush(dpy)
lib.XCloseDisplay(dpy)
print(f'Stripped STEAM_GAME+fullscreen from {hex(wid)}')
" 2>&1 || true
}

# _gw_set_overlay_props: Set override_redirect and STEAM_OVERLAY on a window.
# This puts the window in gamescope's overlay compositing plane where
# per-window geometry IS respected.
# $1 = window ID
_gw_set_overlay_props() {
    local wid="$1"
    echo "[gamescope_windowing] Setting overlay props on window $wid" >&2

    python3 -c "
import ctypes, ctypes.util, os, sys, time
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display', file=sys.stderr)
    sys.exit(1)

wid = $wid
XInternAtom = lib.XInternAtom
XInternAtom.restype = ctypes.c_ulong

# Set STEAM_OVERLAY = 1
steam_overlay_atom = XInternAtom(dpy, b'STEAM_OVERLAY', 0)
val = (ctypes.c_uint32 * 1)(1)
lib.XChangeProperty(dpy, ctypes.c_ulong(wid), steam_overlay_atom,
                    ctypes.c_ulong(4), 32, 0,
                    ctypes.cast(val, ctypes.POINTER(ctypes.c_ubyte)),
                    ctypes.c_int(1))
lib.XFlush(dpy)
time.sleep(0.05)

# Set override_redirect = 1 via XChangeWindowAttributes
class XSetWA(ctypes.Structure):
    _fields_ = [('override_redirect', ctypes.c_int)]
attrs = XSetWA(override_redirect=ctypes.c_int(1))
lib.XChangeWindowAttributes(dpy, ctypes.c_ulong(wid), ctypes.c_ulong(1 << 3), ctypes.byref(attrs))
lib.XFlush(dpy)

# Also set skip_taskbar to prevent any WM interference
# (X11 convention: OR + skip_taskbar = true overlay window)
net_wm_state = XInternAtom(dpy, b'_NET_WM_STATE', 0)
skip_taskbar = XInternAtom(dpy, b'_NET_WM_STATE_SKIP_TASKBAR', 0)
skip_pager = XInternAtom(dpy, b'_NET_WM_STATE_SKIP_PAGER', 0)
# _NET_WM_STATE_ADD = 1
state_arr = (ctypes.c_uint32 * 3)(1, skip_taskbar, skip_pager)
lib.XChangeProperty(dpy, ctypes.c_ulong(wid), net_wm_state,
                    ctypes.c_ulong(4), 32, 0,
                    ctypes.cast(state_arr, ctypes.POINTER(ctypes.c_ubyte)),
                    ctypes.c_int(3))
lib.XFlush(dpy)

lib.XCloseDisplay(dpy)
print(f'Set STEAM_OVERLAY+OR+skip_taskbar on {hex(wid)}')
" 2>&1 || true
}

# _gw_unset_steam_game_fallback: If Python approach fails, use xdotool+xprop.
_gw_unset_steam_game_fallback() {
    local wid="$1"
    xprop -id "$wid" -remove STEAM_GAME 2>/dev/null || true
    xdotool windowstate --remove FULLSCREEN "$wid" 2>/dev/null || true
}

# gamescope_window_setup: Configure a Minecraft window for overlay rendering.
# This is called AFTER the window appears.
# Steps:
#   1. Strip STEAM_GAME (prevent gamescope from treating it as "the game")
#   2. Remove fullscreen state
#   3. Set override_redirect + STEAM_OVERLAY
#   4. Run the OR-cycle to position at (x, y, w, h)
#
# $1 = window ID (decimal)
# $2 = target x
# $3 = target y
# $4 = target w
# $5 = target h
gamescope_window_setup() {
    local wid="$1" x="$2" y="$3" w="$4" h="$5"
    echo "[gamescope_windowing] Setting up window $wid at ${w}x${h}+${x}+${y}" >&2

    # Step 1: Strip STEAM_GAME
    _gw_strip_steam_game "$wid" || _gw_unset_steam_game_fallback "$wid"

    # Small delay for gamescope to process the atom change
    sleep 0.1

    # Step 2: Set overlay properties (STEAM_OVERLAY + OR + skip_taskbar)
    _gw_set_overlay_props "$wid" || true

    sleep 0.1

    # Step 3: Run the override_redirect unmap/remap cycle to position
    _gw_or_cycle_position "$wid" "$x" "$y" "$w" "$h"

    # Step 4: Verify
    _gw_verify_position "$wid" "$x" "$y" "$w" "$h"
}

# _gw_or_cycle_position: Unmap → set OR → move/resize → remap.
# This is the core technique that was "making progress" before TinyWM.
# Using Python ctypes for maximum reliability inside gamescope.
# $1 = wid, $2 = x, $3 = y, $4 = w, $5 = h
_gw_or_cycle_position() {
    local wid="$1" x="$2" y="$3" w="$4" h="$5"
    echo "[gamescope_windowing] OR-cycle: $wid → ${w}x${h}+${x}+${y}" >&2

    python3 -c "
import ctypes, ctypes.util, os, sys, time
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(os.environ.get('DISPLAY', ':0').encode())
if not dpy:
    print('FAIL: cannot open display', file=sys.stderr)
    sys.exit(1)

wid = ${wid}

# 1. Unmap
lib.XUnmapWindow(dpy, wid)
lib.XFlush(dpy)
time.sleep(0.15)

# 2. Set override_redirect
class XSetWA(ctypes.Structure):
    _fields_ = [('override_redirect', ctypes.c_int)]
attrs = XSetWA(override_redirect=ctypes.c_int(1))
lib.XChangeWindowAttributes(dpy, wid, 1 << 3, ctypes.byref(attrs))

# 3. Move and resize
lib.XMoveResizeWindow(dpy, wid, $x, $y, $w, $h)
lib.XFlush(dpy)
time.sleep(0.1)

# 4. Remap
lib.XMapWindow(dpy, wid)
lib.XFlush(dpy)
time.sleep(0.15)

# 5. Raise
lib.XRaiseWindow(dpy, wid)
lib.XFlush(dpy)

# 6. Verify via XGetWindowAttributes
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
        ('colormap', ctypes.c_ulong),
    ]
attrs_out = XWindowAttrs()
lib.XGetWindowAttributes(dpy, wid, ctypes.byref(attrs_out))
print(f'OR-CYCLE RESULT: pos={attrs_out.x},{attrs_out.y} size={attrs_out.width}x{attrs_out.height} OR={attrs_out.override_redirect} map={attrs_out.map_state}')

lib.XCloseDisplay(dpy)
" 2>&1 || true
}

# _gw_verify_position: Read actual geometry and log it.
_gw_verify_position() {
    local wid="$1" ex="$2" ey="$3" ew="$4" eh="$5"
    local ax ay aw ah
    ax=$(xdotool getwindowgeometry "$wid" 2>/dev/null | grep -oP 'Position: \K\d+,\d+' | cut -d, -f1 || echo "?")
    ay=$(xdotool getwindowgeometry "$wid" 2>/dev/null | grep -oP 'Position: \K\d+,\d+' | cut -d, -f2 || echo "?")
    aw=$(xdotool getwindowgeometry "$wid" 2>/dev/null | grep -oP 'Geometry: \K\d+x\d+' | cut -dx -f1 || echo "?")
    ah=$(xdotool getwindowgeometry "$wid" 2>/dev/null | grep -oP 'Geometry: \K\d+x\d+' | cut -dx -f2 || echo "?")
    if [[ "$ax" != "?" && "$ay" != "?" && "$aw" != "?" && "$ah" != "?" ]]; then
        if [[ "$ax" -ne "$ex" || "$ay" -ne "$ey" || "$aw" -ne "$ew" || "$ah" -ne "$eh" ]]; then
            echo "[gamescope_windowing] WARNING: Geometry mismatch: wanted ${ex},${ey} ${ew}x${eh} but got ${ax},${ay} ${aw}x${ah}" >&2
        else
            echo "[gamescope_windowing] Verify: geometry OK (${ax},${ay} ${aw}x${ah})" >&2
        fi
    else
        echo "[gamescope_windowing] WARNING: Could not verify window $wid" >&2
    fi
}

# gamescope_windowing_apply_layout: Apply the full splitscreen layout.
# For each active slot, find its window, strip game props, set overlay
# props, and position via OR-cycle.
#
# $1 = active_slots (space-separated, e.g. "1 2")
# $2 = screen_w (optional)
# $3 = screen_h (optional)
gamescope_windowing_apply_layout() {
    local active_slots="${1:-}"
    local screen_w="${2:-$_GW_SCREEN_W}"
    local screen_h="${3:-$_GW_SCREEN_H}"

    # Default to detected screen size
    if [[ -z "$screen_w" || "$screen_w" -eq 0 ]]; then screen_w="$_GW_SCREEN_W"; fi
    if [[ -z "$screen_h" || "$screen_h" -eq 0 ]]; then screen_h="$_GW_SCREEN_H"; fi

    echo "[gamescope_windowing] Applying layout: active_slots='$active_slots', ${screen_w}x${screen_h}" >&2

    # Compute grid mode
    local grid_mode
    grid_mode=$(compute_grid_mode "$active_slots" 2>/dev/null || echo "half")
    echo "[gamescope_windowing] Grid mode: $grid_mode" >&2

    # Process each slot
    local slot
    for slot in 1 2 3 4; do
        # Check if this slot is active
        local is_active=0
        local as
        for as in $active_slots; do
            if [[ "$as" == "$slot" ]]; then
                is_active=1
                break
            fi
        done
        if (( is_active == 0 )); then
            continue
        fi

        # Compute geometry for this slot
        local geometry x y w h
        geometry=$(compute_slot_geometry "$slot" "$grid_mode" "$screen_w" "$screen_h" 2>/dev/null || echo "0 0 $screen_w $screen_h")
        read -r x y w h <<< "$geometry"

        # Find the window for this slot
        local wid
        wid=$(_gw_find_slot_window "$slot")
        if [[ -z "$wid" ]]; then
            echo "[gamescope_windowing] Window for slot $slot not found yet, skipping" >&2
            continue
        fi

        echo "[gamescope_windowing] Slot $slot: window $wid → ${w}x${h}+${x}+${y}" >&2
        gamescope_window_setup "$wid" "$x" "$y" "$w" "$h"
    done
}

# _gw_find_slot_window: Find the WID for a given slot.
# Checks state file first, then falls back to xdotool name search.
_gw_find_slot_window() {
    local slot="$1"
    local sf="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    local wid=""
    [[ -f "$sf" ]] && wid=$(jq -r ".slots[\"${slot}\"].wid // empty" "$sf" 2>/dev/null || true)
    [[ -z "$wid" ]] && wid=$(xdotool search --name "SplitscreenP${slot}" 2>/dev/null | head -1 || true)
    [[ -z "$wid" ]] && wid=$(xdotool search --name "Minecraft" 2>/dev/null | head -5 | tail -1 || true)
    echo "$wid"
}

# gamescope_windowing_cleanup: Tear down the anchor window and clean up.
gamescope_windowing_cleanup() {
    echo "[gamescope_windowing] Cleaning up..." >&2

    # Kill anchor window
    if [[ -n "$_GW_ANCHOR_PID" ]]; then
        kill "$_GW_ANCHOR_PID" 2>/dev/null || true
        _GW_ANCHOR_PID=""
    fi

    # Clear GAMESCOPECTRL_BASELAYER_WINDOW on root
    xprop -root -display "${DISPLAY:-:0}" -f GAMESCOPECTRL_BASELAYER_WINDOW 32c \
        -set GAMESCOPECTRL_BASELAYER_WINDOW 0 2>/dev/null || true

    echo "[gamescope_windowing] Cleanup complete" >&2
}
