#!/bin/bash
# =============================================================================
# @file        launcher_script_generator.sh
# @version     1.0.0
# @date        2026-06-13
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
# Generates minecraftSplitscreen.sh — the runtime launcher with Controlify
# controller isolation. Supports SteamOS Game Mode (gamescope), Linux Desktop
# Mode, and handheld (single-instance) operation.
#
# Isolation architecture:
#   Primary:   bwrap device-mask sandbox hides all controllers except one
#   Secondary: SDL_JOYSTICK_DEVICE env var restricts SDL to a single evdev node
#   Fallback:  preferredJoystickIndex in Controlify config
#
# Game Mode (gamescope):
#   Steam holds exclusive HID access. bwrap blocks hidraw inside sandbox.
#   Use SDL_JOYSTICK_HIDAPI=0 (evdev path) — raw /dev/input/event* nodes
#   deliver events independently of Steam's HID grab. bwrap masks evdev nodes.
#
# Desktop Mode:
#   hidraw nodes accessible. bwrap masks other controllers' hidraw nodes
#   and all vendor 28de input devices (Steam virtual pads, Deck built-in).
#
# Handheld Mode:
#   Steam Deck HW, no external display, no external controllers.
#   Single instance with built-in controls. No bwrap needed.
#
# @dependencies
# - utilities.sh (print_* functions)
#
# @exports
# - generate_splitscreen_launcher()
#
# @changelog
#   1.0.0 (2026-06-13) - Initial version: Controlify isolation with bwrap
# =============================================================================

# Prevent direct execution — this module is meant to be sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This module is meant to be sourced, not executed directly." >&2
    exit 1
fi

# Timeout variables (no hardcoded values — per user requirement)
INSTANCE_STARTUP_GRACE_SECONDS=180
REPOSITION_MAX_SECONDS=30
REPOSITION_INTERVAL_SECONDS=2
CONTROLLER_RECONNECT_GRACE_SECONDS=60

# =============================================================================
# Environment Detection
# =============================================================================

# Returns 0 if running on Steam Deck hardware (Jupiter/Galileo DMI).
isSteamDeckHardware() {
    local dmi_file="/sys/class/dmi/id/product_name"
    [[ -f "$dmi_file" ]] || return 1
    local dmi
    dmi=$(cat "$dmi_file" 2>/dev/null)
    [[ "$dmi" =~ (Steam[[:space:]]*Deck|Jupiter|Galileo) ]]
}

# Returns 0 if running in SteamOS Game Mode (gamescope compositor).
# Also supports MCSS_GAME_MODE=1 env var for nested session detection.
isGameMode() {
    [[ "${XDG_SESSION_DESKTOP:-}" == "gamescope" ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == "gamescope" ]] || \
    [[ "${MCSS_GAME_MODE:-}" == "1" ]]
}

# Returns 0 if in handheld mode: Steam Deck hardware, no external display,
# and no external controllers connected. Defaults to single-instance.
isHandheldMode() {
    isSteamDeckHardware || return 1
    # Check for external display
    local external_displays
    external_displays=$(xrandr 2>/dev/null | grep -c " connected" || echo 0)
    local internal_displays
    internal_displays=$(xrandr 2>/dev/null | grep -c "eDP" || echo 0)
    local external_only=$((external_displays - internal_displays))
    [[ "$external_only" -gt 0 ]] && return 1
    # No external controllers → handheld
    local ext_count
    ext_count=$(getExternalControllerCount)
    [[ "$ext_count" -eq 0 ]]
}

# =============================================================================
# Controller Enumeration
# =============================================================================

# Cache for SDL enumeration results (computed once per session).
_SDL_CONTROLLERS=""
_SDL_BUILTIN_INDEX=""
declare -a _SDL_EXTERNAL_INDICES=()

# Count external (non-built-in) controllers via sysfs.
# In Game Mode: Steam virtualizes everything as vendor 28de — use device
# name to distinguish built-in from external virtual pads.
# In Desktop Mode: skip vendor 28de (Deck built-in + Steam virtual pads).
getExternalControllerCount() {
    local n=0
    local in_game_mode=0
    isGameMode && in_game_mode=1
    for vendor_file in /sys/class/input/js*/device/id/vendor; do
        [[ -f "$vendor_file" ]] || continue
        local vendor
        vendor=$(cat "$vendor_file" 2>/dev/null)
        if [[ "$in_game_mode" == "0" ]]; then
            # Desktop Mode: skip all Valve devices
            [[ "$vendor" == "28de" ]] && continue
        else
            # Game Mode: all controllers are 28de virtual pads.
            # Distinguish by device name: "Steam Deck" = built-in.
            local dev_name_file="${vendor_file%/id/vendor}/name"
            local dev_name
            dev_name=$(cat "$dev_name_file" 2>/dev/null)
            if [[ "$dev_name" =~ [Ss]team[[:space:]]*[Dd]eck ]]; then
                continue
            fi
        fi
        n=$((n + 1))
    done
    echo "$n"
}

