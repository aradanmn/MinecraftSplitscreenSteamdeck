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
# Public API:
#   start_watchdog()  — blocks; polls state file, writes SLOT_DIED to FIFO
#
# Environment overrides:
#   WATCHDOG_POLL_INTERVAL_S  — override poll interval (default: 2s)
# =============================================================================

readonly WATCHDOG_DEFAULT_POLL_INTERVAL_S=2
readonly WATCHDOG_MAX_SLOT=4

# Dedup cache: key=slot, value=1 if SLOT_DIED already emitted
declare -A _WATCHDOG_REPORTED

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
            local active
            active=$(jq -r ".slots[\"$slot\"].active // false" "$state_file" 2>/dev/null || echo "false")

            if [[ "$active" == "true" ]]; then
                local bwrap_pid
                bwrap_pid=$(jq -r ".slots[\"$slot\"].bwrap_pid // empty" "$state_file" 2>/dev/null || true)
                local java_pid
                java_pid=$(jq -r ".slots[\"$slot\"].pid // empty" "$state_file" 2>/dev/null || true)

                local dead=false
                local reason=""

                # Check bwrap (launcher) PID
                if [[ -n "$bwrap_pid" ]] && ! kill -0 "$bwrap_pid" 2>/dev/null; then
                    dead=true
                    reason="bwrap PID $bwrap_pid"
                fi

                # Check Java (game) PID — game may have exited leaving launcher open
                if [[ -n "$java_pid" ]] && ! kill -0 "$java_pid" 2>/dev/null; then
                    dead=true
                    reason="Java PID $java_pid"
                fi

                if $dead && [[ -z "${_WATCHDOG_REPORTED[$slot]:-}" ]]; then
                    echo "[watchdog] Slot $slot $reason gone → SLOT_DIED" >&2
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
            fi
        done
    done
}
