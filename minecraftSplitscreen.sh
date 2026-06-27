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
# This script IS the production launcher: the installer deploys it as-is
# (setup_splitscreen_launcher_script) and it auto-detects launcher config at runtime.
# runStaticTest() is a prototype-only static path; the orchestrator/test paths are
# the real ones. (The old launcher_script_generator.sh template was retired — the
# launcher is deployed + version-stamped, not generated.)

# ── Build provenance ─────────────────────────────────────────────────────────
# Stamped by the installer at deploy time (setup_splitscreen_launcher_script does
# a sed substitution on the placeholders below).  Run un-stamped (e.g. straight
# from the repo during testing) the placeholders remain and we fall back to
# dev/unknown.  `--version`/`-v` prints and exits before any logging/side effects.
MCSS_VERSION="__MCSS_VERSION__"
MCSS_COMMIT="__MCSS_COMMIT__"
MCSS_BUILD_DATE="__MCSS_BUILD_DATE__"
[[ "$MCSS_VERSION"    == __MCSS_* ]] && MCSS_VERSION="dev"
[[ "$MCSS_COMMIT"     == __MCSS_* ]] && MCSS_COMMIT="unknown"
[[ "$MCSS_BUILD_DATE" == __MCSS_* ]] && MCSS_BUILD_DATE="unknown"
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "minecraftSplitscreen ${MCSS_VERSION} (commit ${MCSS_COMMIT}, built ${MCSS_BUILD_DATE})"
    exit 0