# Enumerate controllers using SDL3 ctypes. Returns pipe-delimited lines:
#   "pos|vid|pid|name"
# where pos is SDL's 0-based joystick index.
# In Game Mode, forces SDL_JOYSTICK_HIDAPI=0 so the enumeration order
# matches what Controlify sees inside the per-instance wrapper.
enumerateSdlControllers() {
    # Find SDL3 library
    local sdl_lib=""
    for candidate in \
        /usr/lib*/libSDL3.so.0 \
        /usr/lib*/x86_64-linux-gnu/libSDL3.so.0 \
        "$HOME/.steam/steam/ubuntu12_32/steam-runtime/usr/lib/x86_64-linux-gnu/libSDL3.so.0" \
        /run/host/usr/lib*/libSDL3.so.0; do
        [[ -f "$candidate" ]] && { sdl_lib="$candidate"; break; }
    done
    [[ -z "$sdl_lib" ]] && { echo "ERROR: libSDL3.so.0 not found" >&2; return 1; }

    local _enum_env="SDL_VIDEODRIVER=dummy"
    # In Game Mode, force evdev path so enumeration matches Controlify's
    # bundled SDL (which also uses evdev when HIDAPI is disabled).
    if isGameMode; then
        _enum_env="$_enum_env SDL_JOYSTICK_HIDAPI=0"
    fi

    _SDL_CONTROLLERS=$(env $_enum_env python3 - "$sdl_lib" 2>/dev/null <<'SDLENUMEOF'
import ctypes, sys
try:
    sdl = ctypes.CDLL(sys.argv[1])
    sdl.SDL_Init(0x200)  # SDL_INIT_JOYSTICK
    count = sdl.SDL_GetJoysticks()
    for i in range(count):
        guid = ctypes.create_string_buffer(33)
        sdl.SDL_GetJoystickGUIDForIndex(i, guid)
        g = guid.value.decode()
        vid = int(g[0:4], 16)
        pid = int(g[4:8], 16)
        name_ptr = sdl.SDL_GetJoystickNameForIndex(i)
        name = ctypes.cast(name_ptr, ctypes.c_char_p).value.decode('utf-8', errors='replace') if name_ptr else f"SDL-{i}"
        print(f"{i}|{vid:04x}|{pid:04x}|{name}")
    sdl.SDL_Quit()
except Exception as e:
    print(f"# SDL enum error: {e}", file=sys.stderr)
SDLENUMEOF
    )

    # Parse enumeration results into built-in vs external indices
    _SDL_BUILTIN_INDEX=""
    _SDL_EXTERNAL_INDICES=()
    local IFS=$'\n'
    for line in $_SDL_CONTROLLERS; do
        [[ "$line" =~ ^# ]] && continue
        IFS='|' read -r pos vid pid name <<< "$line"
        if [[ "$vid" == "28de" ]]; then
            # Valve vendor: could be built-in Deck or Steam virtual pad.
            # Use device name as tiebreaker.
            if [[ "$name" =~ [Ss]team[[:space:]]*[Dd]eck ]] || [[ "$name" =~ ^[Ss]team$ ]]; then
                [[ -z "$_SDL_BUILTIN_INDEX" ]] && _SDL_BUILTIN_INDEX="$pos"
            else
                _SDL_EXTERNAL_INDICES+=("$pos")
            fi
        else
            _SDL_EXTERNAL_INDICES+=("$pos")
        fi
    done
    return 0
}

# =============================================================================
# Device Node Helpers
# =============================================================================

# Instance state arrays (index 0-3 for slots 1-4)
declare -a INSTANCE_CONTROLLER_HIDRAW=()
declare -a INSTANCE_CONTROLLER_DEVICE=()
declare -a INSTANCE_ACTIVE=()

# Find the js device node for a given hidraw device.
jsNodeForHidraw() {
    local hidraw="/dev/$1"
    local base="${1#hidraw}"
    local js
    for js in /sys/class/hidraw/hidraw${base}/device/js*; do
        [[ -d "$js" ]] || continue
        local js_name
        js_name=$(basename "$js")
        [[ -e "/dev/input/$js_name" ]] && echo "/dev/input/$js_name" && return 0
    done
    return 1
}

# Find the first external hidraw device not yet assigned to any instance.
findUnassignedExternalHidraw() {
    local num h vendor
    if ! ls /sys/class/hidraw/ >/dev/null 2>&1; then
        return 1
    fi
    for num in $(ls /sys/class/hidraw/ 2>/dev/null | sed 's/^hidraw//' | sort -n); do
        h="hidraw${num}"
        # Skip Valve devices (Deck built-in, Steam virtual pads)
        vendor=$(cat "/sys/class/hidraw/${h}/device/vendor" 2>/dev/null || echo "0000")
        case "$vendor" in
            28de|0000) continue ;;
        esac
        # Check if this hidraw is already assigned
        local already_assigned=0
        local assigned
        for assigned in "${INSTANCE_CONTROLLER_HIDRAW[@]}"; do
            [[ "$assigned" == "$h" ]] && { already_assigned=1; break; }
        done
        [[ "$already_assigned" == "0" ]] && { echo "$h"; return 0; }
    done
    return 1
}

# =============================================================================
# bwrap Device Masking (THE core isolation mechanism)
# =============================================================================

# Build bwrap device-mask arguments for controller isolation.
# Desktop Mode: masks other controllers' hidraw nodes + all 28de event/js nodes.
# Game Mode: returns empty (evdev masking is in the per-instance wrapper).
# The returned string has a LOAD-BEARING LEADING SPACE — it concatenates
# directly after "--dev-bind / /" in the wrapper template.
buildControllerDeviceMasks() {
    local slot=$1

    # In Game Mode, isolation is handled by SDL_JOYSTICK_HIDAPI=0 + evdev
    # event masking inside the per-slot wrapper script.
    if isGameMode; then
        echo ""
        return 0
    fi

    local assigned="${INSTANCE_CONTROLLER_HIDRAW[$((slot - 1))]}"

    # NOTE: leading space is load-bearing — the wrapper template concatenates
    # this directly after "--dev-bind / /"
    local masks=" --bind /dev/null /dev/full"

    # Mask all OTHER controllers' hidraw nodes
    local num h hid_path vendor
    if ls /sys/class/hidraw/ >/dev/null 2>&1; then
        for num in $(ls /sys/class/hidraw/ 2>/dev/null | sed 's/^hidraw//' | sort -n); do
            h="hidraw${num}"
            hid_path="/dev/$h"
            [[ -e "$hid_path" ]] || continue
            vendor=$(cat "/sys/class/hidraw/${h}/device/vendor" 2>/dev/null || echo "0000")
            case "$vendor" in 28de|0000) continue ;; esac
            [[ "$h" == "$assigned" ]] && continue
            masks="$masks --bind /dev/null $hid_path"
        done
    fi

    # Mask all Valve vendor (28de) input devices so Steam virtual pads
    # and Deck built-in don't leak into the sandbox
    local ev ev_vendor
    for ev in /dev/input/event*; do
        [[ -e "$ev" ]] || continue
        ev_vendor=$(cat "/sys/class/input/$(basename "$ev")/device/id/vendor" 2>/dev/null || echo "")
        [[ "$ev_vendor" == "28de" ]] || continue
        masks="$masks --bind /dev/null $ev"
    done
    for js in /dev/input/js*; do
        [[ -e "$js" ]] || continue
        js_vendor=$(cat "/sys/class/input/$(basename "$js")/device/id/vendor" 2>/dev/null || echo "")
        [[ "$js_vendor" == "28de" ]] || continue
        masks="$masks --bind /dev/null $js"
    done

    echo "$masks"
}

