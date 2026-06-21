#!/bin/bash
set -euo pipefail

# =============================================================================
# WINDOW MANAGER MODULE
# =============================================================================
# Computes window geometry for splitscreen Minecraft instances and applies
# layout via xdotool. Maintains black placeholder windows for vacant slots.
#
# Public API:
#   compute_grid_mode(active_slots)          — stdout: "full", "half", or "quad"
#   compute_slot_geometry(slot, grid, W, H)  — stdout: "x y w h"
#   apply_layout(active_slots, W, H)         — repositions windows, manages placeholders
#   kill_all_placeholders()                  — kills all placeholder windows
#
# Environment overrides:
#   SPLITSCREEN_SCREEN_W, SPLITSCREEN_SCREEN_H — force screen dimensions
# =============================================================================

# --- Module-level constants ---
readonly WINDOW_MANAGER_DEFAULT_SCREEN_W=1280
readonly WINDOW_MANAGER_DEFAULT_SCREEN_H=800
readonly WINDOW_MANAGER_WINDOW_WAIT_TIMEOUT_S=30
readonly WINDOW_MANAGER_XTERM_CHAR_W=6   # approximate pixel width per character cell
readonly WINDOW_MANAGER_XTERM_CHAR_H=13  # approximate pixel height per character cell

# --- Internal state ---
# Track PIDs of placeholder windows: key="slot", value="pid"
declare -A _WINDOW_MANAGER_PLACEHOLDER_PIDS

# --- Internal functions ---

# _apply_override_redirect_cycle: Unmap → set override_redirect → move/resize → remap.
# Uses Python + ctypes X11 directly (avoids xdotool which gamescope may ignore).
# The unmap/remap cycle forces the X server to forget the window's WM-managed state;
# setting override_redirect between them makes it unmanaged so gamescope's WM
# won't intercept the MapRequest and force its own geometry.
#
# Arguments: $1 = WID (decimal or hex), $2 = x, $3 = y, $4 = w, $5 = h
# Returns: 0 if the cycle succeeded (verified by post-check), 1 if it failed.
_apply_override_redirect_cycle() {
    local wid="$1" x="$2" y="$3" w="$4" h="$5"

    # Delegate to dex.sh — the single, verified X11 layer (ctypes via libX11).
    # This replaced an inline ctypes copy of the same logic; keeping three
    # divergent copies (here, instance_lifecycle.sh, gamescope_windowing.sh) is
    # exactly how the pointer-truncation / valuemask / struct bugs crept in.
    # dex_move_resize_force was confirmed on-Deck to position windows exactly in
    # gamescope's XWayland (strategy 2 = override_redirect + XConfigure).
    if ! type dex_move_resize_force >/dev/null 2>&1; then
        echo "[window_manager] ERROR: dex.sh not sourced — cannot position window $wid" >&2
        return 1
    fi

    # Set override_redirect first so KWin/gamescope won't re-tile the window,
    # then move/resize. dex_move_resize_force tries plain move, then
    # override_redirect+XConfigure, then XConfigure, returning the strategy that
    # actually stuck (0 = all failed).
    dex_set_override_redirect "$wid" 1 2>/dev/null || true
    local strat
    strat=$(dex_move_resize_force "$wid" "$x" "$y" "$w" "$h" 2>/dev/null || echo 0)

    local geo
    geo=$(dex_getgeometry "$wid" 2>/dev/null || echo "")
    echo "[window_manager] dex position: window $wid → ${w}x${h}+${x}+${y} (strategy=$strat) readback=[${geo:-?}]" >&2

    if [[ "$strat" != "0" && "$strat" != "fail" && -n "$geo" ]]; then
        return 0
    fi
    echo "[window_manager] dex position FAILED for window $wid (strategy=$strat)" >&2
    return 1
}

