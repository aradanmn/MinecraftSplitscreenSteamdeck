#!/bin/bash
# =============================================================================
# runtime_context.sh — single source of truth for environment/session context
# =============================================================================
# #43: the launcher/modules previously INFERRED critical runtime facts ad hoc
# instead of resolving them ONCE and branching on an authoritative value:
#   - no environment/session-context global (Game Mode/gamescope vs Desktop
#     Mode; inside our own nested session or not) → #42, a bare no-arg
#     invocation (a Desktop-Mode .desktop shortcut with no LaunchOptions) fell
#     straight into the orchestrator's main() -> docked_flow OUTSIDE gamescope,
#     spawning a live 4-player splitscreen on the running desktop.
#   - no authoritative docked/handheld mode global; it's inferred elsewhere
#     from js_node emptiness at spawn time. That inference is unchanged by
#     this module (out of scope here) but SPLITSCREEN_STATE's `.mode` remains
#     the one authoritative value for it (see orchestrator.sh _get_mode/_set_mode).
#
# This module resolves the environment ONCE per process and exposes it as an
# exported global, plus a guard function that refuses to proceed unless we're
# either inside our own nested session or directly in a gamescope session.
#
# Public API:
#   mcss_resolve_environment()  — idempotent; sets/exports MCSS_ENV_CONTEXT
#                                  (gamescope|desktop|unknown) and
#                                  MCSS_LAUNCHED_BY_STEAM (1|0).
#   mcss_require_gamescope()    — returns 0 if MCSS_ENV_CONTEXT=gamescope,
#                                  else logs a clear refusal and returns 1.
#                                  Callers also accept MCSS_NESTED_SESSION=1
#                                  (set by launchFromPlasma/testPlasma/
#                                  nestedPlasma/_nestedSession before they
#                                  re-invoke this script) as an alternative —
#                                  see minecraftSplitscreen.sh's `*)` dispatch.
#
#   SPLITSCREEN_STATE / MCSS_STATE_LOCK — resolved + exported below, at source
#                                  time, exactly once (#50). Respects a value
#                                  already set in the environment (test
#                                  harnesses, nested-session Exec lines).
# =============================================================================

# #50: the ONLY place the state-file default exists. Previously this fallback
# was inline-expanded at 13 runtime sites; losing the export anywhere meant
# every component silently agreed on the fallback EXCEPT the watchdog (which
# hard-requires the var and errored out — slot-death detection quietly gone),
# and the two independently-built ".lock" sidecars could degrade flock into
# two separate locks (the H3 state-corruption race). Every other site now does
# a bare read of these exports.
export SPLITSCREEN_STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
# Advisory mirror for external tooling; the flock sites derive "<state>.lock"
# at use time from the same resolved path (tests re-point SPLITSCREEN_STATE
# after source, and the lock must follow the file actually being locked).
export MCSS_STATE_LOCK="${SPLITSCREEN_STATE}.lock"

mcss_resolve_environment() {
    # Idempotent: resolve once per process, callers may call this freely.
    [[ -n "${MCSS_ENV_CONTEXT:-}" ]] && return 0

    # SteamOS's gamescope-session sets XDG_CURRENT_DESKTOP/XDG_SESSION_DESKTOP
    # to "gamescope" for Game Mode; a full Plasma Desktop-Mode session reports
    # "KDE". This is the same signal minecraftSplitscreen.sh already logs at
    # startup (line ~49) but never acted on — see #43.
    local desktop_signal="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}"
    # Steam sets SteamGameId/SteamAppId for anything it launches, in any mode;
    # useful as a secondary signal (e.g. "never launched by Steam at all",
    # exactly the #42 desktop-icon bypass) but NOT sufficient on its own,
    # since Steam also launches things from Desktop Mode.
    local launched_by_steam="${SteamGameId:-}${SteamAppId:-}"

    if [[ "${desktop_signal,,}" == *gamescope* ]]; then
        MCSS_ENV_CONTEXT="gamescope"
    elif [[ -n "$desktop_signal" ]]; then
        MCSS_ENV_CONTEXT="desktop"
    else
        MCSS_ENV_CONTEXT="unknown"
    fi
    export MCSS_ENV_CONTEXT
    if [[ -n "$launched_by_steam" ]]; then
        MCSS_LAUNCHED_BY_STEAM=1
    else
        MCSS_LAUNCHED_BY_STEAM=0
    fi
    export MCSS_LAUNCHED_BY_STEAM

    local _logf="${LOG:-${SPLITSCREEN_DEBUG_LOG:-}}"
    if [[ -n "$_logf" ]]; then
        echo "[runtime_context] env=${MCSS_ENV_CONTEXT} steam_launch=${MCSS_LAUNCHED_BY_STEAM} (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-unset} SteamGameId=${SteamGameId:-unset} SteamAppId=${SteamAppId:-unset})" >> "$_logf" 2>/dev/null
    fi
}

