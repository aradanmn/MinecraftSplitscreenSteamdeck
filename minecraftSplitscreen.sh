#!/bin/bash
set -euo pipefail

# =============================
# Minecraft Splitscreen Launcher for Steam Deck & Linux
# =============================
# Dynamic launcher: detects handheld vs docked mode, spawns/tears down
# Minecraft instances inside bwrap sandboxes as controllers are hot-plugged.
# Uses the modules/ system for dock detection, controller monitoring,
# window management, and instance lifecycle.
#
# Preserved functions (unchanged from original static launcher):
#   detectLauncher, selfUpdate, nestedPlasma, pruneLauncherFrontends,
#   hidePanels, restorePanels, isSteamDeckGameMode,
#   setInstanceCfgValue, configureInstanceControllerWrapper, clearControllableSelection

# --- Source new modules ---
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/modules/dock_detection.sh"
source "$SCRIPT_DIR/modules/controller_monitor.sh"
source "$SCRIPT_DIR/modules/window_manager.sh"
source "$SCRIPT_DIR/modules/instance_lifecycle.sh"
source "$SCRIPT_DIR/modules/watchdog.sh"

# --- Environment ---
export LAUNCH_DEBUG_LOG="$HOME/.local/share/PolyMC/splitscreen-launch-debug.log"
export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"

# Background process PIDs (for cleanup trap)
_WATCH_DISPLAY_PID=""
_CONTROLLER_MONITOR_PID=""
_WATCHDOG_PID=""
_ANCHOR_PID=""

# =============================
# Function: detectLauncher (PRESERVED)
# =============================
detectLauncher() {
    # Prefer extracted squashfs-root (no FUSE needed inside bwrap)
    if [ -f "$HOME/.local/share/PolyMC/squashfs-root/AppRun" ] && [ -x "$HOME/.local/share/PolyMC/squashfs-root/AppRun" ]; then
        export LAUNCHER_DIR="$HOME/.local/share/PolyMC"
        export LAUNCHER_EXEC="$HOME/.local/share/PolyMC/squashfs-root/AppRun"
        export LAUNCHER_NAME="PolyMC"
        return 0
    fi
    if [ -f "$HOME/.local/share/PolyMC/PolyMC.AppImage" ] && [ -x "$HOME/.local/share/PolyMC/PolyMC.AppImage" ]; then
        export LAUNCHER_DIR="$HOME/.local/share/PolyMC"
        export LAUNCHER_EXEC="$HOME/.local/share/PolyMC/PolyMC.AppImage"
        export LAUNCHER_NAME="PolyMC"
        return 0
    fi

    echo "[Error] PolyMC not found at $HOME/.local/share/PolyMC/" >&2
    echo "[Error] Please run the Minecraft Splitscreen installer to set up PolyMC" >&2
    return 1
}

# =============================
# Function: selfUpdate (PRESERVED)
# =============================
selfUpdate() {
    local repo_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/minecraftSplitscreen.sh"
    local tmpfile
    tmpfile=$(mktemp)
    local script_path
    script_path="$(readlink -f "$0")"
    if ! curl -fsSL "$repo_url" -o "$tmpfile"; then
        echo "[Self-Update] Failed to check for updates." >&2
        rm -f "$tmpfile"
        return
    fi
    if ! cmp -s "$tmpfile" "$script_path"; then
        if [ -z "${PS1:-}" ] && [ -z "${TERM_PROGRAM:-}" ] && ! tty -s; then
            echo "[Self-Update] Update available. Skipping prompt in non-interactive mode."
            rm -f "$tmpfile"
            return
        fi
        echo "[Self-Update] A new version is available. Update now? [y/N]"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            echo "[Self-Update] Updating..."
            cp "$tmpfile" "$script_path"
            chmod +x "$script_path"
            rm -f "$tmpfile"
            echo "[Self-Update] Update complete. Restarting..."
            exec "$script_path" "$@"
        else
            echo "[Self-Update] Update skipped by user."
            rm -f "$tmpfile"
        fi
    else
        rm -f "$tmpfile"
        echo "[Self-Update] Already up to date."
    fi
}