# _get_screen_resolution: Discover screen dimensions.
# Priority: wlr-randr → kscreen-doctor → xrandr → xdpyinfo → env override → fallback.
# Output: "W H" on stdout.
_get_screen_resolution() {
    # 1. wlr-randr
    if command -v wlr-randr >/dev/null 2>&1; then
        local wr_output
        wr_output=$(wlr-randr 2>/dev/null || true)
        if [[ -n "$wr_output" ]]; then
            # Parse lines like: "HDMI-A-1 ... 1920x1080@60 ... (current)"
            local wr_line
            wr_line=$(echo "$wr_output" | grep -m1 '(current)' || true)
            if [[ "$wr_line" =~ ([0-9]+)x([0-9]+) ]]; then
                echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
                echo "[window_manager] Screen resolution via wlr-randr: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
                return 0
            fi
        fi
    fi

    # 2. kscreen-doctor
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local ks_output
        ks_output=$(kscreen-doctor -o 2>/dev/null || true)
        if [[ -n "$ks_output" ]]; then
            # Look for enabled primary output's resolution
            local ks_line
            ks_line=$(echo "$ks_output" | grep -m1 'enabled' | grep -v 'eDP' || true)
            if [[ -z "$ks_line" ]]; then
                ks_line=$(echo "$ks_output" | grep -m1 'enabled' || true)
            fi
            if [[ "$ks_line" =~ ([0-9]+)x([0-9]+) ]]; then
                echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
                echo "[window_manager] Screen resolution via kscreen-doctor: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
                return 0
            fi
        fi
    fi

    # 3. xrandr
    if command -v xrandr >/dev/null 2>&1; then
        local xr_output
        xr_output=$(xrandr 2>/dev/null || true)
        if [[ -n "$xr_output" ]]; then
            # Parse the current mode line: "   1920x1080      60.00*+"
            local xr_line
            xr_line=$(echo "$xr_output" | grep -m1 '\*' || true)
            if [[ "$xr_line" =~ ([0-9]+)x([0-9]+) ]]; then
                echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
                echo "[window_manager] Screen resolution via xrandr: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
                return 0
            fi
        fi
    fi

    # 4. xdpyinfo
    if command -v xdpyinfo >/dev/null 2>&1; then
        local xd_output
        xd_output=$(xdpyinfo 2>/dev/null | grep 'dimensions:' || true)
        if [[ "$xd_output" =~ ([0-9]+)x([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
            echo "[window_manager] Screen resolution via xdpyinfo: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
            return 0
        fi
    fi

    # 5. Environment variable override
    if [[ -n "${SPLITSCREEN_SCREEN_W:-}" && -n "${SPLITSCREEN_SCREEN_H:-}" ]]; then
        echo "${SPLITSCREEN_SCREEN_W} ${SPLITSCREEN_SCREEN_H}"
        echo "[window_manager] Screen resolution via env override: ${SPLITSCREEN_SCREEN_W}x${SPLITSCREEN_SCREEN_H}" >&2
        return 0
    fi

    # 6. Fallback
    echo "[window_manager] All resolution detection methods failed, using fallback ${WINDOW_MANAGER_DEFAULT_SCREEN_W}x${WINDOW_MANAGER_DEFAULT_SCREEN_H}" >&2
    echo "${WINDOW_MANAGER_DEFAULT_SCREEN_W} ${WINDOW_MANAGER_DEFAULT_SCREEN_H}"
    return 0
}

# _spawn_placeholder: Create a black borderless window for a vacant slot.
# $1 = slot (1-4)
# $2 = x, $3 = y, $4 = w, $5 = h
_spawn_placeholder() {
    local slot="$1"
    local x="$2"
    local y="$3"
    local w="$4"
    local h="$5"

    # Kill any existing placeholder for this slot
    if [[ -n "${_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]:-}" ]]; then
        kill "${_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]}" 2>/dev/null || true
        unset '_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]'
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "[window_manager] Spawning tkinter black placeholder for slot $slot (${w}x${h}+${x}+${y})" >&2
        python3 -c "
import tkinter as tk
root = tk.Tk()
root.configure(bg='black')
root.overrideredirect(True)
root.geometry('${w}x${h}+${x}+${y}')
root.title('SplitscreenBlack${slot}')
root.mainloop()
" &
        local pid=$!
        _WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]="$pid"
    elif command -v xterm >/dev/null 2>&1; then
        local cols=$(( w / WINDOW_MANAGER_XTERM_CHAR_W ))
        local rows=$(( h / WINDOW_MANAGER_XTERM_CHAR_H ))
        (( cols < 1 )) && cols=1
        (( rows < 1 )) && rows=1
        echo "[window_manager] Spawning xterm placeholder for slot $slot (${cols}x${rows}+${x}+${y})" >&2
        xterm -bg black -fg black -geometry "${cols}x${rows}+${x}+${y}" -T "SplitscreenBlack${slot}" &
        local pid=$!
        _WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]="$pid"
    else
        echo "[window_manager] ERROR: neither python3 nor xterm available for placeholder window" >&2
        return 1
    fi
}

# _kill_placeholder: Kill the placeholder for a specific slot.
# $1 = slot
_kill_placeholder() {
    local slot="$1"
    if [[ -n "${_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]:-}" ]]; then
        echo "[window_manager] Killing placeholder for slot $slot (PID ${_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]})" >&2
        kill "${_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]}" 2>/dev/null || true
        unset '_WINDOW_MANAGER_PLACEHOLDER_PIDS[$slot]'
    fi
}

# _verify_window_geometry: After applying positioning, query the actual
# position/size via ctypes and log it.
# $1 = slot label (e.g. "1"), $2 = window WID, $3 = expected_x, $4 = expected_y,
# $5 = expected_w, $6 = expected_h
_verify_window_geometry() {
    local slot="$1" wid="$2"
    local ex="$3" ey="$4" ew="$5" eh="$6"
    local ax ay aw ah
    local geo
    geo=$(dex_getgeometry "$wid" 2>/dev/null || echo "")
    if [[ -n "$geo" ]]; then
        read -r ax ay aw ah <<< "$geo"
    else
        ax="?"; ay="?"; aw="?"; ah="?"
    fi
    ah=$(dex_getgeometry "$wid" 2>/dev/null | awk '{print $4}' || echo "?")
    if [[ "$ax" != "?" && "$ay" != "?" && "$aw" != "?" && "$ah" != "?" ]]; then
        if [[ "$ax" -ne "$ex" || "$ay" -ne "$ey" || "$aw" -ne "$ew" || "$ah" -ne "$eh" ]]; then
            echo "[window_manager] WARNING: slot $slot geometry mismatch: wanted ${ex},${ey} ${ew}x${eh} but got ${ax},${ay} ${aw}x${ah}" >&2
        else
            echo "[window_manager] Verify slot $slot: geometry OK (${ax},${ay} ${aw}x${ah})" >&2
        fi
    else
        echo "[window_manager] WARNING: slot $slot geometry check failed — could not query window $wid (got ax=$ax ay=$ay aw=$aw ah=$ah)" >&2
    fi
}

# _get_wid_from_state: Read a slot's WID from the state JSON file, or fall back
# to dex window-name search if missing.
# $1 = slot (1-4)
# Output: WID on stdout, or empty string on failure.
_get_wid_from_state() {
    local slot="$1"
    local sf="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    local wid=""
    [[ -f "$sf" ]] && wid=$(jq -r ".slots[\"${slot}\"].wid // empty" "$sf" 2>/dev/null || true)
    [[ -z "$wid" ]] && wid=$(dex_search --name "SplitscreenP${slot}" 2>/dev/null || true)
    echo "$wid"
}

# --- Public API ---

# Determine grid mode from the set of active slot numbers.
# Arguments: $1 = space-separated list of active slot numbers, e.g. "1 3"
# Output: "full", "half", or "quad" on stdout.
# Empty input → "full".
compute_grid_mode() {
    local active_slots="${1:-}"

    # Normalize: trim, compress whitespace
    active_slots=$(echo "$active_slots" | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$active_slots" ]]; then
        echo "full"
        return 0
    fi

    # Find the highest active slot number
    local highest=0
    local slot
    for slot in $active_slots; do
        if [[ "$slot" =~ ^[1-4]$ ]]; then
            if (( slot > highest )); then
                highest=$slot
            fi
        fi
    done

    if (( highest <= 0 )); then
        echo "full"
    elif (( highest == 1 )); then
        echo "full"
    elif (( highest == 2 )); then
        echo "half"
    else
        echo "quad"
    fi
}

# Compute geometry for a given slot in a given grid mode.
# Arguments: $1=slot(1-4), $2=grid_mode(full|half|quad), $3=screen_w, $4=screen_h
# Output: "x y w h" on stdout.
compute_slot_geometry() {
    local slot="${1:-1}"
    local grid_mode="${2:-full}"
    local screen_w="${3:-1280}"
    local screen_h="${4:-800}"

    case "$grid_mode" in
        full)
            echo "0 0 $screen_w $screen_h"
            ;;
        half)
            local half_h=$(( screen_h / 2 ))
            case "$slot" in
                1) echo "0 0 $screen_w $half_h" ;;
                2) echo "0 $half_h $screen_w $half_h" ;;
                *) echo "0 0 $screen_w $screen_h" ;; # fallback for invalid slot
            esac
            ;;
        quad)
            local half_w=$(( screen_w / 2 ))
            local half_h=$(( screen_h / 2 ))
            case "$slot" in
                1) echo "0 0 $half_w $half_h" ;;
                2) echo "$half_w 0 $half_w $half_h" ;;
                3) echo "0 $half_h $half_w $half_h" ;;
                4) echo "$half_w $half_h $half_w $half_h" ;;
                *) echo "0 0 $screen_w $screen_h" ;; # fallback for invalid slot
            esac
            ;;
        *)
            echo "[window_manager] ERROR: unknown grid mode '$grid_mode'" >&2
            echo "0 0 $screen_w $screen_h"
            return 1
            ;;
    esac
}