fi

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
for _mod in preflight.sh dock_detection.sh controller_monitor.sh kwin_positioner.sh window_manager.sh instance_lifecycle.sh watchdog.sh orchestrator.sh dex.sh; do
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
# PROTOTYPE ONLY — a static launch path kept for reference; not the production flow.
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

    # ── KWin placement rules.
    # Per-slot title-matched position/size rules (fallback positioning) PLUS a forced
    # CENTERED map-time rule.
    #
    # DRAFT 2026-06-27 — research-based, NOT yet tested on a Deck. The centered rule is the
    # structural fix for the "black half" bug: a newly-mapped Minecraft window otherwise
    # appears at 0,0 and FULLY covers an already-tiled window; KWin withholds Wayland frame
    # callbacks from a 100%-occluded surface, so the covered tile goes black and doesn't
    # repaint when uncovered. A centered default-size window overlaps only the middle and
    # never fully covers any tile, so nothing gets culled. Enum values from KWin master src:
    # placement=5 = Centered (KWin6; was 6 on Plasma5 when Cascade=5 existed — do NOT use 6),
    # placementrule=2 = Force, wmclassmatch=2 = Substring.
    # BEFORE TRUSTING THIS: verify the real class on the Deck — `xprop WM_CLASS` on a live
    # splitscreen window. LWJGL3/GLFW usually reports "Minecraft" (substring "minecraft"
    # matches), but a PolyMC/Prism Java window can report "java"/"net-minecraft-…"; if so set
    # wmclass=java (or wmclassmatch=3 regex). Revert this block if positioning regresses.
    {
        echo "[General]"; echo "count=$(( n_slots + 1 ))"
        for _s in $(seq 1 "$n_slots"); do
            read _x _y _w _h < <(compute_geometry "$_s" "$n_slots" "$W" "$H")
            printf '\n[%s]\nDescription=SplitscreenP%s\ntitle=SplitscreenP%s\ntitlematch=1\nposition=%s,%s\npositionrule=3\nsize=%s,%s\nsizerule=3\n' \
                "$_s" "$_s" "$_s" "$_x" "$_y" "$_w" "$_h"
        done
        # [N+1] forced centered placement at map time (DRAFT — see note above).
        printf '\n[%s]\nDescription=Center Minecraft windows on map (splitscreen)\nwmclass=minecraft\nwmclassmatch=2\nwmclasscomplete=false\nplacement=5\nplacementrule=2\n' \
            "$(( n_slots + 1 ))"
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
    # Propagate the chosen test number + observation delay into the nested session
    # (the autostart re-invocation is a fresh process — env does not carry over).
    cat > ~/.config/autostart/splitscreen-test.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen Test
Exec=env SPLITSCREEN_DEBUG_LOG=${LOG} TEST_NUMBER=${TEST_NUMBER:-all} SPLITSCREEN_TEST_OBSERVE_DELAY_S=${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15} ${SCRIPT_PATH} testFromPlasma
Type=Application
X-KDE-AutostartScript=true
DEOF
    _snapshot_session_env
    echo "[testPlasma] autostart written, exec-ing startplasma-wayland" >> "$LOG"
    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
# launchFromPlasma — PRODUCTION outer entry (this is the LaunchOptions the Steam
# shortcut runs). Starts the nested KDE/Plasma session exactly like testPlasma, but
# the autostart runs the PRODUCTION inner handler (prodFromPlasma → the real
# orchestrator) instead of the test harness. A1 (2026-06-23): without this case the
# Steam shortcut fell through to a bare main() with NO nested compositor / no tiling,
# so a real user got no splitscreen — the working windowing lived only in `test`.
# NOTE: kept parallel to testPlasma (not refactored into a shared helper) to avoid
# regressing the validated test path; DRY in a later cleanup.
# ─────────────────────────────────────────────────────────────────────────────
launchFromPlasma() {
    echo "[launchFromPlasma] start (production)" >> "$LOG"
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    echo "[launchFromPlasma] W=$W H=$H" >> "$LOG"

    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH

    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/splitscreen-prod.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen
Exec=env SPLITSCREEN_DEBUG_LOG=${LOG} ${SCRIPT_PATH} prodFromPlasma
Type=Application
X-KDE-AutostartScript=true
DEOF
    _snapshot_session_env
    echo "[launchFromPlasma] autostart written (→ prodFromPlasma), exec startplasma-wayland" >> "$LOG"
    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
# launchProdFromPlasma — PRODUCTION inner handler (runs inside the nested Plasma
# session, from launchFromPlasma's autostart). Same nested-session scaffolding as
# launchTestFromPlasma (strip the panel for full real estate, clean full-session
# teardown on exit) but runs the REAL orchestrator main() — the FIFO event loop +
# controller monitor + spawn slot 1 + reflow — instead of the test harness.
# ─────────────────────────────────────────────────────────────────────────────
launchProdFromPlasma() {
    echo "[launchProdFromPlasma] start" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-prod.desktop ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    # Strip the Plasma panel (black backdrop, full tiling area); respawn-killer loop.
    pkill -x plasmashell 2>/dev/null || true
    ( while :; do pkill -x plasmashell 2>/dev/null; sleep 2; done ) &
    _PANEL_KILLER_PID=$!

    # On exit: restore leaked session env, stop the panel killer, reap the WHOLE nested
    # session (so Steam/gamescope return to the library — see _end_nested_session).
    trap '_restore_session_env; kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null; _end_nested_session' EXIT

    if ! declare -f main >/dev/null 2>&1; then
        echo "[launchProdFromPlasma] ERROR: orchestrator main() not available — modules not sourced?" >> "$LOG"
        return 1
    fi

    # Initialise the FIFO + state file. main() ensures the FIFO but NOT the state file;
    # the test path does this in _run_phase_b_session. Without SPLITSCREEN_STATE the
    # watchdog/spawn fail ("SPLITSCREEN_STATE is not set") so nothing launches → gamescope
    # shows only the spinner. (2026-06-23)
    local fifo="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
    export SPLITSCREEN_FIFO="$fifo"
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    export SPLITSCREEN_STATE="$state"
    echo '{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null}}}' > "$state"

    # Run the real orchestrator. It blocks until the session ends (P1/Deck instance
    # exits). Output to the log directly (NO pipe — a pipe's write-end would be inherited
    # by bwrap descendants and stall the orchestrator's FIFO reads).
    main >> "$LOG" 2>&1 || true

    # Final teardown.
    if declare -f teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>/dev/null || true
    fi
    kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null || true
    trap - EXIT
    _restore_session_env
    qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null \
        || qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null || true
    sleep 1
    _end_nested_session
    echo "[launchProdFromPlasma] complete" >> "$LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# _end_nested_session: tear down the WHOLE nested Plasma session so Steam's reaper
# releases and gamescope returns to the library. Two gotchas (both confirmed 2026-06-23):
#   1. kwin_wayland_wrapper RESPAWNS kwin_wayland — kill the wrapper first or kwin comes back.
#   2. Plasma session services (baloo_file, kded, kglobalacceld, kactivitymanagerd, …)
#      survive a compositor-only teardown, get adopted by Steam's subreaper, and keep the
#      "game" alive forever (Abort-Game overlay) — the reaper waits on the whole descendant
#      tree. So reap them too. TERM pass, then KILL pass.
_end_nested_session() {
    local sig svc
    for sig in TERM KILL; do
        pkill -"$sig" -f kwin_wayland_wrapper 2>/dev/null || true
        pkill -"$sig" -x kwin_wayland 2>/dev/null || true
        for svc in startplasma-wayland plasma_session baloo_file kded6 \
                   kglobalacceld kactivitymanagerd kscreen_backend_launcher \
                   xdg-desktop-portal-kde; do
            pkill -"$sig" -f "$svc" 2>/dev/null || true
        done
        [ "$sig" = TERM ] && sleep 1
    done
}

# (Decoration is handled by kwin_set_noborder <pid> in spawn_instance — set ONCE when the
# window appears. The earlier at-map "No titlebar and frame" window rule was removed
# 2026-06-23: it missed because Minecraft sets its caption/WM_CLASS only AFTER mapping, so
# the rule had nothing to match at evaluation time, and it clobbered ~/.config/kwinrulesrc.)

# launchTestFromPlasma
# Called from KDE autostart inside the nested test session.
# Starts docked_flow in background, runs the Phase B lifecycle test
# script against the FIFO, then tears down.
# ─────────────────────────────────────────────────────────────────────────────
launchTestFromPlasma() {
    echo "[launchTestFromPlasma] start" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    # Strip the Plasma panel for full-screen real estate.  plasma-session can
    # respawn plasmashell, so keep a background killer running for the whole
    # session (reaped on exit).  Killing plasmashell also clears the desktop
    # wallpaper → black backdrop behind the splitscreen tiles, which is what we
    # want (this is the "nested Plasma, no panel" path; bare nested KWin is a
    # future option — see TODO "Research — bare nested KWin on SteamOS 3.8").
    pkill -x plasmashell 2>/dev/null || true
    ( while :; do pkill -x plasmashell 2>/dev/null; sleep 2; done ) &
    _PANEL_KILLER_PID=$!


    # Tear down the nested KWin session, stop the panel killer, and restore the
    # leaked session env on exit — prevents a permanent black screen / sddm restart
    # loop if the test hangs, crashes, or is interrupted.
    trap '_restore_session_env; kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null; _end_nested_session' EXIT

    if ! declare -f docked_flow >/dev/null 2>&1; then
        echo "[launchTestFromPlasma] ERROR: docked_flow not available" >> "$LOG"
        return 1
    fi

    # Run the Phase B session via the shared runner (FIFO-safe orchestrator restart
    # loop, full process-tree teardown, observation delay).  Default a viewing delay
    # for this interactive Game-Mode path.  _run_phase_b_session initialises the
    # FIFO + state file itself.
    export SPLITSCREEN_TEST_OBSERVE_DELAY_S="${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15}"
    if [[ "${TEST_NUMBER:-}" == "8" ]]; then
        echo "[launchTestFromPlasma] TEST 8 — single-instance position sweep" >> "$LOG"
        _run_position_sweep_session
    else
        _run_phase_b_session
    fi

    # Final instance cleanup, then tear down KWin explicitly (cleaner log ordering).
    if declare -f teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>/dev/null || true
    fi
    kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null || true
    trap - EXIT
    _restore_session_env

    # Graceful Plasma logout first (lets session services stop cleanly), then FORCE-reap
    # the WHOLE nested session — compositor, wrapper, AND the Plasma helpers (baloo_file,
    # kded, …) that otherwise survive, get adopted by Steam's subreaper, and keep the
    # "game" alive (gamescope Abort-Game overlay). 2026-06-23: baloo_file adopted by the
    # reaper was confirmed to be why the game wouldn't exit on its own.
    qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null \
        || qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null || true
    sleep 1
    _end_nested_session
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
# _run_position_sweep_session  (TEST 8 — single-instance position sweep)
# Spawn ONE instance (slot 1) and move it through every layout position in turn —
# full, top half, bottom half, and all four quad cells — pausing at each so the
# user can SEE whether the window actually moves on screen. Logs the geometry
# immediately after each move AND again after the observation delay, so a revert
# (e.g. the Splitscreen mod re-asserting its own position every frame) shows up in
# the log even between captures.
#
# Purpose: isolate window POSITIONING from all the multi-instance confounders
# (reflows, slot-1-vs-others, focus/restack). If a single window won't move or
# won't STAY, the next step is to retry with the Splitscreen mod removed — it is
# the one constant across every failed attempt and may be pinning each window to
# its splitscreen.properties region.
# ─────────────────────────────────────────────────────────────────────────────
_run_position_sweep_session() {
    local fifo="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
    export SPLITSCREEN_FIFO="$fifo"
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    export SPLITSCREEN_STATE="$state"
    echo '{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null}}}' > "$state"

    local W H
    W=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}' | cut -dx -f1); [[ "$W" =~ ^[0-9]+$ ]] || W=1280
    H=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}' | cut -dx -f2); [[ "$H" =~ ^[0-9]+$ ]] || H=720
    local hw=$((W/2)) hh=$((H/2))
    local delay="${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-12}"
    echo "[sweep] single-instance position sweep on ${W}x${H}, observe ${delay}s/step" >> "$LOG"

    # Give the mod its single-instance config, then spawn slot 1 only.
    if declare -f _write_splitscreen_properties >/dev/null 2>&1; then
        _write_splitscreen_properties 1 "1" 2>/dev/null || true
    fi
    echo "[sweep] spawning slot 1 (single instance)…" >> "$LOG"
    spawn_instance 1 "" "" >> "$LOG" 2>&1 || true

    local wid="" i
    for i in $(seq 1 60); do
        wid=$(_get_wid_from_state 1 2>/dev/null || true)
        [[ -n "$wid" ]] && break
        sleep 1
    done
    if [[ -z "$wid" ]]; then
        echo "[sweep] ERROR: slot 1 window never appeared — aborting sweep" >> "$LOG"
        declare -f teardown_all_instances >/dev/null 2>&1 && teardown_all_instances 2>/dev/null || true
        return 1
    fi
    echo "[sweep] slot 1 wid=$wid — beginning sweep" >> "$LOG"

    _sweep_geo() { xwininfo -id "$1" 2>/dev/null | awk '/Absolute upper-left X/{x=$NF}/Absolute upper-left Y/{y=$NF}/Width:/{w=$NF}/Height:/{h=$NF}/Map State/{m=$NF}END{if(w=="")print "<none>";else printf "%sx%s+%s+%s %s",w,h,x,y,m}'; }

    local positions=(
        "FULL 0 0 $W $H"
        "TOP_HALF 0 0 $W $hh"
        "BOTTOM_HALF 0 $hh $W $hh"
        "QUAD_TL 0 0 $hw $hh"
        "QUAD_TR $hw 0 $hw $hh"
        "QUAD_BL 0 $hh $hw $hh"
        "QUAD_BR $hw $hh $hw $hh"
    )
    local p name x y w h
    for p in "${positions[@]}"; do
        read -r name x y w h <<< "$p"
        echo "[sweep] ===== $name → target ${w}x${h}+${x}+${y} =====" >> "$LOG"
        _position_slot 1 "$x" "$y" "$w" "$h" >> "$LOG" 2>&1 || true
        sleep 2
        echo "[sweep]   immediately: $(_sweep_geo "$wid")" >> "$LOG"
        sleep "$delay"
        echo "[sweep]   after ${delay}s:  $(_sweep_geo "$wid")" >> "$LOG"
    done

    echo "[sweep] sweep complete — tearing down" >> "$LOG"
    declare -f teardown_all_instances >/dev/null 2>&1 && teardown_all_instances 2>/dev/null || true
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

    # Nested resolution.  CRITICAL: do NOT probe the compositor here (wlr-randr /
    # xdpyinfo).  When launched as a Steam game, gamescope watches the game's
    # Wayland clients — a throwaway probe that connects and immediately disconnects
    # makes gamescope think the game exited and it kills us before we ever exec
    # kwin (observed: trace died right after a wlr-randr connect/disconnect).  KWin
    # must be the FIRST and ONLY client.  Use an env override, else default to the
    # Deck's handheld panel size; gamescope scales the nested surface to its output.
    local W H
    W="${SPLITSCREEN_SCREEN_W:-1280}"
    H="${SPLITSCREEN_SCREEN_H:-800}"
    echo "[launchNested] nested resolution ${W}x${H} (override SPLITSCREEN_SCREEN_W/H to change)" >> "$LOG"

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
            SPLITSCREEN_TEST_OBSERVE_DELAY_S="${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15}" \
            TEST_NUMBER="${TEST_NUMBER:-all}" \
            _NESTED_X_BEFORE="$x_before" \
            bash "$self" _nestedSession
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point — Phase B: event-loop orchestrator
# ─────────────────────────────────────────────────────────────────────────────
# dispatch_mode is set by the test/testPlasma wrappers to override the
# default behavior when running automated tests inside nested KDE.

# Fail-fast HARD STOP if the KDE/Plasma/KWin stack (or other critical deps) is missing —
# a clear, distro-aware message beats a cryptic mid-launch crash (preflight, item G).
# Skip only the version flag (needs no deps).
if declare -f _preflight_deps >/dev/null 2>&1; then
    case "${1:-}" in
        --version|-v) : ;;
        *) _preflight_deps launch || exit 1 ;;
    esac
fi

case "${1:-}" in
    launchFromPlasma)
        # PRODUCTION entry — this is the LaunchOptions the Steam shortcut runs
        # (set by add-to-steam.py). Start the nested Plasma session; its autostart
        # re-invokes this script as `prodFromPlasma` INSIDE the session. (A1: previously
        # this fell through to `*) → main()` with no nested compositor = no splitscreen.)
        echo "[main] Production launch — launchFromPlasma (starting nested Plasma)" >> "$LOG"
        launchFromPlasma
        ;;
    prodFromPlasma)
        # PRODUCTION inner handler — runs INSIDE the nested Plasma session (from the
        # launchFromPlasma autostart). Strips the panel + runs the real orchestrator.
        echo "[main] Production launch — prodFromPlasma (inside nested Plasma)" >> "$LOG"
        if declare -f launchProdFromPlasma >/dev/null 2>&1; then
            launchProdFromPlasma
        else
            echo "[main] ERROR: launchProdFromPlasma not available — modules not sourced?" >> "$LOG"
        fi
        ;;
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

        # Give the nested compositor an IMMEDIATE full-screen background window.
        # gamescope shows a loading spinner for a nested compositor that presents no
        # window (the old nested-Plasma path always had plasmashell's surfaces, so
        # gamescope always had content).  A persistent black full-screen window makes
        # KWin present a surface right away → gamescope displays it — and it doubles
        # as the black backdrop behind the splitscreen tiles.  Sized from the nested
        # root window (querying our OWN XWayland is safe; the earlier problem was
        # probing the gamescope parent before kwin existed).
        _ns_geo=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2; exit}')
        [[ -z "$_ns_geo" ]] && _ns_geo="1280x800"
        _ns_bw="${_ns_geo%x*}"; _ns_bh="${_ns_geo#*x}"
        echo "[_nestedSession] spawning ${_ns_bw}x${_ns_bh} background window" >> "$LOG"
        python3 -c "
import tkinter as tk
r=tk.Tk(); r.overrideredirect(True); r.geometry('${_ns_bw}x${_ns_bh}+0+0'); r.configure(bg='black')
r.lower(); r.mainloop()
" >> "$LOG" 2>&1 &
        _NS_BG_PID=$!
        sleep 1

        _run_phase_b_session
        kill "$_NS_BG_PID" 2>/dev/null || true
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