# =============================
# Function: nestedPlasma (PRESERVED)
# =============================
nestedPlasma() {
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
    [ -z "$RES" ] && RES="1280x800"
    cat <<EOF > /tmp/kwin_wayland_wrapper
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${RES%x*} --height ${RES#*x} --no-lockscreen \$@
EOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat <<EOF > ~/.config/autostart/minecraft-launch.desktop
[Desktop Entry]
Name=Minecraft Split Launch
Exec=$SCRIPT_PATH launchFromPlasma
Type=Application
X-KDE-AutostartScript=true
EOF
    exec dbus-run-session startplasma-wayland
}

# =============================
# Function: pruneLauncherFrontends (PRESERVED)
# =============================
pruneLauncherFrontends() {
    local reason="${1:-manual}"
    local launcher_pids=""
    local left_after=""

    launcher_pids="$(pgrep -f 'AppRun\.wrapped|PolyMC\.AppImage|kde-inhibit.*PolyMC' 2>/dev/null || true)"
    if [ -n "$launcher_pids" ]; then
        {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prune launcher frontends (${reason})"
            pgrep -af 'AppRun\.wrapped|PolyMC\.AppImage|kde-inhibit.*PolyMC' 2>/dev/null || true
        } >> "$LAUNCH_DEBUG_LOG"
        kill $launcher_pids 2>/dev/null || true
        sleep 1
        left_after="$(pgrep -f 'AppRun\.wrapped|PolyMC\.AppImage|kde-inhibit.*PolyMC' 2>/dev/null || true)"
        if [ -n "$left_after" ]; then
            kill -9 $left_after 2>/dev/null || true
            sleep 0.5
        fi
    fi

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Frontends after prune (${reason})"
        pgrep -af 'AppRun\.wrapped|PolyMC\.AppImage|kde-inhibit.*PolyMC' 2>/dev/null || echo "  <none>"
    } >> "$LAUNCH_DEBUG_LOG"
}

# =============================
# Function: setInstanceCfgValue (PRESERVED)
# =============================
setInstanceCfgValue() {
    local cfg_path="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    [ -f "$cfg_path" ] || return 1

    if grep -q "^${key}=" "$cfg_path"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$cfg_path"
    else
        printf '%s=%s\n' "$key" "$value" >> "$cfg_path"
    fi

    if grep -Fqx "${key}=${value}" "$cfg_path"; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk -F= -v k="$key" -v v="$value" '
        BEGIN { updated=0 }
        $1 == k { print k "=" v; updated=1; next }
        { print }
        END { if (!updated) print k "=" v }
    ' "$cfg_path" > "$tmp_file"
    mv "$tmp_file" "$cfg_path"

    grep -Fqx "${key}=${value}" "$cfg_path"
}

# =============================
# Function: configureInstanceControllerWrapper (PRESERVED — not called by new code)
# =============================
configureInstanceControllerWrapper() {
    local instance_name="$1"
    local joystick_device="${2:-}"
    local cfg_path="$LAUNCHER_DIR/instances/${instance_name}/instance.cfg"
    local wrapper_cmd=""

    [ -f "$cfg_path" ] || return 0

    if [ -n "$joystick_device" ]; then
        wrapper_cmd="env SDL_JOYSTICK_DEVICE=${joystick_device} SDL_GAMECONTROLLER_IGNORE_DEVICES= SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1 SDL_JOYSTICK_HIDAPI=0"
        setInstanceCfgValue "$cfg_path" "OverrideCommands" "true"
        setInstanceCfgValue "$cfg_path" "WrapperCommand" "$wrapper_cmd"
    else
        setInstanceCfgValue "$cfg_path" "OverrideCommands" "false"
        setInstanceCfgValue "$cfg_path" "WrapperCommand" ""
    fi

    mkdir -p "$(dirname "$LAUNCH_DEBUG_LOG")"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wrapper config for ${instance_name}"
        echo "  $(grep -m1 '^OverrideCommands=' "$cfg_path" || echo 'OverrideCommands=<missing>')"
        echo "  $(grep -m1 '^WrapperCommand=' "$cfg_path" || echo 'WrapperCommand=<missing>')"
    } >> "$LAUNCH_DEBUG_LOG"
}

