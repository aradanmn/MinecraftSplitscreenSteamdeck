#!/bin/bash
# minecraftSplitscreen.sh — Phase A prototype: static Minecraft instance test
#
# Launches actual PolyMC/PrismLauncher instances inside a nested KWin session
# with per-slot bwrap controller isolation.  Waits for all instances to reach
# the Minecraft main menu ("Sound engine started" in the log), runs for
# TEST_ACTIVE_S seconds, then auto-quits.  No operator interaction required.
#
# Overridable env vars:
#   N_SLOTS          — number of player slots (default 4)
#   TEST_ACTIVE_S    — active run duration in seconds (default 600)
#   LOAD_TIMEOUT_S   — max seconds to wait for all instances to load (default 180)
#   INSTANCES_DIR    — override auto-detected launcher instances directory
#   LAUNCHER_EXEC    — override auto-detected launcher command
#
# Production equivalent: modules/launcher_script_generator.sh → launchGames()
# runStaticTest() is prototype-only; everything else is kept in sync with the
# generator's LAUNCHER_SCRIPT_EOF heredoc.

# Per-run timestamped debug log. The script re-execs itself across the
# gamescope→KDE boundary (nestedPlasma/testPlasma write an autostart that
# re-invokes us); those autostart Exec lines pass SPLITSCREEN_DEBUG_LOG so both
# halves of one run append to the SAME file. Only the first invocation (env var
# unset) mints a new timestamp. A stable -latest symlink makes tailing easy.
LOG="${SPLITSCREEN_DEBUG_LOG:-/tmp/splitscreen-debug-$(date +%Y%m%d-%H%M%S).log}"
export SPLITSCREEN_DEBUG_LOG="$LOG"
ln -sfn "$LOG" /tmp/splitscreen-debug-latest.log 2>/dev/null || true
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-unset} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# Source runtime orchestrator modules
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
for _mod in dock_detection.sh controller_monitor.sh window_manager.sh instance_lifecycle.sh watchdog.sh orchestrator.sh dex.sh; do
    _mod_path="$SCRIPT_DIR/modules/$_mod"
    if [[ -f "$_mod_path" ]]; then
        source "$_mod_path"
    fi
done

N_SLOTS="${N_SLOTS:-4}"
TEST_ACTIVE_S="${TEST_ACTIVE_S:-600}"
LOAD_TIMEOUT_S="${LOAD_TIMEOUT_S:-180}"

# ─────────────────────────────────────────────────────────────────────────────
# Launcher auto-detection  (prototype only — generator bakes these in via sed)
# ─────────────────────────────────────────────────────────────────────────────

_detect_instances_dir() {
    local candidates=(
        "$HOME/.local/share/PolyMC/instances"
        "$HOME/.var/app/org.fn2006.PolyMC/data/PolyMC/instances"
        "$HOME/.local/share/PrismLauncher/instances"
        "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances"
    )
    for dir in "${candidates[@]}"; do
        [[ -d "$dir" ]] && { echo "$dir"; return 0; }
    done
    return 1
}

_detect_launcher_exec() {
    # AppImage bundled alongside the PolyMC data directory
    local appimage="$HOME/.local/share/PolyMC/PolyMC.AppImage"
    [[ -x "$appimage" ]] && { echo "$appimage"; return 0; }

    if flatpak list 2>/dev/null | grep -q "org.fn2006.PolyMC"; then
        echo "flatpak run org.fn2006.PolyMC"; return 0
    fi
    if flatpak list 2>/dev/null | grep -q "org.prismlauncher.PrismLauncher"; then
        echo "flatpak run org.prismlauncher.PrismLauncher"; return 0
    fi
    command -v polymc        >/dev/null 2>&1 && { echo "polymc"; return 0; }
    command -v prismlauncher >/dev/null 2>&1 && { echo "prismlauncher"; return 0; }
    return 1
}

INSTANCES_DIR="${INSTANCES_DIR:-$(_detect_instances_dir)}"
LAUNCHER_EXEC="${LAUNCHER_EXEC:-$(_detect_launcher_exec)}"

# ─────────────────────────────────────────────────────────────────────────────
# compute_geometry  slot total W H  →  stdout "x y w h"
# Layouts: 1p=full, 2p=top/bottom, 3-4p=2×2 quad.
# ─────────────────────────────────────────────────────────────────────────────
compute_geometry() {
    local slot=$1 total=$2 W=$3 H=$4
    local hw=$(( W / 2 )) hh=$(( H / 2 ))
    case $total in
        1) echo "0 0 $W $H" ;;
        2) [[ $slot -eq 1 ]] && echo "0 0 $W $hh" || echo "0 $hh $W $hh" ;;
        3|4)
            case $slot in
                1) echo "0 0 $hw $hh" ;;
                2) echo "$hw 0 $hw $hh" ;;
                3) echo "0 $hh $hw $hh" ;;
                4) echo "$hw $hh $hw $hh" ;;
            esac ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# setSplitscreenModeForPlayer  slot n_slots