# Apply the full layout for the current active slots.
# Arguments: $1=active_slots (space-separated), $2=screen_w, $3=screen_h
# Effects: repositions Minecraft windows, spawns/kills black placeholders.
apply_layout() {
    local active_slots="${1:-}"
    local screen_w="${2:-}"
    local screen_h="${3:-}"

    # Resolve screen dimensions if not provided
    if [[ -z "$screen_w" || -z "$screen_h" ]]; then
        local dims
        dims=$(_get_screen_resolution)
        screen_w=$(echo "$dims" | awk '{print $1}')
        screen_h=$(echo "$dims" | awk '{print $2}')
    fi

    local grid_mode
    grid_mode=$(compute_grid_mode "$active_slots")

    echo "[window_manager] Applying layout: active_slots='$active_slots', grid=$grid_mode, ${screen_w}x${screen_h}" >&2

    # List visible windows for debugging (via dex — the single X11 layer).
    # Best-effort; never use xdotool here (its search/getwindowname can block
    # indefinitely inside gamescope's XWayland, freezing the synchronous caller).
    if type dex_list_windows >/dev/null 2>&1; then
        echo "[window_manager] All visible windows (via dex):" >&2
        dex_list_windows 2>/dev/null | while read -r w name; do
            echo "  $w: $name" >&2
        done
    fi

    # In full mode, only slot 1 matters — no placeholders needed for other slots
    if [[ "$grid_mode" == "full" ]]; then
        local wid
        wid=$(_get_wid_from_state 1)
        if [[ -n "$wid" ]]; then
            echo "[window_manager] Repositioning slot 1: window $wid → fullscreen" >&2
            _apply_override_redirect_cycle "$wid" 0 0 "$screen_w" "$screen_h"
            _verify_window_geometry 1 "$wid" 0 0 "$screen_w" "$screen_h"
        fi
        return 0
    fi

    local -a active_array=($active_slots)

    # Determine the highest slot number the current grid supports.
    # Slots beyond this limit are simply ignored — they have no defined
    # geometry in this grid mode and must not receive placeholder windows.
    local max_grid_slot
    case "$grid_mode" in
        half) max_grid_slot=2 ;;
        quad) max_grid_slot=4 ;;
        *)    max_grid_slot=1 ;;
    esac

    # Process only slots within the grid capacity
    local slot
    for slot in 1 2 3 4; do
        if (( slot > max_grid_slot )); then
            # Kill any stale placeholder that may have been left from a
            # previous layout (e.g. transitioning from quad back to half)
            _kill_placeholder "$slot"
            continue
        fi
        local is_active=0
        local as
        for as in "${active_array[@]}"; do
            if [[ "$as" == "$slot" ]]; then
                is_active=1
                break
            fi
        done

        local geometry
        geometry=$(compute_slot_geometry "$slot" "$grid_mode" "$screen_w" "$screen_h")
        local x y w h
        read -r x y w h <<< "$geometry"

        if (( is_active == 1 )); then
            # Kill placeholder if one exists for this slot
            _kill_placeholder "$slot"

            # Find and reposition the Minecraft window.
            # _get_wid_from_state prefers WID from state file (reliable in gamescope)
            # and falls back to xdotool name search for X11 sessions.
            local wid
            wid=$(_get_wid_from_state "$slot")
            if [[ -n "$wid" ]]; then
                echo "[window_manager] Repositioning slot $slot: window $wid → ${w}x${h}+${x}+${y}" >&2

                # KEY FIX: Set override_redirect via Python ctypes unmap/remap cycle.
                # KWin in --x11-display mode tiles windows on MapNotify.
                # Setting override_redirect post-map is too late — KWin already
                # decided the layout.  Solution: unmap first (so KWin forgets
                # the window), set override_redirect, then remap at desired
                # geometry.  The window becomes "unmanaged" from KWin's POV.
                # Using Python ctypes X11 directly is more reliable than xdotool
                # inside gamescope's XWayland where xdotool's windowmove/windowsize
                # may return success but have no visual effect.
                _apply_override_redirect_cycle "$wid" "$x" "$y" "$w" "$h"
                echo "[orchestrator] WINDOW SplitscreenP${slot}: ${x},${y} ${w}x${h} ($grid_mode) [override_redirect via unmap/remap]" >&2
                _verify_window_geometry "$slot" "$wid" "$x" "$y" "$w" "$h"
            else
                echo "[window_manager] Window for slot $slot not found (SplitscreenP${slot})" >&2
            fi
        else
            # Vacant slot — spawn placeholder
            _spawn_placeholder "$slot" "$x" "$y" "$w" "$h"
        fi
    done
}