# =============================
# Function: clearControllableSelection (PRESERVED)
# =============================
clearControllableSelection() {
    local instance_name="$1"
    local selected_file="$LAUNCHER_DIR/instances/${instance_name}/.minecraft/config/controllable/selected_controllers.json"
    rm -f "$selected_file"
}

# =============================
# Function: hidePanels (PRESERVED)
# =============================
hidePanels() {
    if command -v plasmashell >/dev/null 2>&1; then
        pkill plasmashell || true
        sleep 1
        if pgrep -u "$USER" plasmashell >/dev/null; then
            killall plasmashell || true
            sleep 1
        fi
        if pgrep -u "$USER" plasmashell >/dev/null; then
            pkill -9 plasmashell || true
            sleep 1
        fi
    else
        echo "[Info] plasmashell not found. Skipping KDE panel hiding."
    fi
}

# =============================
# Function: restorePanels (PRESERVED)
# =============================
restorePanels() {
    if command -v plasmashell >/dev/null 2>&1; then
        nohup plasmashell >/dev/null 2>&1 &
        sleep 2
    else
        echo "[Info] plasmashell not found. Skipping KDE panel restore."
    fi
}

# =============================
# Function: isSteamDeckGameMode (PRESERVED)
# =============================
isSteamDeckGameMode() {
    local dmi_file="/sys/class/dmi/id/product_name"
    local dmi_contents=""
    if [ -f "$dmi_file" ]; then
        dmi_contents="$(cat "$dmi_file" 2>/dev/null)"
    fi
    if echo "$dmi_contents" | grep -Ei 'Steam Deck|Jupiter' >/dev/null; then
        if [ "$XDG_SESSION_DESKTOP" = "gamescope" ] && [ "$XDG_CURRENT_DESKTOP" = "gamescope" ]; then
            return 0
        fi
        if pgrep -af 'steam' | grep -q '\-gamepadui'; then
            return 0
        fi
    else
        if [ "${XDG_SESSION_DESKTOP:-}" = "gamescope" ] && [ "${XDG_CURRENT_DESKTOP:-}" = "gamescope" ] && [ "$USER" = "deck" ]; then
            return 0
        fi
        if [ "${XDG_SESSION_DESKTOP:-}" = "gamescope" ] && [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ] && [ "$USER" = "deck" ]; then
            return 0
        fi
    fi
    return 1
}

# =============================
# NEW: handheld_flow
# =============================
# Launches exactly one Minecraft instance using the built-in gamepad.
# Static — no dynamic join/leave.
handheld_flow() {
    echo "[orchestrator] Entering handheld mode" >&2

    local device_line
    device_line=$(list_eligible_controllers handheld)

    if [[ -z "$device_line" ]]; then
        echo "[orchestrator] ERROR: No gamepad-capable device found for handheld mode" >&2
        exit 1
    fi

    local event_node js_node
    event_node=$(echo "$device_line" | awk '{print $1}')
    js_node=$(echo "$device_line" | awk '{print $2}')

    echo "[orchestrator] Handheld device: $event_node $js_node" >&2

    spawn_instance 1 "$event_node" "$js_node"

    # Wait for instance to exit via FIFO events (supports SLOT_DIED and hot-swap)
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local action
        action=$(echo "$line" | awk '{print $1}')
        case "$action" in
            SLOT_DIED)
                local died_slot
                died_slot=$(echo "$line" | awk '{print $2}')
                if [[ "$died_slot" == "1" ]]; then
                    break
                fi
                ;;
            DISPLAY_MODE_CHANGE)
                local new_mode
                new_mode=$(echo "$line" | awk '{print $2}')
                if [[ "$new_mode" == "docked" ]]; then
                    echo "[orchestrator] handheld→docked hot-swap" >&2
                    teardown_all_instances
                    docked_flow
                    return
                fi
                ;;
            *)
                ;;
        esac
    done < "$SPLITSCREEN_FIFO"

    teardown_all_instances
    restorePanels
    echo "[orchestrator] Handheld session ended" >&2
    exit 0
}