mcss_require_gamescope() {
    mcss_resolve_environment
    if [[ "$MCSS_ENV_CONTEXT" == "gamescope" ]]; then
        return 0
    fi
    local msg="[runtime_context] REFUSED: docked/handheld splitscreen must run inside Steam Game Mode (gamescope); detected context='${MCSS_ENV_CONTEXT}' (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}, launched_by_steam=${MCSS_LAUNCHED_BY_STEAM}). This guard exists because of #42 (a Desktop-Mode shortcut previously ran a live splitscreen outside gamescope)."
    echo "$msg" >&2
    local _logf="${LOG:-${SPLITSCREEN_DEBUG_LOG:-}}"
    [[ -n "$_logf" ]] && echo "$msg" >> "$_logf" 2>/dev/null
    return 1
}

# =============================================================================
# #45 (#43 part 2) — paths, screen, and cross-module constants
# =============================================================================
# Everything below centralizes values that were previously re-derived at 2+
# independent sites (the bar for inclusion — see docs/PLAN-V1.1-2026-07-05.md
# Part 4). Module-local tunables (ORCHESTRATOR_*_S, WATCHDOG_*, ...) stay in
# their modules on purpose.
#
# Load-guard rule (plan Part 4, verifier catch + review of PR #76): functions
# are always (re)defined — a re-exec'd child that sources this file needs the
# API even though it inherited the exported values. Idempotency is gated on
# NON-exported, process-local sentinels (_MCSS_*_LOCKED/_DONE), never on the
# presence of an exported value. That distinction is load-bearing: an exported
# value crosses fork/exec, so a value-presence guard in a CHILD would see the
# parent's value and skip re-resolution — silently ignoring the child's own
# legacy overrides (N_SLOTS, INSTANCES_DIR, ...), which on main were always
# re-read per process. The non-exported sentinel is absent in the child, so the
# child re-resolves from ITS environment; within one process the sentinel is
# set, so re-sourcing is a no-op and never trips a readonly re-declaration.
#
# Legacy override inputs (consumed here, never read downstream after the PR-2
# migration): INSTANCES_DIR, LAUNCHER_EXEC, N_SLOTS, SPLITSCREEN_SCREEN_W/H,
# CONTROLLER_MONITOR_RAW_BINDING.
# =============================================================================

