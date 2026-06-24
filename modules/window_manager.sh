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
#   apply_layout(active_slots, W, H)         — repositions active windows (KWin scripting)
#
# Environment overrides:
#   SPLITSCREEN_SCREEN_W, SPLITSCREEN_SCREEN_H — force screen dimensions
# =============================================================================

# --- Module-level constants ---
readonly WINDOW_MANAGER_DEFAULT_SCREEN_W=1280
readonly WINDOW_MANAGER_DEFAULT_SCREEN_H=800
readonly WINDOW_MANAGER_WINDOW_WAIT_TIMEOUT_S=30

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
    # This replaced earlier divergent inline ctypes copies of the same logic,
    # which is exactly how the pointer-truncation / valuemask / struct bugs crept
    # in.  dex's move/resize is confirmed on-Deck to position windows in the
    # nested XWayland (override_redirect + XConfigure).
    if ! type dex_move_resize_remap >/dev/null 2>&1; then
        echo "[window_manager] ERROR: dex.sh not sourced — cannot position window $wid" >&2
        return 1
    fi

    # Full cycle: unmap → set override_redirect → move/resize → map → raise.
    # Setting override_redirect on a live KWin-managed window makes KWin unmanage
    # and UNMAP it, and the change only applies at the next map (ICCCM).  The old
    # code set override_redirect + XConfigure but never remapped, so reflowed
    # windows ended up with the correct geometry but UNMAPPED (invisible) — the
    # "windows disappear when a second player joins" bug.  dex_move_resize_remap
    # performs the whole cycle and echoes the geometry readback.
    local geo
    geo=$(dex_move_resize_remap "$wid" "$x" "$y" "$w" "$h" 2>/dev/null || echo "")
    echo "[window_manager] dex remap: window $wid → ${w}x${h}+${x}+${y} readback=[${geo:-?}]" >&2

    [[ -n "$geo" ]] && return 0
    echo "[window_manager] dex remap FAILED for window $wid" >&2
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

# NOTE: black placeholder windows were removed 2026-06-23. They existed only to mask
# the desktop showing through empty quad cells, but the splitscreen session kills
# plasmashell (black backdrop), so empty cells are already black. The leaked ones
# (their PIDs didn't survive apply_layout's background subshells) were covering the
# real game windows. Empty cells now simply show the black backdrop.

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

# _get_pid_from_state: Read a slot's Minecraft (java) PID from the state JSON.
# $1 = slot (1-4).  Output: PID on stdout, or empty string.
# The KWin positioner matches windows by PID (window.windowId is undefined in
# KWin 6.x), so this is the primary identifier for Path-B positioning.
_get_pid_from_state() {
    local slot="$1"
    local sf="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    [[ -f "$sf" ]] && jq -r ".slots[\"${slot}\"].pid // empty" "$sf" 2>/dev/null || true
}

# _position_slot: Position a slot's window to an exact cell.
# Path B (preferred): KWin scripting — the window stays KWin-MANAGED and KWin sets
# frameGeometry itself, so there is no override_redirect and nothing to fight. For
# XWayland (X11) windows KWin has synchronous geometry authority, so this is
# reliable (deep-research 2026-06-22). Falls back to the legacy override_redirect
# cycle only if KWin scripting is unreachable. See [[windowing-solution-confirmed]].
# $1=slot $2=x $3=y $4=w $5=h
_position_slot() {
    local slot="$1" x="$2" y="$3" w="$4" h="$5"
    local pid wid
    pid=$(_get_pid_from_state "$slot")
    if [[ -n "$pid" ]] && type kwin_place_windows >/dev/null 2>&1 && kwin_positioner_available; then
        kwin_place_windows "$pid $x $y $w $h"
        echo "[window_manager] KWin-positioned slot $slot (pid $pid) → ${w}x${h}+${x}+${y} (managed, frameGeometry)" >&2
        return 0
    fi
    wid=$(_get_wid_from_state "$slot")
    if [[ -n "$wid" ]]; then
        echo "[window_manager] (fallback override_redirect) slot $slot wid $wid → ${w}x${h}+${x}+${y}" >&2
        _apply_override_redirect_cycle "$wid" "$x" "$y" "$w" "$h"
        return $?
    fi
    echo "[window_manager] slot $slot: no pid or wid available to position" >&2
    return 1
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
        echo "[window_manager] Repositioning slot 1 → fullscreen ${screen_w}x${screen_h}" >&2
        _position_slot 1 0 0 "$screen_w" "$screen_h"
        wid=$(_get_wid_from_state 1); [[ -n "$wid" ]] && _verify_window_geometry 1 "$wid" 0 0 "$screen_w" "$screen_h"
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

        if (( is_active != 1 )); then
            # Vacant slot — nothing to do. plasmashell is killed so the backdrop is
            # already black (placeholders removed 2026-06-23).
            continue
        fi

        # Position the Minecraft window via KWin scripting (window stays KWin-managed;
        # no override_redirect). KWin holds the geometry, so we set it once per reflow;
        # _position_slot falls back to the legacy OR cycle only if KWin scripting is down.
        echo "[window_manager] Repositioning slot $slot → ${w}x${h}+${x}+${y}" >&2
        _position_slot "$slot" "$x" "$y" "$w" "$h"
        echo "[orchestrator] WINDOW SplitscreenP${slot}: ${x},${y} ${w}x${h} ($grid_mode) [kwin frameGeometry]" >&2
        local wid
        wid=$(_get_wid_from_state "$slot"); [[ -n "$wid" ]] && _verify_window_geometry "$slot" "$wid" "$x" "$y" "$w" "$h"
    done

    # Settle + single re-assert (the "let it settle, then position" fix).
    # A freshly-mapped Minecraft/XWayland window is still finishing setup when the
    # first reflow positions it, so the geometry can be dropped/clobbered. KWin
    # HOLDS managed-window geometry, so ONE re-assert after a short settle is enough
    # — no continuous loop (that's what caused the old persistent-script issues).
    # Skip in full mode (single window) and when disabled. Tunable via env.
    if [[ "${MCSS_REASSERT:-1}" == "1" && "$grid_mode" != "full" && -n "${active_slots// }" ]]; then
        sleep "${MCSS_REASSERT_DELAY_S:-1.2}"
        local rs
        for rs in $active_slots; do
            local rgeo rx ry rw rh
            rgeo=$(compute_slot_geometry "$rs" "$grid_mode" "$screen_w" "$screen_h")
            read -r rx ry rw rh <<< "$rgeo"
            _position_slot "$rs" "$rx" "$ry" "$rw" "$rh"
        done
        echo "[window_manager] re-asserted layout for active slots: $active_slots" >&2
    fi
}

# (kill_all_placeholders removed 2026-06-23 — placeholders no longer exist.)

# sync_apply_layout: thin wrapper around apply_layout, kept so existing callers
# don't need to change. (It used to branch to the gamescope-windowing approach,
# now removed — window positioning is always done by apply_layout on nested KWin.)
# Arguments: same as apply_layout — active_slots, screen_w, screen_h
sync_apply_layout() {
    apply_layout "${1:-}" "${2:-}" "${3:-}"
}