# =============================================================================
# Controlify Configuration
# =============================================================================

# Write Controlify configuration for a slot.
# Sets use_enhanced_steam_deck_driver=false (SteamOS driver broken, halts
# controller init in Game Mode), out_of_focus_input=true,
# auto_select=false (prevents trackpad hijack).
writeControlifyConfig() {
    local slot=$1
    local config_dir="$INSTANCES_DIR/latestUpdate-${slot}/.minecraft/config/controlify"
    mkdir -p "$config_dir"
    local config_path="$config_dir/config.json"

    python3 - "$config_path" <<'CFYCFGEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
data.setdefault("schema_version", 1)
data.setdefault("global", {})["out_of_focus_input"] = True
data.setdefault("global", {})["use_enhanced_steam_deck_driver"] = False
data.setdefault("global", {})["auto_select"] = False
with open(path, "w") as f:
    json.dump(data, f, indent=2)
CFYCFGEOF
}

# =============================================================================
# Per-Instance Wrapper and Controller Assignment
# =============================================================================

# Assign a controller to a slot and generate its wrapper script.
# The wrapper handles:
# 1. Game Mode: SDL_JOYSTICK_HIDAPI=0 + evdev event masking via bwrap
# 2. Desktop Mode: hidraw masking via bwrap
# 3. Fallback: SDL_JOYSTICK_DEVICE if bwrap unavailable
assignControllerToSlot() {
    local slot=$1
    local idx=$((slot - 1))

    # Enumerate once per session
    if [[ -z "$_SDL_CONTROLLERS" ]]; then
        enumerateSdlControllers || true
    fi

    # Determine the SDL index for this slot
    local sdl_index=""
    if isHandheldMode; then
        sdl_index="${_SDL_BUILTIN_INDEX:-0}"
    elif isGameMode; then
        # Game Mode: use sequential indices. Controlify's SDL filters vendor
        # 28de, so index 0 = first external controller.
        sdl_index=$idx
    elif [[ "$idx" -lt "${#_SDL_EXTERNAL_INDICES[@]}" ]]; then
        sdl_index="${_SDL_EXTERNAL_INDICES[$idx]}"
    fi

    # Find and assign a hidraw for this slot
    if [[ -z "${INSTANCE_CONTROLLER_HIDRAW[$idx]}" ]]; then
        INSTANCE_CONTROLLER_HIDRAW[$idx]=$(findUnassignedExternalHidraw || echo "")
    fi

    # Find the js and evdev nodes for this controller
    INSTANCE_CONTROLLER_DEVICE[$idx]=""
    if [[ -n "${INSTANCE_CONTROLLER_HIDRAW[$idx]}" ]]; then
        INSTANCE_CONTROLLER_DEVICE[$idx]=$(jsNodeForHidraw "${INSTANCE_CONTROLLER_HIDRAW[$idx]}" || echo "")
    fi

    # Compute raw evdev node for SDL_JOYSTICK_DEVICE
    local slot_ev_dev=""
    if [[ -n "${INSTANCE_CONTROLLER_DEVICE[$idx]}" ]]; then
        local _ev
        _ev=$(ls "/sys/class/input/$(basename "${INSTANCE_CONTROLLER_DEVICE[$idx]}")/device/" 2>/dev/null | grep "^event" | head -1)
        [[ -n "$_ev" ]] && slot_ev_dev="/dev/input/$_ev"
    fi

    local device_masks
    device_masks=$(buildControllerDeviceMasks "$slot")

    # Generate the wrapper script
    local wrapper="$INSTANCES_DIR/latestUpdate-${slot}/sdl-wrapper.sh"
    cat > "$wrapper" << WRAPINJECTEOF
#!/usr/bin/env bash
# Auto-generated for slot ${slot}: per-instance controller isolation.
# Desktop Mode: bwrap masks other controllers' hidraw nodes.
# Game Mode (gamescope): SDL_JOYSTICK_HIDAPI=0 + bwrap evdev masking.

# Detect Game Mode (including nested Plasma session via MCSS_GAME_MODE)
_is_game_mode=0
if [ "\${XDG_SESSION_DESKTOP:-}" = "gamescope" ] || \\
   [ "\${XDG_CURRENT_DESKTOP:-}" = "gamescope" ] || \\
   [ "\${MCSS_GAME_MODE:-}" = "1" ]; then
    _is_game_mode=1
fi

if [ "\$_is_game_mode" = "1" ]; then
    # Steam holds exclusive HID access in Game Mode.
    # Force evdev path — raw /dev/input/event* nodes deliver events
    # even when Steam holds the HID device exclusively.
    export SDL_JOYSTICK_HIDAPI=0
    export SDL_JOYSTICK_HIDAPI_PS4=0

    # Build evdev masks: find ALL raw controller event devices
    # (non-28de, with js child) and mask all EXCEPT this slot's.
    _gm_masks=" --bind /dev/null /dev/full"
    for _gm_ev in /dev/input/event*; do
        [ -e "\$_gm_ev" ] || continue
        _gm_v=\$(cat /sys/class/input/\$(basename "\$_gm_ev")/device/id/vendor 2>/dev/null || echo "")
        [ "\$_gm_v" = "28de" ] && continue
        ls /sys/class/input/\$(basename "\$_gm_ev")/device/js* >/dev/null 2>&1 || continue
        [ "\$_gm_ev" = "${slot_ev_dev}" ] && continue
        _gm_masks="\$_gm_masks --bind /dev/null \$_gm_ev"
    done
    if [ -n "\$_gm_masks" ] && command -v bwrap >/dev/null 2>&1; then
        exec bwrap --dev-bind / /\$_gm_masks -- "\$@"
    fi
    # Fallback: bwrap unavailable — use SDL_JOYSTICK_DEVICE
    [ -n "${slot_ev_dev}" ] && export SDL_JOYSTICK_DEVICE="${slot_ev_dev}"
elif [ -n "${device_masks}" ] && command -v bwrap >/dev/null 2>&1 \\
     && bwrap --dev-bind / / -- /bin/true 2>/dev/null; then
    # Desktop Mode: bwrap with hidraw device masks
    exec bwrap --dev-bind / /${device_masks} -- "\$@"
else
    # Fallback for desktop without bwrap: SDL_JOYSTICK_DEVICE only
    [ -n "${slot_ev_dev}" ] && export SDL_JOYSTICK_DEVICE="${slot_ev_dev}"
    exec "\$@"
fi
WRAPINJECTEOF

    chmod +x "$wrapper"

    # Write Controlify config
    writeControlifyConfig "$slot"

    # Configure PolyMC to use the wrapper via WrapperCommand
    local cfg_path="$INSTANCES_DIR/latestUpdate-${slot}/instance.cfg"
    if grep -q "^OverrideCommands=" "$cfg_path" 2>/dev/null; then
        sed -i "s|^OverrideCommands=.*|OverrideCommands=true|" "$cfg_path"
    else
        echo "OverrideCommands=true" >> "$cfg_path"
    fi
    if grep -q "^WrapperCommand=" "$cfg_path" 2>/dev/null; then
        sed -i "s|^WrapperCommand=.*|WrapperCommand=$wrapper|" "$cfg_path"
    else
        echo "WrapperCommand=$wrapper" >> "$cfg_path"
    fi

    print_info "Slot $slot: assigned ${INSTANCE_CONTROLLER_HIDRAW[$idx]:-built-in} (js: ${INSTANCE_CONTROLLER_DEVICE[$idx]:-n/a}, index: $sdl_index)"
    return 0
}