# --- Constants block (Group C) — the cross-process contracts ----------------
# These are protocol values between cooperating components (orchestrator,
# watchdog, controller monitor, dex's Python backend, generated KWin JS, JVM
# window titles). A drifted copy doesn't error — it silently partitions the
# system (a pkill pattern that misses, a window search that never matches).
#
# Per-value precedence: explicit legacy override → inherited/prior value →
# default. Each value self-defaults independently (`${VAR:-…}`) so a partial
# preset — a consumer/test setting only one of a pair — still leaves BOTH
# members of the pair defined (review finding: the vendor/product pair
# previously shared one guard, so presetting one left the other unbound).
if [[ -z "${_MCSS_CONSTANTS_LOCKED:-}" ]]; then
    # Slot count; N_SLOTS honored as the legacy override name. Clamped to 1..4:
    # the 4-slot ceiling is STRUCTURAL (state-file schema, compute_geometry's
    # layout arms, installer-created latestUpdate-1..4 instances) — an
    # unclamped N_SLOTS=5 previously only sized the static test, but now feeds
    # _find_free_slot and would spawn-error-loop on a nonexistent slot 5
    # (review finding on PR #78).
    export MCSS_MAX_PLAYERS="${N_SLOTS:-${MCSS_MAX_PLAYERS:-4}}"
    if ! [[ "$MCSS_MAX_PLAYERS" =~ ^[1-4]$ ]]; then
        echo "[runtime_context] WARNING: MCSS_MAX_PLAYERS='$MCSS_MAX_PLAYERS' outside the structural 1-4 range — clamping to 4" >&2
        MCSS_MAX_PLAYERS=4
    fi
    # PolyMC instance dir prefix → latestUpdate-1..N. Also appears in
    # pgrep/pkill process-match patterns — the highest-blast-radius copy.
    export MCSS_INSTANCE_PREFIX="${MCSS_INSTANCE_PREFIX:-latestUpdate-}"
    # accounts.json profile names P1..PN (NOT derivable from the instance
    # prefix — independent contract with the installer-shipped accounts.json).
    export MCSS_ACCOUNT_PREFIX="${MCSS_ACCOUNT_PREFIX:-P}"
    # The join key between JVM -Dorg.lwjgl.opengl.Window.title args, dex's
    # window search, KWin rules, and the watchdog.
    export MCSS_WINDOW_TITLE_PREFIX="${MCSS_WINDOW_TITLE_PREFIX:-SplitscreenP}"
    # Deck built-in controller USB ids (28de:11ff) — excluded from player
    # slots by design. CONTROLLER_MONITOR_STEAM_VENDOR/PRODUCT remain as
    # aliases in controller_monitor.sh for one release.
    export MCSS_STEAM_VENDOR_ID="${MCSS_STEAM_VENDOR_ID:-28de}"
    export MCSS_STEAM_PRODUCT_ID="${MCSS_STEAM_PRODUCT_ID:-11ff}"
    # Raw per-slot controller binding. Resolved ONCE from the legacy override:
    # controller_monitor (enumeration) and instance_lifecycle (sandboxing)
    # previously each defaulted this independently — they MUST agree or
    # enumeration and sandbox masking diverge.
    export MCSS_RAW_BINDING="${CONTROLLER_MONITOR_RAW_BINDING:-${MCSS_RAW_BINDING:-1}}"
    export MCSS_STATE_LOCK_TIMEOUT_S="${MCSS_STATE_LOCK_TIMEOUT_S:-5}"

    readonly MCSS_MAX_PLAYERS MCSS_INSTANCE_PREFIX MCSS_ACCOUNT_PREFIX \
             MCSS_WINDOW_TITLE_PREFIX MCSS_STEAM_VENDOR_ID MCSS_STEAM_PRODUCT_ID \
             MCSS_RAW_BINDING MCSS_STATE_LOCK_TIMEOUT_S
    _MCSS_CONSTANTS_LOCKED=1   # process-local — NOT exported (see load-guard rule)
fi

# MCSS_NESTED_SESSION: 0 outside our nested session; truthy inside (today the
# Exec-line writers set 1; the planned value space is 0|plasma|kwin so teardown
# can pick its path — writers migrate in the PR-2 pass). Default the export so
# bare readers stop needing their own :-0 fallbacks.
export MCSS_NESTED_SESSION="${MCSS_NESTED_SESSION:-0}"

