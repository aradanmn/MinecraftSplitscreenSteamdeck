#!/bin/bash
set -euo pipefail

# =============================================================================
# INSTANCE LIFECYCLE MODULE
# =============================================================================
# Spawns and terminates individual Minecraft instances inside bwrap sandboxes.
# Manages the shared JSON state file (atomic writes via jq + tmp + mv).
# Coordinates with the window manager for layout application.
#
# Dependencies (sourced at the top of the orchestrator):
#   dock_detection.sh, controller_monitor.sh, window_manager.sh
#
# Public API:
#   spawn_instance(slot, event_node, js_node)
#   teardown_instance(slot)
#   teardown_all_instances()
#   slot_is_active(slot)          — exit 0 if active, 1 otherwise
#
# State file:
#   read_state()                  — stdout: JSON or "null"
#   update_slot_state(slot, jq_expr)
#   get_active_slots()            — stdout: "1 3" (space-separated, ascending)
#   get_bwrap_pid(slot)           — stdout: PID or empty
#   get_java_pid(slot)            — stdout: PID or empty
#   get_window_id(slot)           — stdout: X11 WID or empty
#
# Environment overrides (for testing):
#   BWRAP_CMD                     — override bwrap path
#   LAUNCHER_EXEC                 — override PolyMC executable path
#   SPLITSCREEN_STATE             — override state file path
#   INSTANCE_LIFECYCLE_LAUNCHER_DIR — override ~/.local/share/PolyMC base
# =============================================================================

# --- Module-level constants ---
readonly INSTANCE_LIFECYCLE_MAX_PLAYERS=4
readonly INSTANCE_LIFECYCLE_POLL_INTERVAL_S=0.5
readonly INSTANCE_LIFECYCLE_POLL_TIMEOUT_S=60
readonly INSTANCE_LIFECYCLE_WINDOW_WAIT_TIMEOUT_S=30
readonly INSTANCE_LIFECYCLE_TEARDOWN_GRACE_S=10
# Title-keeper: after the window is found, Minecraft's own startup overwrites the
# caption (SplitscreenP<slot> → "Minecraft* <ver>" — the flash). Re-assert our name
# a few times over this window to win the race so the label sticks on screen.
readonly INSTANCE_LIFECYCLE_TITLE_REASSERT_COUNT=15
readonly INSTANCE_LIFECYCLE_TITLE_REASSERT_INTERVAL_S=1
# Map-keeper (Fix #57, UNTESTED 2026-07-05): in handheld/full-screen the game's own
# LATE window setup (GL context / fullscreen switch, well after apply_layout positioned
# the window) can leave the override_redirect'd window UNMAPPED → black screen with audio
# (the first on-Deck handheld symptom). Poll the window over its startup and re-map it if
# the game unmapped it. Longer than the title flash because the unmap can land after MC
# finishes loading assets: ~90s of coverage (45 × 2s) then self-exit.
readonly INSTANCE_LIFECYCLE_MAP_KEEP_COUNT=45
readonly INSTANCE_LIFECYCLE_MAP_KEEP_INTERVAL_S=2
# Window poll can take longer than the java poll (MC takes 60-90s to open its window).
readonly INSTANCE_LIFECYCLE_WINDOW_POLL_TIMEOUT_S=120
# H11: derive loop iteration counts from timeout / interval instead of hardcoding 120/240
# (which silently duplicated the constants). awk handles the fractional 0.5s interval.
INSTANCE_LIFECYCLE_JAVA_POLL_ITERS=$(awk "BEGIN{print int(${INSTANCE_LIFECYCLE_POLL_TIMEOUT_S}/${INSTANCE_LIFECYCLE_POLL_INTERVAL_S})}")
INSTANCE_LIFECYCLE_WINDOW_POLL_ITERS=$(awk "BEGIN{print int(${INSTANCE_LIFECYCLE_WINDOW_POLL_TIMEOUT_S}/${INSTANCE_LIFECYCLE_POLL_INTERVAL_S})}")
readonly INSTANCE_LIFECYCLE_JAVA_POLL_ITERS INSTANCE_LIFECYCLE_WINDOW_POLL_ITERS
readonly INSTANCE_LIFECYCLE_DEFAULT_LAUNCHER_DIR="$HOME/.local/share/PolyMC"
readonly INSTANCE_LIFECYCLE_DEFAULT_STATE_FILE="$HOME/.local/share/PolyMC/splitscreen_state.json"

# --- Internal functions ---

# _get_launcher_dir: Return the PolyMC base directory.
_get_launcher_dir() {
    echo "${INSTANCE_LIFECYCLE_LAUNCHER_DIR:-$INSTANCE_LIFECYCLE_DEFAULT_LAUNCHER_DIR}"
}

# _get_state_file: Return the state file path.
_get_state_file() {
    echo "${SPLITSCREEN_STATE:-$INSTANCE_LIFECYCLE_DEFAULT_STATE_FILE}"
}

# _get_bwrap_cmd: Return the bwrap command path.
_get_bwrap_cmd() {
    echo "${BWRAP_CMD:-bwrap}"
}

# _get_launcher_exec: Return the PolyMC executable path.
_get_launcher_exec() {
    echo "${LAUNCHER_EXEC:-$(_get_launcher_dir)/PolyMC.AppImage}"
}

# _ensure_state_file: Reset the state file to default (all slots inactive).
# Called on every startup to guarantee a known clean state.
_ensure_state_file() {
    local state_file
    state_file=$(_get_state_file)

    local dir
    dir=$(dirname "$state_file")
    mkdir -p "$dir"

    # Always reset — stale state from a previous crashed session poisons the next.
    # wid field holds the X11 window ID (hex integer) so apply_layout can locate
    # the Minecraft window without relying on xdotool name-search (which fails in
    # gamescope's XWayland where xdotool set_window --name doesn't persist).
    jq -n '{
        mode: "handheld",
        slots: {
            "1": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null},
            "2": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null},
            "3": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null},
            "4": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null}
        }
    }' > "$state_file"
    echo "[instance_lifecycle] Reset state file: $state_file" >&2
}

