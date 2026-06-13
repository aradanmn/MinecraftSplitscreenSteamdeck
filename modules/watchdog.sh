#!/bin/bash
set -euo pipefail

# =============================================================================
# WATCHDOG MODULE
# =============================================================================
# Polls $SPLITSCREEN_STATE on a fixed interval. For each slot marked
# active: true, checks whether its bwrap_pid is still a live process
# (kill -0). If the process is gone, emits SLOT_DIED <slot> to
# $SPLITSCREEN_FIFO. Deduplicates: emits at most once per death;
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

                if [[ -n "$bwrap_pid" ]]; then
                    # Check if process is alive
                    if ! kill -0 "$bwrap_pid" 2>/dev/null; then
                        if [[ -z "${_WATCHDOG_REPORTED[$slot]:-}" ]]; then
                            echo "[watchdog] Slot $slot bwrap PID $bwrap_pid gone → SLOT_DIED" >&2
                            echo "SLOT_DIED $slot" >> "$fifo"
                            _WATCHDOG_REPORTED[$slot]=1
                        fi
                    fi
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