# --- mcss_resolve_paths (Group B) --------------------------------------------
# Idempotent PER PROCESS; resolves + exports the path group. The detection
# cascades (flatpak probe, launcher-exec candidates) run at most once per
# process. The guard is a NON-exported sentinel (_MCSS_PATHS_DONE): a child
# process re-runs this so its own INSTANCES_DIR/LAUNCHER_EXEC overrides win —
# an exported flag would let the child inherit "already resolved" and silently
# keep the parent's paths (review finding). Values stay exported for
# same-process consumers and for the internal `${OVERRIDE:-${INHERITED:-…}}`
# precedence, which honors a child's explicit override first.
mcss_resolve_paths() {
    [[ -n "${_MCSS_PATHS_DONE:-}" ]] && return 0

    # Launcher root. Single probe order: PolyMC native, PolyMC flatpak,
    # PrismLauncher native, PrismLauncher flatpak (same order as the entry
    # script's historical _detect_instances_dir candidate list).
    if [[ -z "${MCSS_LAUNCHER_ROOT:-}" ]]; then
        local _root
        for _root in \
            "$HOME/.local/share/PolyMC" \
            "$HOME/.var/app/org.fn2006.PolyMC/data/PolyMC" \
            "$HOME/.local/share/PrismLauncher" \
            "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher"; do
            if [[ -d "$_root/instances" ]]; then
                MCSS_LAUNCHER_ROOT="$_root"
                break
            fi
        done
        # Nothing found (fresh box, tests): default to the primary install
        # location rather than leaving consumers with an empty root.
        MCSS_LAUNCHER_ROOT="${MCSS_LAUNCHER_ROOT:-$HOME/.local/share/PolyMC}"
    fi
    export MCSS_LAUNCHER_ROOT

    # INSTANCES_DIR is the legacy override name (test harnesses set it).
    export MCSS_INSTANCES_DIR="${INSTANCES_DIR:-${MCSS_INSTANCES_DIR:-$MCSS_LAUNCHER_ROOT/instances}}"

    # Launcher executable. LAUNCHER_EXEC honored as legacy override. One
    # cascade replaces the entry script's probe AND instance_lifecycle's
    # divergent bare default; the squashfs-root/AppRun candidate is the FUSE
    # workaround previously only utilities.sh (installer side) knew about.
    if [[ -z "${LAUNCHER_EXEC:-}" && -z "${MCSS_LAUNCHER_EXEC:-}" ]]; then
        local _exec=""
        if [[ -x "$MCSS_LAUNCHER_ROOT/squashfs-root/AppRun" ]]; then
            _exec="$MCSS_LAUNCHER_ROOT/squashfs-root/AppRun"
        elif [[ -x "$MCSS_LAUNCHER_ROOT/PolyMC.AppImage" ]]; then
            _exec="$MCSS_LAUNCHER_ROOT/PolyMC.AppImage"
        elif [[ -x "$MCSS_LAUNCHER_ROOT/PrismLauncher.AppImage" ]]; then
            _exec="$MCSS_LAUNCHER_ROOT/PrismLauncher.AppImage"
        elif command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q "org.fn2006.PolyMC"; then
            _exec="flatpak run org.fn2006.PolyMC"
        elif command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q "org.prismlauncher.PrismLauncher"; then
            _exec="flatpak run org.prismlauncher.PrismLauncher"
        elif command -v polymc >/dev/null 2>&1; then
            _exec="polymc"
        elif command -v prismlauncher >/dev/null 2>&1; then
            _exec="prismlauncher"
        fi
        MCSS_LAUNCHER_EXEC="$_exec"   # may be empty — callers report, not us
    else
        MCSS_LAUNCHER_EXEC="${LAUNCHER_EXEC:-$MCSS_LAUNCHER_EXEC}"
    fi
    export MCSS_LAUNCHER_EXEC

    # IPC paths. SPLITSCREEN_FIFO keeps its name (cross-process contract, same
    # rationale as SPLITSCREEN_STATE above); default resolved exactly once.
    # mkfifo stays in orchestrator.sh:main — this only names the path.
    export SPLITSCREEN_FIFO="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
    export MCSS_GEOM_DIR="${MCSS_GEOM_DIR:-/tmp/mcss-geom}"

    # Launch-time runtime dir snapshot. kwin_positioner legitimately rewrites
    # XDG_RUNTIME_DIR when importing the nested session bus — MCSS_RUNTIME_DIR
    # deliberately preserves the ORIGINAL value for consumers like
    # MCSS_PULSE_SERVER that must keep pointing at the host session.
    export MCSS_RUNTIME_DIR="${MCSS_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"
    export MCSS_PULSE_SERVER="${MCSS_PULSE_SERVER:-unix:$MCSS_RUNTIME_DIR/pulse/native}"

    # Generated-helper directory: replaces world-writable /tmp drops (the kwin
    # wrapper shim is injected into PATH and KWin EXECUTES the generated .js —
    # security items N6/N7). 0700 like XDG_RUNTIME_DIR itself. If the dir can't
    # be created/written (no /run/user/$UID: containers, root/cron, bare CI),
    # fall back to /tmp — that restores the old guaranteed-writable invariant
    # (mktemp in kwin_positioner must not hard-fail positioning; review finding
    # on PR #78), trading the 0700 hardening only in already-degraded envs.
    export MCSS_HELPER_DIR="${MCSS_HELPER_DIR:-$MCSS_RUNTIME_DIR/mcss}"
    mkdir -p "$MCSS_HELPER_DIR" 2>/dev/null || true
    chmod 700 "$MCSS_HELPER_DIR" 2>/dev/null || true
    if [[ ! -d "$MCSS_HELPER_DIR" || ! -w "$MCSS_HELPER_DIR" ]]; then
        echo "[runtime_context] WARNING: helper dir '$MCSS_HELPER_DIR' not writable — falling back to /tmp (N6/N7 hardening degraded)" >&2
        export MCSS_HELPER_DIR="/tmp"
    fi
    export MCSS_KWIN_WRAPPER_PATH="${MCSS_KWIN_WRAPPER_PATH:-$MCSS_HELPER_DIR/kwin_wayland_wrapper}"
    export MCSS_SESSION_ENV_BAK="${MCSS_SESSION_ENV_BAK:-$MCSS_HELPER_DIR/session-env.bak}"

    # Autostart contract: exactly two .desktop names exist; a missed rm here
    # strands an autostart that relaunches the game on every Plasma login.
    export MCSS_AUTOSTART_DIR="${MCSS_AUTOSTART_DIR:-$HOME/.config/autostart}"
    export MCSS_AUTOSTART_TEST_DESKTOP="${MCSS_AUTOSTART_TEST_DESKTOP:-splitscreen-test.desktop}"
    export MCSS_AUTOSTART_PROD_DESKTOP="${MCSS_AUTOSTART_PROD_DESKTOP:-splitscreen-prod.desktop}"

    _MCSS_PATHS_DONE=1   # process-local — NOT exported (see load-guard rule)

    local _logf="${LOG:-${SPLITSCREEN_DEBUG_LOG:-}}"
    if [[ -n "$_logf" ]]; then
        echo "[runtime_context] paths: root=${MCSS_LAUNCHER_ROOT} instances=${MCSS_INSTANCES_DIR} exec=${MCSS_LAUNCHER_EXEC:-<none>} fifo=${SPLITSCREEN_FIFO} helper=${MCSS_HELPER_DIR}" >> "$_logf" 2>/dev/null
    fi
}