# Kill all placeholder windows spawned by this module.
kill_all_placeholders() {
    echo "[window_manager] Killing all placeholders" >&2
    local slot
    for slot in "${!_WINDOW_MANAGER_PLACEHOLDER_PIDS[@]}"; do
        _kill_placeholder "$slot"
    done
}

# =============================================================================
# TinyWM Integration
# =============================================================================
# TinyWM is a minimal Python ctypes-X11 window manager that replaces KWin
# inside gamescope. It takes SubstructureRedirectMask on the root window,
# intercepts MapRequest events, and positions windows according to the
# splitscreen_state.json geometry.
#
# This approach avoids the unreliability of xdotool override_redirect hacks
# (which KWin fights inside --x11-display mode). TinyWM becomes the sole WM
# on :0 and simply puts windows where they belong.
#
# Environment:
#   TINYWM_DISABLE=1  — set to skip TinyWM startup (falls back to xdotool)
#   TINYWM_STATE_FILE — path to state file (default: SPLITSCREEN_STATE)
# =============================================================================

# Path to the TinyWM Python script
readonly _TINYWM_SCRIPT="$SCRIPT_DIR/modules/tinywm.py"
_TINYWM_PID=""   # PID of the running TinyWM process

# _install_tinywm: Ensure tinywm.py is installed to a known path, symlinking
# from the repo location if needed. Returns the script path on stdout.
_install_tinywm() {
    local tinywm_src="$SCRIPT_DIR/modules/tinywm.py"
    local tinywm_dst="/tmp/tinywm.py"

    if [[ -f "$tinywm_src" ]]; then
        # Symlink from repo into /tmp so it's always at the expected location
        if [[ ! -L "$tinywm_dst" ]] || [[ "$(readlink -f "$tinywm_dst")" != "$(readlink -f "$tinywm_src")" ]]; then
            ln -sf "$tinywm_src" "$tinywm_dst" 2>/dev/null || true
        fi
    elif [[ -f "$tinywm_dst" ]]; then
        # Already at /tmp, use it
        true
    else
        echo "[window_manager] TinyWM script not found at $tinywm_src or $tinywm_dst" >&2
        return 1
    fi
    echo "$tinywm_dst"
}

