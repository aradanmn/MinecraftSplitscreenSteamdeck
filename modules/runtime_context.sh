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