# mcss_instance_dir <slot> — the ONE place the instance-dir shape lives.
mcss_instance_dir() {
    mcss_resolve_paths
    echo "$MCSS_INSTANCES_DIR/${MCSS_INSTANCE_PREFIX}$1"
}

# --- mcss_resolve_screen ------------------------------------------------------
# Sets/exports MCSS_SCREEN_W / MCSS_SCREEN_H (NOT readonly — hotplug changes
# them; re-run with --refresh on DISPLAY_MODE_CHANGE).
#
# Env override comes FIRST — the historical cascade in window_manager.sh
# checked SPLITSCREEN_SCREEN_W/H only after all four probes, so a test
# harness's forced dimensions lost to whatever the live display reported.
#
# --no-probe: skip all probes (override or 1280x800 fallback only). For the
# launchNested path — wlr-randr is a throwaway Wayland client and gamescope
# kills those (see GAMESCOPE-WINDOWING.md).
mcss_resolve_screen() {
    local _refresh=0 _no_probe=0 _arg
    for _arg in "$@"; do
        case "$_arg" in
            --refresh)  _refresh=1 ;;
            --no-probe) _no_probe=1 ;;
        esac
    done

    # Early-return gate is the NON-exported per-process sentinel, not the
    # presence of the exported MCSS_SCREEN_W/H — a fresh child must re-resolve
    # so its own SPLITSCREEN_SCREEN_W/H override applies (review finding: an
    # inherited value otherwise beat the child's override unless the call site
    # remembered --refresh, which a 1:1 migration from window_manager's
    # always-honor-override behavior would not).
    if [[ -n "${_MCSS_SCREEN_DONE:-}" && "$_refresh" != "1" ]]; then
        return 0
    fi

    local _w="" _h=""

    # 1. Explicit override (legacy names kept as the override inputs). Values
    #    must be pure digits: they feed $((W/2)) arithmetic under leaked set -e,
    #    where SPLITSCREEN_SCREEN_W=1920px would abort the whole session — the
    #    old per-site probes validated this; the resolver must too (review
    #    finding on PR #78). A malformed override is ignored loudly and the
    #    cascade/fallback proceeds, matching the old degrade-don't-die behavior.
    if [[ -n "${SPLITSCREEN_SCREEN_W:-}" && -n "${SPLITSCREEN_SCREEN_H:-}" ]]; then
        if [[ "$SPLITSCREEN_SCREEN_W" =~ ^[0-9]+$ && "$SPLITSCREEN_SCREEN_H" =~ ^[0-9]+$ ]]; then
            _w="$SPLITSCREEN_SCREEN_W"; _h="$SPLITSCREEN_SCREEN_H"
        else
            echo "[runtime_context] WARNING: ignoring non-numeric SPLITSCREEN_SCREEN_W/H override ('$SPLITSCREEN_SCREEN_W'x'$SPLITSCREEN_SCREEN_H')" >&2
        fi
    fi
    if [[ -z "$_w" && "$_no_probe" != "1" ]]; then
        # 2. Probe cascade — X11 CLIENTS ONLY. wlr-randr is deliberately ABSENT
        #    (it led window_manager's old cascade): it is a throwaway Wayland
        #    client, and gamescope kills the launcher when one connects and
        #    disconnects (documented in GAMESCOPE-WINDOWING.md; the reason
        #    --no-probe exists). The old gamescope-side probe sites silently
        #    enforced 'X11-only' by being xdpyinfo one-liners — this resolver
        #    must enforce it explicitly, for every context it can run in
        #    (review finding on PR #78: latent only because the Deck doesn't
        #    ship wlr-randr). kscreen-doctor is D-Bus (not a Wayland client),
        #    but with no KWin session it BLOCKS forever waiting for the
        #    org.kde.KScreen service instead of erroring (hung a Game Mode
        #    launch, 2026-07-10). Two guards: it is only tried at all inside
        #    a KDE session (host Plasma, or our nested plasma/kwin — the only
        #    places a KWin answers AND the only places its per-output fidelity
        #    beats xrandr's merged XWayland screen), and every probe runs
        #    under timeout(1) so a hang falls through like a failure. The
        #    binary existing is NOT a session signal — SteamOS ships Plasma,
        #    so Game Mode has kscreen-doctor on PATH with nothing listening.
        local _out _line _kde_session=0
        if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* || -n "${KDE_FULL_SESSION:-}" || "${MCSS_NESTED_SESSION:-0}" != "0" ]]; then
            _kde_session=1
        fi
        if [[ -z "$_w" && "$_kde_session" == "1" ]] && command -v kscreen-doctor >/dev/null 2>&1; then
            _out=$(timeout 3 kscreen-doctor -o 2>/dev/null || true)
            # Prefer the first EXTERNAL enabled output. The eDP filter must run
            # BEFORE the head -n1 — piping `grep -m1 enabled` first keeps only
            # the internal panel when it is listed first, and grep -v then drops
            # it to nothing, so a docked Deck fell back to the eDP resolution
            # (review finding; window_manager.sh:90 has the same latent bug).
            _line=$(echo "$_out" | grep 'enabled' | grep -v 'eDP' | head -n1 || true)
            [[ -z "$_line" ]] && _line=$(echo "$_out" | grep -m1 'enabled' || true)
            [[ "$_line" =~ ([0-9]+)x([0-9]+) ]] && { _w="${BASH_REMATCH[1]}"; _h="${BASH_REMATCH[2]}"; }
        fi
        if [[ -z "$_w" ]] && command -v xrandr >/dev/null 2>&1; then
            _out=$(timeout 3 xrandr 2>/dev/null || true)
            _line=$(echo "$_out" | grep -m1 '\*' || true)
            [[ "$_line" =~ ([0-9]+)x([0-9]+) ]] && { _w="${BASH_REMATCH[1]}"; _h="${BASH_REMATCH[2]}"; }
        fi
        if [[ -z "$_w" ]] && command -v xdpyinfo >/dev/null 2>&1; then
            _out=$(timeout 3 xdpyinfo 2>/dev/null | grep 'dimensions:' || true)
            [[ "$_out" =~ ([0-9]+)x([0-9]+) ]] && { _w="${BASH_REMATCH[1]}"; _h="${BASH_REMATCH[2]}"; }
        fi
    fi

    # 3. Result. Retain the last-known-good dimensions when a probe transiently
    #    yields nothing (review finding: a --refresh whose probes all fail —
    #    e.g. gamescope killed wlr-randr and the others are absent — must NOT
    #    clobber a good 1920x1080 with the 1280x800 fallback and tile four
    #    windows into a corner). Fall to 1280x800 only with no prior value.
    export MCSS_SCREEN_W="${_w:-${MCSS_SCREEN_W:-1280}}"
    export MCSS_SCREEN_H="${_h:-${MCSS_SCREEN_H:-800}}"
    _MCSS_SCREEN_DONE=1   # process-local — NOT exported (see load-guard rule)

    local _logf="${LOG:-${SPLITSCREEN_DEBUG_LOG:-}}"
    if [[ -n "$_logf" ]]; then
        echo "[runtime_context] screen: ${MCSS_SCREEN_W}x${MCSS_SCREEN_H} (refresh=${_refresh} no_probe=${_no_probe})" >> "$_logf" 2>/dev/null
    fi
}