# start_tinywm: Launch TinyWM as the window manager on the current display.
# Must be called BEFORE Minecraft windows are created, so TinyWM catches
# their MapRequest events as the sole WM.
#
# Arguments:
#   $1  — X display (default: :0)
#   $2  — state file path (default: SPLITSCREEN_STATE or ~/.local/share/PolyMC/splitscreen_state.json)
#
# Sets _TINYWM_PID globally. Returns 0 on success, 1 on failure.
start_tinywm() {
    local display="${1:-:0}"
    local state_file="${2:-${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}}"

    # Skip if disabled
    if [[ "${TINYWM_DISABLE:-0}" == "1" ]]; then
        echo "[window_manager] TinyWM disabled via TINYWM_DISABLE=1 — using xdotool fallback" >&2
        return 0
    fi

    # Check if TinyWM script exists
    local tinywm_script
    tinywm_script="$(_install_tinywm)" || {
        echo "[window_manager] ERROR: Cannot start TinyWM — script not found" >&2
        return 1
    }

    # Check Python3 availability
    if ! command -v python3 >/dev/null 2>&1; then
        echo "[window_manager] ERROR: python3 not found — cannot start TinyWM" >&2
        return 1
    fi

    # Check if we can open the X display
    # Try to open the X display. For gamescope, DISPLAY is already :0.
    # Use DISPLAY="${display}" (NO backslash-quotes — literal quotes break XOpenDisplay)
    if ! DISPLAY="${display}" python3 -c "
import ctypes, ctypes.util
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(b'${display}')
if not dpy:
    print('FAIL: cannot open ${display}')
    exit(1)
lib.XCloseDisplay(dpy)
print('OK: ${display}')
" 2>/dev/null; then
        echo "[window_manager] ERROR: Cannot open display ${display} for TinyWM" >&2
        return 1
    fi

    # Check if another WM is already running (SubstructureRedirect already claimed)
    if DISPLAY="${display}" python3 -c "
import os, ctypes, ctypes.util
lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library('X11') or 'libX11.so.6')
dpy = lib.XOpenDisplay(b'${display}')
if not dpy: exit(2)
root = lib.XDefaultRootWindow(dpy)
SubstructureRedirectMask = 1 << 16
XSelectInput = lib.XSelectInput
import signal
# Temporarily suppress X errors
def handler(d,e): return 0
cb = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)(handler)
lib.XSetErrorHandler(cb)
lib.XSelectInput(dpy, root, SubstructureRedirectMask)
lib.XSync(dpy, 0)
# If another WM already claimed SubstructureRedirect, the error handler
# will have been called with BadAccess. We can't easily check err from python
# but we can note it.
lib.XCloseDisplay(dpy)
" 2>&1 | grep -q 'BadAccess\|already managing'; then
        echo "[window_manager] WARNING: Another WM may already be managing display ${display}" >&2
        echo "[window_manager] TinyWM will try to run anyway (may get BadAccess errors)" >&2
    fi

    echo "[window_manager] Starting TinyWM on ${display} (state: ${state_file})" >&2

    # Launch TinyWM in background. It connects to :0 and registers as WM.
    # We pass display, state_file, and FIFO path so it can auto-reload layout.
    local fifo="${SPLITSCREEN_FIFO:-}"
    local fifo_arg=""
    [[ -n "$fifo" ]] && fifo_arg="$fifo"

    DISPLAY="${display}" python3 "$tinywm_script" "${display}" "${state_file}" "${fifo_arg}" &
    _TINYWM_PID=$!

    # Wait briefly for TinyWM to connect and verify it's alive
    sleep 0.5

    if kill -0 "$_TINYWM_PID" 2>/dev/null; then
        echo "[window_manager] TinyWM started (PID $_TINYWM_PID)" >&2
        return 0
    else
        echo "[window_manager] ERROR: TinyWM failed to start" >&2
        _TINYWM_PID=""
        return 1
    fi
}

