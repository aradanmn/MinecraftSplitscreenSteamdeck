#!/bin/bash
# =============================================================================
# @file        launcher_script_generator.sh
# @version     3.0.10
# @date        2026-03-07
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Generates the minecraftSplitscreen.sh launcher script with correct paths
#   baked in based on the detected launcher configuration. The generated script
#   handles Steam Deck Game Mode detection, controller counting, splitscreen
#   configuration, and instance launching.
#
#   Key features:
#   - Template-based script generation with placeholder replacement
#   - Support for both AppImage and Flatpak launchers
#   - Steam Deck Game Mode detection with nested Plasma session
#   - Controller detection with Steam Input duplicate handling
#   - Per-instance splitscreen.properties configuration
#
# @dependencies
#   - git (for commit hash embedding, optional)
#   - sed (for placeholder replacement)
#
# @exports
#   Functions:
#     - generate_splitscreen_launcher : Main generation function
#     - verify_generated_script       : Validation utility
#     - print_generation_config       : Debug/info utility
#
# @changelog
#   3.0.10 (2026-03-07) - Fix: Zombie process reaping, cleanup_exit reentrancy guard, gamescope cleanup race prevention; default mode changed to dynamic; remove dead launchGames()
#   3.0.9 (2026-02-08) - Fix: Pre-warm PrismLauncher on first launch to prevent "still initializing" errors
#   3.0.8 (2026-02-08) - Fix: Import desktop session env for SSH; stop killing plasmashell; use FullArea in KWin JS; detect WAYLAND_DISPLAY in game mode check
#   3.0.7 (2026-02-07) - Fix: KDE 6 KWin API compatibility (Object.assign for geometry, tile=null); verbose KWin JS logging
#   3.0.6 (2026-02-07) - Feat: FULLSCREEN-only mode + KWin positioning (avoids Splitscreen mod Wayland crash); no-restart dynamic scaling
#   3.0.5 (2026-02-07) - Feat: KWin scripting for Wayland-native window repositioning; block xdotool on Wayland
#   3.0.4 (2026-02-07) - Feat: Steam Deck handheld vs docked mode detection; single-player in handheld
#   3.0.3 (2026-02-07) - Fix: Background notify-send to prevent blocking on D-Bus issues
#   3.0.2 (2026-02-07) - Fix: PID tracking, orphaned process cleanup, clean exit with Steam refocus
#   3.0.1 (2026-02-01) - Add CLI arguments (--mode=static/dynamic, --help) for non-interactive use
#   3.0.0 (2026-02-01) - Dynamic splitscreen mode, controller hotplug, window repositioning
#   2.1.1 (2026-02-01) - Fix: promptControllerMode sends status to stderr, add keyboard/mouse detection
#   2.1.0 (2026-01-31) - Added Steam Deck OLED (Galileo) detection, improved controller detection
#   2.0.4 (2026-01-31) - Fix: Replace hardcoded /tmp with mktemp/TMPDIR
#   2.0.3 (2026-01-31) - Fix: Add log_debug() function, debug output now logged to file
#   2.0.2 (2026-01-31) - Fix: grep -c exit code causing "0\n0" controller count
#   2.0.1 (2026-01-26) - Added logging system, improved controller/game mode detection
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# =============================================================================
# MAIN GENERATOR FUNCTION
# =============================================================================

# @function    generate_splitscreen_launcher
# @description Generate the minecraftSplitscreen.sh launcher script with
#              configuration values baked in via placeholder replacement.
# @param       $1 - output_path: Path for the generated script
# @param       $2 - launcher_name: "PrismLauncher"
# @param       $3 - launcher_type: "appimage" or "flatpak"
# @param       $4 - launcher_exec: Full path or flatpak command
# @param       $5 - launcher_dir: Launcher data directory
# @param       $6 - instances_dir: Instances directory path
# @global      SCRIPT_VERSION - (input, optional) Version string for embedding
# @global      REPO_URL - (input, optional) Repository URL for embedding
# @return      0 on success
# @example
#   generate_splitscreen_launcher "/path/to/script.sh" "PrismLauncher" "flatpak" \
#       "flatpak run org.prismlauncher.PrismLauncher" "/home/user/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher" \
#       "/home/user/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances"
generate_splitscreen_launcher() {
    local output_path="$1"
    local launcher_name="$2"
    local launcher_type="$3"
    local launcher_exec="$4"
    local launcher_dir="$5"
    local instances_dir="$6"

    # Get version info
    local generation_date
    local commit_hash
    generation_date=$(date -Iseconds 2>/dev/null || date "+%Y-%m-%dT%H:%M:%S%z")
    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Ensure output directory exists
    mkdir -p "$(dirname "$output_path")"

    # Generate the script using heredoc
    # Note: We use a mix of quoted and unquoted heredoc markers:
    # - 'EOF' (quoted) prevents variable expansion in the heredoc
    # - We then use sed to replace placeholders with actual values
    cat > "$output_path" << 'LAUNCHER_SCRIPT_EOF'
#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Launcher for Steam Deck & Linux
# =============================================================================
# Version: __SCRIPT_VERSION__ (commit: __COMMIT_HASH__)
# Generated: __GENERATION_DATE__
# Generator: install-minecraft-splitscreen.sh v__SCRIPT_VERSION__
# Source: __REPO_URL__
#
# DO NOT EDIT - This file is auto-generated by the installer.
# To update, re-run the installer script.
# =============================================================================
#
# This script launches 1-4 Minecraft instances in splitscreen mode.
# On Steam Deck Game Mode, it launches a nested KDE Plasma session.
# On desktop mode, it launches Minecraft instances directly.
#
# Features:
# - Controller detection (1-4 players)
# - Per-instance splitscreen configuration
# - KDE panel hiding/restoring
# - Steam Input duplicate device handling
# - Nested Plasma session for Steam Deck Game Mode
# =============================================================================

set +e  # Allow script to continue on errors for robustness

# =============================================================================
# GENERATED CONFIGURATION - DO NOT MODIFY
# =============================================================================
# These values were set by the installer based on your system configuration.

LAUNCHER_NAME="__LAUNCHER_NAME__"
LAUNCHER_TYPE="__LAUNCHER_TYPE__"
LAUNCHER_EXEC="__LAUNCHER_EXEC__"
LAUNCHER_DIR="__LAUNCHER_DIR__"
INSTANCES_DIR="__INSTANCES_DIR__"

# =============================================================================
# END GENERATED CONFIGURATION
# =============================================================================

# =============================================================================
# DYNAMIC SPLITSCREEN STATE (Rev 3.0.0)
# =============================================================================
# These variables track the state of dynamic splitscreen sessions where
# players can join and leave mid-game.

declare -a INSTANCE_PIDS=("" "" "" "")     # PID for each player slot (index 0-3)
declare -a INSTANCE_ACTIVE=(0 0 0 0)       # 1 if slot is in use, 0 otherwise
declare -a INSTANCE_WRAPPER_PIDS=("" "" "" "")  # Wrapper/subshell PID (kde-inhibit or flatpak)
declare -a INSTANCE_JAVA_RESOLVED=(0 0 0 0)     # 1 once actual Java PID has been found
declare -a INSTANCE_LAUNCH_TIME=(0 0 0 0)       # epoch seconds when instance was launched
declare -a INSTANCE_CONTROLLER_DEVICE=("" "" "" "")  # /dev/input/eventN assigned to each slot
CURRENT_PLAYER_COUNT=0                      # Number of active players
KNOWN_CONTROLLER_COUNT=0                    # Last controller count seen by handleControllerChange
DYNAMIC_MODE=0                              # 1 if dynamic mode enabled
HANDHELD_MODE=0                             # 1 if Steam Deck handheld (no external display)
CONTROLLER_MONITOR_PID=""                   # PID of monitor subprocess
CONTROLLER_PIPE=""                          # Path to named pipe for controller events
MAIN_PID=$$                                 # Track main process PID for cleanup guard
CLEANUP_DONE=0                              # Reentrancy guard for cleanup_exit

# =============================================================================
# END DYNAMIC SPLITSCREEN STATE
# =============================================================================

# Ensure D-Bus session bus is available (needed for KWin scripting)
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if [ -S "/run/user/$(id -u)/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi
fi

# Temporary directory for intermediate files (respects TMPDIR if set)
export target="${TMPDIR:-/tmp}"

# =============================================================================
# LOGGING (prints to terminal AND logs to file)
# =============================================================================

LOG_DIR="$HOME/.local/share/MinecraftSplitscreen/logs"
LOG_FILE=""

_init_log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR="/tmp/MinecraftSplitscreen/logs"; mkdir -p "$LOG_DIR"; }
    LOG_FILE="$LOG_DIR/launcher-$(date +%Y-%m-%d-%H%M%S).log"
    # Rotate old logs (keep last 10)
    local c=0; while IFS= read -r f; do c=$((c+1)); [[ $c -gt 10 ]] && rm -f "$f"; done < <(ls -t "$LOG_DIR"/launcher-*.log 2>/dev/null)
    { echo "=== Minecraft Splitscreen Launcher ==="; echo "Started: $(date)"; echo ""; } >> "$LOG_FILE"
}

log() { [[ -n "$LOG_FILE" ]] && echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null; }
log_info() { echo "[Info] $*"; log "INFO: $*"; }
log_error() { echo "[Error] $*" >&2; log "ERROR: $*"; }
log_warning() { echo "[Warning] $*"; log "WARNING: $*"; }
log_debug() { echo "[Debug] $*" >&2; log "DEBUG: $*"; }

_init_log

# Import desktop session environment when launched from SSH or headless context.
# SSH sessions lack DISPLAY/WAYLAND_DISPLAY, causing false "game mode" detection.
# If a KDE desktop is running, import its env vars so the script detects desktop mode.
# NOTE: kwin_wayland (the compositor) does NOT have WAYLAND_DISPLAY in its own env —
# it creates that for child processes. So we check plasmashell first (has both
# DISPLAY and WAYLAND_DISPLAY), then fall back to kwin_wayland for other vars.
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    # Try plasmashell first (has WAYLAND_DISPLAY and DISPLAY)
    _session_pid=$(pgrep -u "$(id -u)" plasmashell 2>/dev/null | head -1)
    _source="plasmashell"
    # Fall back to kwin_wayland if plasmashell not found
    if [ -z "$_session_pid" ]; then
        _session_pid=$(pgrep -u "$(id -u)" kwin_wayland 2>/dev/null | head -1)
        _source="kwin_wayland"
    fi
    if [ -n "$_session_pid" ] && [ -r "/proc/$_session_pid/environ" ]; then
        log_info "No display vars but $_source running (PID $_session_pid) — importing session environment"
        while IFS= read -r -d '' _envline; do
            _key="${_envline%%=*}"
            _val="${_envline#*=}"
            case "$_key" in
                WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|XDG_SESSION_TYPE)
                    export "$_key=$_val"
                    log_debug "Imported $_key=$_val"
                    ;;
            esac
        done < "/proc/$_session_pid/environ"
        unset _envline _key _val
    fi
    unset _session_pid _source
fi

# =============================================================================
# Launcher Validation
# =============================================================================