# =============================
# NEW: docked_flow
# =============================
# Runs an event loop: spawns/tears down instances as external controllers
# are added/removed. Built-in Steam Deck gamepad is never used in docked mode.
docked_flow() {
    echo "[orchestrator] Entering docked mode" >&2

    # Start controller monitor in background
    start_controller_monitor docked &
    _CONTROLLER_MONITOR_PID=$!
    echo "[orchestrator] Controller monitor PID: $_CONTROLLER_MONITOR_PID" >&2

    # Initial scan and spawn: collect all controllers first, then spawn with isolation masks
    local -a _all_events=() _all_js=() _all_vendor=() _all_product=()
    local _dl
    while IFS= read -r _dl; do
        [[ -z "$_dl" ]] && continue
        _all_events+=("$(echo "$_dl" | awk '{print $1}')")
        _all_js+=("$(echo "$_dl" | awk '{print $2}')")
        _all_vendor+=("$(echo "$_dl" | awk '{print $3}')")
        _all_product+=("$(echo "$_dl" | awk '{print $4}')")
    done < <(list_eligible_controllers docked)

    local _nc=${#_all_events[@]}
    echo "[orchestrator] Found $_nc docked controller(s)" >&2

    # Get the Deck built-in event node so we can mask it in every sandbox.
    # This prevents the Deck's built-in controls from leaking through
    # Steam's IPC socket even though we set ALLOW_STEAM_VIRTUAL=1.
    local _internal_event
    _internal_event=$(get_internal_event_node 2>/dev/null || true)

    local _i
    for (( _i=0; _i<_nc && _i<4; _i++ )); do
        local slot=$(( _i + 1 ))
        local event_node="${_all_events[$_i]}"
        local js_node="${_all_js[$_i]}"
        echo "[orchestrator] SLOT $slot: controller ${_all_vendor[$_i]}:${_all_product[$_i]} → $event_node $js_node" >&2

        # Build exclusion mask: all other controllers' event/js nodes
        local -a _mask=()
        local _j
        for (( _j=0; _j<_nc; _j++ )); do
            if [[ $_j -ne $_i ]]; then
                _mask+=("${_all_events[$_j]}" "${_all_js[$_j]}")
            fi
        done
        # Also mask the Deck built-in event node (belt-and-suspenders)
        if [[ -n "$_internal_event" && "$_internal_event" != "$event_node" ]]; then
            _mask+=("$_internal_event" "")
        fi

        update_slot_state "$slot" "{\"active\": true, \"event_node\": \"${event_node}\", \"js_node\": \"${js_node}\", \"pid\": null, \"bwrap_pid\": null}"
        if [[ ${#_mask[@]} -gt 0 ]]; then
            spawn_instance "$slot" "$event_node" "$js_node" "${_mask[@]}" &
        else
            spawn_instance "$slot" "$event_node" "$js_node" &
        fi
    done

    # Event loop: read FIFO
    echo "[orchestrator] Entering event loop, reading from $SPLITSCREEN_FIFO" >&2
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local action
        action=$(echo "$line" | awk '{print $1}')

        case "$action" in
            CONTROLLER_ADD)
                local add_event add_js add_vendor add_product
                add_event=$(echo "$line" | awk '{print $2}')
                add_js=$(echo "$line" | awk '{print $3}')
                add_vendor=$(echo "$line" | awk '{print $4}')
                add_product=$(echo "$line" | awk '{print $5}')

                # Check if we're at max capacity
                local active_count
                active_count=$(get_active_slots | wc -w)

                if (( active_count >= 4 )); then
                    echo "[orchestrator] Max 4 players, ignoring new controller ($add_event)" >&2
                    continue
                fi

                # Find next free slot
                local current_active
                current_active=$(get_active_slots)
                local add_slot
                local add_assigned=0
                for add_slot in 1 2 3 4; do
                    local taken=0
                    local as2
                    for as2 in $current_active; do
                        if [[ "$as2" == "$add_slot" ]]; then
                            taken=1
                            break
                        fi
                    done
                    if (( taken == 0 )); then
                        echo "[orchestrator] CONTROLLER_ADD: slot $add_slot ($add_event $add_js)" >&2
                        # Mask all currently active controllers from this new instance
                        local _add_state _add_mask_args _me _mj
                        _add_state=$(read_state 2>/dev/null || echo "{}")
                        local -a _add_mask=()
                        while IFS=" " read -r _me _mj; do
                            [[ -z "$_me" || "$_me" == "null" ]] && continue
                            _add_mask+=("$_me" "$_mj")
                        done < <(echo "$_add_state" | jq -r '.slots | to_entries[] | select(.value.active == true) | "\(.value.event_node) \(.value.js_node)"'  2>/dev/null)
                        if [[ ${#_add_mask[@]} -gt 0 ]]; then
                            spawn_instance "$add_slot" "$add_event" "$add_js" "${_add_mask[@]}" &
                        else
                            spawn_instance "$add_slot" "$add_event" "$add_js" &
                        fi
                        add_assigned=1
                        break
                    fi
                done
                if (( add_assigned == 0 )); then
                    echo "[orchestrator] No free slot for added controller $add_event" >&2
                fi
                ;;

            CONTROLLER_REMOVE)
                local remove_event
                remove_event=$(echo "$line" | awk '{print $2}')

                # Find which slot has this event node
                local rem_slot=""
                local rem_slot_num
                for rem_slot_num in 1 2 3 4; do
                    if ! slot_is_active "$rem_slot_num"; then
                        continue
                    fi
                    local slot_event
                    slot_event=$(jq -r ".slots[\"$rem_slot_num\"].event_node // empty" "$SPLITSCREEN_STATE" 2>/dev/null || true)
                    if [[ "$slot_event" == "$remove_event" ]]; then
                        rem_slot="$rem_slot_num"
                        break
                    fi
                done

                if [[ -n "$rem_slot" ]]; then
                    echo "[orchestrator] CONTROLLER_REMOVE: slot $rem_slot ($remove_event)" >&2
                    teardown_instance "$rem_slot"

                    # Check if no players remain
                    local remaining
                    remaining=$(get_active_slots)
                    if [[ -z "$remaining" ]]; then
                        echo "[orchestrator] No players remaining, waiting for controllers..." >&2
                    fi
                else
                    echo "[orchestrator] CONTROLLER_REMOVE: no active slot found for $remove_event" >&2
                fi
                ;;

            SLOT_DIED)
                local died_slot
                died_slot=$(echo "$line" | awk '{print $2}')
                echo "[orchestrator] SLOT_DIED: slot $died_slot" >&2
                if slot_is_active "$died_slot"; then
                    teardown_instance "$died_slot"
                fi
                ;;

            DISPLAY_MODE_CHANGE)
                local new_mode
                new_mode=$(echo "$line" | awk '{print $2}')

                echo "[orchestrator] DISPLAY_MODE_CHANGE: $new_mode" >&2

                if [[ "$new_mode" == "handheld" ]]; then
                    echo "[orchestrator] Switching from docked to handheld" >&2
                    teardown_all_instances

                    # Kill controller monitor
                    if [[ -n "$_CONTROLLER_MONITOR_PID" ]]; then
                        kill "$_CONTROLLER_MONITOR_PID" 2>/dev/null || true
                        _CONTROLLER_MONITOR_PID=""
                    fi

                    handheld_flow
                    # handheld_flow calls exit, never returns
                fi
                # If switching to docked, we're already in docked_flow — just continue
                ;;

            *)
                echo "[orchestrator] Unknown FIFO message: $line" >&2
                ;;
        esac
    done < "$SPLITSCREEN_FIFO"

    # FIFO closed — clean exit
    echo "[orchestrator] FIFO closed, exiting event loop" >&2
    teardown_all_instances
    restorePanels
    exit 0
}

# =============================
# Cleanup trap
# =============================
# launch_gamescope_anchor: Create a full-screen black GTK window and register it
# as GAMESCOPECTRL_BASELAYER_WINDOW so gamescope dismisses the Steam loading overlay.
# Saved PID in _ANCHOR_PID; cleanup() kills it and resets the property.
launch_gamescope_anchor() {
    echo "[orchestrator] Launching gamescope anchor window..." >&2
    local res w h
    res=$(xdpyinfo -display :0 2>/dev/null | awk '/dimensions:/{print $2}')
    if [[ -z "$res" ]]; then
        echo "[orchestrator] WARNING: could not get display resolution, defaulting to 1920x1080" >&2
        res="1920x1080"
    fi
    w="${res%%x*}"
    h="${res##*x}"
    echo "[orchestrator] Anchor size: ${w}x${h}" >&2

    local anchor_py="/tmp/splitscreen_anchor_$$.py"
    python3 - "$w" "$h" << 'PYEOF' &
import sys, subprocess, signal
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk

w, h = int(sys.argv[1]), int(sys.argv[2])
win = Gtk.Window()
win.set_decorated(False)
win.set_default_size(w, h)
win.move(0, 0)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0, 1))
win.show_all()

def on_realize(widget):
    xid = win.get_window().get_xid()
    subprocess.run(['xprop', '-root', '-display', ':0',
                    '-f', 'GAMESCOPECTRL_BASELAYER_WINDOW', '32c',
                    '-set', 'GAMESCOPECTRL_BASELAYER_WINDOW', str(xid)],
                   capture_output=True)
    import sys as _sys
    _sys.stderr.write(f'[anchor] GAMESCOPECTRL_BASELAYER_WINDOW = {hex(xid)}\n')
    _sys.stderr.flush()

win.connect('realize', on_realize)
signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
Gtk.main()
PYEOF

    _ANCHOR_PID=$!
    echo "[orchestrator] Anchor PID: $_ANCHOR_PID" >&2

    # Force anchor window to correct size/position via xdotool
    # GTK's set_default_size can produce wrong sizes in gamescope's XWayland
    sleep 0.5
    local anchor_wid
    anchor_wid=$(xdotool search --pid "$_ANCHOR_PID" 2>/dev/null | head -1)
    if [[ -n "$anchor_wid" ]]; then
        echo "[orchestrator] Forcing anchor window $anchor_wid to ${w}x${h}+0+0 via xdotool" >&2
        xdotool windowmove "$anchor_wid" 0 0 2>/dev/null || true
        xdotool windowsize "$anchor_wid" "$w" "$h" 2>/dev/null || true
        xdotool set_window --overrideredirect 1 "$anchor_wid" 2>/dev/null || true
    fi
}