# =============================================================================
# Main Generator Entry Point
# =============================================================================
# Arguments:
#   $1 = output path for generated launcher script
#   $2 = launcher type (polymc)
#   $3 = launcher format (appimage)
#   $4 = launcher executable path
#   $5 = launcher data directory
#   $6 = instances directory
generate_splitscreen_launcher() {
    local output_path="$1"
    local launcher_type="${2:-polymc}"
    local launcher_format="${3:-appimage}"
    local launcher_exec="${4:-$HOME/.local/share/PolyMC/PolyMC.AppImage}"
    local launcher_data="${5:-$HOME/.local/share/PolyMC}"
    local instances_dir="${6:-$launcher_data/instances}"

    print_info "Generating splitscreen launcher..."
    print_debug "  Output: $output_path"
    print_debug "  Launcher: $launcher_exec"
    print_debug "  Instances: $instances_dir"

    # Write the generated script header
    local gen_time
    gen_time=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    cat > "$output_path" << GENHEADER
#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Launcher for Steam Deck & Linux
# =============================================================================
# Version: 5.0.0
# Generated: $gen_time
# Generator: launcher_script_generator.sh v1.0.0
# Source: https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# DO NOT EDIT - This file is auto-generated by the installer.
# To update, re-run the installer script.
# =============================================================================
#
# This script launches 1-4 Minecraft instances in splitscreen mode with
# Controlify controller isolation via bwrap device-mask sandboxes.
# Each instance can only see its assigned controller.
#
# Modes:
#   Handheld  — Steam Deck undocked, 1 instance, built-in controls
#   Game Mode — Docked gamescope, bwrap + evdev, 2-4 instances
#   Desktop   — Docked Linux desktop, bwrap + hidraw, 2-4 instances
# =============================================================================

set +e  # Allow script to continue on errors for robustness

# =============================================================================
# GENERATED CONFIGURATION
# =============================================================================
readonly LAUNCHER_DIR="$launcher_data"
readonly LAUNCHER_EXEC="$launcher_exec"
readonly INSTANCES_DIR="$instances_dir"
readonly LAUNCHER_NAME="PolyMC"
readonly LAUNCH_DEBUG_LOG="$launcher_data/splitscreen-launch-debug.log"

# Timeout variables
readonly INSTANCE_STARTUP_GRACE_SECONDS=$INSTANCE_STARTUP_GRACE_SECONDS
readonly REPOSITION_MAX_SECONDS=$REPOSITION_MAX_SECONDS
readonly REPOSITION_INTERVAL_SECONDS=$REPOSITION_INTERVAL_SECONDS
readonly CONTROLLER_RECONNECT_GRACE_SECONDS=$CONTROLLER_RECONNECT_GRACE_SECONDS

GENHEADER

    # Append the runtime functions from the generator into the launcher
    # (isSteamDeckHardware, isGameMode, isHandheldMode, getExternalControllerCount,
    #  enumerateSdlControllers, jsNodeForHidraw, findUnassignedExternalHidraw,
    #  buildControllerDeviceMasks, writeControlifyConfig, assignControllerToSlot)
    # These are embedded as inline source so the launcher is self-contained.

    cat >> "$output_path" << 'RUNTIMEFUNCS'

# =============================================================================
# Environment Detection
# =============================================================================
isSteamDeckHardware() {
    local dmi_file="/sys/class/dmi/id/product_name"
    [[ -f "$dmi_file" ]] || return 1
    local dmi
    dmi=$(cat "$dmi_file" 2>/dev/null)
    [[ "$dmi" =~ (Steam[[:space:]]*Deck|Jupiter|Galileo) ]]
}

isGameMode() {
    [[ "${XDG_SESSION_DESKTOP:-}" == "gamescope" ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == "gamescope" ]] || \
    [[ "${MCSS_GAME_MODE:-}" == "1" ]]
}

isHandheldMode() {
    isSteamDeckHardware || return 1
    local external_displays
    external_displays=$(xrandr 2>/dev/null | grep -c " connected" || echo 0)
    local internal_displays
    internal_displays=$(xrandr 2>/dev/null | grep -c "eDP" || echo 0)
    local external_only=$((external_displays - internal_displays))
    [[ "$external_only" -gt 0 ]] && return 1
    local ext_count
    ext_count=$(getExternalControllerCount)
    [[ "$ext_count" -eq 0 ]]
}

# =============================================================================
# Controller Enumeration
# =============================================================================
_SDL_CONTROLLERS=""
_SDL_BUILTIN_INDEX=""
declare -a _SDL_EXTERNAL_INDICES=()

getExternalControllerCount() {
    local n=0
    local in_game_mode=0
    isGameMode && in_game_mode=1
    for vendor_file in /sys/class/input/js*/device/id/vendor; do
        [[ -f "$vendor_file" ]] || continue
        local vendor
        vendor=$(cat "$vendor_file" 2>/dev/null)
        if [[ "$in_game_mode" == "0" ]]; then
            [[ "$vendor" == "28de" ]] && continue
        else
            local dev_name_file="${vendor_file%/id/vendor}/name"
            local dev_name
            dev_name=$(cat "$dev_name_file" 2>/dev/null)
            if [[ "$dev_name" =~ [Ss]team[[:space:]]*[Dd]eck ]]; then
                continue
            fi
        fi
        n=$((n + 1))
    done
    echo "$n"
}

enumerateSdlControllers() {
    local sdl_lib=""
    for candidate in \
        /usr/lib*/libSDL3.so.0 \
        /usr/lib*/x86_64-linux-gnu/libSDL3.so.0 \
        "$HOME/.steam/steam/ubuntu12_32/steam-runtime/usr/lib/x86_64-linux-gnu/libSDL3.so.0" \
        /run/host/usr/lib*/libSDL3.so.0; do
        [[ -f "$candidate" ]] && { sdl_lib="$candidate"; break; }
    done
    [[ -z "$sdl_lib" ]] && { echo "[Error] libSDL3.so.0 not found" >&2; return 1; }

    local _enum_env="SDL_VIDEODRIVER=dummy"
    if isGameMode; then
        _enum_env="$_enum_env SDL_JOYSTICK_HIDAPI=0"
    fi

    _SDL_CONTROLLERS=$(env $_enum_env python3 - "$sdl_lib" 2>/dev/null <<'SDLENUMEOF'
import ctypes, sys
try:
    sdl = ctypes.CDLL(sys.argv[1])
    sdl.SDL_Init(0x200)
    count = sdl.SDL_GetJoysticks()
    for i in range(count):
        guid = ctypes.create_string_buffer(33)
        sdl.SDL_GetJoystickGUIDForIndex(i, guid)
        g = guid.value.decode()
        vid = int(g[0:4], 16)
        pid = int(g[4:8], 16)
        name_ptr = sdl.SDL_GetJoystickNameForIndex(i)
        name = ctypes.cast(name_ptr, ctypes.c_char_p).value.decode('utf-8', errors='replace') if name_ptr else f"SDL-{i}"
        print(f"{i}|{vid:04x}|{pid:04x}|{name}")
    sdl.SDL_Quit()
except Exception as e:
    print(f"# SDL enum error: {e}", file=sys.stderr)
SDLENUMEOF
    )

    _SDL_BUILTIN_INDEX=""
    _SDL_EXTERNAL_INDICES=()
    local IFS=$'\n'
    for line in $_SDL_CONTROLLERS; do
        [[ "$line" =~ ^# ]] && continue
        IFS='|' read -r pos vid pid name <<< "$line"
        if [[ "$vid" == "28de" ]]; then
            if [[ "$name" =~ [Ss]team[[:space:]]*[Dd]eck ]] || [[ "$name" =~ ^[Ss]team$ ]]; then
                [[ -z "$_SDL_BUILTIN_INDEX" ]] && _SDL_BUILTIN_INDEX="$pos"
            else
                _SDL_EXTERNAL_INDICES+=("$pos")
            fi
        else
            _SDL_EXTERNAL_INDICES+=("$pos")
        fi
    done
    return 0
}

# =============================================================================
# Device Node Helpers
# =============================================================================
declare -a INSTANCE_CONTROLLER_HIDRAW=()
declare -a INSTANCE_CONTROLLER_DEVICE=()

jsNodeForHidraw() {
    local base="${1#hidraw}"
    local js
    for js in /sys/class/hidraw/hidraw${base}/device/js*; do
        [[ -d "$js" ]] || continue
        local js_name
        js_name=$(basename "$js")
        [[ -e "/dev/input/$js_name" ]] && echo "/dev/input/$js_name" && return 0
    done
    return 1
}

findUnassignedExternalHidraw() {
    if ! ls /sys/class/hidraw/ >/dev/null 2>&1; then
        return 1
    fi
    local num h vendor
    for num in $(ls /sys/class/hidraw/ 2>/dev/null | sed 's/^hidraw//' | sort -n); do
        h="hidraw${num}"
        vendor=$(cat "/sys/class/hidraw/${h}/device/vendor" 2>/dev/null || echo "0000")
        case "$vendor" in 28de|0000) continue ;; esac
        local already_assigned=0
        local assigned
        for assigned in "${INSTANCE_CONTROLLER_HIDRAW[@]}"; do
            [[ "$assigned" == "$h" ]] && { already_assigned=1; break; }
        done
        [[ "$already_assigned" == "0" ]] && { echo "$h"; return 0; }
    done
    return 1
}

# =============================================================================
# bwrap Device Masking
# =============================================================================
buildControllerDeviceMasks() {
    local slot=$1
    if isGameMode; then
        echo ""
        return 0
    fi
    local assigned="${INSTANCE_CONTROLLER_HIDRAW[$((slot - 1))]}"
    local masks=" --bind /dev/null /dev/full"
    if ls /sys/class/hidraw/ >/dev/null 2>&1; then
        local num h vendor
        for num in $(ls /sys/class/hidraw/ 2>/dev/null | sed 's/^hidraw//' | sort -n); do
            h="hidraw${num}"
            [[ -e "/dev/$h" ]] || continue
            vendor=$(cat "/sys/class/hidraw/${h}/device/vendor" 2>/dev/null || echo "0000")
            case "$vendor" in 28de|0000) continue ;; esac
            [[ "$h" == "$assigned" ]] && continue
            masks="$masks --bind /dev/null /dev/$h"
        done
    fi
    local ev ev_vendor
    for ev in /dev/input/event*; do
        [[ -e "$ev" ]] || continue
        ev_vendor=$(cat "/sys/class/input/$(basename "$ev")/device/id/vendor" 2>/dev/null || echo "")
        [[ "$ev_vendor" == "28de" ]] || continue
        masks="$masks --bind /dev/null $ev"
    done
    for js in /dev/input/js*; do
        [[ -e "$js" ]] || continue
        js_vendor=$(cat "/sys/class/input/$(basename "$js")/device/id/vendor" 2>/dev/null || echo "")
        [[ "$js_vendor" == "28de" ]] || continue
        masks="$masks --bind /dev/null $js"
    done
    echo "$masks"
}

# =============================================================================
# Controlify Config & Per-Instance Wrapper
# =============================================================================
writeControlifyConfig() {
    local slot=$1
    local config_dir="$INSTANCES_DIR/latestUpdate-${slot}/.minecraft/config/controlify"
    mkdir -p "$config_dir"
    local config_path="$config_dir/config.json"
    python3 - "$config_path" <<'CFYCFGEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
data.setdefault("schema_version", 1)
data.setdefault("global", {})["out_of_focus_input"] = True
data.setdefault("global", {})["use_enhanced_steam_deck_driver"] = False
data.setdefault("global", {})["auto_select"] = False
with open(path, "w") as f:
    json.dump(data, f, indent=2)
CFYCFGEOF
}

assignControllerToSlot() {
    local slot=$1
    local idx=$((slot - 1))

    if [[ -z "$_SDL_CONTROLLERS" ]]; then
        enumerateSdlControllers || true
    fi

    local sdl_index=""
    if isHandheldMode; then
        sdl_index="${_SDL_BUILTIN_INDEX:-0}"
    elif isGameMode; then
        sdl_index=$idx
    elif [[ "$idx" -lt "${#_SDL_EXTERNAL_INDICES[@]}" ]]; then
        sdl_index="${_SDL_EXTERNAL_INDICES[$idx]}"
    fi

    if [[ -z "${INSTANCE_CONTROLLER_HIDRAW[$idx]}" ]]; then
        INSTANCE_CONTROLLER_HIDRAW[$idx]=$(findUnassignedExternalHidraw || echo "")
    fi

    INSTANCE_CONTROLLER_DEVICE[$idx]=""
    if [[ -n "${INSTANCE_CONTROLLER_HIDRAW[$idx]}" ]]; then
        INSTANCE_CONTROLLER_DEVICE[$idx]=$(jsNodeForHidraw "${INSTANCE_CONTROLLER_HIDRAW[$idx]}" || echo "")
    fi

    local slot_ev_dev=""
    if [[ -n "${INSTANCE_CONTROLLER_DEVICE[$idx]}" ]]; then
        local _ev
        _ev=$(ls "/sys/class/input/$(basename "${INSTANCE_CONTROLLER_DEVICE[$idx]}")/device/" 2>/dev/null | grep "^event" | head -1)
        [[ -n "$_ev" ]] && slot_ev_dev="/dev/input/$_ev"
    fi

    local device_masks
    device_masks=$(buildControllerDeviceMasks "$slot")

    local wrapper="$INSTANCES_DIR/latestUpdate-${slot}/sdl-wrapper.sh"
    cat > "$wrapper" << WRAPINJECTEOF
#!/usr/bin/env bash
# Auto-generated for slot ${slot}: per-instance controller isolation.
_is_game_mode=0
if [ "\${XDG_SESSION_DESKTOP:-}" = "gamescope" ] || \\
   [ "\${XDG_CURRENT_DESKTOP:-}" = "gamescope" ] || \\
   [ "\${MCSS_GAME_MODE:-}" = "1" ]; then
    _is_game_mode=1
fi
if [ "\$_is_game_mode" = "1" ]; then
    export SDL_JOYSTICK_HIDAPI=0
    export SDL_JOYSTICK_HIDAPI_PS4=0
    _gm_masks=" --bind /dev/null /dev/full"
    for _gm_ev in /dev/input/event*; do
        [ -e "\$_gm_ev" ] || continue
        _gm_v=\$(cat /sys/class/input/\$(basename "\$_gm_ev")/device/id/vendor 2>/dev/null || echo "")
        [ "\$_gm_v" = "28de" ] && continue
        ls /sys/class/input/\$(basename "\$_gm_ev")/device/js* >/dev/null 2>&1 || continue
        [ "\$_gm_ev" = "${slot_ev_dev}" ] && continue
        _gm_masks="\$_gm_masks --bind /dev/null \$_gm_ev"
    done
    if [ -n "\$_gm_masks" ] && command -v bwrap >/dev/null 2>&1; then
        exec bwrap --dev-bind / /\$_gm_masks -- "\$@"
    fi
    [ -n "${slot_ev_dev}" ] && export SDL_JOYSTICK_DEVICE="${slot_ev_dev}"
elif [ -n "${device_masks}" ] && command -v bwrap >/dev/null 2>&1 \\
     && bwrap --dev-bind / / -- /bin/true 2>/dev/null; then
    exec bwrap --dev-bind / /${device_masks} -- "\$@"
else
    [ -n "${slot_ev_dev}" ] && export SDL_JOYSTICK_DEVICE="${slot_ev_dev}"
    exec "\$@"
fi
WRAPINJECTEOF

    chmod +x "$wrapper"
    writeControlifyConfig "$slot"

    local cfg_path="$INSTANCES_DIR/latestUpdate-${slot}/instance.cfg"
    if grep -q "^OverrideCommands=" "$cfg_path" 2>/dev/null; then
        sed -i "s|^OverrideCommands=.*|OverrideCommands=true|" "$cfg_path"
    else
        echo "OverrideCommands=true" >> "$cfg_path"
    fi
    if grep -q "^WrapperCommand=" "$cfg_path" 2>/dev/null; then
        sed -i "s|^WrapperCommand=.*|WrapperCommand=$wrapper|" "$cfg_path"
    else
        echo "WrapperCommand=$wrapper" >> "$cfg_path"
    fi

    echo "[Info] Slot $slot: assigned ${INSTANCE_CONTROLLER_HIDRAW[$idx]:-built-in} (js: ${INSTANCE_CONTROLLER_DEVICE[$idx]:-n/a}, index: $sdl_index)"
    return 0
}

# =============================================================================
# Splitscreen Configuration
# =============================================================================
setSplitscreenModeForPlayer() {
    local player=$1
    local numberOfControllers=$2
    local config_path="$INSTANCES_DIR/latestUpdate-${player}/.minecraft/config/splitscreen.properties"
    mkdir -p "$(dirname "$config_path")"
    local mode="FULLSCREEN"
    case "$numberOfControllers" in
        1) mode="FULLSCREEN" ;;
        2) if [ "$player" = 1 ]; then mode="TOP"; else mode="BOTTOM"; fi ;;
        3) if [ "$player" = 1 ]; then mode="TOP"
           elif [ "$player" = 2 ]; then mode="BOTTOM_LEFT"
           else mode="BOTTOM_RIGHT"; fi ;;
        4) if [ "$player" = 1 ]; then mode="TOP_LEFT"
           elif [ "$player" = 2 ]; then mode="TOP_RIGHT"
           elif [ "$player" = 3 ]; then mode="BOTTOM_LEFT"
           else mode="BOTTOM_RIGHT"; fi ;;
    esac
    echo -e "gap=1\\nmode=$mode" > "$config_path"
    sync
    sleep 0.5
}