# --- mcss_set_display ---------------------------------------------------------
# Single writer for MCSS_DISPLAY — the nested Xwayland DISPLAY, set once by
# launch code WHEN THE X SOCKET IS CONFIRMED UP (never at source time: dex.sh's
# old source-time DEX_DISPLAY capture ran before the nested X existed).
mcss_set_display() {
    export MCSS_DISPLAY="$1"
    local _logf="${LOG:-${SPLITSCREEN_DEBUG_LOG:-}}"
    [[ -n "$_logf" ]] && echo "[runtime_context] display: MCSS_DISPLAY=$1" >> "$_logf" 2>/dev/null
    return 0
}

# --- mcss_exec_env_string -----------------------------------------------------
# The canonical env list for the three RE-EXEC boundaries (autostart .desktop
# Exec= lines, the kwin session command, dbus-run-session), where exported env
# does NOT flow and every launch path previously hand-listed its own drifting
# subset (only 2 of ~7 vars were common to all four sites).
#
# Emits space-separated NAME=VALUE pairs (printf %q-escaped) for every
# canonical var that is currently set and non-empty, plus any extra NAME=VALUE
# args verbatim (values %q-escaped). Usage:
#   Exec=env $(mcss_exec_env_string MCSS_NESTED_SESSION=1) ${SCRIPT_PATH} ...
# Note: %q backslash-escaping is fine for the current value space (paths
# without spaces); .desktop Exec parsing has its own quoting rules, so keep
# generated values space-free.
mcss_exec_env_string() {
    # Resolve the origin context NOW, before emitting. A re-exec child inside
    # nested Plasma re-derives MCSS_ENV_CONTEXT from XDG_CURRENT_DESKTOP=KDE and
    # would get 'desktop' instead of the origin 'gamescope' — so the value MUST
    # be carried across explicitly. If the emitting site never happened to have
    # called mcss_resolve_environment, MCSS_ENV_CONTEXT would be unset here and
    # silently dropped, reintroducing the #42-class guard false-positive (review
    # finding). Resolving here makes the emission self-sufficient.
    mcss_resolve_environment

    local _canonical=(
        MCSS_ENV_CONTEXT
        MCSS_LAUNCHED_BY_STEAM
        MCSS_NESTED_SESSION       # plan Part 4 canonical list; omitting it let a
                                  # PR-2 Exec line default the child to 0 → the
                                  # gamescope guard REFUSES inside nested Plasma
        MCSS_MODE
        SPLITSCREEN_STATE
        SPLITSCREEN_FIFO
        SPLITSCREEN_DEBUG_LOG
        SPLITSCREEN_TEST_OBSERVE_DELAY_S
        TEST_NUMBER
    )
    # Emission is RAW NAME=VALUE, not shell-quoted: the consumers (.desktop
    # Exec= parsing, env(1) argv after $()-word-splitting) do NOT shell-unquote,
    # so %q output would arrive literally (an empty value would become two
    # literal apostrophes). Values therefore must be word-safe; anything with
    # whitespace/quotes is REFUSED loudly rather than emitted corrupted —
    # callers pass such values as their own quoted env args outside the
    # substitution (e.g. _NESTED_X_BEFORE="$x_before").
    local _parts=() _var _val
    _mcss_emit_env() {
        # $1=name $2=value → appends to _parts, or warns+skips if word-unsafe
        if [[ "$2" == *[[:space:]\'\"\\]* ]]; then
            echo "[runtime_context] WARNING: mcss_exec_env_string refused $1 (value not word-safe: '$2') — pass it as a quoted env arg at the call site" >&2
            return 1
        fi
        _parts+=("$1=$2")
    }
    for _var in "${_canonical[@]}"; do
        if [[ -n "${!_var:-}" ]]; then
            _mcss_emit_env "$_var" "${!_var}" || true
        fi
    done
    # Extras (e.g. MCSS_NESTED_SESSION=plasma) override or extend; caller
    # values win by coming last on the env line. Empty extra values emit NAME=
    # (env sets the variable to empty, which is what a caller passing X= wants).
    local _extra
    for _extra in "$@"; do
        _mcss_emit_env "${_extra%%=*}" "${_extra#*=}" || true
    done
    echo "${_parts[*]}"
}