# Writes splitscreen.properties so the in-game Splitscreen mod knows which
# screen region to render.  This is the primary layout mechanism.
# ─────────────────────────────────────────────────────────────────────────────
setSplitscreenModeForPlayer() {
    local player=$1 n=$2
    local config_path="$INSTANCES_DIR/latestUpdate-${player}/.minecraft/config/splitscreen.properties"
    mkdir -p "$(dirname "$config_path")"
    local mode="FULLSCREEN"
    case "$n" in
        1) mode="FULLSCREEN" ;;
        2) [[ $player -eq 1 ]] && mode="TOP" || mode="BOTTOM" ;;
        3)
            case $player in
                1) mode="TOP" ;; 2) mode="BOTTOM_LEFT" ;; *) mode="BOTTOM_RIGHT" ;;
            esac ;;
        4)
            case $player in
                1) mode="TOP_LEFT" ;; 2) mode="TOP_RIGHT" ;;
                3) mode="BOTTOM_LEFT" ;; *) mode="BOTTOM_RIGHT" ;;
            esac ;;
    esac
    echo -e "gap=1\nmode=$mode" > "$config_path"
    sync
    sleep 0.5
}

# ─────────────────────────────────────────────────────────────────────────────
# logMsg  slot level msg...
# Structured log line → LOG and stderr.  slot=0 for session-level events.
# Works in both prototype (LOG) and generator (LOG_FILE) contexts.
# ─────────────────────────────────────────────────────────────────────────────
declare -A SLOT_PIDS