# =============================================================================
# Instance Launching
# =============================================================================
prewarmLauncher() {
    [ -n "$LAUNCHER_PREWARMED" ] && return 0
    echo "[Info] Pre-warming $LAUNCHER_NAME..."
    "$LAUNCHER_EXEC" --no-single-instance >/dev/null 2>&1 &
    local _i
    for _i in $(seq 1 60); do
        if ls /tmp/qtsingleapp-* 2>/dev/null | grep -q .; then
            LAUNCHER_PREWARMED=1
            echo "[Info] $LAUNCHER_NAME pre-warmed"
            return 0
        fi
        sleep 1
    done
    echo "[Warning] $LAUNCHER_NAME pre-warm timed out, continuing anyway"
    LAUNCHER_PREWARMED=1
}

launchInstance() {
    local instance_name="$1"
    local account_name="$2"

    echo "[Info] Launching $LAUNCHER_NAME instance '$instance_name' with account '$account_name'..."
    prewarmLauncher

    mkdir -p "$(dirname "$LAUNCH_DEBUG_LOG")"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launching $instance_name ($account_name)"
    } >> "$LAUNCH_DEBUG_LOG"

    "$LAUNCHER_EXEC" -l "$instance_name" -a "$account_name" &
}

# =============================================================================
# Game Mode: Nested Plasma Session
# =============================================================================
nestedPlasma() {
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH
    local RES
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
    [ -z "$RES" ] && RES="1280x800"
    cat <<EOF > /tmp/kwin_wayland_wrapper
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${RES%x*} --height ${RES#*x} --no-lockscreen \\\$@
EOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH
    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat <<EOF > ~/.config/autostart/minecraft-launch.desktop
[Desktop Entry]
Name=Minecraft Split Launch
Exec=env MCSS_GAME_MODE=1 $SCRIPT_PATH launchFromPlasma
Type=Application
X-KDE-AutostartScript=true
EOF
    exec dbus-run-session startplasma-wayland
}

cleanup_autostart() {
    rm -f "$HOME/.config/autostart/minecraft-launch.desktop"
}
trap cleanup_autostart EXIT

# =============================================================================
# Main Entry Point
# =============================================================================
if isSteamDeckHardware && isGameMode; then
    if [ "${1:-}" = "launchFromPlasma" ]; then
        rm -f ~/.config/autostart/minecraft-launch.desktop
        SCRIPT_PATH="$(readlink -f "$0")"
    else
        nestedPlasma
    fi
fi

echo "=== Minecraft Splitscreen Launcher v5.0.0 ==="

# Detect mode
if isHandheldMode; then
    echo "[Info] Handheld mode — launching 1 instance with built-in controls"
    assignControllerToSlot 1
    setSplitscreenModeForPlayer 1 1
    launchInstance "latestUpdate-1" "P1"
    wait
    exit 0
fi

# Docked mode: count controllers and launch
enumerateSdlControllers || true
local numberOfControllers
numberOfControllers=$(getExternalControllerCount)

# Clamp 1-4
[ "$numberOfControllers" -gt 4 ] && numberOfControllers=4
[ "$numberOfControllers" -lt 1 ] && numberOfControllers=1

echo "[Info] Detected $numberOfControllers external controller(s)"
echo "[Info] Mode: $(isGameMode && echo 'Game Mode (gamescope)' || echo 'Desktop Mode')"

for player in $(seq 1 $numberOfControllers); do
    assignControllerToSlot "$player"
    setSplitscreenModeForPlayer "$player" "$numberOfControllers"
done

for player in $(seq 1 $numberOfControllers); do
    launchInstance "latestUpdate-$player" "P$player"
done

wait
echo "[Info] All instances exited. Goodbye!"
RUNTIMEFUNCS

    chmod +x "$output_path"
    print_success "Launcher generated: $output_path"
}