# _atomic_write: Write JSON content atomically to a file.
# $1 = file path, $2 = JSON content
_atomic_write() {
    local target="$1"
    local content="$2"
    # H3 (UNTESTED 2026-06-27): unique temp per writer. `$$` is the PARENT shell pid — it is
    # IDENTICAL across backgrounded `{ } &` subshells (only $BASHPID differs), so two
    # concurrent spawns would write the SAME ".tmp.$$" and clobber each other before mv,
    # corrupting the state file. mktemp gives each writer its own temp.
    local tmp
    tmp=$(mktemp "${target}.tmp.XXXXXX") || {
        echo "[instance_lifecycle] ERROR: mktemp failed for $target" >&2
        return 1
    }
    printf '%s\n' "$content" > "$tmp" && mv -f "$tmp" "$target" || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
}

# (_write_splitscreen_properties removed 2026-06-23 — the Splitscreen Support mod that
# consumed .minecraft/config/splitscreen.properties is no longer installed; KWin does the
# window tiling. See [[windowing-solution-confirmed]].)

# _vendor_of_js_node: Given $1 = a /dev/input/jsN path, echo the lowercased Vendor of the
# /proc/bus/input/devices block whose `H: Handlers=` field contains that EXACT jsN token.
# Token equality (split on whitespace, compare ==), NEVER substring — so js1 does NOT match
# js10/js11; otherwise a wrong-but-parseable 28de match could flip the per-slot ALLOW.
# Echoes the 4-hex vendor (lowercased) or empty (no match / unparseable).
_vendor_of_js_node() {
    local js_path="${1:-}"
    [[ -z "$js_path" ]] && return 0
    local want
    want=$(basename "$js_path")            # e.g. "js1"
    [[ -z "$want" ]] && return 0

    local proc_path="${PROC_INPUT_DEVICES:-/proc/bus/input/devices}"
    [[ -f "$proc_path" ]] || return 0

    local in_block=0 vendor="" handlers="" line _h
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if (( in_block == 1 )); then
                for _h in $handlers; do
                    if [[ "$_h" == "$want" ]]; then
                        echo "$vendor"
                        return 0
                    fi
                done
            fi
            in_block=0; vendor=""; handlers=""
            continue
        fi
        in_block=1
        case "$line" in
            I:*) [[ "$line" =~ Vendor=([0-9a-fA-F]{4}) ]] && vendor="${BASH_REMATCH[1],,}" ;;
            H:*) handlers="${line#H: Handlers=}" ;;
        esac
    done < "$proc_path"
    # Last block (file may not end with a blank line).
    if (( in_block == 1 )); then
        for _h in $handlers; do
            if [[ "$_h" == "$want" ]]; then
                echo "$vendor"
                return 0
            fi
        done
    fi
    return 0
}

# _build_direct_command: HANDHELD launch — NO bwrap, full system access. Handheld is one
# player on the Deck's built-in controls; there is NOTHING to isolate, and the sandbox
# actively BREAKS the built-in: `--dev /dev` leaves an empty /dev/input, so the built-in's
# Steam 28de:11ff virtual has no device node to open and Controlify reports "No controllers
# found". Launching directly (like a normal Deck Minecraft run) gives full /dev/input access
# so the built-in works. $1 = slot. Output: a printf '%q'-quoted "env … launcher … -l … -a"
# command string (same shape spawn_instance expects, just without the bwrap prefix).
_build_direct_command() {
    local slot="$1"
    local launcher_exec
    launcher_exec=$(_get_launcher_exec)

    # Reach the nested session's XWayland the same way the sandbox path does.
    local _xauth=""
    if [[ -n "${XAUTHORITY:-}" && -e "${XAUTHORITY:-}" ]]; then
        _xauth="$XAUTHORITY"
    else
        _xauth=$(ps -C kwin_wayland -o args= 2>/dev/null \
            | grep -oP '(?<=--xwayland-xauthority )\S+' | head -1)
    fi

    local -a _env=(
        APPIMAGE_EXTRACT_AND_RUN=1
        QT_QPA_PLATFORM=xcb
        "PULSE_SERVER=unix:/run/user/$(id -u)/pulse/native"
        # Full controller access — the built-in reaches the game as a Steam 28de:11ff
        # virtual, so allow Steam virtual gamepads. Deliberately NO isolation hints
        # (DISABLE_UDEV / udev tmpfs / pipe mask): we WANT normal udev + Steam discovery so
        # the built-in is actually found.
        SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1
        # DRAFT 2026-06-27 (research, UNTESTED): disable the gamescope Vulkan WSI layer — the
        # GL game never uses it, and in Game Mode its abort()-on-no-dialog path is a suspected
        # crash source. DISABLE_GAMESCOPE_WSI=1 is the correct off-switch (the layer keys on
        # the var's PRESENCE; ENABLE_GAMESCOPE_WSI=0 does NOT disable it). RADV_SYS_MEM_LIMIT
        # caps RADV's claim on the 16GB unified APU RAM, leaving headroom for JVM heaps.
        # (Mainly matters for docked 4-instance; harmless for a single handheld instance.)
        DISABLE_GAMESCOPE_WSI=1
        RADV_SYS_MEM_LIMIT=50
    )
    [[ -n "$_xauth" ]] && _env+=("XAUTHORITY=$_xauth")

    local -a cmd=(
        env
        -u ENABLE_GAMESCOPE_WSI
        "${_env[@]}"
        "${launcher_exec}"
        -l "latestUpdate-${slot}"
        -a "P${slot}"
    )
    printf '%q ' "${cmd[@]}"
}