# Validate that the configured launcher is available
validate_launcher() {
    local launcher_available=false

    if [[ "$LAUNCHER_TYPE" == "flatpak" ]]; then
        # For Flatpak, check if the app is installed
        local flatpak_id
        case "$LAUNCHER_NAME" in
            "PrismLauncher"|*) flatpak_id="org.prismlauncher.PrismLauncher" ;;
        esac
        if command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q "$flatpak_id"; then
            launcher_available=true
        fi
    else
        # For AppImage, check if the executable exists
        # Handle both direct path and "flatpak run" style commands
        local exec_path
        exec_path=$(echo "$LAUNCHER_EXEC" | awk '{print $1}')
        if [[ -x "$exec_path" ]] || command -v "$exec_path" >/dev/null 2>&1; then
            launcher_available=true
        fi
    fi

    if [[ "$launcher_available" == false ]]; then
        log_error "$LAUNCHER_NAME not found!"
        log_error "Expected: $LAUNCHER_EXEC"
        log_error "Please re-run the Minecraft Splitscreen installer."
        return 1
    fi

    return 0
}

# Validate launcher at startup
if ! validate_launcher; then
    exit 1
fi

log_info "Using $LAUNCHER_NAME ($LAUNCHER_TYPE) for splitscreen gameplay"
log_info "Log file: $LOG_FILE"

# =============================================================================
# Nested Plasma Session (Steam Deck Game Mode)
# =============================================================================

