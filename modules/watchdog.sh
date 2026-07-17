#!/bin/bash
set -euo pipefail

# =============================================================================
# WATCHDOG MODULE
# =============================================================================
# Polls $SPLITSCREEN_STATE on a fixed interval. For each slot marked
# active: true, checks whether its bwrap_pid and/or java_pid (pid) are
# still live processes (kill -0). If either is gone, emits SLOT_DIED <slot>
# to $SPLITSCREEN_FIFO. Deduplicates: emits at most once per death;
# stops suppressing once the orchestrator clears the slot (active: false).
#
# ALSO (#37): treats a slot whose game WINDOW has been destroyed as dead, even
# if its process is still alive. A player who quits in-game destroys the window
# but the JVM may then hang in shutdown (Bug B) — the kill -0 check above would
# never fire, leaving a black screen. Window-gone → SLOT_DIED → teardown_instance
# force-kills the hung process. Only acts on a CONFIRMED-absent window (debounced),
# and skips when it can't tell (no wid yet / dex unavailable) so it never kills a
# launching or unverifiable instance.
#
# Dependencies (sourced earlier per runtime_modules.list):
#   instance_lifecycle.sh — state accessors (_get_slot_field, get_bwrap_pid,
#   get_java_pid, get_window_id); #51/D11 retired this module's raw jq copies.
#
# Public API:
#   start_watchdog()  — blocks; polls state file, writes SLOT_DIED to FIFO
#
# Environment overrides:
#   WATCHDOG_POLL_INTERVAL_S  — override poll interval (default: 2s)
# =============================================================================

readonly WATCHDOG_DEFAULT_POLL_INTERVAL_S=2
# Fix #86: named from MCSS_MAX_PLAYERS, not a bare "4" (#86 item d). watchdog.sh
# does not source runtime_context.sh itself (grandfathered — relies on ambient
# sourcing by the launcher), so the ${:-4} fallback stays for standalone use.
readonly WATCHDOG_MAX_SLOT="${MCSS_MAX_PLAYERS:-4}"
# Consecutive polls a slot's window must be CONFIRMED absent before declaring the
# player quit (debounce against a transient/partial window-tree query). ~2 polls = ~4s.
readonly WATCHDOG_WINDOW_GONE_TICKS="${WATCHDOG_WINDOW_GONE_TICKS:-2}"

# Dedup cache: key=slot, value=1 if SLOT_DIED already emitted
declare -A _WATCHDOG_REPORTED
# Window-gone debounce: key=slot, value=consecutive polls the window has been absent.
declare -A _WATCHDOG_WINDOW_GONE_COUNT

# _watchdog_window_present <wid>
# Is window <wid> still in the live window tree?
#   0 = present · 1 = CONFIRMED absent (window destroyed) · 2 = can't tell (skip, don't kill)
# Uses dex_list_windows (a full recursive XQueryTree walk — sees override-redirect windows
# too). Returns 2 (not 1) whenever the check itself is unavailable/empty, so an X hiccup or
# a missing dex/DISPLAY never escalates to a teardown.
_watchdog_window_present() {
    local wid="$1"
    [[ -z "$wid" || "$wid" == "null" ]] && return 2
    type dex_list_windows >/dev/null 2>&1 || return 2
    local listing
    listing=$(dex_list_windows 2>/dev/null) || return 2
    [[ -z "$listing" ]] && return 2   # empty enumeration = query problem, not "gone"
    awk '{print $1}' <<<"$listing" | grep -qx -- "$wid" && return 0
    return 1
}