# _build_bwrap_command: Construct a bwrap command string with printf '%q' quoting.
# $1 = slot, $2 = event_node, $3 = js_node
# $4+ = pairs of (mask_event, mask_js) for other controllers to mask
# Output: a single command string (printf '%q' quoted) ready for eval.
_build_bwrap_command() {
    local slot="$1"
    local event_node="$2"
    local js_node="$3"
    shift 3
    local launcher_exec
    launcher_exec=$(_get_launcher_exec)

    local -a cmd=(
        $(_get_bwrap_cmd)
        --dev-bind / /
        --dev /dev
        --dev-bind /dev/fuse /dev/fuse
        # Each slot gets an isolated tmpfs for /tmp so PolyMC's qtsingleapp
        # socket is NOT shared between slots. Without this, slot 2's PolyMC
        # would see slot 1's socket, forward its args to slot 1, and exit —
        # leaving slot 2 with no running Minecraft process.
        --tmpfs /tmp
        --dev-bind /tmp/.X11-unix /tmp/.X11-unix
        --dev-bind /home /home
        --dev-bind /run /run
        --dev-bind /dev/dri /dev/dri
    )
    # STRICT vs POROUS sandbox, decided by whether a specific pad's jsN is bound:
    #   DOCKED / multi-player (a real pad's jsN bound) → STRICT isolation. SDL/Controlify
    #     enumerate controllers via udev (/run/udev) + the Steam IPC pipe + sysfs, NOT just
    #     /dev/input — so bind-isolating /dev/input alone LEAKS every controller (proven:
    #     bind 1 pad, /sys/class/input still listed all 9). Blank the udev DB + mask the Steam
    #     pipe; with SDL_JOYSTICK_DISABLE_UDEV=1 (env below) SDL is forced onto scandir-only,
    #     seeing ONLY the one jsN we bind. Validated live w/ 4 DS4s.
    #   HANDHELD / single player (NO jsN bound — the built-in reaches the game as a Steam
    #     28de:11ff virtual, not a bound node) → POROUS. The built-in is DISCOVERED through
    #     udev + the Steam pipe, so blanking them + DISABLE_UDEV would leave SDL with no
    #     controller (the "built-in dead in handheld" bug). One player ⇒ nothing to isolate.
    local _strict=0
    [[ -n "$js_node" ]] && _strict=1
    if (( _strict )); then
        cmd+=(--tmpfs /run/udev)
        [[ -e "$HOME/.steam/steam.pipe" ]] && cmd+=(--bind /dev/null "$HOME/.steam/steam.pipe")
    fi

    local _raw="${CONTROLLER_MONITOR_RAW_BINDING:-1}"
    local _js_bound=0

    # event_node bind: under RAW binding WITH a real js_node we bind js-ONLY and SKIP the
    # eventN. Steam Input's EVIOCGRAB lives on the evdev eventN, NOT on the separate legacy
    # jsN char device (jsN is multiply-openable and has no grab ioctl), so never placing the
    # eventN in this namespace means a grabbed/dead evdev can't be surfaced to Controlify's
    # SDL. When the flag is OFF (legacy virtual path) OR this is the handheld/controller-less
    # case (empty js_node), bind the eventN exactly as before. event_node is otherwise
    # optional — skip an empty/missing source rather than aborting the whole sandbox launch.
    if [[ "$_raw" == "1" && -n "$js_node" ]]; then
        : # raw js-only mode — intentionally do NOT --dev-bind the eventN
    elif [[ -n "$event_node" && -e "$event_node" ]]; then
        cmd+=(--dev-bind "${event_node}" "${event_node}")
    fi

    # js_node is optional — char devices fail -f; use -e which matches any file type
    if [[ -e "$js_node" ]]; then
        cmd+=(--dev-bind "${js_node}" "${js_node}")
        # Set SDL_JOYSTICK_DEVICE to the assigned joystick only
        cmd+=(--setenv "SDL_JOYSTICK_DEVICE" "${js_node}")
        _js_bound=1
    fi

    # SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD is per-slot + mode-independent (see the
    # env block below). DEFENSIVE-ONLY under js-only raw binding — no 28de node is ever in a
    # raw namespace, so correctness rests on js-only binding + SDL_JOYSTICK_DISABLE_UDEV, not
    # this hint. Rule: a real raw pad bound (vendor parsed != 28de, OR vendor empty/
    # unparseable) → 0 (don't let SDL fall back to a Steam virtual); the 28de virtual itself
    # OR no js bound (handheld slot 1) → 1.
    local _allow=1
    if (( _js_bound == 1 )); then
        local _js_vendor
        _js_vendor=$(_vendor_of_js_node "$js_node")
        if [[ "$_js_vendor" == "${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}" ]]; then
            _allow=1
        else
            _allow=0
        fi
    fi

    # Mask other controllers so this sandbox can't see another player's pad.
    # Use if-statements, not &&, to avoid set -e treating "file not found" as fatal.
    # INERT under --dev /dev + js-only binding: the fresh devtmpfs at /dev holds NO input
    #   nodes except the single jsN we bind in, so the masked targets simply do not exist
    #   and the -e guard below skips them. The REAL isolation is --dev /dev +
    #   SDL_JOYSTICK_DISABLE_UDEV (proven by the live in-sandbox `ls /dev/input` test), not
    #   this masking. KEPT for revert-safety and for the legacy (flag-OFF) path.
    # N5 (a): NEVER mask THIS slot's own node. If another (e.g. orphaned) slot still
    #   claims the same reused node, masking it would --bind /dev/null over our own
    #   --dev-bind (last bind wins) and leave us with no controller. Confirmed live
    #   2026-06-26 on the disconnect→reconnect→same-node path. Compare per node.
    # N5 (b): don't silently DROP a trailing unpaired arg — mask it too (so no node is
    #   left visible cross-slot) and warn, since an odd count means a producer-side bug.
    while [[ $# -ge 2 ]]; do
        local mask_event="$1" mask_js="$2"
        shift 2
        if [[ -e "$mask_event" && "$mask_event" != "$event_node" ]]; then cmd+=(--bind /dev/null "${mask_event}"); fi
        if [[ -e "$mask_js"    && "$mask_js"    != "$js_node"    ]]; then cmd+=(--bind /dev/null "${mask_js}"); fi
    done
    if [[ $# -ge 1 ]]; then
        echo "[instance_lifecycle] WARNING: slot ${slot} got an odd controller-mask arg count; masking trailing node '$1'" >&2
        if [[ -e "$1" && "$1" != "$event_node" && "$1" != "$js_node" ]]; then cmd+=(--bind /dev/null "$1"); fi
    fi

    # SDL env vars — explicitly override Steam's inherited environment:
    #   SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=${_allow}:
    #     Per-slot and mode-INDEPENDENT (computed above from the bound jsN's vendor).
    #     DEFENSIVE-ONLY under raw js-only binding: EVIOCGRAB is on the evdev eventN, NOT the
    #     legacy jsN, so under raw mode we bind js-ONLY and never place an eventN (nor any
    #     28de node) in this namespace — SDL therefore cannot see a Steam virtual at all and
    #     this hint is moot. It is set =1 only when the bound device IS the 28de virtual
    #     (legacy path) or when no js is bound (handheld slot 1, which depends on Steam
    #     minting the built-in's virtual); =0 when a real raw pad is bound so SDL won't
    #     prefer a phantom Steam virtual. Correctness rests on js-only binding +
    #     SDL_JOYSTICK_DISABLE_UDEV, not on this hint.
    #   SDL_GAMECONTROLLER_IGNORE_DEVICES= (empty):
    #     Left empty (do NOT add 0x28de/0x11ff): under js-only raw binding no 28de node is
    #     ever in the namespace, the 0xVVVV/0xPPPP format is unverified against Controlify's
    #     SDL, and js-only binding already removes the contention. Clearing Steam's inherited
    #     exclusion list keeps SDL free to use the one bound jsN via the classic path.
    #   SDL_JOYSTICK_HIDAPI=0:
    #     Disables HIDAPI backend (no /dev/hidraw* nodes in this sandbox).
    #     SDL3 falls back to pure evdev where our bound event/js nodes live.
    #   SDL_LINUX_JOYSTICK_CLASSIC=1:
    #     Forces classic joystick driver path, ensuring SDL_JOYSTICK_DEVICE
    #     pinning is honoured on Linux. Required for compatibility with the
    #     older Controllable mod's bundled SDL and some gamescope builds.
    # AppImage / Qt / audio env — must match the known-working launchSlot config.
    #   APPIMAGE_EXTRACT_AND_RUN=1: the AppImage cannot FUSE-mount inside the
    #     sandbox (no fusermount on PATH → "Cannot mount AppImage"); extract-and-run
    #     sidesteps FUSE entirely. THIS is what was killing every spawn_instance.
    #   QT_QPA_PLATFORM=xcb: force PolyMC's Qt GUI onto X11 — the nested KDE session
    #     exports QT_QPA_PLATFORM=wayland, which PolyMC would otherwise inherit.
    #   PULSE_SERVER: absolute path to the host socket so audio works regardless of
    #     XDG_RUNTIME_DIR (the socket is inside the sandbox via --dev-bind / /).
    # XAUTHORITY: bwrap inherits env but SSH sessions don't have the cookie set.
    # Auto-detect from the kwin_wayland_wrapper --xwayland-xauthority flag, which
    # names the actual file regardless of login session or boot path.
    local _xauth="${XAUTHORITY:-}"
    if [[ -z "$_xauth" ]]; then
        _xauth=$(ps -C kwin_wayland -o args= 2>/dev/null \
            | grep -oP '(?<=--xwayland-xauthority )\S+' | head -1)
    fi

    local -a _env_vars=(
        APPIMAGE_EXTRACT_AND_RUN=1
        QT_QPA_PLATFORM=xcb
        "PULSE_SERVER=unix:/run/user/$(id -u)/pulse/native"
        SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=${_allow}
        SDL_GAMECONTROLLER_IGNORE_DEVICES=
        SDL_JOYSTICK_HIDAPI=0
        SDL_LINUX_JOYSTICK_CLASSIC=1
        # DRAFT 2026-06-27 (research, UNTESTED): gamescope WSI layer off (the GL game doesn't
        # use it; its abort()-on-no-dialog path is a suspected 4-instance crash source —
        # DISABLE_GAMESCOPE_WSI=1 is the correct switch, NOT ENABLE=0) + cap RADV's claim on
        # the 16GB unified APU RAM (the 4-instance reset is JVM-heap memory pressure, not
        # swapchain memory). See docs/RESEARCH-WINDOWING-GAMESCOPE-2026-06-27.md.
        DISABLE_GAMESCOPE_WSI=1
        RADV_SYS_MEM_LIMIT=50
    )
    # SDL_JOYSTICK_DISABLE_UDEV=1 — THE key strict-isolation hint, but set ONLY in
    # strict/docked mode. SDL does NOT detect a plain bwrap sandbox as a container, so by
    # default it stays on libudev enumeration and reads every device from the (reachable)
    # udev DB, bypassing our /dev/input bind; this hint is checked BEFORE that sandbox check
    # and forces the scandir("/dev/input") fallback so SDL sees only nodes in this namespace
    # (the one bound pad). In POROUS/handheld mode we must NOT set it — the built-in is
    # discovered via udev, so DISABLE_UDEV would hide it (the built-in-dead-in-handheld bug).
    # (SDL_LINUX_JOYSTICK_CLASSIC does NOT do this — it only filters js vs event node names.)
    # Root-caused via deep-research + live Deck testing 2026-06-26.
    (( _strict )) && _env_vars+=(SDL_JOYSTICK_DISABLE_UDEV=1)
    if [[ -n "$_xauth" ]]; then
        _env_vars+=("XAUTHORITY=$_xauth")
        # If xauth file is in /tmp, bind it into the isolated tmpfs
        [[ "$_xauth" == /tmp/* ]] && cmd+=(--bind "$_xauth" "$_xauth")
    fi

    cmd+=(
        --
        env
        -u ENABLE_GAMESCOPE_WSI
        "${_env_vars[@]}"
        "${launcher_exec}"
        -l "latestUpdate-${slot}"
        -a "P${slot}"
    )

    # Output the command as a safely-quoted single string
    printf '%q ' "${cmd[@]}"
}

# _poll_for_java: Poll for the Java process PID.
# $1 = slot
# Returns PID on stdout, empty string if not found within timeout.
_poll_for_java() {
    local slot="$1"
    local launcher_dir
    launcher_dir=$(_get_launcher_dir)
    local search_pattern="instances/latestUpdate-${slot}/natives"

    local max_iterations="$INSTANCE_LIFECYCLE_JAVA_POLL_ITERS"

    local _i
    for (( _i = 0; _i < max_iterations; _i++ )); do
        local found_pid
        found_pid=$(pgrep -af "$search_pattern" 2>/dev/null | head -1 | awk '{print $1}' || true)
        if [[ -n "$found_pid" ]]; then
            echo "$found_pid"
            return 0
        fi
        sleep "$INSTANCE_LIFECYCLE_POLL_INTERVAL_S"
    done

    echo "[instance_lifecycle] WARNING: Java process for slot $slot not found within ${INSTANCE_LIFECYCLE_POLL_TIMEOUT_S}s" >&2
    echo ""
    return 1
}

# _collect_slot_pids: echo every PID that could own the slot's Minecraft window —
# all java processes referencing the slot's natives dir PLUS their full descendant
# trees. A modern Minecraft instance has >1 java process (the launcher's child + the
# game JVM), and the GLFW window's _NET_WM_PID can belong to a child we did NOT store
# as get_java_pid (which is just head -1 of the natives match). Searching only that
# one PID is why window detection returned wid=null in production (2026-06-23). One
# PID per line, de-duplicated.
_collect_slot_pids() {
    local slot="$1"
    local search_pattern="instances/latestUpdate-${slot}/natives"
    local roots root
    roots=$(pgrep -f "$search_pattern" 2>/dev/null || true)
    {
        local pid
        for root in $roots; do
            _emit_pid_tree "$root"
        done
    } | awk 'NF && !seen[$0]++'
}

# _emit_pid_tree: recursively echo a PID and all of its descendants (one per line).
_emit_pid_tree() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    echo "$pid"
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        _emit_pid_tree "$child"
    done
}

# _poll_for_window: Wait for the Minecraft window to appear.
# $1 = slot
# Returns window ID on stdout, empty string if timeout.
# Strategy (via dex — the single X11 layer):
#   1. dex_search --name "SplitscreenP<slot>" — works only with LWJGL 2 (the title
#      property is ignored by LWJGL 3 / GLFW, and modern MC overwrites the caption to
#      "Minecraft* <ver>" right after mapping — the title-flash — so this rarely hits).
#   2. dex_search --pid <pid> across the slot's WHOLE java subtree (matches _NET_WM_PID)
#      — LWJGL 3 (MC 1.18+). On match: rename WM_NAME (dex_set_name) so apply_layout /
#      _get_wid_from_state can find it by name on future calls. Positioning is
#      apply_layout's job. Searching the subtree (not just the stored java_pid) is what
#      makes this tolerant of the two-java-per-instance / wrong-stored-pid case.
_poll_for_window() {
    local slot="$1"

    local max_iterations="$INSTANCE_LIFECYCLE_WINDOW_POLL_ITERS"

    local _i
    for (( _i = 0; _i < max_iterations; _i++ )); do
        # Strategy 1: title-based (works if the LWJGL2 title property was honoured)
        local wid
        wid=$(dex_search --name "SplitscreenP${slot}" 2>/dev/null | head -1 || true)
        if [[ -n "$wid" ]]; then
            echo "$wid"
            return 0
        fi

        # Strategy 2: PID-based after a short warm-up (LWJGL3 ignores the title
        # property; match the JVM's _NET_WM_PID instead). Try EVERY pid in the slot's
        # java subtree, not just the stored java_pid — the window can belong to a child.
        if (( _i > 10 )); then
            local cand_pid
            while IFS= read -r cand_pid; do
                [[ -n "$cand_pid" ]] || continue
                # tail -1 picks the most-recently-opened window for this PID
                # (avoids grabbing PrismLauncher's own launch dialog if still open)
                wid=$(dex_search --pid "$cand_pid" 2>/dev/null | tail -1 || true)
                if [[ -n "$wid" ]]; then
                    echo "[instance_lifecycle] Found window by PID $cand_pid for slot $slot: wid=$wid" >&2
                    # Rename WM_NAME so apply_layout / _get_wid_from_state can find
                    # it by name on subsequent calls — and so it survives the caption
                    # flash to "Minecraft* <ver>".
                    dex_set_name "$wid" "SplitscreenP${slot}" 2>/dev/null || true

                    # NOTE: window POSITIONING (override_redirect + move/resize) is
                    # intentionally NOT done here. apply_layout() positions every
                    # active slot via dex right after spawn_instance records this WID.
                    echo "$wid"
                    return 0
                fi
            done < <(_collect_slot_pids "$slot")
        fi

        sleep "$INSTANCE_LIFECYCLE_POLL_INTERVAL_S"
    done

    echo "[instance_lifecycle] WARNING: Window for slot $slot not found within ${INSTANCE_LIFECYCLE_WINDOW_POLL_TIMEOUT_S}s" >&2
    echo ""
    return 1
}

# --- State file management ---

# Read the current state file. Returns "null" on stdout if file doesn't exist.
read_state() {
    local state_file
    state_file=$(_get_state_file)

    jq -c '.' "$state_file" 2>/dev/null || echo "null"
}

# Update a single slot's fields by merging the provided JSON object.
# $1 = slot (1-4), $2 = JSON object to merge into the slot's data
# The provided object is recursively merged with the existing slot data via jq's * operator.
update_slot_state() {
    local slot="$1"
    local merge_json="$2"
    local state_file
    state_file=$(_get_state_file)

    # Only initialize if missing — main() calls _ensure_state_file at startup
    if [[ ! -f "$state_file" ]]; then
        _ensure_state_file
    fi

    # H3 (UNTESTED 2026-06-27): serialize the read-modify-write across processes. Up to 4
    # CONTROLLER_ADD spawns run in backgrounded subshells, each doing jq-read → merge → write
    # of the WHOLE file over ~120s, overlapping the main loop's active:true reservation and
    # reap/teardown writes. Without locking, a later writer merging from a STALE snapshot
    # reverts another slot's just-written field → lost bwrap_pid (un-reapable zombie slot) or
    # lost active:true (slot handed out twice → double-spawn / controller on wrong player).
    # flock on a sidecar lock fd makes the jq-read + atomic-write one critical section.
    local lock_file="${state_file}.lock"
    (
        flock -w 5 9 || {
            echo "[instance_lifecycle] WARNING: state-file lock timeout updating slot $slot" >&2
            exit 1
        }
        local updated
        updated=$(jq --arg slot "$slot" --argjson merge "$merge_json" \
            '.slots[$slot] = ((.slots[$slot] // {}) * $merge)' \
            "$state_file" 2>/dev/null) || {
            echo "[instance_lifecycle] ERROR: jq update failed for slot $slot" >&2
            exit 1
        }
        _atomic_write "$state_file" "$updated"
    ) 9>"$lock_file"
}

# Return active slot numbers as a space-separated string (ascending order).
get_active_slots() {
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r '[.slots | to_entries[] | select(.value.active == true) | .key | tonumber] | sort | join(" ")' <<< "$state" 2>/dev/null
}

# Return the bwrap PID for a slot.
get_bwrap_pid() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r --arg s "$slot" '.slots[$s].bwrap_pid // empty' <<< "$state" 2>/dev/null
}

# Return the Java PID for a slot.
get_java_pid() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r --arg s "$slot" '.slots[$s].pid // empty' <<< "$state" 2>/dev/null
}

# Return the X11 window ID (WID) for a slot, or empty if not known.
# Used by apply_layout to find the Minecraft window without xdotool name-search.
get_window_id() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r --arg s "$slot" '.slots[$s].wid // empty' <<< "$state" 2>/dev/null
}

# --- Public API ---

# Spawn a Minecraft instance in the given slot.
# $1 = slot (1-4)
# $2 = event_node (e.g. /dev/input/event4)
# $3 = js_node (e.g. /dev/input/js1)
spawn_instance() {
    local slot="${1:-}"
    local event_node="${2:-}"
    local js_node="${3:-}"
    # Args 4+: pairs of (event_node, js_node) for other controllers to mask in bwrap
    local -a mask_controllers=()
    if [[ $# -gt 3 ]]; then
        mask_controllers=("${@:4}")
    fi

    if [[ -z "$slot" ]]; then
        echo "[spawn_instance] ERROR: slot is required" >&2
        return 1
    fi
    # event_node/js_node may be empty for a controller-LESS single instance — e.g.
    # P1 on the Deck's built-in controls (orchestrator single-player entry) or the
    # test-8 position sweep. In that case the bwrap sandbox simply doesn't bind/mask
    # a dedicated controller (no isolation), which is fine when only one instance runs.
    if [[ -z "$event_node" || -z "$js_node" ]]; then
        echo "[spawn_instance] slot $slot: no controller node(s) — launching without controller isolation" >&2
    fi

    local bwrap_cmd
    bwrap_cmd=$(_get_bwrap_cmd)

    # Check bwrap availability
    if ! command -v "$bwrap_cmd" >/dev/null 2>&1; then
        echo "[spawn_instance] ERROR: $bwrap_cmd (bubblewrap) is required but not found. Cannot sandbox instance." >&2
        return 1
    fi

    # Check if slot is already active with a running instance
    if slot_is_active "$slot"; then
        local existing_bwrap
        existing_bwrap=$(get_bwrap_pid "$slot")
        if [[ -n "$existing_bwrap" ]]; then
            echo "[spawn_instance] ERROR: slot $slot is already active (bwrap_pid=$existing_bwrap)" >&2
            return 2
        fi
        # Slot was pre-reserved (active but no bwrap_pid) — continue
        echo "[spawn_instance] Slot $slot pre-reserved, proceeding with launch" >&2
    fi

    echo "[spawn_instance] Launching instance for slot $slot ($event_node, $js_node)" >&2

    # ── Mock mode ─────────────────────────────────────────────────────────────
    # When SPLITSCREEN_MOCK_SPAWN=1, replace bwrap+PolyMC with a sleep stub.
    # Exercises the orchestrator's FIFO dispatch and state machine without any
    # hardware (no controllers, no real game).  teardown_instance works unchanged
    # because it just kills the stub PID.
    if [[ "${SPLITSCREEN_MOCK_SPAWN:-}" == "1" ]]; then
        sleep 86400 &
        local stub_pid=$!
        update_slot_state "$slot" \
            "{\"active\": true, \"event_node\": \"${event_node}\", \"js_node\": \"${js_node}\", \"pid\": ${stub_pid}, \"bwrap_pid\": ${stub_pid}, \"wid\": null}"
        echo "[spawn_instance] MOCK: slot $slot active (stub_pid=$stub_pid)" >&2
        return 0
    fi

    # (Removed splitscreen.properties writing 2026-06-23 — the Splitscreen mod that read
    # it is gone; KWin does the tiling now.)

    # 2. Clear selected_controllers.json
    local launcher_dir
    launcher_dir=$(_get_launcher_dir)
    rm -f "${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/config/controllable/selected_controllers.json"

    # 2.3 Set out_of_focus_input=true so unfocused instances respond to their controller
    local controlify_cfg="${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/config/controlify.json"
    if [[ -f "$controlify_cfg" ]] && command -v jq >/dev/null 2>&1; then
        local updated_cfg
        updated_cfg=$(jq '.global.out_of_focus_input = true' "$controlify_cfg" 2>/dev/null)
        if [[ -n "$updated_cfg" ]]; then
            echo "$updated_cfg" > "$controlify_cfg"
            echo "[spawn_instance] Set out_of_focus_input=true for slot $slot" >&2
        fi
    fi

    # 2.5 Set window title via instance.cfg JvmArgs
    local cfg_path="${launcher_dir}/instances/latestUpdate-${slot}/instance.cfg"
    if [[ -f "$cfg_path" ]]; then
        setInstanceCfgValue "$cfg_path" "OverrideJavaArgs" "true"
        setInstanceCfgValue "$cfg_path" "JvmArgs" "-Dorg.lwjgl.opengl.Window.title=SplitscreenP${slot}"
        echo "[spawn_instance] Set window title SplitscreenP${slot} via instance.cfg" >&2
    fi

    # 3. Build the launch command string.
    #    HANDHELD (no js bound — single player on the Deck's built-in): launch WITHOUT bwrap,
    #    full system access. Nothing to isolate (one player), and a sandbox gives the
    #    built-in's Steam virtual no /dev/input node to open → Controlify finds no controller.
    #    DOCKED (a real pad's js bound): keep the bwrap sandbox for per-instance isolation.
    local bwrap_command
    if [[ -z "$js_node" ]]; then
        bwrap_command=$(_build_direct_command "$slot")
        echo "[spawn_instance] Slot $slot: handheld direct launch (no sandbox, full access)" >&2
    elif [[ ${#mask_controllers[@]} -gt 0 ]]; then
        bwrap_command=$(_build_bwrap_command "$slot" "$event_node" "$js_node" "${mask_controllers[@]}")
    else
        bwrap_command=$(_build_bwrap_command "$slot" "$event_node" "$js_node")
    fi

    # 4. Mark slot as active in state file (preliminary, bwrap_pid filled after launch)
    update_slot_state "$slot" "{\"active\": true, \"event_node\": \"${event_node}\", \"js_node\": \"${js_node}\", \"pid\": null, \"bwrap_pid\": null}"

    # 5. Spawn the instance in its OWN process group via setsid.
    #    Previously `eval "$bwrap_command" &; bwrap_pid=$!` captured the PID of a
    #    transient subshell wrapper, NOT the real bwrap process (off by ~2). That
    #    made the watchdog fire spurious SLOT_DIED (it saw the wrapper exit) and
    #    made teardown SIGTERM the wrong PID, leaking the whole bwrap→PolyMC→java
    #    tree. setsid makes bwrap the session/group leader so $! is the real
    #    group-leader PID; teardown signals the negative PID to kill the group.
    #
    #    Remove any stale PolyMC SingleApplication socket left over from a prior
    #    SIGKILL — if the socket exists but nothing is listening, Qt's SingleApplication
    #    tries to forward to the dead peer, fails silently, and exits without launching.
    rm -f /tmp/qtsingleapp-* 2>/dev/null || true
    # Redirect bwrap stdout/stderr directly to the debug log (bypassing any pipe
    # the caller may have put around spawn_instance). Without this, bwrap and all
    # its Minecraft descendants inherit the pipe's write-end and keep it open until
    # the game exits — which blocks the orchestrator's sed pipe and prevents it from
    # reading FIFO events (e.g. SLOT_DIED) until after Minecraft is already dead.
    setsid bash -c "$bwrap_command" </dev/null >>"${LOG:-/tmp/splitscreen-bwrap-${slot}.log}" 2>&1 &
    local bwrap_pid=$!

    update_slot_state "$slot" "{\"bwrap_pid\": ${bwrap_pid}}"
    echo "[spawn_instance] bwrap PID: $bwrap_pid" >&2

    # N11: liveness check right after launch. Without this, a bwrap that fails/exits
    # instantly (bad bwrap args, missing binary, immediate sandbox rejection) still
    # burns the FULL INSTANCE_LIFECYCLE_POLL_TIMEOUT_S (60s) java poll below before
    # anything notices — a short grace then kill -0 fails fast instead.
    sleep 0.3
    if ! kill -0 "$bwrap_pid" 2>/dev/null; then
        echo "[spawn_instance] ERROR: bwrap PID $bwrap_pid died immediately after launch — aborting (skipping the ${INSTANCE_LIFECYCLE_POLL_TIMEOUT_S}s java poll)" >&2
        return 1
    fi

    # 6. Poll for Java process
    local java_pid
    java_pid=$(_poll_for_java "$slot" || true)
    if [[ -n "$java_pid" ]]; then
        update_slot_state "$slot" "{\"pid\": ${java_pid}}"
        echo "[spawn_instance] Java PID: $java_pid" >&2
    fi

    # 7. Wait for window to appear and store its WID in state
    local window_id
    window_id=$(_poll_for_window "$slot" || true)
    if [[ -n "$window_id" ]]; then
        update_slot_state "$slot" "{\"wid\": ${window_id}}"
        echo "[spawn_instance] Stored WID $window_id for slot $slot" >&2

        # 7.1 Title-keeper (belt-and-suspenders): _poll_for_window already restored the
        # SplitscreenP<slot> name once on match, but the game can flash its own caption
        # ("Minecraft* <ver>") slightly later during title-screen init. Re-assert our
        # name a few times in the background so the label sticks. Backgrounded + bounded
        # so it never blocks spawn_instance and self-exits (no reaping needed).
        if type dex_set_name >/dev/null 2>&1; then
            (
                _k=0
                while (( _k < INSTANCE_LIFECYCLE_TITLE_REASSERT_COUNT )); do
                    dex_set_name "$window_id" "SplitscreenP${slot}" 2>/dev/null || true
                    sleep "$INSTANCE_LIFECYCLE_TITLE_REASSERT_INTERVAL_S"
                    _k=$(( _k + 1 ))
                done
            ) &
        fi
    fi

    # 7.5 Strip the title bar via _MOTIF_WM_HINTS (the standard X way, set on the WID by
    # dex). KWin honours the property change in its event loop — NO synchronous frame
    # recreate — so this does NOT hang spawn_instance the way the KWin-scripting noBorder
    # did. Done before layout so the (borderless) frame == client when we position it.
    if [[ -n "$window_id" ]] && type dex_set_decorations >/dev/null 2>&1; then
        dex_set_decorations "$window_id" 0 2>/dev/null || true
    fi

    # 8. Apply layout with all currently active slots
    local updated_active
    updated_active=$(get_active_slots)

    # Apply the layout for all currently-active slots.
    sync_apply_layout "$updated_active" "" ""

    # 9. Map-keeper (Fix #57, UNTESTED 2026-07-05): apply_layout maps the window when it
    # positions it, but Minecraft/GLFW can unmap→(fail to remap) when it finalizes its
    # GL/fullscreen window much LATER — leaving a black screen with audio (the first
    # on-Deck handheld symptom; a manual `xdotool windowmap` late in load fixed it and
    # stuck). Re-show the window whenever the game leaves it unmapped, over its startup.
    # Backgrounded + bounded so it never blocks spawn_instance and self-exits; stops early
    # once the window is gone (teardown/crash). Runs AFTER positioning so it only guards
    # the post-placement life of the window, not the override_redirect cycle itself.
    if [[ -n "$window_id" ]] && type dex_is_viewable >/dev/null 2>&1 && type dex_map_raise >/dev/null 2>&1; then
        (
            _m=0
            while (( _m < INSTANCE_LIFECYCLE_MAP_KEEP_COUNT )); do
                _vis=$(dex_is_viewable "$window_id" 2>/dev/null || echo gone)
                [[ "$_vis" == "gone" ]] && break
                if [[ "$_vis" == "unmapped" ]]; then
                    dex_map_raise "$window_id" 2>/dev/null || true
                    echo "[spawn_instance] map-keeper: re-mapped unmapped window $window_id (slot $slot)" >&2
                fi
                sleep "$INSTANCE_LIFECYCLE_MAP_KEEP_INTERVAL_S"
                _m=$(( _m + 1 ))
            done
        ) &
    fi
}

# Tear down the instance in the given slot.
# $1 = slot
teardown_instance() {
    local slot="$1"

    if ! slot_is_active "$slot"; then
        echo "[teardown_instance] Slot $slot is not active, nothing to tear down" >&2
        return 0
    fi

    echo "[teardown_instance] Tearing down slot $slot" >&2

    local bwrap_pid
    bwrap_pid=$(get_bwrap_pid "$slot")
    local java_pid
    java_pid=$(get_java_pid "$slot")

    # bwrap_pid is the process-group leader (see spawn_instance / setsid), so the
    # whole bwrap→PolyMC→java tree shares PGID == bwrap_pid. Signalling the
    # NEGATIVE pid hits the entire group, which is the only reliable way to reap
    # the tree (PolyMC's AppImage extract-and-run forks intermediate processes
    # that a single-PID kill misses).
    # 1. Send SIGTERM to the whole group (fall back to single PID if group is gone)
    if [[ -n "$bwrap_pid" ]]; then
        kill -TERM "-${bwrap_pid}" 2>/dev/null || kill -TERM "$bwrap_pid" 2>/dev/null || true
    fi

    # 2. Wait up to TEARDOWN_GRACE_S for processes to exit
    local _i
    for (( _i = 0; _i < INSTANCE_LIFECYCLE_TEARDOWN_GRACE_S; _i++ )); do
        local still_alive=0
        if [[ -n "$bwrap_pid" ]] && kill -0 "$bwrap_pid" 2>/dev/null; then
            still_alive=1
        fi
        if [[ -n "$java_pid" ]] && kill -0 "$java_pid" 2>/dev/null; then
            still_alive=1
        fi
        if (( still_alive == 0 )); then
            break
        fi
        sleep 1
    done

    # 3. SIGKILL the whole group if anything is still alive, then mop up the
    #    individually-tracked PIDs as a belt-and-suspenders fallback.
    if [[ -n "$bwrap_pid" ]]; then
        if kill -0 "$bwrap_pid" 2>/dev/null || kill -0 "$java_pid" 2>/dev/null; then
            kill -KILL "-${bwrap_pid}" 2>/dev/null || kill -9 "$bwrap_pid" 2>/dev/null || true
        fi
    fi
    if [[ -n "$java_pid" ]] && kill -0 "$java_pid" 2>/dev/null; then
        kill -9 "$java_pid" 2>/dev/null || true
    fi

    # 4. Update state file: mark slot inactive (including WID so layout doesn't find a stale window)
    update_slot_state "$slot" "{\"active\": false, \"pid\": null, \"bwrap_pid\": null, \"event_node\": null, \"js_node\": null, \"wid\": null}"
    # Clear apply_layout's per-slot geom cache so a fresh instance reusing this slot is
    # always repositioned (belt-and-suspenders; the cache is also WID-keyed). See apply_layout.
    rm -f "${MCSS_GEOM_DIR:-/tmp/mcss-geom}/slot${slot}" 2>/dev/null || true

    # Layout reflow is the caller's responsibility (e.g. SLOT_DIED handler calls
    # _reflow_layout after teardown_instance returns). Calling sync_apply_layout
    # here would hang if the window is already dead (X11 BadWindow → no response).
}

# Tear down all active instances.
teardown_all_instances() {
    echo "[teardown_all_instances] Tearing down all instances" >&2

    local active
    active=$(get_active_slots)

    local slot
    for slot in $active; do
        teardown_instance "$slot"
    done
}

# Return 0 if the given slot has an active running instance, 1 otherwise.
# $1 = slot
slot_is_active() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        return 1
    fi

    local is_active
    is_active=$(jq -r --arg s "$slot" '.slots[$s].active // false' <<< "$state" 2>/dev/null)

    if [[ "$is_active" == "true" ]]; then
        return 0
    else
        return 1
    fi
}