logMsg() {
    local slot="$1" level="$2"
    shift 2
    local ts
    ts=$(date +%H:%M:%S)
    local line="[SLOT-${slot} ${level} ${ts}] $*"
    local _logf="${LOG_FILE:-${LOG:-/tmp/splitscreen-debug.log}}"
    echo "$line" >> "$_logf" 2>/dev/null
    echo "$line" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# find_controller_pairs  →  stdout "js_dev ev_dev" per physical controller
# Maps /dev/input/jsN to its sibling eventM via sysfs.
# Steam virtual pads have no js node and are automatically excluded.
# ─────────────────────────────────────────────────────────────────────────────
find_controller_pairs() {
    for js in /dev/input/js*; do
        [[ -e "$js" ]] || continue
        local jsnum="${js##*js}"
        local evname
        evname=$(ls /sys/class/input/js${jsnum}/device/ 2>/dev/null | grep '^event' | head -1)
        [[ -n "$evname" ]] && echo "$js /dev/input/$evname"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# launchSlot  slot js_dev ev_dev
# Launches one PolyMC/PrismLauncher instance inside a bwrap controller sandbox.
# Records the bwrap PID in SLOT_PIDS[slot].  Returns 1 if bwrap dies immediately.
# ─────────────────────────────────────────────────────────────────────────────
launchSlot() {
    local slot="$1" js_dev="$2" ev_dev="$3"
    local instance_id="latestUpdate-${slot}"

    logMsg "$slot" INFO "launching instance=$instance_id js=${js_dev:-none} ev=${ev_dev:-none}"

    if [[ -z "$LAUNCHER_EXEC" ]]; then
        logMsg "$slot" ERROR "LAUNCHER_EXEC not set — cannot launch"
        return 1
    fi

    # Per-slot isolated XDG_RUNTIME_DIR so PolyMC's SingleApplication QLocalServer
    # sockets don't find each other.  Without this, slots 2-4 detect slot 1 running,
    # route their -l command to it, and exit — only one Minecraft actually launches.
    # QT_QPA_PLATFORM=xcb forces PolyMC's Qt GUI to X11 so it doesn't need the
    # Wayland socket (which lives in the now-isolated XDG_RUNTIME_DIR).
    local slot_runtime="/tmp/polymc-runtime-slot${slot}"
    mkdir -p "$slot_runtime"

    local -a bwrap_cmd=(bwrap --dev-bind / / --dev /dev --proc /proc)
    # --dev /dev overlays an empty devtmpfs, wiping the device nodes that
    # --dev-bind / / provided.  Re-bind the GPU (required by Qt xcb / LWJGL),
    # X11 socket, shared memory, and FUSE back in, matching the known-working
    # bwrap configuration from commit d5f060c (modules/instance_lifecycle.sh).
    [[ -d /dev/dri ]]       && bwrap_cmd+=(--dev-bind /dev/dri /dev/dri)
    [[ -e /dev/fuse ]]      && bwrap_cmd+=(--dev-bind /dev/fuse /dev/fuse)
    [[ -d /dev/shm ]]       && bwrap_cmd+=(--dev-bind /dev/shm /dev/shm)
    [[ -d /tmp/.X11-unix ]] && bwrap_cmd+=(--dev-bind /tmp/.X11-unix /tmp/.X11-unix)
    bwrap_cmd+=(
        --setenv APPIMAGE_EXTRACT_AND_RUN 1
        --setenv XDG_RUNTIME_DIR "$slot_runtime"
        --setenv QT_QPA_PLATFORM xcb
        --setenv DISPLAY "${DISPLAY:-:2}"
        # XDG_RUNTIME_DIR is repointed at the isolated per-slot dir above, which
        # breaks PulseAudio/PipeWire client discovery ($XDG_RUNTIME_DIR/pulse/native),
        # leaving every instance silent. Point PULSE_SERVER at the real host socket
        # by absolute path so each instance gets audio. The socket is already inside
        # the sandbox via --dev-bind / /.
        --setenv PULSE_SERVER "unix:/run/user/$(id -u)/pulse/native"
    )
    [[ -n "$js_dev" ]] && bwrap_cmd+=(--dev-bind "$js_dev" "$js_dev")
    [[ -n "$ev_dev" ]] && bwrap_cmd+=(--dev-bind "$ev_dev" "$ev_dev")

    if command -v kde-inhibit >/dev/null 2>&1; then
        "${bwrap_cmd[@]}" kde-inhibit --power --screenSaver --colorCorrect --notifications \
            $LAUNCHER_EXEC -l "$instance_id" -a "P${slot}" &
    else
        logMsg "$slot" WARN "kde-inhibit not found — launching without power inhibition"
        "${bwrap_cmd[@]}" $LAUNCHER_EXEC -l "$instance_id" -a "P${slot}" &
    fi

    local pid=$!
    SLOT_PIDS[$slot]=$pid

    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        logMsg "$slot" ERROR "bwrap PID=$pid exited immediately — check instance config and LAUNCHER_EXEC=$LAUNCHER_EXEC"
        return 1
    fi

    logMsg "$slot" INFO "bwrap PID=$pid alive"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# waitForAllReady  n_slots [timeout_s]
# Polls each instance's latest.log for "Sound engine started" (main menu).
# Returns 0 when all n_slots are ready, 1 on timeout.
# On timeout logs per-slot diagnostics but does NOT kill anything.
# ─────────────────────────────────────────────────────────────────────────────
waitForAllReady() {
    local n_slots="$1" timeout_s="${2:-180}"
    local marker="Sound engine started"
    local deadline=$(( $(date +%s) + timeout_s ))

    logMsg 0 INFO "waiting for $n_slots instances — marker='$marker' timeout=${timeout_s}s"

    while [[ $(date +%s) -lt $deadline ]]; do
        local ready=0
        for slot in $(seq 1 "$n_slots"); do
            local mc_log="$INSTANCES_DIR/latestUpdate-${slot}/.minecraft/logs/latest.log"
            if [[ -f "$mc_log" ]] && grep -q "$marker" "$mc_log" 2>/dev/null; then
                (( ready++ ))
            fi
        done
        logMsg 0 DEBUG "$ready/$n_slots at main menu"
        if [[ $ready -ge $n_slots ]]; then
            logMsg 0 INFO "all $n_slots instances ready"
            return 0
        fi
        sleep 5
    done

    logMsg 0 ERROR "load timeout after ${timeout_s}s — per-slot status:"
    for slot in $(seq 1 "$n_slots"); do
        local mc_log="$INSTANCES_DIR/latestUpdate-${slot}/.minecraft/logs/latest.log"
        if [[ ! -f "$mc_log" ]]; then
            logMsg "$slot" ERROR "no log file at $mc_log — instance likely crashed"
        elif grep -q "$marker" "$mc_log" 2>/dev/null; then
            logMsg "$slot" INFO "ready (arrived after deadline)"
        else
            local last
            last=$(tail -3 "$mc_log" 2>/dev/null | tr '\n' '|')
            logMsg "$slot" ERROR "NOT ready — last log: $last"
        fi
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# quitSlot  slot bwrap_pid
# SIGTERM to bwrap and its children, waits up to 30s, then SIGKILLs stragglers.
# ─────────────────────────────────────────────────────────────────────────────
quitSlot() {
    local slot="$1" bwrap_pid="$2"

    if ! kill -0 "$bwrap_pid" 2>/dev/null; then
        logMsg "$slot" INFO "PID $bwrap_pid already gone"
        return 0
    fi

    logMsg "$slot" INFO "SIGTERM → PID $bwrap_pid and children"
    kill -TERM "$bwrap_pid" 2>/dev/null || true
    pkill -TERM -P "$bwrap_pid" 2>/dev/null || true

    local waited=0
    while [[ $waited -lt 30 ]]; do
        kill -0 "$bwrap_pid" 2>/dev/null || {
            logMsg "$slot" INFO "exited gracefully after ${waited}s"
            return 0
        }
        sleep 1
        (( waited++ ))
    done

    logMsg "$slot" WARN "still alive after 30s — SIGKILL"
    kill -KILL "$bwrap_pid" 2>/dev/null || true
    pkill -KILL -P "$bwrap_pid" 2>/dev/null || true
    sleep 1

    if kill -0 "$bwrap_pid" 2>/dev/null; then
        logMsg "$slot" ERROR "survived SIGKILL — manual intervention needed (PID=$bwrap_pid)"
        return 1
    fi

    logMsg "$slot" INFO "killed (forced)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# quitAllSlots
# Quits all SLOT_PIDS entries in parallel, then clears the array.
# ─────────────────────────────────────────────────────────────────────────────
quitAllSlots() {
    if [[ ${#SLOT_PIDS[@]} -eq 0 ]]; then
        logMsg 0 INFO "quitAllSlots: nothing to quit"
        return 0
    fi
    logMsg 0 INFO "quitting slots: ${!SLOT_PIDS[*]}"
    local slot
    for slot in "${!SLOT_PIDS[@]}"; do
        quitSlot "$slot" "${SLOT_PIDS[$slot]}" &
    done
    wait
    unset SLOT_PIDS
    declare -gA SLOT_PIDS
    logMsg 0 INFO "all slots quit"
}

# ─────────────────────────────────────────────────────────────────────────────
# Session-env leak guard.
# nestedPlasma/testPlasma exec `dbus-run-session startplasma-wayland`. KDE startup
# pushes the NESTED compositor's WAYLAND_DISPLAY (e.g. wayland-1) into the shared
# systemd --user environment (dbus-update-activation-environment --systemd). But
# dbus-run-session only isolates the dbus *bus*, not the per-user systemd manager —
# so that value outlives our session. Afterward the next gamescope/Steam session
# inherits WAYLAND_DISPLAY pointing at a now-dead socket → gamescope can't start →
# sddm relaunches forever → both displays stay black.
# We snapshot the gamescope value BEFORE going nested and restore it on the way out.
# ─────────────────────────────────────────────────────────────────────────────
_SESSION_ENV_BAK="/tmp/splitscreen-session-env.bak"

_snapshot_session_env() {
    : > "$_SESSION_ENV_BAK" 2>/dev/null || true
    local v cur
    for v in WAYLAND_DISPLAY DISPLAY; do
        # systemd --user still holds the gamescope value here (startplasma has not
        # clobbered it yet); fall back to our own inherited process env.
        cur=$(systemctl --user show-environment 2>/dev/null | sed -n "s/^${v}=//p" | head -1)
        [[ -z "$cur" ]] && cur="${!v:-}"
        if [[ -n "$cur" ]]; then
            echo "${v}=${cur}" >> "$_SESSION_ENV_BAK"
        else
            echo "#UNSET ${v}" >> "$_SESSION_ENV_BAK"
        fi
    done
    echo "[session-env] snapshot: $(tr '\n' ' ' < "$_SESSION_ENV_BAK" 2>/dev/null)" >> "$LOG"
}

_restore_session_env() {
    [[ -f "$_SESSION_ENV_BAK" ]] || return 0
    local line
    while IFS= read -r line; do
        case "$line" in
            \#UNSET\ *) systemctl --user unset-environment "${line#\#UNSET }" 2>/dev/null || true ;;
            *=*)        systemctl --user set-environment "$line" 2>/dev/null || true ;;
        esac
    done < "$_SESSION_ENV_BAK"
    echo "[session-env] restored gamescope WAYLAND_DISPLAY/DISPLAY in systemd --user" >> "$LOG"
    rm -f "$_SESSION_ENV_BAK" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# nestedPlasma
# Starts a nested KDE Plasma Wayland session inside gamescope.
# Writes an autostart .desktop so this script is re-invoked as launchWindowTest
# once the KDE session is up.
# ─────────────────────────────────────────────────────────────────────────────
nestedPlasma() {
    echo "[nestedPlasma] start" >> "$LOG"
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    echo "[nestedPlasma] W=$W H=$H" >> "$LOG"

    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true

    # KWin wrapper with correct resolution
    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH

    # Autostart re-invokes this script once KDE session is running
    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/splitscreen-test.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen Test
Exec=env SPLITSCREEN_DEBUG_LOG=${LOG} ${SCRIPT_PATH}
Type=Application
X-KDE-AutostartScript=true
DEOF
    _snapshot_session_env
    echo "[nestedPlasma] autostart written, exec-ing startplasma-wayland" >> "$LOG"
    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
# runStaticTest  [n_slots] [test_active_s]
# PROTOTYPE ONLY — not generated by the installer.
# Production equivalent: launchGames() in launcher_script_generator.sh.
#
# Full Phase A orchestration:
#   detect launchers → write KWin rules → write splitscreen configs →
#   launch all slots → wait for main menu → active test → auto-quit
# ─────────────────────────────────────────────────────────────────────────────
runStaticTest() {
    local n_slots="${1:-$N_SLOTS}" test_active_s="${2:-$TEST_ACTIVE_S}"

    logMsg 0 INFO "=== PHASE A STATIC TEST === slots=$n_slots active=${test_active_s}s load_timeout=${LOAD_TIMEOUT_S}s"
    logMsg 0 INFO "INSTANCES_DIR=${INSTANCES_DIR:-<not detected>}"
    logMsg 0 INFO "LAUNCHER_EXEC=${LAUNCHER_EXEC:-<not detected>}"

    # ── Pre-flight checks
    if [[ -z "$INSTANCES_DIR" || ! -d "$INSTANCES_DIR" ]]; then
        logMsg 0 ERROR "INSTANCES_DIR not found: '${INSTANCES_DIR:-empty}'"
        logMsg 0 ERROR "ensure PolyMC/PrismLauncher is installed, or set INSTANCES_DIR"
        return 1
    fi
    if [[ -z "$LAUNCHER_EXEC" ]]; then
        logMsg 0 ERROR "no launcher detected — install PolyMC/PrismLauncher or set LAUNCHER_EXEC"
        return 1
    fi
    for slot in $(seq 1 "$n_slots"); do
        local inst_dir="$INSTANCES_DIR/latestUpdate-${slot}"
        if [[ ! -d "$inst_dir" ]]; then
            logMsg "$slot" ERROR "instance dir missing: $inst_dir — run the installer first"
            return 1
        fi
        logMsg "$slot" INFO "instance dir OK: $inst_dir"
    done

    # ── Screen size
    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    logMsg 0 INFO "screen: ${W}x${H}"

    # ── Detect controller pairs
    local -a js_devs ev_devs
    local idx=0
    while IFS=' ' read -r js ev; do
        js_devs[$idx]="$js"; ev_devs[$idx]="$ev"; (( idx++ ))
    done < <(find_controller_pairs)
    logMsg 0 INFO "detected ${#js_devs[@]} controller pair(s)"

    # ── KWin placement rules (fallback positioning)
    {
        echo "[General]"; echo "count=$n_slots"
        for _s in $(seq 1 "$n_slots"); do
            read _x _y _w _h < <(compute_geometry "$_s" "$n_slots" "$W" "$H")
            printf '\n[%s]\nDescription=SplitscreenP%s\ntitle=SplitscreenP%s\ntitlematch=1\nposition=%s,%s\npositionrule=3\nsize=%s,%s\nsizerule=3\n' \
                "$_s" "$_s" "$_s" "$_x" "$_y" "$_w" "$_h"
        done
    } > ~/.config/kwinrulesrc
    logMsg 0 INFO "kwinrulesrc written for $n_slots slots"

    # ── Clear stale Minecraft logs so waitForAllReady doesn't match previous-run entries
    for slot in $(seq 1 "$n_slots"); do
        local mc_log="$INSTANCES_DIR/latestUpdate-${slot}/.minecraft/logs/latest.log"
        [[ -f "$mc_log" ]] && > "$mc_log" && logMsg "$slot" INFO "cleared stale latest.log"
    done

    # ── Splitscreen mod config + launch each slot
    local launch_ok=true
    for slot in $(seq 1 "$n_slots"); do
        setSplitscreenModeForPlayer "$slot" "$n_slots"
        logMsg "$slot" INFO "splitscreen.properties written"

        local js_dev="${js_devs[$((slot-1))]:-}"
        local ev_dev="${ev_devs[$((slot-1))]:-}"
        if ! launchSlot "$slot" "$js_dev" "$ev_dev"; then
            logMsg "$slot" ERROR "launch failed — aborting test"
            launch_ok=false; break
        fi
        sleep 2
    done

    if [[ "$launch_ok" != true ]]; then
        logMsg 0 ERROR "launch aborted — cleaning up"
        quitAllSlots; return 1
    fi

    # ── Wait for all instances to reach main menu
    if ! waitForAllReady "$n_slots" "$LOAD_TIMEOUT_S"; then
        logMsg 0 ERROR "load failed — instances left running for SSH inspection"
        logMsg 0 INFO "inspect: $INSTANCES_DIR/latestUpdate-N/.minecraft/logs/latest.log"
        logMsg 0 INFO "waiting 5min grace period before force-quit"
        sleep 300
        quitAllSlots; return 1
    fi

    # ── Active test run
    logMsg 0 INFO "=== ACTIVE TEST START === running ${test_active_s}s"
    sleep "$test_active_s"

    # ── Auto-quit
    logMsg 0 INFO "=== ACTIVE TEST COMPLETE === quitting all slots"
    quitAllSlots
    logMsg 0 INFO "=== PHASE A TEST PASS ==="
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# launchWindowTest
# Entry point when running inside the nested KDE session.
# Calls runStaticTest then tears down the KWin session.
# ─────────────────────────────────────────────────────────────────────────────
launchWindowTest() {
    echo "[launchWindowTest] start" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true
    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    runStaticTest "$N_SLOTS" "$TEST_ACTIVE_S"
    local result=$?

    pkill -TERM kwin_wayland 2>/dev/null || true
    sleep 2
    pkill -KILL kwin_wayland 2>/dev/null || true
    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# testPlasma
# Starts nested KDE session for Phase B automated lifecycle test.
# Writes autostart .desktop that calls launchTestFromPlasma instead of main().
# ─────────────────────────────────────────────────────────────────────────────
testPlasma() {
    echo "[testPlasma] start" >> "$LOG"
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    echo "[testPlasma] W=$W H=$H" >> "$LOG"

    # KWin wrapper with correct resolution
    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH

    # Autostart calls launchTestFromPlasma
    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/splitscreen-test.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen Test
Exec=env SPLITSCREEN_DEBUG_LOG=${LOG} ${SCRIPT_PATH} testFromPlasma
Type=Application
X-KDE-AutostartScript=true
DEOF
    _snapshot_session_env
    echo "[testPlasma] autostart written, exec-ing startplasma-wayland" >> "$LOG"
    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
# launchTestFromPlasma
# Called from KDE autostart inside the nested test session.
# Starts docked_flow in background, runs the Phase B lifecycle test
# script against the FIFO, then tears down.
# ─────────────────────────────────────────────────────────────────────────────
launchTestFromPlasma() {
    echo "[launchTestFromPlasma] start" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true
    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    # Always kill the nested KWin session AND restore the leaked session env on exit
    # — prevents both a permanent black screen and the sddm restart loop if the test
    # script hangs, crashes, or is interrupted.
    trap '_restore_session_env; pkill -TERM kwin_wayland 2>/dev/null; sleep 1; pkill -KILL kwin_wayland 2>/dev/null || true' EXIT

    # Ensure FIFO exists
    local fifo="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
    export SPLITSCREEN_FIFO="$fifo"
    if [[ ! -p "$fifo" ]]; then
        mkfifo "$fifo" 2>/dev/null || true
    fi

    # Initialize the state file
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    export SPLITSCREEN_STATE="$state"
    echo '{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null}}}' > "$state" 2>/dev/null || true

    # Restart-loop wrapper around docked_flow.
    # DISPLAY_MODE_CHANGE handheld causes docked_flow to return 1 and exit —
    # tests 1 and 5 both send that message.  Without a restart loop the FIFO
    # has no reader and every subsequent _inject blocks forever.
    if ! declare -f docked_flow >/dev/null 2>&1; then
        echo "[launchTestFromPlasma] ERROR: docked_flow not available" >> "$LOG"
        return 1
    fi
    _orchestrator_loop() {
        while true; do
            docked_flow || true   # ignore rc=1 (mode-change exit), restart immediately
            sleep 0.5             # brief gap before re-entry
        done
    }
    echo "[launchTestFromPlasma] Starting orchestrator restart loop" >> "$LOG"
    _orchestrator_loop &
    local orch_pid=$!
    echo "[launchTestFromPlasma] Orchestrator PID: $orch_pid" >> "$LOG"

    # Give the first docked_flow iteration time to open the FIFO
    sleep 2

    # Run the Phase B lifecycle test — all tests by default,
    # or a specific test number if TEST_NUMBER is set (from "test N" arg)
    local test_arg="${TEST_NUMBER:-all}"
    echo "[launchTestFromPlasma] Running test harness (tests=$test_arg)" >> "$LOG"
    local test_script
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    test_script="$SCRIPT_DIR/tests/test_phase_b_lifecycle.sh"
    if [[ -f "$test_script" ]]; then
        echo "[launchTestFromPlasma] Running test harness: $test_script" >> "$LOG"
        timeout 7200 bash "$test_script" "$test_arg" || true
        echo "[launchTestFromPlasma] Test complete" >> "$LOG"
    else
        echo "[launchTestFromPlasma] Test script not found at $test_script" >> "$LOG"
    fi

    # Clean up — kill the restart loop and its children (monitors, sleep stubs)
    echo "[launchTestFromPlasma] Cleaning up orchestrator (PID $orch_pid)" >> "$LOG"
    kill -TERM "$orch_pid" 2>/dev/null || true
    pkill -P "$orch_pid" 2>/dev/null || true
    sleep 2

    # Final cleanup
    if declare -f teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>/dev/null || true
    fi

    # Disarm the trap and do the KWin cleanup explicitly (cleaner log ordering)
    trap - EXIT
    _restore_session_env
    pkill -TERM kwin_wayland 2>/dev/null || true
    sleep 2
    pkill -KILL kwin_wayland 2>/dev/null || true
    echo "[launchTestFromPlasma] complete" >> "$LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kill_tree: recursively SIG a process and all of its descendants.
# pkill -P reaps only DIRECT children; docked_flow spawns grandchildren (subshells,
# spawn_instance, monitors) that otherwise orphan to init.  $1 = pid, $2 = signal.
# ─────────────────────────────────────────────────────────────────────────────
_kill_tree() {
    local pid="$1" sig="${2:-TERM}" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _kill_tree "$child" "$sig"
    done
    kill "-${sig}" "$pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# _run_phase_b_session: Shared Phase B lifecycle-test runner.
# Assumes the display environment (DISPLAY / XAUTHORITY / WAYLAND_DISPLAY) is
# already set by the caller and that the orchestrator modules (docked_flow, …)
# are sourced.  Starts the orchestrator restart-loop in-process (so docked_flow
# stays in scope), runs the lifecycle harness against the FIFO, then tears down
# the whole orchestrator process tree.  Publishes the loop PID in the global
# _PHASE_B_ORCH_PID so an outer EXIT trap can also reap it.
# ─────────────────────────────────────────────────────────────────────────────
_run_phase_b_session() {
    if ! declare -f docked_flow >/dev/null 2>&1; then
        echo "[run_phase_b] docked_flow not available — modules not loaded?" >> "$LOG"
        return 1
    fi

    local fifo="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
    export SPLITSCREEN_FIFO="$fifo"
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    export SPLITSCREEN_STATE="$state"
    echo '{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null}}}' > "$state"

    _orch_loop() { while true; do docked_flow || true; sleep 0.5; done; }
    _orch_loop &
    _PHASE_B_ORCH_PID=$!
    echo "[run_phase_b] orchestrator loop PID=$_PHASE_B_ORCH_PID (DISPLAY=$DISPLAY)" >> "$LOG"
    sleep 2

    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    local test_script="$SCRIPT_DIR/tests/test_phase_b_lifecycle.sh"
    if [[ -f "$test_script" ]]; then
        timeout 7200 bash "$test_script" "${TEST_NUMBER:-all}" || true
    else
        echo "[run_phase_b] test script not found at $test_script" >> "$LOG"
    fi

    _kill_tree "$_PHASE_B_ORCH_PID" TERM
    sleep 1
    _kill_tree "$_PHASE_B_ORCH_PID" KILL
    rm -f "$fifo" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# launchNested: Run the Phase B session inside a BARE nested KWin compositor.
# kwin_wayland nests as a Wayland client of the current session compositor
# (gamescope in Game Mode, host KWin in Desktop Mode) and owns the full screen
# with NO Plasma shell/panel — so instances tile across the entire display and
# nothing draws behind a menu bar.  Controller isolation is unaffected: only the
# DISPLAY target changes; bwrap --dev-bind device isolation is untouched.
# ─────────────────────────────────────────────────────────────────────────────
launchNested() {
    echo "[launchNested] start" >> "$LOG"
    if [[ -n "${2:-}" ]]; then
        export TEST_NUMBER="$2"
    fi

    # Parent compositor socket (kwin nests into it).  Auto-detect if unset.
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" cand
        for cand in gamescope-0 wayland-0 wayland-1; do
            [[ -S "$rt/$cand" ]] && { export WAYLAND_DISPLAY="$cand"; break; }
        done
    fi
    echo "[launchNested] parent WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<none>}" >> "$LOG"

    # Nested resolution = parent output size.  env override → wlr-randr → xdpyinfo → fallback.
    local W H res=""
    if [[ -n "${SPLITSCREEN_SCREEN_W:-}" && -n "${SPLITSCREEN_SCREEN_H:-}" ]]; then
        W="$SPLITSCREEN_SCREEN_W"; H="$SPLITSCREEN_SCREEN_H"
    else
        res=$(wlr-randr 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | head -1)
        [[ -z "$res" ]] && res=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
        [[ -z "$res" ]] && res="1280x800"
        W="${res%x*}"; H="${res#*x}"
    fi
    echo "[launchNested] nested resolution ${W}x${H}" >> "$LOG"

    # Snapshot existing X sockets so the nested session can identify which XWayland
    # display kwin creates — it auto-picks the lowest free number and ignores
    # --xwayland-display (confirmed on-Deck: requesting :2 yields :1 when free).
    # Passed to the session child via env as a comma-wrapped list.
    local x_before
    x_before=",$(ls /tmp/.X11-unix/ 2>/dev/null | tr '\n' ',')"

    # Re-invoke THIS script as kwin's session leader.  kwin_wayland becomes the
    # FOREGROUND process so Steam/gamescope tracks and focuses it — a backgrounded
    # nested compositor never gets focus in Game Mode (confirmed on-Deck: gamescope
    # only displays apps launched through Steam).  kwin launches the session command
    # with WAYLAND_DISPLAY + DISPLAY pointing at the nested compositor; _nestedSession
    # runs the orchestrator + tests there and then exits, which makes kwin — and thus
    # the Steam "game" — exit too.
    local self; self="$(readlink -f "$0")"
    echo "[launchNested] exec nested kwin ${W}x${H} → _nestedSession (test=${TEST_NUMBER:-all})" >> "$LOG"
    exec kwin_wayland \
        --width "$W" --height "$H" \
        --no-lockscreen --no-global-shortcuts \
        --xwayland \
        -- env \
            SPLITSCREEN_DEBUG_LOG="$LOG" \
            SPLITSCREEN_FIFO="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}" \
            SPLITSCREEN_STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}" \
            SPLITSCREEN_TEST_OBSERVE_DELAY_S="${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-30}" \
            TEST_NUMBER="${TEST_NUMBER:-all}" \
            _NESTED_X_BEFORE="$x_before" \
            bash "$self" _nestedSession
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point — Phase B: event-loop orchestrator
# ─────────────────────────────────────────────────────────────────────────────
# dispatch_mode is set by the test/testPlasma wrappers to override the
# default behavior when running automated tests inside nested KDE.
case "${1:-}" in
    test)
        # Phase B lifecycle test: first call from outside nested session.
        # Optional second arg is a test number for the harness.
        # Steam launch option: "test" (run all) or "test 6" (run specific)
        echo "[main] Phase B test mode — starting (outer)" >> "$LOG"
        if [[ -n "${2:-}" ]]; then
            export TEST_NUMBER="$2"
            echo "[main] Test number: $TEST_NUMBER" >> "$LOG"
        fi
        testPlasma
        ;;
    testFromPlasma|testPlasma)
        # Called from KDE autostart inside the nested test session
        echo "[main] Phase B test mode — inside KDE session" >> "$LOG"
        if declare -f launchTestFromPlasma >/dev/null 2>&1; then
            launchTestFromPlasma
        elif declare -f main >/dev/null 2>&1; then
            echo "[main] No launchTestFromPlasma — starting orchestrator main()" >> "$LOG"
            main
        else
            echo "[main] Falling back to legacy batch runStaticTest" >> "$LOG"
            launchWindowTest
        fi
        ;;
    testDirect)
        # Run Phase B tests directly against an EXISTING display session (the bare
        # host :0).  Does NOT start a nested compositor — windows render on the host
        # desktop (subject to its panel/WM).  Kept for SSH/headless debugging; for a
        # clean full-screen run use "testNested".
        # Usage: DISPLAY=:0 XAUTHORITY=… bash minecraftSplitscreen.sh testDirect [N]
        echo "[main] testDirect — using existing display ${DISPLAY:-<unset>}" >> "$LOG"
        if [[ -n "${2:-}" ]]; then
            export TEST_NUMBER="$2"
        fi
        _td_cleanup() {
            [[ -n "${_PHASE_B_ORCH_PID:-}" ]] && { _kill_tree "$_PHASE_B_ORCH_PID" TERM; sleep 1; _kill_tree "$_PHASE_B_ORCH_PID" KILL; }
            rm -f "${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}" 2>/dev/null || true
        }
        trap '_td_cleanup' EXIT
        _run_phase_b_session
        trap - EXIT
        ;;
    testNested)
        # Run Phase B tests inside a BARE nested KWin compositor (full screen, no
        # panel).  Works from Game Mode (nests into gamescope) or Desktop Mode
        # (nests into host KWin).  This is the intended path — instances tile across
        # the whole display with no menu bar, and we fully control window placement.
        # Usage: bash minecraftSplitscreen.sh testNested [N]
        echo "[main] testNested — bare nested KWin compositor" >> "$LOG"
        launchNested "$@"
        ;;
    _nestedSession)
        # INTERNAL: runs INSIDE the bare nested kwin (launched by launchNested's
        # `exec kwin_wayland … -- … bash "$0" _nestedSession`).  kwin sets
        # WAYLAND_DISPLAY + DISPLAY for this session; resolve/confirm the nested X
        # display, run the Phase B session against it, then terminate kwin so the
        # Steam "game" exits cleanly.
        echo "[_nestedSession] start (DISPLAY=${DISPLAY:-<unset>})" >> "$LOG"
        _ns_display="${DISPLAY:-}"
        _ns_ready=0
        for _i in $(seq 1 60); do
            if [[ -n "$_ns_display" ]] && DISPLAY="$_ns_display" xdpyinfo >/dev/null 2>&1; then
                _ns_ready=1; break
            fi
            # Fallback: kwin didn't export DISPLAY — find the new X socket vs the
            # snapshot launchNested passed in _NESTED_X_BEFORE.
            _newx=""
            for _x in /tmp/.X11-unix/X*; do
                [[ -e "$_x" ]] || continue
                _b="$(basename "$_x")"
                case "${_NESTED_X_BEFORE:-,}" in
                    *",$_b,"*) ;;
                    *) _newx="$_b" ;;
                esac
            done
            if [[ -n "$_newx" ]]; then
                _ns_display=":${_newx#X}"
                DISPLAY="$_ns_display" xdpyinfo >/dev/null 2>&1 && { _ns_ready=1; break; }
            fi
            sleep 0.5
        done
        if [[ "$_ns_ready" -ne 1 ]]; then
            echo "[_nestedSession] ERROR: nested X display never became ready" >> "$LOG"
            exit 1
        fi
        # nested XWayland accepts local same-user connections without auth; drop any
        # inherited (stale) cookie so it can't cause a spurious rejection.
        unset XAUTHORITY
        export DISPLAY="$_ns_display" GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb
        echo "[_nestedSession] nested display ready: $DISPLAY" >> "$LOG"
        _run_phase_b_session
        echo "[_nestedSession] session complete — terminating nested kwin (PPID=$PPID)" >> "$LOG"
        kill -TERM "$PPID" 2>/dev/null || true
        ;;
    *)
        # Normal mode
        if declare -f main >/dev/null 2>&1; then
            echo "[main] Phase B orchestrator available — starting main()" >> "$LOG"
            main
        else
            echo "[main] Phase B orchestrator not loaded — falling back to legacy dispatch" >> "$LOG"
            if [[ "${XDG_SESSION_DESKTOP:-}" == "KDE" || "${XDG_CURRENT_DESKTOP:-}" == "KDE" ]]; then
                echo "[main] KDE session detected — launchWindowTest" >> "$LOG"
                launchWindowTest
            else
                echo "[main] gamescope session detected — nestedPlasma" >> "$LOG"
                nestedPlasma
            fi
        fi
        ;;
esac