start_watchdog() {
    local poll_interval="${WATCHDOG_POLL_INTERVAL_S:-$WATCHDOG_DEFAULT_POLL_INTERVAL_S}"
    local state_file="${SPLITSCREEN_STATE:-}"
    local fifo="${SPLITSCREEN_FIFO:-}"

    if [[ -z "$state_file" ]]; then
        echo "[watchdog] ERROR: SPLITSCREEN_STATE is not set" >&2
        return 1
    fi
    if [[ -z "$fifo" ]]; then
        echo "[watchdog] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    echo "[watchdog] Starting watchdog (poll interval: ${poll_interval}s)" >&2

    # L1: exit cleanly on TERM/INT so cleanup()'s TERM (before its KILL) reaps us
    # without needing the force-kill.
    trap 'exit 0' TERM INT

    while true; do
        sleep "$poll_interval"

        if [[ ! -f "$state_file" ]]; then
            continue
        fi

        local slot
        for slot in $(seq 1 "$WATCHDOG_MAX_SLOT"); do
            # Fix #51 (D11): consume the instance_lifecycle accessors instead
            # of private raw-jq copies of the state schema.
            local active
            active=$(_get_slot_field "$slot" active false || echo "false")

            if [[ "$active" == "true" ]]; then
                local bwrap_pid
                bwrap_pid=$(get_bwrap_pid "$slot" || true)
                local java_pid
                java_pid=$(get_java_pid "$slot" || true)

                local dead=false
                local reason=""

                # Check bwrap (launcher) PID
                if [[ -n "$bwrap_pid" ]] && ! kill -0 "$bwrap_pid" 2>/dev/null; then
                    dead=true
                    reason="bwrap PID $bwrap_pid gone"
                fi

                # Check Java (game) PID — game may have exited leaving launcher open
                if [[ -n "$java_pid" ]] && ! kill -0 "$java_pid" 2>/dev/null; then
                    dead=true
                    reason="Java PID $java_pid gone"
                fi

                # Window-gone (#37): if the process still looks alive, check whether the
                # game window was destroyed (player quit, even if the JVM is now hung).
                # Debounced; skips while wid is null (mid-spawn) or unverifiable.
                if ! $dead; then
                    local wid
                    wid=$(get_window_id "$slot" || true)
                    if [[ -n "$wid" ]]; then
                        local wp=0
                        _watchdog_window_present "$wid" || wp=$?
                        if (( wp == 0 )); then
                            _WATCHDOG_WINDOW_GONE_COUNT[$slot]=0
                        elif (( wp == 1 )); then
                            local gc=$(( ${_WATCHDOG_WINDOW_GONE_COUNT[$slot]:-0} + 1 ))
                            _WATCHDOG_WINDOW_GONE_COUNT[$slot]=$gc
                            echo "[watchdog] Slot $slot window $wid absent (${gc}/${WATCHDOG_WINDOW_GONE_TICKS})" >&2
                            if (( gc >= WATCHDOG_WINDOW_GONE_TICKS )); then
                                dead=true
                                reason="window $wid gone (player quit)"
                            fi
                        fi
                        # wp == 2: can't tell — leave the counter alone, do not escalate.
                    fi
                fi

                if $dead && [[ -z "${_WATCHDOG_REPORTED[$slot]:-}" ]]; then
                    echo "[watchdog] Slot $slot $reason → SLOT_DIED" >&2
                    # H6: tolerate a broken pipe (orchestrator closed the read end) —
                    # a failed FIFO write under `set -e` would otherwise kill the watchdog.
                    echo "SLOT_DIED $slot" >> "$fifo" || true
                    _WATCHDOG_REPORTED[$slot]=1
                fi
            else
                # Slot is inactive — clear dedup cache so it can be monitored again on reuse
                if [[ -n "${_WATCHDOG_REPORTED[$slot]:-}" ]]; then
                    echo "[watchdog] Slot $slot reset (active=false), clearing dedup cache" >&2
                    unset '_WATCHDOG_REPORTED[$slot]'
                fi
                [[ -n "${_WATCHDOG_WINDOW_GONE_COUNT[$slot]:-}" ]] && unset '_WATCHDOG_WINDOW_GONE_COUNT[$slot]'
            fi
        done
    done
}