cleanup() {
    echo "[orchestrator] Cleanup: shutting down" >&2
    echo "=== SESSION END: $(date) === slots active: $(get_active_slots 2>/dev/null || echo '?') ===" >&2

    # Kill background monitors
    if [[ -n "$_CONTROLLER_MONITOR_PID" ]]; then
        kill "$_CONTROLLER_MONITOR_PID" 2>/dev/null || true
    fi
    if [[ -n "$_WATCH_DISPLAY_PID" ]]; then
        kill "$_WATCH_DISPLAY_PID" 2>/dev/null || true
    fi
    if [[ -n "$_WATCHDOG_PID" ]]; then
        kill "$_WATCHDOG_PID" 2>/dev/null || true
    fi
    if [[ -n "$_ANCHOR_PID" ]]; then
        kill "$_ANCHOR_PID" 2>/dev/null || true
        xprop -root -display :0 -f GAMESCOPECTRL_BASELAYER_WINDOW 32c \
            -set GAMESCOPECTRL_BASELAYER_WINDOW 0 2>/dev/null || true
        _ANCHOR_PID=""
    fi
    # Tear down all instances
    teardown_all_instances 2>/dev/null || true

    # Kill all placeholders
    kill_all_placeholders 2>/dev/null || true

    # Restore panels
    restorePanels 2>/dev/null || true

    # Close persistent FIFO write fd, then remove FIFO
    exec 9>&- 2>/dev/null || true
    rm -f "$HOME/.config/autostart/minecraft-launch.desktop"
    rm -f "$SPLITSCREEN_FIFO"

    echo "[orchestrator] Cleanup complete" >&2
}