# Launches a nested KDE Plasma Wayland session and sets up Minecraft autostart.
# Needed so Minecraft can run in a clean, isolated desktop environment.
nestedPlasma() {
    # Unset variables that may interfere with launching a nested session
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH

    # Get current screen resolution
    local RES
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
    [ -z "$RES" ] && RES="1280x800"

    # Create a wrapper for kwin_wayland with the correct resolution
    cat <<EOF > "$target/kwin_wayland_wrapper"
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${RES%x*} --height ${RES#*x} --no-lockscreen \$@
EOF
    chmod +x "$target/kwin_wayland_wrapper"
    export PATH="$target:$PATH"

    # Write an autostart .desktop file that will re-invoke this script
    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat <<EOF > ~/.config/autostart/minecraft-launch.desktop
[Desktop Entry]
Name=Minecraft Split Launch
Exec=$SCRIPT_PATH launchFromPlasma
Type=Application
X-KDE-AutostartScript=true
EOF

    # Start nested Plasma session (never returns)
    exec dbus-run-session startplasma-wayland
}

# =============================================================================
# Controller Isolation
# =============================================================================
# Per-slot controller assignment so each Minecraft instance uses a different
# physical device. Handles Steam Input mode (Game Mode) transparently.

# Write SDL_JOYSTICK_DEVICE and SDL_JOYSTICK_HIDAPI=0 to instance.cfg so each
# JVM sees exactly one controller device.
# Arguments: $1=slot, $2=/dev/input/eventN path
writeInstanceSdlEnv() {
    local slot=$1
    local dev="$2"
    local cfg="$INSTANCES_DIR/latestUpdate-$slot/instance.cfg"
    [ -f "$cfg" ] || { log_warning "No instance.cfg for slot $slot — SDL isolation skipped"; return 1; }
    local env_json="{\"SDL_JOYSTICK_DEVICE\":\"$dev\",\"SDL_JOYSTICK_HIDAPI\":\"0\"}"
    sed -i "s|^Env=.*|Env=$env_json|" "$cfg"
    sed -i "s|^OverrideEnv=.*|OverrideEnv=true|" "$cfg"
    log_info "Slot $slot: wrote SDL_JOYSTICK_DEVICE=$dev to instance.cfg"
}

# Clear SDL env vars from instance.cfg when the slot is no longer active.
# Arguments: $1=slot
clearInstanceSdlEnv() {
    local slot=$1
    local cfg="$INSTANCES_DIR/latestUpdate-$slot/instance.cfg"
    [ -f "$cfg" ] || return 0
    sed -i "s|^Env=.*|Env={}|" "$cfg"
    sed -i "s|^OverrideEnv=.*|OverrideEnv=false|" "$cfg"
    log_info "Slot $slot: cleared SDL env vars from instance.cfg"
}

# Enumerate real (non-Steam-virtual) controller event devices from sysfs.
# Outputs one /dev/input/eventN path per line, sorted for stable ordering.
# Filters out Steam Input virtual gamepads (vendor 28de) so only physical
# controllers are enumerated.
findRealControllerEventDevices() {
    for js in $(ls -d /sys/class/input/js* 2>/dev/null | sort); do
        local vendor
        vendor=$(cat "$js/device/id/vendor" 2>/dev/null)
        # Skip Steam Input virtual gamepads (vendor=28de, Valve)
        [[ "$vendor" == "28de" ]] && continue
        local event_dev
        event_dev=$(ls "$js/device/" 2>/dev/null | grep "^event" | head -1)
        if [ -n "$event_dev" ] && [ -e "/dev/input/$event_dev" ]; then
            echo "/dev/input/$event_dev"
        fi
    done
}

# Enumerate Steam Input virtual gamepad event devices (vendor 28de).
# Outputs one /dev/input/eventN path per line, sorted for stable ordering.
# Used in Game Mode so each slot gets its own Steam Virtual Gamepad device.
findSteamVirtualEventDevices() {
    for js in $(ls -d /sys/class/input/js* 2>/dev/null | sort); do
        local vendor
        vendor=$(cat "$js/device/id/vendor" 2>/dev/null)
        [[ "$vendor" != "28de" ]] && continue
        local event_dev
        event_dev=$(ls "$js/device/" 2>/dev/null | grep "^event" | head -1)
        if [ -n "$event_dev" ] && [ -e "/dev/input/$event_dev" ]; then
            echo "/dev/input/$event_dev"
        fi
    done
}

# Enable or disable Controllable's autoSelect for a slot.
# Arguments: $1=slot, $2=true|false
setControllableAutoSelect() {
    local slot=$1
    local enabled=$2
    local toml="$INSTANCES_DIR/latestUpdate-$slot/.minecraft/config/controllable-client.toml"
    [ -f "$toml" ] || return 0
    sed -i "s/^\s*autoSelect = .*/\tautoSelect = $enabled/" "$toml"
}

# Get the Bluetooth serial (MAC address) for an event device from sysfs.
# Arguments: $1=/dev/input/eventN path
getControllerSerial() {
    local event_dev="$1"
    local event_name="${event_dev##*/}"
    cat "/sys/class/input/$event_name/device/uniq" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Search all instance selected_controllers.json files for a saved config
# whose "serial" field matches the given serial. Outputs the full JSON content.
# Arguments: $1=serial (e.g., "a0:5a:5e:d0:8a:dc")
findControllableConfigBySerial() {
    local target_serial="$1"
    local cfg_dir cfg_file cfg_serial
    for i in 1 2 3 4; do
        cfg_file="$INSTANCES_DIR/latestUpdate-$i/.minecraft/config/controllable/selected_controllers.json"
        [ -f "$cfg_file" ] || continue
        cfg_serial=$(grep -o '"serial": *"[^"]*"' "$cfg_file" | head -1 | grep -o '"[^"]*"$' | tr -d '"' | tr '[:upper:]' '[:lower:]')
        if [ "$cfg_serial" = "$target_serial" ]; then
            cat "$cfg_file"
            return 0
        fi
    done
    return 1
}

# Write Controllable's selected_controllers.json for a slot using the Bluetooth
# serial to match a previously-saved controller config.
# In Game Mode (Steam Virtual Gamepad present), uses autoSelect=true instead
# so Controllable picks whatever SDL can open (the Steam Input virtual device).
# Arguments: $1=slot, $2=/dev/input/eventN path
writeControllableConfigBySerial() {
    local slot=$1
    local event_dev="$2"
    local config_dir="$INSTANCES_DIR/latestUpdate-$slot/.minecraft/config/controllable"

    # In Game Mode, Steam Input grabs the raw device and presents a Steam Virtual
    # Gamepad with a different GUID. Use autoSelect=true so Controllable picks
    # whatever SDL can actually open.
    if hasSteamVirtualController; then
        log_info "Slot $slot: Steam Virtual Gamepad detected — using autoSelect (Game Mode)"
        setControllableAutoSelect "$slot" "true"
        return 0
    fi

    local serial
    serial=$(getControllerSerial "$event_dev")
    if [ -z "$serial" ]; then
        log_warning "Slot $slot: no Bluetooth serial for $event_dev — Controllable will use autoSelect"
        setControllableAutoSelect "$slot" "true"
        return 1
    fi

    local saved_config
    saved_config=$(findControllableConfigBySerial "$serial")
    if [ -z "$saved_config" ]; then
        log_warning "Slot $slot: no saved Controllable config for serial $serial — Controllable will use autoSelect"
        setControllableAutoSelect "$slot" "true"
        return 1
    fi

    mkdir -p "$config_dir"
    echo "$saved_config" > "$config_dir/selected_controllers.json"
    setControllableAutoSelect "$slot" "false"
    log_info "Slot $slot: assigned controller serial $serial via Controllable config (autoSelect=false)"
    return 0
}

# Assign a specific controller event device to a slot.
# Enumerates real (non-Steam-virtual) devices, picks the first unclaimed one,
# writes SDL_JOYSTICK_DEVICE to instance.cfg, and configures Controllable.
# In Game Mode, skips SDL_JOYSTICK_DEVICE restriction so Steam Virtual Gamepad
# is accessible to SDL.
# Arguments: $1=slot
assignControllerToSlot() {
    local slot=$1
    local idx=$((slot - 1))

    # In Game Mode, Steam Input grabs physical devices and presents Steam Virtual
    # Gamepads (vendor 28de). Assign one virtual device per slot so each instance
    # only sees its own controller via SDL_JOYSTICK_DEVICE.
    if hasSteamVirtualController; then
        local -a virtual_devices
        mapfile -t virtual_devices < <(findSteamVirtualEventDevices)

        if [ ${#virtual_devices[@]} -eq 0 ]; then
            log_warning "Slot $slot: no Steam Virtual Gamepad devices found — falling back to autoSelect"
            setControllableAutoSelect "$slot" "true"
            return
        fi

        log_debug "Available Steam Virtual event devices: ${virtual_devices[*]}"

        # Collect virtual devices already claimed by active slots
        local -a used_devices=()
        for i in 0 1 2 3; do
            if [ "${INSTANCE_ACTIVE[$i]}" = "1" ] && [ -n "${INSTANCE_CONTROLLER_DEVICE[$i]}" ]; then
                used_devices+=("${INSTANCE_CONTROLLER_DEVICE[$i]}")
            fi
        done

        # Pick first unclaimed virtual device
        local chosen_device=""
        for dev in "${virtual_devices[@]}"; do
            local in_use=false
            for used in "${used_devices[@]}"; do
                [[ "$used" == "$dev" ]] && in_use=true && break
            done
            if [ "$in_use" = "false" ]; then
                chosen_device="$dev"
                break
            fi
        done

        if [ -z "$chosen_device" ]; then
            local dev_idx=$((idx < ${#virtual_devices[@]} ? idx : ${#virtual_devices[@]} - 1))
            chosen_device="${virtual_devices[$dev_idx]}"
            log_warning "Slot $slot: all virtual devices claimed — falling back to index $dev_idx"
        fi

        INSTANCE_CONTROLLER_DEVICE[$idx]="$chosen_device"
        setControllableAutoSelect "$slot" "true"
        writeInstanceSdlEnv "$slot" "$chosen_device"
        log_info "Slot $slot: assigned Steam Virtual Gamepad $chosen_device (autoSelect=true)"
        return
    fi

    # Desktop Mode: enumerate real (non-Steam-virtual) controller event devices
    local -a all_devices
    mapfile -t all_devices < <(findRealControllerEventDevices)

    if [ ${#all_devices[@]} -eq 0 ]; then
        log_warning "No controller event devices found — slot $slot will use Controllable autoSelect"
        return
    fi

    log_debug "Available controller event devices: ${all_devices[*]}"

    # Collect devices already claimed by active slots
    local -a used_devices=()
    for i in 0 1 2 3; do
        if [ "${INSTANCE_ACTIVE[$i]}" = "1" ] && [ -n "${INSTANCE_CONTROLLER_DEVICE[$i]}" ]; then
            used_devices+=("${INSTANCE_CONTROLLER_DEVICE[$i]}")
        fi
    done

    # Pick the first unclaimed device
    local chosen_device=""
    for dev in "${all_devices[@]}"; do
        local in_use=false
        for used in "${used_devices[@]}"; do
            [[ "$used" == "$dev" ]] && in_use=true && break
        done
        if [ "$in_use" = "false" ]; then
            chosen_device="$dev"
            break
        fi
    done

    # Fallback: all devices claimed — use slot-index-based assignment
    if [ -z "$chosen_device" ]; then
        local dev_idx=$((idx < ${#all_devices[@]} ? idx : ${#all_devices[@]} - 1))
        chosen_device="${all_devices[$dev_idx]}"
        log_warning "Slot $slot: all devices claimed — falling back to device index $dev_idx"
    fi

    INSTANCE_CONTROLLER_DEVICE[$idx]="$chosen_device"
    writeControllableConfigBySerial "$slot" "$chosen_device"
    writeInstanceSdlEnv "$slot" "$chosen_device"
    log_info "Slot $slot: assigned controller device $chosen_device"
}

# =============================================================================
# Game Launching
# =============================================================================

# Pre-start the launcher so it's ready to accept instance launch commands.
# PrismLauncher ignores -l commands received while still initializing.
# This starts the launcher in the background and waits for it to be ready.
LAUNCHER_PREWARMED=0
prewarmLauncher() {
    if [ "$LAUNCHER_PREWARMED" = "1" ]; then
        return 0
    fi

    log_info "Pre-starting $LAUNCHER_NAME to ensure it's ready for launch commands..."

    # Start launcher without -l flag — just opens the main window
    $LAUNCHER_EXEC &
    local launcher_pid=$!
    disown $launcher_pid 2>/dev/null || true

    # Wait for PrismLauncher to finish initializing (up to 30 seconds)
    local waited=0
    local max_wait=30
    while [ $waited -lt $max_wait ]; do
        sleep 1
        waited=$((waited + 1))

        # Check if a Java process from PrismLauncher's managed instances exists
        # OR if the PrismLauncher GUI has fully loaded (process is stable and responsive)
        # We detect readiness by checking if the launcher's QLocalServer socket exists
        local socket_path=""
        if [ "$LAUNCHER_TYPE" = "flatpak" ]; then
            socket_path=$(find /tmp/.flatpak-org.prismlauncher.PrismLauncher*/tmp/ -name "PrismLauncher-*" -type s 2>/dev/null | head -1)
            if [ -z "$socket_path" ]; then
                socket_path=$(find /run/user/$(id -u)/ -name "PrismLauncher*" -type s 2>/dev/null | head -1)
            fi
        else
            socket_path=$(find /tmp/ -name "PrismLauncher-*" -type s 2>/dev/null | head -1)
        fi

        if [ -n "$socket_path" ]; then
            log_info "$LAUNCHER_NAME ready after ${waited}s (IPC socket: $socket_path)"
            LAUNCHER_PREWARMED=1
            return 0
        fi

        # Fallback: if we can't find a socket, just wait a reasonable time
        if [ $waited -ge 10 ]; then
            log_info "$LAUNCHER_NAME assumed ready after ${waited}s (no IPC socket found, using timeout)"
            LAUNCHER_PREWARMED=1
            return 0
        fi
    done

    log_warning "$LAUNCHER_NAME may not be fully ready after ${max_wait}s — proceeding anyway"
    LAUNCHER_PREWARMED=1
    return 0
}

# Launch a single Minecraft instance with KDE inhibition.
# SDL isolation strategy (two complementary layers):
#   1. writeInstanceSdlEnv() writes SDL_JOYSTICK_DEVICE to instance.cfg before
#      each launch. PrismLauncher reads per-instance Env at launch time, so
#      IPC-delegated launches (Player 2+) pick up the correct device from config.
#   2. For Player 1 (no existing PrismLauncher running), 'flatpak run --env='
#      bakes SDL_JOYSTICK_DEVICE directly into the new PrismLauncher process
#      so the JVM inherits it without relying on instance.cfg parsing.
# NOTE: --no-single-instance is intentionally NOT used — it causes PrismLauncher
# to start a fresh GUI and silently ignore the -l launch argument.
# Arguments:
#   $1 = Instance name (e.g., latestUpdate-1)
#   $2 = Player name (e.g., Player1)
#   $3 = SDL device path (e.g., /dev/input/event13), optional
launchGame() {
    local instance_name="$1"
    local player_name="$2"
    local sdl_dev="${3:-}"

    local -a cmd
    if [[ "$LAUNCHER_TYPE" == "flatpak" ]] && [ -n "$sdl_dev" ]; then
        # Pass SDL device into the flatpak sandbox environment.
        # If no PrismLauncher is running, this starts a fresh process that
        # inherits the env. If one is already running, IPC delegation occurs
        # and the env flag is ignored — instance.cfg Env handles that case.
        cmd=(flatpak run
             --env=SDL_JOYSTICK_DEVICE="$sdl_dev"
             --env=SDL_JOYSTICK_HIDAPI=0
             org.prismlauncher.PrismLauncher)
    else
        # shellcheck disable=SC2206
        cmd=($LAUNCHER_EXEC)
    fi

    if command -v kde-inhibit >/dev/null 2>&1; then
        kde-inhibit --power --screenSaver --colorCorrect --notifications \
            "${cmd[@]}" -l "$instance_name" -a "$player_name"
    else
        log_warning "kde-inhibit not found. Running $LAUNCHER_NAME without KDE inhibition."
        "${cmd[@]}" -l "$instance_name" -a "$player_name"
    fi
}

# =============================================================================
# KDE Panel Management
# =============================================================================

# Hide KDE panels for splitscreen.
# When KWin scripting is available, we use FullArea (covers panels) in the
# repositioning JS, so panels are simply covered — no need to kill plasmashell.
# This prevents the desktop from being lost if the script crashes.
hidePanels() {
    if canUseKWinScripting 2>/dev/null; then
        log_info "KWin scripting available — panels covered by FullArea geometry, not killed"
        return 0
    fi
    # Fallback for non-KWin environments: kill plasmashell (legacy behavior)
    if command -v plasmashell >/dev/null 2>&1; then
        log_warning "No KWin scripting — killing plasmashell (risky fallback)"
        pkill plasmashell
        sleep 1
        if pgrep -u "$USER" plasmashell >/dev/null; then
            killall plasmashell
            sleep 1
        fi
        if pgrep -u "$USER" plasmashell >/dev/null; then
            pkill -9 plasmashell
            sleep 1
        fi
    else
        log_info "plasmashell not found. Skipping KDE panel hiding."
    fi
}

# Restore KDE panels.
# If KWin scripting was used, panels were never killed — nothing to restore.
restorePanels() {
    if canUseKWinScripting 2>/dev/null; then
        log_info "KWin scripting was used — panels were never killed, nothing to restore"
        return 0
    fi
    # Fallback: restart plasmashell if it was killed
    if command -v plasmashell >/dev/null 2>&1; then
        if ! pgrep -u "$USER" plasmashell >/dev/null; then
            log_info "Restarting plasmashell..."
            nohup plasmashell >/dev/null 2>&1 &
            sleep 2
        fi
    else
        log_info "plasmashell not found. Skipping KDE panel restore."
    fi
}

# =============================================================================
# Hardware Detection
# =============================================================================

# Check if running on Steam Deck hardware
# Returns 0 (true) if Steam Deck hardware detected, 1 (false) otherwise
# Codenames: Jupiter = Steam Deck LCD, Galileo = Steam Deck OLED
isSteamDeckHardware() {
    local dmi_file="/sys/class/dmi/id/product_name"
    if [ -f "$dmi_file" ]; then
        local product_name
        product_name=$(cat "$dmi_file" 2>/dev/null)
        if echo "$product_name" | grep -Ei 'Steam Deck|Jupiter|Galileo' >/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Check if Steam Deck is docked (external display connected)
# Returns 0 (true) if an external display is connected via DisplayPort
# Uses glob for robustness across Steam Deck hardware revisions (LCD/OLED)
isSteamDeckDocked() {
    local dp_status
    for dp_path in /sys/class/drm/card*-DP-*/status; do
        if [ -f "$dp_path" ]; then
            dp_status=$(cat "$dp_path" 2>/dev/null)
            if [ "$dp_status" = "connected" ]; then
                return 0
            fi
        fi
    done
    return 1
}

# Check if Steam virtual controller is present
# Returns 0 (true) if a Steam Input virtual gamepad is detected.
# Detects by Valve vendor ID (28de) on a joystick device — more reliable than
# name matching since Steam presents virtual pads as "Microsoft X-Box 360 pad".
hasSteamVirtualController() {
    for js in $(ls -d /sys/class/input/js* 2>/dev/null); do
        local vendor
        vendor=$(cat "$js/device/id/vendor" 2>/dev/null)
        [[ "$vendor" == "28de" ]] && return 0
    done
    return 1
}

# =============================================================================
# Controller Detection
# =============================================================================

# Detect the number of controllers (0-4)
# Handles Steam Input device duplication when Steam is running
# Returns 0 if no controllers found (keyboard-only mode possible)
getControllerCount() {
    # Handheld mode: always report exactly 1 controller (Steam Deck built-in)
    if [ "${HANDHELD_MODE:-0}" = "1" ]; then
        log_debug "Controller detection: handheld mode, reporting 1 controller"
        echo "1"
        return 0
    fi

    local count=0
    local steam_running=0
    local real_controllers=0

    # Method 1: Count actual gamepad/joystick devices from /proc/bus/input/devices
    # This is more reliable than /dev/input/js* as it works across different udev configs
    # Filter for actual gamepads (have js handler) and exclude virtual/Steam duplicates
    if [ -f /proc/bus/input/devices ]; then
        # Count unique physical controllers by looking at the Handlers line with "js"
        # and filtering by Sysfs path - uhid devices are real, virtual/input are Steam duplicates
        # Note: grep -c exits with 1 when count is 0, so we capture output and default if empty
        real_controllers=$(grep -B5 "Handlers=.*js[0-9]" /proc/bus/input/devices 2>/dev/null | \
            grep -c "Sysfs=.*/uhid/" 2>/dev/null) || true
        real_controllers=${real_controllers:-0}
    fi

    # Method 2: Fallback to /dev/input/js* if method 1 fails
    if [ "$real_controllers" -eq 0 ]; then
        count=$(ls /dev/input/js* 2>/dev/null | wc -l)
    else
        count=$real_controllers
    fi

    # Method 3: Final fallback to sysfs
    if [ "$count" -eq 0 ]; then
        count=$(ls /sys/class/input/js* 2>/dev/null | wc -l)
    fi

    # Check if Steam is running (native or Flatpak) - expanded patterns for Bazzite/SteamOS
    if pgrep -x steam >/dev/null 2>&1 \
        || pgrep -f '/steam$' >/dev/null 2>&1 \
        || pgrep -f 'ubuntu12_32/steam' >/dev/null 2>&1 \
        || pgrep -f '^/app/bin/steam$' >/dev/null 2>&1 \
        || pgrep -f 'flatpak run com.valvesoftware.Steam' >/dev/null 2>&1; then
        steam_running=1
    fi

    # Only halve if we used fallback methods (not the uhid filtering method)
    # The uhid method already filters out Steam duplicates
    if [ "$steam_running" -eq 1 ] && [ "$real_controllers" -eq 0 ]; then
        count=$(( (count + 1) / 2 ))
    fi

    # Special case: Steam Deck hardware without Steam running
    # The Steam Deck's built-in controls show up as 2 js devices (gamepad + touchpads/motion)
    # but it's really just 1 physical controller
    if isSteamDeckHardware && [ "$steam_running" -eq 0 ] && [ "$count" -gt 1 ]; then
        log_debug "Steam Deck hardware detected without Steam - treating as 1 controller (was $count)"
        count=1
    fi

    # Special case: Steam Deck with no external controllers
    # If on Steam Deck AND count is 0 AND Steam virtual controller detected,
    # count the Steam Deck's built-in controls as 1 player
    if [ "$count" -eq 0 ] && isSteamDeckHardware && hasSteamVirtualController; then
        count=1
        log_debug "Steam Deck built-in controls detected as Player 1"
    fi

    # Clamp to maximum of 4 (no minimum - allow 0 for keyboard-only mode)
    [ "$count" -gt 4 ] && count=4

    log_debug "Controller detection: real=$real_controllers, total=$count, steam=$steam_running"
    echo "$count"
}

# Check if keyboard and mouse are available (for desktop mode)
# Returns: 0 if keyboard detected, 1 otherwise
hasKeyboardInput() {
    # Check for keyboard devices in /proc/bus/input/devices
    if [ -f /proc/bus/input/devices ]; then
        if grep -q "keyboard" /proc/bus/input/devices 2>/dev/null; then
            return 0
        fi
    fi
    # Fallback: check for common keyboard device paths
    if [ -e /dev/input/by-path/*-kbd ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# Check if mouse is available
# Returns: 0 if mouse detected, 1 otherwise
hasMouseInput() {
    # Check for mouse device
    if [ -e /dev/input/mice ] && [ -r /dev/input/mice ]; then
        return 0
    fi
    # Fallback: check for mouse in input devices
    if [ -f /proc/bus/input/devices ]; then
        if grep -qi "mouse" /proc/bus/input/devices 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Prompt user for input mode when no controllers detected
# Returns: player count (1 for keyboard mode, 0 to exit)
# All status messages go to stderr, only the count goes to stdout
promptControllerMode() {
    local has_keyboard=false
    local has_mouse=false

    # Detect available input devices
    if hasKeyboardInput; then
        has_keyboard=true
    fi
    if hasMouseInput; then
        has_mouse=true
    fi

    echo "" >&2
    echo "==========================================" >&2
    echo "  No game controllers detected!" >&2
    echo "==========================================" >&2
    echo "" >&2

    # Show detected input devices
    if [ "$has_keyboard" = true ] && [ "$has_mouse" = true ]; then
        echo "  Detected: Keyboard + Mouse" >&2
    elif [ "$has_keyboard" = true ]; then
        echo "  Detected: Keyboard only" >&2
    else
        echo "  Detected: No standard input devices" >&2
    fi
    echo "" >&2

    echo "Options:" >&2
    if [ "$has_keyboard" = true ]; then
        echo "  1. Launch with keyboard/mouse (1 player)" >&2
    else
        echo "  1. Launch anyway (1 player)" >&2
    fi
    echo "  2. Wait for controller connection" >&2
    echo "  3. Exit" >&2
    echo "" >&2

    # Try to read from terminal - test if /dev/tty can actually be opened
    local choice=""
    if [ -t 0 ]; then
        read -r -p "Your choice [1-3]: " choice
    elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
        # Test if we can actually read from /dev/tty
        if exec 3</dev/tty 2>/dev/null; then
            exec 3<&-  # Close the test fd
            read -r -p "Your choice [1-3]: " choice < /dev/tty 2>/dev/null || choice="1"
        else
            echo "[Warning] Cannot open terminal, defaulting to keyboard mode" >&2
            choice="1"
        fi
    else
        echo "[Warning] No interactive terminal available, defaulting to keyboard mode" >&2
        choice="1"
    fi

    case "$choice" in
        1)
            if [ "$has_keyboard" = true ]; then
                echo "[Info] Launching with keyboard/mouse (1 player)" >&2
                log "INFO: User selected keyboard/mouse mode"
            else
                echo "[Info] Launching in single-player mode" >&2
                log "INFO: User selected single-player mode (no input devices detected)"
            fi
            echo "1"
            ;;
        2)
            echo "[Info] Waiting for controller connection..." >&2
            echo "[Info] Connect a controller and press Enter to continue, or Ctrl+C to exit" >&2
            log "INFO: User waiting for controller connection"
            # Wait for user input
            if [ -t 0 ]; then
                read -r
            elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
                read -r < /dev/tty 2>/dev/null || true
            else
                echo "[Warning] Cannot wait without terminal, continuing..." >&2
                sleep 5
            fi
            # Re-detect controllers after waiting
            local new_count
            new_count=$(getControllerCount)
            if [ "$new_count" -eq 0 ]; then
                echo "[Warning] Still no controllers detected. Launching with keyboard/mouse." >&2
                echo "1"
            else
                echo "[Info] Detected $new_count controller(s)" >&2
                echo "$new_count"
            fi
            ;;
        3)
            echo "[Info] Exiting..." >&2
            log "INFO: User chose to exit"
            echo "0"
            ;;
        *)
            # Invalid input - default to keyboard mode
            echo "[Warning] Invalid choice '$choice', defaulting to keyboard mode" >&2
            log "INFO: Invalid choice, defaulting to keyboard mode"
            echo "1"
            ;;
    esac
}

# =============================================================================
# Controller Hotplug Monitoring (Dynamic Splitscreen)
# =============================================================================
# These functions enable real-time monitoring of controller connections
# and disconnections for dynamic player join/leave functionality.

# Monitor controller connections/disconnections
# Writes "CONTROLLER_CHANGE:<count>" to stdout when changes detected
# Uses inotifywait for efficiency, falls back to polling if unavailable
monitorControllers() {
    local last_count
    last_count=$(getControllerCount)

    # Prefer inotifywait (event-driven, efficient)
    if command -v inotifywait >/dev/null 2>&1; then
        log "Using inotifywait for controller monitoring"
        inotifywait -m -q -e create -e delete /dev/input/ 2>/dev/null | while read -r _ action file; do
            if [[ "$file" =~ ^js[0-9]+$ ]]; then
                sleep 0.5  # Debounce rapid events
                local new_count
                new_count=$(getControllerCount)
                if [ "$new_count" != "$last_count" ]; then
                    echo "CONTROLLER_CHANGE:$new_count"
                    last_count=$new_count
                fi
            fi
        done
    else
        # Fallback: poll every 2 seconds
        log "inotifywait not available, using polling for controller monitoring"
        while true; do
            sleep 2
            local new_count
            new_count=$(getControllerCount)
            if [ "$new_count" != "$last_count" ]; then
                echo "CONTROLLER_CHANGE:$new_count"
                last_count=$new_count
            fi
        done
    fi
}

# Start controller monitoring in background
# Creates a named pipe for IPC and spawns monitor subprocess
startControllerMonitor() {
    # Create a named pipe for communication
    CONTROLLER_PIPE="/tmp/mc-splitscreen-$$"
    rm -f "$CONTROLLER_PIPE" 2>/dev/null
    mkfifo "$CONTROLLER_PIPE" 2>/dev/null || {
        log_warning "Failed to create named pipe, controller monitoring disabled"
        return 1
    }

    # Start monitor in background, writing to pipe
    monitorControllers > "$CONTROLLER_PIPE" &
    CONTROLLER_MONITOR_PID=$!

    # Open pipe for reading on fd 3
    exec 3< "$CONTROLLER_PIPE"

    log_info "Controller monitor started (PID: $CONTROLLER_MONITOR_PID)"
    return 0
}

# Stop controller monitoring and clean up resources
stopControllerMonitor() {
    if [ -n "$CONTROLLER_MONITOR_PID" ]; then
        kill "$CONTROLLER_MONITOR_PID" 2>/dev/null || true
        wait "$CONTROLLER_MONITOR_PID" 2>/dev/null || true
        CONTROLLER_MONITOR_PID=""
        log "Controller monitor stopped"
    fi

    # Close fd 3 and clean up pipe
    exec 3<&- 2>/dev/null || true
    if [ -n "$CONTROLLER_PIPE" ]; then
        rm -f "$CONTROLLER_PIPE" 2>/dev/null || true
        CONTROLLER_PIPE=""
    fi
}

# =============================================================================
# Instance Lifecycle Management (Dynamic Splitscreen)
# =============================================================================
# Functions to track and manage individual Minecraft instance processes
# for dynamic join/leave functionality.

# Launch a single instance for a player slot
# Arguments:
#   $1 = slot number (1-4)
#   $2 = total players for layout calculation
launchInstanceForSlot() {
    local slot=$1
    local total_players=$2
    local idx=$((slot - 1))

    # Configure splitscreen position using existing function
    setSplitscreenModeForPlayer "$slot" "$total_players"

    # Assign the correct controller to this slot before launch
    assignControllerToSlot "$slot"

    # Launch the game in background — returns immediately
    # Launch the game in background — returns immediately.
    # Subshell must clear the EXIT trap to prevent cleanup_exit from running
    # when the wrapper process (flatpak/kde-inhibit) exits.
    # SDL isolation is passed as an argument to launchGame, which injects it
    # via 'flatpak run --env=...' so it survives into the JVM regardless of
    # whether PrismLauncher's single-instance IPC is in play.
    local sdl_dev="${INSTANCE_CONTROLLER_DEVICE[$idx]:-}"
    ( trap - EXIT INT TERM
      launchGame "latestUpdate-$slot" "Player$slot" "$sdl_dev" ) &
    local wrapper_pid=$!

    # Track the instance — Java PID will be resolved lazily by isInstanceRunning()
    INSTANCE_PIDS[$idx]=$wrapper_pid
    INSTANCE_WRAPPER_PIDS[$idx]=$wrapper_pid
    INSTANCE_ACTIVE[$idx]=1
    INSTANCE_JAVA_RESOLVED[$idx]=0
    INSTANCE_LAUNCH_TIME[$idx]=$(date +%s)

    log_info "Launched instance $slot (wrapper PID: $wrapper_pid) in $total_players-player layout"
}

# Check if an instance is still running
# Arguments:
#   $1 = slot number (1-4)
# Returns: 0 if running, 1 if not
isInstanceRunning() {
    local slot=$1
    local idx=$((slot - 1))
    local pid="${INSTANCE_PIDS[$idx]}"

    # Try to resolve actual Java PID if not yet done
    if [ "${INSTANCE_JAVA_RESOLVED[$idx]}" = "0" ]; then
        local java_pid
        java_pid=$(pgrep -f "java.*instances/latestUpdate-${slot}/" 2>/dev/null | head -1)
        if [ -n "$java_pid" ]; then
            INSTANCE_PIDS[$idx]=$java_pid
            INSTANCE_JAVA_RESOLVED[$idx]=1
            log_debug "Resolved Java PID for slot $slot: $java_pid"
        fi
    fi

    pid="${INSTANCE_PIDS[$idx]}"

    # Check if the tracked process is alive
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    # If Java PID was resolved and is dead, instance truly exited
    if [ "${INSTANCE_JAVA_RESOLVED[$idx]}" = "1" ]; then
        return 1
    fi

    # Java not yet resolved — check if wrapper is still alive (still starting up)
    local wrapper_pid="${INSTANCE_WRAPPER_PIDS[$idx]}"
    if [ -n "$wrapper_pid" ] && kill -0 "$wrapper_pid" 2>/dev/null; then
        return 0
    fi

    # Grace period: if launched recently, assume still starting up
    # The flatpak wrapper exits before Java starts, creating a gap where
    # neither wrapper nor Java PID is alive. Give 60s for Java to appear.
    local launch_time="${INSTANCE_LAUNCH_TIME[$idx]}"
    if [ -n "$launch_time" ] && [ "$launch_time" -gt 0 ]; then
        local now
        now=$(date +%s)
        local elapsed=$((now - launch_time))
        if [ "$elapsed" -lt 60 ]; then
            log_debug "Instance $slot: wrapper dead, Java not yet found, but only ${elapsed}s since launch — assuming still starting"
            return 0
        fi
    fi

    return 1
}

# Get next available slot (1-4)
# Outputs: slot number, or empty string if all full
getNextAvailableSlot() {
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "0" ]; then
            echo "$i"
            return 0
        fi
    done
    echo ""
}

# Count currently active instances
# Outputs: number of active instances (0-4)
countActiveInstances() {
    local count=0
    for i in 0 1 2 3; do
        if [ "${INSTANCE_ACTIVE[$i]}" = "1" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# Mark an instance as stopped (called when instance exits)
# Arguments:
#   $1 = slot number (1-4)
markInstanceStopped() {
    local slot=$1
    local idx=$((slot - 1))

    # Reap the wrapper subshell to prevent zombie accumulation.
    # The wrapper is a direct child (launched via `( ... ) &` in launchInstanceForSlot),
    # so `wait` collects its exit status and releases the process table entry.
    local wrapper_pid="${INSTANCE_WRAPPER_PIDS[$idx]}"
    if [ -n "$wrapper_pid" ]; then
        wait "$wrapper_pid" 2>/dev/null || true
    fi

    clearInstanceSdlEnv "$slot"
    INSTANCE_PIDS[$idx]=""
    INSTANCE_WRAPPER_PIDS[$idx]=""
    INSTANCE_ACTIVE[$idx]=0
    INSTANCE_JAVA_RESOLVED[$idx]=0
    INSTANCE_LAUNCH_TIME[$idx]=0
    log "Instance $slot marked as stopped (wrapper $wrapper_pid reaped)"
}

# Stop a specific instance, killing Java and wrapper processes
# Arguments:
#   $1 = slot number (1-4)
stopInstance() {
    local slot=$1
    local idx=$((slot - 1))
    local pid="${INSTANCE_PIDS[$idx]}"
    local wrapper_pid="${INSTANCE_WRAPPER_PIDS[$idx]}"

    # Kill Java process (graceful then force)
    # Note: Java is NOT a direct child — it's spawned by PrismLauncher inside the
    # wrapper subshell. Once the wrapper exits, Java is reparented to init/systemd,
    # so `wait` would fail. The pkill fallback below handles any survivors.
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi

    # Kill wrapper (kde-inhibit / flatpak) if still alive.
    # Zombie reaping is handled by markInstanceStopped() below.
    if [ -n "$wrapper_pid" ]; then
        kill "$wrapper_pid" 2>/dev/null || true
    fi

    # Catch any remaining processes for this specific instance
    pkill -f "java.*instances/latestUpdate-${slot}/" 2>/dev/null || true

    markInstanceStopped "$slot"
}

# =============================================================================
# Window Repositioning (Dynamic Splitscreen)
# =============================================================================
# Functions to reposition Minecraft windows when player count changes.
# Priority: KWin scripting (Wayland) > xdotool/wmctrl (X11) > restart instances.

# Check if external window management is available
# Returns: 0 if available (X11 with tools), 1 if not
canUseExternalWindowManagement() {
    # Must have a display
    if [ -z "$DISPLAY" ]; then
        return 1
    fi

    # Not available in gamescope/Game Mode
    if isSteamDeckGameMode; then
        return 1
    fi

    # On Wayland, don't use xdotool/wmctrl - causes display crashes
    # KWin scripting is checked separately via canUseKWinScripting()
    if [ -n "$WAYLAND_DISPLAY" ]; then
        return 1
    fi

    # Check for window management tools (X11 only)
    if command -v xdotool >/dev/null 2>&1 || command -v wmctrl >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Check if KWin scripting is available (Wayland-native window management)
# Returns: 0 if available (qdbus + KWin running), 1 if not
canUseKWinScripting() {
    # Need qdbus (or qdbus6) and KWin running
    local qdbus_cmd=""
    if command -v qdbus6 >/dev/null 2>&1; then
        qdbus_cmd="qdbus6"
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus_cmd="qdbus"
    else
        return 1
    fi

    # Verify KWin Scripting D-Bus interface is accessible
    if $qdbus_cmd org.kde.KWin /Scripting 2>/dev/null | grep -q loadScript; then
        return 0
    fi

    return 1
}

# Get window ID for a Minecraft instance by PID
# Arguments:
#   $1 = process PID
# Outputs: window ID or empty string
getWindowIdForPid() {
    local pid=$1
    local window_id=""

    if command -v xdotool >/dev/null 2>&1; then
        # xdotool can search by PID - wait briefly for window to appear
        sleep 0.5
        window_id=$(xdotool search --pid "$pid" 2>/dev/null | head -1)
    elif command -v wmctrl >/dev/null 2>&1; then
        # wmctrl needs window list parsing
        window_id=$(wmctrl -lp 2>/dev/null | awk -v pid="$pid" '$3 == pid {print $1; exit}')
    fi

    echo "$window_id"
}

# Move and resize a window
# Arguments:
#   $1 = window_id, $2 = x, $3 = y, $4 = width, $5 = height
moveResizeWindow() {
    local window_id=$1
    local x=$2 y=$3 width=$4 height=$5

    if [ -z "$window_id" ]; then
        return 1
    fi

    if command -v xdotool >/dev/null 2>&1; then
        xdotool windowmove "$window_id" "$x" "$y" 2>/dev/null
        xdotool windowsize "$window_id" "$width" "$height" 2>/dev/null
    elif command -v wmctrl >/dev/null 2>&1; then
        wmctrl -i -r "$window_id" -e "0,$x,$y,$width,$height" 2>/dev/null
    fi
}

# Get screen dimensions
# Outputs: "width height" (e.g., "1920 1080")
getScreenDimensions() {
    local width=1920
    local height=1080

    if command -v xdpyinfo >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        local dims
        dims=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}')
        if [ -n "$dims" ]; then
            width=$(echo "$dims" | cut -dx -f1)
            height=$(echo "$dims" | cut -dx -f2)
        fi
    fi

    echo "$width $height"
}

# Reposition windows using KWin scripting (Wayland-native)
# Arguments:
#   $1 = new total player count
repositionWindowsKWin() {
    local new_total=$1
    local script_file="/tmp/mc-splitscreen-position-$$.js"

    # Force-resolve Java PIDs before building the list
    # The wrapper PIDs (flatpak/kde-inhibit) don't own the KWin windows — Java does
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ] && [ "${INSTANCE_JAVA_RESOLVED[$idx]}" = "0" ]; then
            local java_pid
            java_pid=$(pgrep -f "java.*instances/latestUpdate-${i}/" 2>/dev/null | head -1)
            if [ -n "$java_pid" ]; then
                INSTANCE_PIDS[$idx]=$java_pid
                INSTANCE_JAVA_RESOLVED[$idx]=1
                log_debug "Pre-reposition: resolved Java PID for slot $i: $java_pid"
            fi
        fi
    done

    # Build PID array and slot mapping for active instances
    local pid_list=""
    local slot_num=0
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            slot_num=$((slot_num + 1))
            local pid="${INSTANCE_PIDS[$idx]}"
            if [ -n "$pid_list" ]; then
                pid_list="${pid_list},${pid}"
            else
                pid_list="${pid}"
            fi
        fi
    done

    log_debug "KWin reposition: PIDs=[$pid_list], total=$new_total"

    if [ -z "$pid_list" ]; then
        log_warning "No active instance PIDs for KWin repositioning"
        return 1
    fi

    # Generate KWin JavaScript with embedded PIDs and layout
    # KDE 6 KWin scripting API notes:
    #   - workspace.windowList() replaces clientList() from KDE 5
    #   - frameGeometry must be cloned via Object.assign() before modification
    #   - win.tile must be cleared to prevent tiling system from overriding geometry
    #   - console.log() output goes to journalctl (journalctl --user -t kwin_scripting)
    cat > "$script_file" << 'KWINSCRIPTEOF'
(function() {
    var pids = [__MC_PIDS__];
    var total = __MC_TOTAL__;

    console.log("MC-Splitscreen: Starting reposition for " + total + " players, PIDs: [" + pids.join(",") + "]");

    // Layout definitions as fractions of screen: {x, y, w, h}
    var layouts = {
        1: [ {x:0, y:0, w:1, h:1} ],
        2: [ {x:0, y:0, w:1, h:0.5}, {x:0, y:0.5, w:1, h:0.5} ],
        3: [ {x:0, y:0, w:0.5, h:0.5}, {x:0.5, y:0, w:0.5, h:0.5}, {x:0, y:0.5, w:0.5, h:0.5} ],
        4: [ {x:0, y:0, w:0.5, h:0.5}, {x:0.5, y:0, w:0.5, h:0.5}, {x:0, y:0.5, w:0.5, h:0.5}, {x:0.5, y:0.5, w:0.5, h:0.5} ]
    };

    var positions = layouts[total];
    if (!positions) { console.log("MC-Splitscreen: No layout for total=" + total); return; }

    // Find windows matching our PIDs
    var windows = workspace.windowList();
    console.log("MC-Splitscreen: Found " + windows.length + " total windows");

    var matched = [];
    for (var p = 0; p < pids.length; p++) {
        var found = false;
        for (var i = 0; i < windows.length; i++) {
            if (windows[i].pid === pids[p]) {
                matched.push(windows[i]);
                console.log("MC-Splitscreen: PID " + pids[p] + " matched window: '" + (windows[i].caption || "unknown") + "'");
                found = true;
                break;
            }
        }
        if (!found) {
            console.log("MC-Splitscreen: PID " + pids[p] + " NOT found in any window");
        }
    }

    // Fallback: if PID matching found fewer windows than expected,
    // try matching by window caption containing "Minecraft"
    if (matched.length < total) {
        console.log("MC-Splitscreen: PID match got " + matched.length + "/" + total + ", trying title fallback");
        var mcWindows = [];
        for (var i = 0; i < windows.length; i++) {
            var cap = windows[i].caption || "";
            if (cap.indexOf("Minecraft") !== -1) {
                // Check not already matched
                var already = false;
                for (var m = 0; m < matched.length; m++) {
                    if (matched[m] === windows[i]) { already = true; break; }
                }
                if (!already) {
                    mcWindows.push(windows[i]);
                    console.log("MC-Splitscreen: Title fallback found: '" + cap + "' (PID " + windows[i].pid + ")");
                }
            }
        }
        // Add title-matched windows to fill remaining slots
        for (var j = 0; j < mcWindows.length && matched.length < total; j++) {
            matched.push(mcWindows[j]);
        }
    }

    console.log("MC-Splitscreen: Total matched: " + matched.length + " windows for " + total + " players");
    if (matched.length === 0) { console.log("MC-Splitscreen: No windows matched, aborting"); return; }

    // Get full screen area ignoring panels/struts
    // KWin.FullScreenArea (4) gives us the entire screen, not MaximizeArea (2) which respects panel struts
    var screen = workspace.clientArea(KWin.FullScreenArea, matched[0]);
    console.log("MC-Splitscreen: Screen area: " + screen.x + "," + screen.y + " " + screen.width + "x" + screen.height);

    for (var m = 0; m < matched.length && m < positions.length; m++) {
        var pos = positions[m];
        var win = matched[m];

        // Clear tiling to prevent KWin tiling system from overriding geometry
        if (win.tile) win.tile = null;
        // Un-minimize windows so all players are visible simultaneously
        if (win.minimized) win.minimized = false;
        // Remove window decorations for borderless splitscreen
        win.noBorder = true;
        // Keep windows on top and skip taskbar/pager to prevent desktop interference
        win.keepAbove = true;
        win.skipTaskbar = true;
        win.skipPager = true;
        // Take out of fullscreen if the window manager thinks it's fullscreen
        if (win.fullScreen) win.fullScreen = false;

        // KDE 6: Must clone geometry object — mutating in-place doesn't trigger updates
        var rect = Object.assign({}, win.frameGeometry);
        rect.x = screen.x + Math.round(pos.x * screen.width);
        rect.y = screen.y + Math.round(pos.y * screen.height);
        rect.width = Math.round(pos.w * screen.width);
        rect.height = Math.round(pos.h * screen.height);
        win.frameGeometry = rect;

        console.log("MC-Splitscreen: Window " + m + " -> " + rect.x + "," + rect.y + " " + rect.width + "x" + rect.height + " (minimized=" + win.minimized + ", noBorder=" + win.noBorder + ")");
    }

    // Activate player 1's window so it has sound/input focus
    if (matched.length > 0) {
        workspace.activeWindow = matched[0];
        console.log("MC-Splitscreen: Activated window 0 (Player 1) for sound focus");
    }

    console.log("MC-Splitscreen: Reposition complete");
})();
KWINSCRIPTEOF

    # Replace placeholders with actual values
    sed -i "s/__MC_PIDS__/${pid_list}/g" "$script_file"
    sed -i "s/__MC_TOTAL__/${new_total}/g" "$script_file"

    # Determine qdbus command
    local qdbus_cmd="qdbus"
    command -v qdbus6 >/dev/null 2>&1 && qdbus_cmd="qdbus6"

    # Load, run, unload via D-Bus
    local script_name="mc-splitscreen-$$"
    local script_id
    script_id=$($qdbus_cmd org.kde.KWin /Scripting loadScript "$script_file" "$script_name" 2>/dev/null)

    if [ -n "$script_id" ]; then
        $qdbus_cmd org.kde.KWin "/Scripting/Script${script_id}" run 2>/dev/null
        sleep 0.5
        $qdbus_cmd org.kde.KWin /Scripting unloadScript "$script_name" 2>/dev/null
        # Capture KWin script debug output from journal
        local kwin_output
        kwin_output=$(journalctl --user -t kwin_scripting --since "5 seconds ago" --no-pager 2>/dev/null | grep "MC-Splitscreen" || true)
        if [ -n "$kwin_output" ]; then
            while IFS= read -r line; do
                log_debug "KWin JS: $line"
            done <<< "$kwin_output"
        fi
        log_info "KWin script executed (ID: $script_id) for $new_total-player layout"
    else
        log_warning "Failed to load KWin script"
        rm -f "$script_file"
        return 1
    fi

    rm -f "$script_file"
    return 0
}

# Install a persistent KWin script that enforces noBorder on Minecraft windows
# when they receive focus. KDE can re-apply decorations on focus change;
# this handler counteracts that by re-setting noBorder on every activation.
# The script stays loaded for the duration of the splitscreen session.
installBorderEnforcer() {
    local qdbus_cmd="qdbus"
    command -v qdbus6 >/dev/null 2>&1 && qdbus_cmd="qdbus6"

    local script_file="/tmp/mc-border-enforcer-$$.js"
    cat > "$script_file" << 'BORDERENFORCER'
(function() {
    console.log("MC-Splitscreen: Border enforcer installed");

    function isMC(win) {
        return win && win.caption && win.caption.indexOf("Minecraft") !== -1;
    }

    // Re-enforce noBorder when a Minecraft window gains focus
    workspace.windowActivated.connect(function(win) {
        if (isMC(win) && !win.noBorder) {
            win.noBorder = true;
            console.log("MC-Splitscreen: Re-enforced noBorder on: " + win.caption);
        }
    });

    // Prevent Minecraft windows from being minimized
    // Connect to each existing Minecraft window
    function guardWindow(win) {
        if (!isMC(win)) return;
        win.minimizedChanged.connect(function() {
            if (win.minimized) {
                win.minimized = false;
                console.log("MC-Splitscreen: Prevented minimize on: " + win.caption);
            }
        });
    }

    // Guard all existing Minecraft windows
    var windows = workspace.windowList();
    for (var i = 0; i < windows.length; i++) {
        guardWindow(windows[i]);
    }

    // Guard any new Minecraft windows that appear
    workspace.windowAdded.connect(function(win) {
        guardWindow(win);
    });
})();
BORDERENFORCER

    BORDER_ENFORCER_NAME="mc-border-enforcer-$$"
    local script_id
    script_id=$($qdbus_cmd org.kde.KWin /Scripting loadScript "$script_file" "$BORDER_ENFORCER_NAME" 2>/dev/null)

    if [ -n "$script_id" ]; then
        $qdbus_cmd org.kde.KWin "/Scripting/Script${script_id}" run 2>/dev/null
        BORDER_ENFORCER_ID="$script_id"
        log_info "Border enforcer installed (script ID: $script_id)"
    else
        log_warning "Failed to install border enforcer"
    fi

    rm -f "$script_file"
}

# Unload the persistent border enforcer script
uninstallBorderEnforcer() {
    if [ -n "$BORDER_ENFORCER_NAME" ]; then
        local qdbus_cmd="qdbus"
        command -v qdbus6 >/dev/null 2>&1 && qdbus_cmd="qdbus6"
        $qdbus_cmd org.kde.KWin /Scripting unloadScript "$BORDER_ENFORCER_NAME" 2>/dev/null
        log_info "Border enforcer uninstalled"
        BORDER_ENFORCER_NAME=""
        BORDER_ENFORCER_ID=""
    fi
}

# Calculate window geometry for external positioning
# Arguments:
#   $1 = slot (1-4), $2 = total_players, $3 = screen_width, $4 = screen_height
# Outputs: "x y width height"
calculateWindowPosition() {
    local slot=$1
    local total_players=$2
    local screen_width=$3
    local screen_height=$4

    case "$total_players" in
        1)
            echo "0 0 $screen_width $screen_height"
            ;;
        2)
            local half_height=$((screen_height / 2))
            case "$slot" in
                1) echo "0 0 $screen_width $half_height" ;;
                2) echo "0 $half_height $screen_width $half_height" ;;
            esac
            ;;
        3|4)
            local half_width=$((screen_width / 2))
            local half_height=$((screen_height / 2))
            case "$slot" in
                1) echo "0 0 $half_width $half_height" ;;
                2) echo "$half_width 0 $half_width $half_height" ;;
                3) echo "0 $half_height $half_width $half_height" ;;
                4) echo "$half_width $half_height $half_width $half_height" ;;
            esac
            ;;
    esac
}

# Reposition all active windows for new player count
# Arguments:
#   $1 = new total player count
repositionAllWindows() {
    local new_total=$1

    if canUseKWinScripting; then
        # KWin scripting: Wayland-native, preferred on KDE Plasma
        log_info "Repositioning windows via KWin scripting for $new_total players"
        if ! repositionWindowsKWin "$new_total"; then
            log_warning "KWin scripting failed, falling back to restart"
            repositionWithRestart "$new_total"
        fi
    elif canUseExternalWindowManagement; then
        # xdotool/wmctrl: X11 fallback for non-KDE environments
        log_info "Repositioning windows via xdotool/wmctrl for $new_total players"
        local screen_width screen_height
        read -r screen_width screen_height < <(getScreenDimensions)

        local slot_num=0
        for i in 1 2 3 4; do
            local idx=$((i - 1))
            if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
                slot_num=$((slot_num + 1))
                local pid="${INSTANCE_PIDS[$idx]}"
                local window_id
                window_id=$(getWindowIdForPid "$pid")

                if [ -n "$window_id" ]; then
                    local x y w h
                    read -r x y w h < <(calculateWindowPosition "$slot_num" "$new_total" "$screen_width" "$screen_height")
                    moveResizeWindow "$window_id" "$x" "$y" "$w" "$h"
                    log "Repositioned window for slot $i to ${x},${y} ${w}x${h}"
                else
                    log_warning "Could not find window for instance $i (PID: $pid)"
                fi
            fi
        done
    else
        # Universal fallback: restart instances with new layout
        log_warning "No window management available, restarting instances"
        repositionWithRestart "$new_total"
    fi
}

# Reposition by restarting instances (Game Mode fallback)
# Arguments:
#   $1 = new total player count
repositionWithRestart() {
    local new_total=$1

    log_info "Restarting instances for $new_total-player layout"

    # Track which slots were active before stopping
    local -a was_active=(0 0 0 0)
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            was_active[$idx]=1
            stopInstance "$i"
        fi
    done

    # Wait for all to exit
    sleep 2

    # Relaunch previously active instances with new positions
    local launch_count=0
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${was_active[$idx]}" = "1" ]; then
            # Stagger launches to avoid GPU contention
            if [ "$launch_count" -gt 0 ]; then
                log_info "Waiting 10 seconds for GPU initialization..."
                sleep 10
            fi
            launchInstanceForSlot "$i" "$new_total"
            launch_count=$((launch_count + 1))
        fi
    done
}

# =============================================================================
# Splitscreen Configuration
# =============================================================================

# Write splitscreen.properties for a player instance
# Always uses FULLSCREEN mode to avoid Splitscreen mod's Wayland StackOverflowError.
# The mod's non-FULLSCREEN modes (TOP, BOTTOM, etc.) call glfwSetWindowMonitor() which
# triggers an infinite recursion via onResolutionChange -> repositionWindow on Wayland.
# FULLSCREEN mode only sets this.fullscreen=true (no GLFW calls), so it's safe.
# Window positioning is handled externally by KWin scripting.
# Arguments:
#   $1 = Player number (1-4)
#   $2 = Total number of controllers/players (unused, kept for API compatibility)
setSplitscreenModeForPlayer() {
    local player=$1
    local numberOfControllers=$2
    local config_path="$INSTANCES_DIR/latestUpdate-${player}/.minecraft/config/splitscreen.properties"

    mkdir -p "$(dirname "$config_path")"

    # Always FULLSCREEN — KWin handles actual window positioning
    echo -e "gap=0\nmode=FULLSCREEN" > "$config_path"
    sync
    sleep 0.5
}

# =============================================================================
# Dynamic Splitscreen Event Handlers (Rev 3.0.0)
# =============================================================================
# Event handlers for dynamic player join/leave functionality.

# Show desktop notification (if available)
# Arguments:
#   $1 = title, $2 = message
showNotification() {
    local title="$1"
    local message="$2"

    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Minecraft Splitscreen" "$title" "$message" 2>/dev/null &
    fi
}

# Handle controller count change event
# With FULLSCREEN mode, the Splitscreen mod doesn't manage windows (no GLFW calls),
# so we can freely add instances and reposition via KWin without crashes.
# Arguments:
#   $1 = new controller count
handleControllerChange() {
    local new_controller_count=$1
    local current_active
    current_active=$(countActiveInstances)

    log_info "Controller change: $new_controller_count controllers (currently $current_active active)"

    # Compare against KNOWN_CONTROLLER_COUNT (last count seen here), NOT against
    # current_active.  If a player exits Minecraft but keeps their controller connected,
    # current_active drops but KNOWN_CONTROLLER_COUNT stays the same, so
    # slots_to_launch will be 0 or negative — no spurious relaunch.
    local slots_to_launch=$(( new_controller_count - KNOWN_CONTROLLER_COUNT ))
    KNOWN_CONTROLLER_COUNT=$new_controller_count

    if [ "$slots_to_launch" -le 0 ]; then
        CURRENT_PLAYER_COUNT=$current_active
        return
    fi

    local new_total=$(( current_active + slots_to_launch ))
    [ "$new_total" -gt 4 ] && new_total=4

    log_info "Scaling up: $current_active -> $new_total players"

    # Launch only the NEW instances (keep existing ones running)
    for slot in $(seq 1 $new_total); do
        local idx=$((slot - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" != "1" ]; then
            showNotification "Player Joined" "Player $slot is joining the game"
            setSplitscreenModeForPlayer "$slot" "$new_total"
            if [ "$current_active" -gt 0 ]; then
                log_info "Waiting 10 seconds for GPU initialization..."
                sleep 10
            fi
            launchInstanceForSlot "$slot" "$new_total"
            current_active=$((current_active + 1))
        fi
    done

    # Wait for new instance(s) to finish loading, then reposition ALL via KWin
    log_info "Waiting 15 seconds for new instance(s) to load before repositioning..."
    sleep 15
    repositionAllWindows "$new_total"

    CURRENT_PLAYER_COUNT=$current_active
}

# Check for and handle exited instances
# Called periodically to detect when players quit
checkForExitedInstances() {
    local any_exited=0

    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            if ! isInstanceRunning "$i"; then
                log_info "Player $i has exited"
                showNotification "Player Left" "Player $i has left the game"
                markInstanceStopped "$i"
                any_exited=1
            fi
        fi
    done

    if [ "$any_exited" = "1" ]; then
        local remaining
        remaining=$(countActiveInstances)
        CURRENT_PLAYER_COUNT=$remaining

        if [ "$remaining" -gt 0 ]; then
            log_info "Repositioning $remaining remaining player(s) via KWin"
            # Just reposition remaining windows — no restart needed since all
            # instances run in FULLSCREEN mode (mod won't fight the resize)
            repositionAllWindows "$remaining"
        fi
    fi
}

# =============================================================================
# Dynamic Splitscreen Mode (Rev 3.0.0)
# =============================================================================
# Main loop for dynamic player join/leave mode.

# Run dynamic splitscreen mode - players can join/leave mid-session
runDynamicSplitscreen() {
    log_info "Starting dynamic splitscreen mode"
    DYNAMIC_MODE=1
    local instances_ever_launched=0

    hidePanels

    # Install persistent KWin script to enforce borderless windows on focus
    if canUseKWinScripting 2>/dev/null; then
        installBorderEnforcer
    fi

    # Enforce memory settings before PrismLauncher loads configs
    enforceMemorySettings

    # Start controller monitoring
    if ! startControllerMonitor; then
        log_error "Failed to start controller monitor, falling back to static mode"
        runStaticSplitscreen
        return
    fi

    # Initial launch based on current controllers
    local initial_count
    initial_count=$(getControllerCount)
    if [ "$initial_count" -gt 0 ]; then
        handleControllerChange "$initial_count"
        instances_ever_launched=1
    else
        log_info "No controllers detected. Waiting for controller connection..."
        showNotification "Waiting for Controllers" "Connect a controller to start playing"
    fi

    # Main event loop
    while true; do
        # Check for controller events (non-blocking read with timeout)
        if read -t 1 -u 3 event 2>/dev/null; then
            if [[ "$event" =~ ^CONTROLLER_CHANGE:([0-9]+)$ ]]; then
                handleControllerChange "${BASH_REMATCH[1]}"
                instances_ever_launched=1
            fi
        fi

        # Check for exited instances
        checkForExitedInstances

        # Exit if all players have left (and at least one ever played)
        local active
        active=$(countActiveInstances)
        if [ "$active" -eq 0 ] && [ "$instances_ever_launched" = "1" ]; then
            log_info "All players have exited. Ending session."
            break
        fi
    done

    # Cleanup
    stopControllerMonitor
    restorePanels
    log_info "Dynamic splitscreen session ended"
}

# Run static splitscreen mode (original behavior)
runStaticSplitscreen() {
    log_info "Starting static splitscreen mode"
    DYNAMIC_MODE=0

    hidePanels

    # Install persistent KWin script to enforce borderless windows on focus
    if canUseKWinScripting 2>/dev/null; then
        installBorderEnforcer
    fi

    # Enforce memory settings before PrismLauncher loads configs
    enforceMemorySettings

    local numberOfControllers
    numberOfControllers=$(getControllerCount)

    # Handle 0 controllers - prompt user for options
    if [ "$numberOfControllers" -eq 0 ]; then
        numberOfControllers=$(promptControllerMode)
        # If user chose to exit (returned 0), exit gracefully
        if [ "$numberOfControllers" -eq 0 ]; then
            restorePanels
            exit 0
        fi
    fi

    echo "[Info] $numberOfControllers player(s), launching splitscreen instances..."

    for player in $(seq 1 "$numberOfControllers"); do
        echo "[Info] Launching instance $player of $numberOfControllers (latestUpdate-$player)"
        if [ "$player" -gt 1 ]; then
            log_info "Waiting 10 seconds for instance $((player - 1)) to initialize GPU..."
            sleep 10
        fi
        launchInstanceForSlot "$player" "$numberOfControllers"
    done

    # Reposition windows via KWin after all instances are launched
    if [ "$numberOfControllers" -gt 1 ] && canUseKWinScripting; then
        log_info "Waiting 15 seconds for instances to load before KWin repositioning..."
        sleep 15
        repositionAllWindows "$numberOfControllers"
    fi

    echo "[Info] All instances launched. Waiting for games to exit..."

    # Wait for all instances to exit by polling (wait builtin doesn't work
    # for processes launched via flatpak/wrappers since they detach)
    while true; do
        local active=0
        for i in $(seq 1 "$numberOfControllers"); do
            local idx=$((i - 1))
            if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
                if isInstanceRunning "$i"; then
                    active=$((active + 1))
                else
                    # Reap wrapper zombie immediately on natural exit
                    markInstanceStopped "$i"
                fi
            fi
        done
        if [ "$active" -eq 0 ]; then
            break
        fi
        sleep 2
    done

    uninstallBorderEnforcer 2>/dev/null || true
    restorePanels
    echo "[Info] All games have exited."
}

# =============================================================================
# Steam Deck Detection
# =============================================================================

# Returns 0 if running in Steam Deck Game Mode or equivalent (Bazzite, ChimeraOS, etc.)
# This determines whether we need a nested Plasma session for proper window management
#
# We need a nested session when:
#   - Running in gamescope (no traditional window manager)
#   - Running in Steam's game mode without a full desktop
#
# We DON'T need a nested session when:
#   - Running in a full KDE/GNOME desktop (even if Steam Big Picture is running)
#   - User switched from game mode to desktop mode
isSteamDeckGameMode() {
    local dmi_file="/sys/class/dmi/id/product_name"
    local dmi_contents=""

    if [ -f "$dmi_file" ]; then
        dmi_contents="$(cat "$dmi_file" 2>/dev/null)"
    fi

    # Check 1: Running in gamescope session (Steam Deck Game Mode or Bazzite Game Mode)
    # This is the most reliable indicator - gamescope IS game mode
    if [ "$XDG_SESSION_DESKTOP" = "gamescope" ] || [ "$XDG_CURRENT_DESKTOP" = "gamescope" ]; then
        log_debug "Detected gamescope session"
        return 0
    fi

    # Check 2: Running in KDE/other full desktop - this is DESKTOP mode, not game mode
    # Even if launched from startplasma-steamos, if we're in KDE, we have window management
    # Check both DISPLAY (X11/Xwayland) and WAYLAND_DISPLAY (pure Wayland sessions)
    if { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; } && [[ "$XDG_CURRENT_DESKTOP" =~ ^(KDE|GNOME|XFCE|MATE|Cinnamon|LXQt)$ ]]; then
        log_debug "Desktop mode detected (full desktop environment: $XDG_CURRENT_DESKTOP)"
        return 1
    fi

    # Check 3: Steam Deck hardware with gamepadui (and not in desktop mode)
    # Codenames: Jupiter = Steam Deck LCD, Galileo = Steam Deck OLED
    if echo "$dmi_contents" | grep -Ei 'Steam Deck|Jupiter|Galileo' >/dev/null; then
        if pgrep -af 'steam' | grep -q -- '-gamepadui'; then
            log_debug "Detected Steam Deck with gamepadui"
            return 0
        fi
    fi

    # Check 4: No display at all - likely running in pure game mode
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        log_debug "No display - assuming game mode"
        return 0
    fi

    log_debug "Desktop mode detected (default fallback)"
    return 1
}

# =============================================================================
# Cleanup
# =============================================================================

# Stop all running Minecraft instances
killAllInstances() {
    log_info "Stopping all Minecraft instances..."
    for i in 1 2 3 4; do
        local idx=$((i - 1))
        if [ "${INSTANCE_ACTIVE[$idx]}" = "1" ]; then
            stopInstance "$i"
        fi
    done
    # Final sweep for any stragglers (use INSTANCES_DIR for specificity)
    pkill -f "java.*${INSTANCES_DIR}/latestUpdate" 2>/dev/null || true
    pkill -f "kde-inhibit.*$LAUNCHER_NAME" 2>/dev/null || true
}

# Kill the PrismLauncher process itself
killLauncher() {
    log_info "Stopping $LAUNCHER_NAME..."
    if [ "$LAUNCHER_TYPE" = "flatpak" ]; then
        local flatpak_id=""
        case "$LAUNCHER_NAME" in
            "PrismLauncher"|*) flatpak_id="org.prismlauncher.PrismLauncher" ;;
        esac
        flatpak kill "$flatpak_id" 2>/dev/null || true
    fi
    pkill -f "$LAUNCHER_EXEC" 2>/dev/null || true
    sleep 1
}

# Enforce memory settings in instance configs before PrismLauncher starts.
# PrismLauncher overwrites instance.cfg when it saves state, so we must
# set these BEFORE prewarmLauncher() to ensure correct values are loaded.
enforceMemorySettings() {
    local max_mem=1536
    log_info "Enforcing MaxMemAlloc=${max_mem}MB for all instances"
    for i in 1 2 3 4; do
        local cfg="$INSTANCES_DIR/latestUpdate-${i}/instance.cfg"
        if [ -f "$cfg" ]; then
            # Enable per-instance override so global default can't clobber
            sed -i "s/OverrideMemory=false/OverrideMemory=true/" "$cfg" 2>/dev/null
            # Set memory (handles any previous value)
            sed -i "s/MaxMemAlloc=[0-9]*/MaxMemAlloc=${max_mem}/" "$cfg" 2>/dev/null
        fi
    done
}

# Core cleanup logic — shared between explicit cleanup and trap handler.
# Can be called directly before gamescope logout, or indirectly via cleanup_exit().
perform_cleanup() {
    killAllInstances
    killLauncher 2>/dev/null || true
    stopControllerMonitor 2>/dev/null || true
    uninstallBorderEnforcer 2>/dev/null || true
    restorePanels 2>/dev/null || true
    rm -f "$HOME/.config/autostart/minecraft-launch.desktop"
    rm -f "/tmp/mc-splitscreen-mode"

    # Log any remaining Java processes for diagnostics
    local remaining_java
    remaining_java=$(pgrep -af "java.*${INSTANCES_DIR}/latestUpdate" 2>/dev/null || true)
    if [ -n "$remaining_java" ]; then
        log_warning "Remaining Java processes after cleanup:"
        log_warning "$remaining_java"
    fi
}

# Trap handler — reentrancy-safe wrapper around perform_cleanup().
# Multiple signals (EXIT + TERM) can trigger this concurrently; the guard prevents
# double-cleanup which causes race conditions with kill/wait on already-dead PIDs.
cleanup_exit() {
    local exit_code=$?
    log_info "cleanup_exit triggered (exit_code=$exit_code, PID=$$, BASHPID=${BASHPID:-unknown}, MAIN_PID=$MAIN_PID)"

    # Guard 1: Only run cleanup in the main process (subshell guard)
    if [ "${BASHPID:-$$}" != "$MAIN_PID" ]; then
        log_debug "Skipping cleanup — not main process"
        return
    fi

    # Guard 2: Reentrancy protection — prevent concurrent cleanup from
    # EXIT + TERM signals overlapping (e.g., gamescope/Plasma shutdown)
    if [ "$CLEANUP_DONE" = "1" ]; then
        log_debug "Skipping cleanup — already performed"
        return
    fi
    CLEANUP_DONE=1

    perform_cleanup
    log_info "Cleanup complete"
}
trap cleanup_exit EXIT INT TERM

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Show help/usage
show_help() {
    echo "Minecraft Splitscreen Launcher v__SCRIPT_VERSION__"
    echo ""
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --mode=static    Launch with fixed player count (original behavior)"
    echo "  --mode=dynamic   Launch with dynamic join/leave support [NEW in v3.0]"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Shorthand:"
    echo "  static           Same as --mode=static"
    echo "  dynamic          Same as --mode=dynamic"
    echo ""
    echo "Environment Variables:"
    echo "  SPLITSCREEN_DEBUG=1    Enable debug output"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                   # Interactive mode selection"
    echo "  $(basename "$0") --mode=dynamic    # Start dynamic mode directly"
    echo "  $(basename "$0") static            # Start static mode directly"
    echo ""
    echo "Steam Deck: Handheld = single player. Dock to a TV for splitscreen."
    echo ""
    exit 0
}

# Enable debug output with SPLITSCREEN_DEBUG=1
if [ "${SPLITSCREEN_DEBUG:-0}" = "1" ]; then
    log_debug "=== Minecraft Splitscreen Launcher v__SCRIPT_VERSION__ ==="
    log_debug "Launcher: $LAUNCHER_NAME ($LAUNCHER_TYPE)"
    log_debug "Instances: $INSTANCES_DIR"
    log_debug "Environment: XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP DISPLAY=$DISPLAY"
    if isSteamDeckHardware; then
        if isSteamDeckDocked; then
            log_debug "Steam Deck: DOCKED (external display connected)"
        else
            log_debug "Steam Deck: HANDHELD (internal display only)"
        fi
    fi
fi

# Parse command line arguments
LAUNCH_MODE=""
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            show_help
            ;;
        --mode=static|static)
            LAUNCH_MODE="static"
            ;;
        --mode=dynamic|dynamic)
            LAUNCH_MODE="dynamic"
            ;;
        launchFromPlasma)
            LAUNCH_MODE="launchFromPlasma"
            ;;
    esac
done

# Steam Deck handheld mode: single player, no splitscreen
if [ -z "$LAUNCH_MODE" ] || [ "$LAUNCH_MODE" != "launchFromPlasma" ]; then
    if isSteamDeckHardware && ! isSteamDeckDocked; then
        log_info "Steam Deck handheld mode detected (no external display)"
        log_info "Running single-player mode with built-in controls"
        echo ""
        echo "=== Steam Deck Handheld Mode ==="
        echo "Single-player mode (dock to a TV for splitscreen)"
        echo ""
        LAUNCH_MODE="static"
        HANDHELD_MODE=1
    fi
fi

# Interactive mode selection if no mode specified
if [ -z "$LAUNCH_MODE" ]; then
    # If no terminal available (e.g. launched from Steam/Game Mode), default to static
    if ! [ -t 0 ] 2>/dev/null; then
        log_info "No terminal detected — defaulting to static mode"
        LAUNCH_MODE="static"
    else
        echo ""
        echo "=== Minecraft Splitscreen Launcher v__SCRIPT_VERSION__ ==="
        echo ""
        echo "Launch Modes:"
        echo "  1. Static  - Launch based on current controllers (original behavior)"
        echo "  2. Dynamic - Players can join/leave during session [NEW in v3.0]"
        echo ""
        echo "Tip: Use '--mode=static' or '--mode=dynamic' to skip this prompt."
        echo ""
        read -t 15 -p "Select mode [2]: " mode_choice </dev/tty 2>/dev/null || mode_choice=""
        mode_choice=${mode_choice:-2}

        case "$mode_choice" in
            1|static|s) LAUNCH_MODE="static" ;;
            *) LAUNCH_MODE="dynamic" ;;
        esac
        echo ""
    fi
fi

if isSteamDeckGameMode; then
    if [ "$LAUNCH_MODE" = "launchFromPlasma" ]; then
        # Inside nested Plasma session - check for stored mode
        rm -f ~/.config/autostart/minecraft-launch.desktop

        # Read stored mode from temp file (set by outer invocation)
        stored_mode=""
        if [ -f "/tmp/mc-splitscreen-mode" ]; then
            stored_mode=$(cat "/tmp/mc-splitscreen-mode" 2>/dev/null)
            rm -f "/tmp/mc-splitscreen-mode"
        fi

        if [ "$stored_mode" = "dynamic" ]; then
            runDynamicSplitscreen
        else
            runStaticSplitscreen
        fi

        # Explicit cleanup BEFORE Plasma logout.
        # Once qdbus logout is called, Plasma begins async shutdown and may:
        # - Kill our child processes before we can clean them up
        # - Send SIGTERM to this script, causing cleanup_exit to race
        # - Kill KWin, making D-Bus calls (uninstallBorderEnforcer) fail
        # By cleaning up first, we avoid all these race conditions.
        log_info "Performing explicit cleanup before Plasma logout..."
        perform_cleanup
        CLEANUP_DONE=1

        # Disable traps — cleanup is done, don't let EXIT/TERM re-run it
        # during Plasma's shutdown sequence
        trap - EXIT INT TERM

        qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
    else
        # Store mode for nested session and start it
        echo "$LAUNCH_MODE" > "/tmp/mc-splitscreen-mode"
        nestedPlasma
    fi
else
    # Desktop mode: launch directly with selected mode
    # Handle launchFromPlasma case: nested Plasma session ended up in desktop mode
    # (isSteamDeckGameMode returns false because KDE is now running)
    if [ "$LAUNCH_MODE" = "launchFromPlasma" ]; then
        rm -f ~/.config/autostart/minecraft-launch.desktop
        stored_mode=""
        if [ -f "/tmp/mc-splitscreen-mode" ]; then
            stored_mode=$(cat "/tmp/mc-splitscreen-mode" 2>/dev/null)
            rm -f "/tmp/mc-splitscreen-mode"
        fi
        if [ "$stored_mode" = "dynamic" ]; then
            runDynamicSplitscreen
        else
            runStaticSplitscreen
        fi
    elif [ "$LAUNCH_MODE" = "dynamic" ]; then
        runDynamicSplitscreen
    else
        runStaticSplitscreen
    fi

    # Return focus to Steam if it was running
    if pgrep -x steam >/dev/null 2>&1; then
        sleep 1
        if canUseKWinScripting; then
            # KWin-native: activate Steam window via scripting
            steam_focus_script="/tmp/mc-steam-focus-$$.js"
            cat > "$steam_focus_script" << 'STEAMFOCUSEOF'
(function() {
    var windows = workspace.windowList();
    for (var i = 0; i < windows.length; i++) {
        if (windows[i].caption.indexOf("Steam") !== -1) {
            workspace.activeWindow = windows[i];
            break;
        }
    }
})();
STEAMFOCUSEOF
            qdbus_cmd="qdbus"
            command -v qdbus6 >/dev/null 2>&1 && qdbus_cmd="qdbus6"
            sf_id=$($qdbus_cmd org.kde.KWin /Scripting loadScript "$steam_focus_script" "mc-steam-focus-$$" 2>/dev/null)
            if [ -n "$sf_id" ]; then
                $qdbus_cmd org.kde.KWin "/Scripting/Script${sf_id}" run 2>/dev/null
                sleep 0.2
                $qdbus_cmd org.kde.KWin /Scripting unloadScript "mc-steam-focus-$$" 2>/dev/null
                log_info "Returned focus to Steam via KWin"
            fi
            rm -f "$steam_focus_script"
        elif command -v xdotool >/dev/null 2>&1 && [ -z "${WAYLAND_DISPLAY:-}" ]; then
            # X11 fallback
            steam_wid=$(xdotool search --name "Steam" 2>/dev/null | head -1)
            if [ -n "$steam_wid" ]; then
                xdotool windowactivate "$steam_wid" 2>/dev/null || true
                log_info "Returned focus to Steam via xdotool"
            fi
        fi
    fi
fi
LAUNCHER_SCRIPT_EOF

    # Replace placeholders with actual values
    # Use | as delimiter since paths may contain /
    sed -i "s|__LAUNCHER_NAME__|${launcher_name}|g" "$output_path"
    sed -i "s|__LAUNCHER_TYPE__|${launcher_type}|g" "$output_path"
    sed -i "s|__LAUNCHER_EXEC__|${launcher_exec}|g" "$output_path"
    sed -i "s|__LAUNCHER_DIR__|${launcher_dir}|g" "$output_path"
    sed -i "s|__INSTANCES_DIR__|${instances_dir}|g" "$output_path"
    sed -i "s|__SCRIPT_VERSION__|${SCRIPT_VERSION:-3.0.0}|g" "$output_path"
    sed -i "s|__COMMIT_HASH__|${commit_hash}|g" "$output_path"
    sed -i "s|__GENERATION_DATE__|${generation_date}|g" "$output_path"
    sed -i "s|__REPO_URL__|${REPO_URL:-https://github.com/aradanmn/MinecraftSplitscreenSteamdeck}|g" "$output_path"

    # Make executable
    chmod +x "$output_path"

    print_success "Generated launcher script: $output_path"
    return 0
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# @function    verify_generated_script
# @description Verify that a generated launcher script is valid.
#              Checks existence, permissions, placeholder replacement, and syntax.
# @param       $1 - script_path: Path to the generated script
# @return      0 if valid, 1 if invalid
# @example
#   if verify_generated_script "/path/to/script.sh"; then echo "Valid"; fi
verify_generated_script() {
    local script_path="$1"

    if [[ ! -f "$script_path" ]]; then
        print_error "Generated script not found: $script_path"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        print_error "Generated script is not executable: $script_path"
        return 1
    fi

    # Check for placeholder remnants
    if grep -q '__LAUNCHER_' "$script_path"; then
        print_error "Generated script contains unreplaced placeholders"
        return 1
    fi

    # Basic syntax check
    if ! bash -n "$script_path" 2>/dev/null; then
        print_error "Generated script has syntax errors"
        return 1
    fi

    print_success "Generated script verified: $script_path"
    return 0
}

# @function    print_generation_config
# @description Print the configuration that would be used for script generation.
#              Useful for debugging and verification.
# @param       $1-$6 - Same as generate_splitscreen_launcher
# @stdout      Formatted configuration summary
# @return      0 always
print_generation_config() {
    local output_path="$1"
    local launcher_name="$2"
    local launcher_type="$3"
    local launcher_exec="$4"
    local launcher_dir="$5"
    local instances_dir="$6"

    echo "=== Launcher Script Generation Config ==="
    echo "Output:       $output_path"
    echo "Launcher:     $launcher_name"
    echo "Type:         $launcher_type"
    echo "Executable:   $launcher_exec"
    echo "Data Dir:     $launcher_dir"
    echo "Instances:    $instances_dir"
    echo "Version:      ${SCRIPT_VERSION:-3.0.0}"
    echo "=========================================="
}
