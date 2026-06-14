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

    # In full mode, only slot 1 matters — no placeholders needed for other slots
    if [[ "$grid_mode" == "full" ]]; then
        local wid
        wid=$(xdotool search --name "SplitscreenP1" 2>/dev/null || true)
        if [[ -n "$wid" ]]; then
            echo "[window_manager] Repositioning slot 1: window $wid → fullscreen" >&2
            xdotool windowmove "$wid" 0 0 2>/dev/null || true
            xdotool windowsize "$wid" "$screen_w" "$screen_h" 2>/dev/null || true
            xdotool set_window --overrideredirect 1 "$wid" 2>/dev/null || true
            xdotool windowraise "$wid" 2>/dev/null || true
        fi
        return 0
    fi

    local -a active_array=($active_slots)

    # Process all 4 slots
    local slot
    for slot in 1 2 3 4; do
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

            # Find and reposition the Minecraft window
            local wid
            wid=$(xdotool search --name "SplitscreenP${slot}" 2>/dev/null || true)
            if [[ -n "$wid" ]]; then
                echo "[window_manager] Repositioning slot $slot: window $wid → ${w}x${h}+${x}+${y}" >&2
                xdotool windowmove "$wid" "$x" "$y" 2>/dev/null || true
                xdotool windowsize "$wid" "$w" "$h" 2>/dev/null || true
                xdotool set_window --overrideredirect 1 "$wid" 2>/dev/null || true
                xdotool windowraise "$wid" 2>/dev/null || true
                echo "[orchestrator] WINDOW SplitscreenP${slot}: ${x},${y} ${w}x${h} ($grid_mode)" >&2
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