# =============================
# MAIN
# =============================
main() {
    trap cleanup EXIT

    # --native: bare PolyMC launch, no orchestration, for testing controller
    if [ "${1:-}" = "--native" ]; then
        detectLauncher
        echo "[native-test] Launching bare PolyMC: ${LAUNCHER_EXEC} -l latestUpdate-1 -a P1"
        exec "${LAUNCHER_EXEC}" -l latestUpdate-1 -a P1
    fi

    # --xdotool-test: run the xdotool geometry test inside gamescope
    if [ "${1:-}" = "--xdotool-test" ]; then
        exec "$SCRIPT_DIR/tests/gamescope-xdotool-test.sh"
    fi

    # --- Session logging: tee stderr to persistent log for post-mortem ---
    local SESSION_LOG="$HOME/splitscreen-session.log"
    exec 2> >(tee -a "$SESSION_LOG" >&2)

    echo "=== SESSION START: $(date) ===" >&2

    if ! detectLauncher; then
        echo "[Error] Cannot continue without a compatible Minecraft launcher" >&2
        exit 1
    fi

    echo "[Info] Using $LAUNCHER_NAME for splitscreen gameplay"

    if [ "${1:-}" != "launchFromPlasma" ]; then
        selfUpdate
    fi

    # Steam Deck Game Mode: launch nested Plasma session
    if isSteamDeckGameMode; then
        if [ "${1:-}" = "launchFromPlasma" ]; then
            # Inside nested Plasma session — clean autostart and proceed
            rm -f "$HOME/.config/autostart/minecraft-launch.desktop"
        elif [ "${XDG_SESSION_DESKTOP:-}" = "gamescope" ]; then
            : # Pure gamescope — bwrap launches directly, no nested Plasma needed
        else
            # Not yet in nested session — start it (never returns)
            nestedPlasma
        fi
    fi

    # --- Startup sequence ---

    # Reset state file to known clean state (stale PIDs from crashed sessions)
    _ensure_state_file

    # Detect XAUTHORITY if not set (SSH sessions lack it)
    if [[ -z "${XAUTHORITY:-}" ]]; then
        for _xa in /run/user/1000/xauth_* ~/.Xauthority; do
            if [[ -f "$_xa" ]]; then
                export XAUTHORITY="$_xa"
                echo "[orchestrator] Auto-detected XAUTHORITY=$_xa" >&2
                break
            fi
        done
    fi

    # Create FIFO and hold a write end open so readers never block on open()
    mkfifo "$SPLITSCREEN_FIFO" 2>/dev/null || true
    exec 9<>"$SPLITSCREEN_FIFO"

    # Start watchdog before display watcher
    start_watchdog &
    _WATCHDOG_PID=$!
    echo "[orchestrator] Watchdog PID: $_WATCHDOG_PID" >&2

    # Start display mode watcher
    watch_display_mode &
    _WATCH_DISPLAY_PID=$!
    echo "[orchestrator] Display watcher PID: $_WATCH_DISPLAY_PID" >&2

    # Hide KDE panels (only in Game Mode / gamescope — Desktop Mode has a full desktop)
    if isSteamDeckGameMode; then
        hidePanels
    fi

    # Determine mode and branch
    display_mode=$(get_display_mode)
    # Gamescope abstracts DRM — DP-1 shows disconnected even when a TV is connected.
    # Override to docked if external controllers are present (more reliable signal).
    if [[ "$display_mode" == "handheld" ]]; then
        local _ext_count
        _ext_count=$(list_eligible_controllers docked 2>/dev/null | grep -c .)
        if [[ "$_ext_count" -ge 1 ]]; then
            echo "[orchestrator] DRM said handheld but $_ext_count external controller(s) found - docked" >&2
            display_mode="docked"
        fi
    fi
    echo "[orchestrator] Display mode: $display_mode" >&2

    # In gamescope, register an anchor window so Steam dismisses the loading overlay
    if [[ "${XDG_SESSION_DESKTOP:-}" == "gamescope" ]]; then
        launch_gamescope_anchor
    fi

    case "$display_mode" in
        handheld)
            handheld_flow
            ;;
        docked)
            docked_flow
            ;;
        *)
            echo "[orchestrator] ERROR: unknown display mode '$display_mode'" >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