# stop_tinywm: Gracefully terminate the TinyWM window manager.
# Sends SIGTERM and waits for exit. Called by cleanup trap.
stop_tinywm() {
    if [[ -z "$_TINYWM_PID" ]]; then
        return 0
    fi

    echo "[window_manager] Stopping TinyWM (PID $_TINYWM_PID)" >&2

    if kill -0 "$_TINYWM_PID" 2>/dev/null; then
        kill "$_TINYWM_PID" 2>/dev/null || true
        local _i
        for (( _i = 0; _i < 5; _i++ )); do
            if ! kill -0 "$_TINYWM_PID" 2>/dev/null; then
                echo "[window_manager] TinyWM stopped" >&2
                _TINYWM_PID=""
                return 0
            fi
            sleep 0.5
        done
        # Force kill if still running
        kill -9 "$_TINYWM_PID" 2>/dev/null || true
        echo "[window_manager] TinyWM force killed" >&2
    fi

    _TINYWM_PID=""
}

# is_tinywm_running: Return 0 if TinyWM is running, 1 otherwise.
is_tinywm_running() {
    [[ -n "$_TINYWM_PID" ]] && kill -0 "$_TINYWM_PID" 2>/dev/null
}

# signal_tinywm_layout: Signal TinyWM to reload layout by touching the state
# file's mtime. TinyWM detects mtime changes on each MapRequest/ConfigureRequest.
# Using touch is simpler than a dedicated IPC channel.
signal_tinywm_layout() {
    local state_file="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    if [[ -f "$state_file" ]]; then
        touch "$state_file" 2>/dev/null || true
        echo "[window_manager] Signalled TinyWM layout reload (touched $state_file)" >&2
    fi
}

# sync_apply_layout: Wrapper around apply_layout.
# When the gamescope windowing system is active, we call it instead.
# Otherwise, we use the standard apply_layout (which works on KWin/Desktop).
#
# Arguments: same as apply_layout — active_slots, screen_w, screen_h
sync_apply_layout() {
    local active_slots="${1:-}"
    local screen_w="${2:-}"
    local screen_h="${3:-}"

    # Check if gamescope windowing is active (anchor PID exists)
    if [[ -n "${_GW_ANCHOR_PID:-}" ]] && kill -0 "${_GW_ANCHOR_PID}" 2>/dev/null; then
        echo "[window_manager] Gamescope windowing active, delegating to gamescope_windowing_apply_layout" >&2
        if command -v gamescope_windowing_apply_layout >/dev/null 2>&1 || type gamescope_windowing_apply_layout >/dev/null 2>&1; then
            gamescope_windowing_apply_layout "$active_slots" "$screen_w" "$screen_h"
        else
            apply_layout "$active_slots" "$screen_w" "$screen_h"
        fi
    else
        # No gamescope windowing — use regular apply_layout (Desktop KWin, etc.)
        apply_layout "$active_slots" "$screen_w" "$screen_h"
    fi
}
