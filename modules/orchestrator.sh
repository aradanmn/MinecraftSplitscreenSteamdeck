#!/bin/bash
set -euo pipefail

# =============================================================================
# ORCHESTRATOR MODULE
# =============================================================================
# Main event-loop that reads from SPLITSCREEN_FIFO and dispatches to
# the existing handler modules (controller_monitor, instance_lifecycle,
# window_manager, watchdog, dock_detection).
#
# Architecture:
#   controller_monitor → FIFO → orchestrator → spawn_instance / teardown_instance
#   watchdog           → FIFO → orchestrator → teardown_instance (on SLOT_DIED)
#   dock_detection     → FIFO → orchestrator → switch handheld/docked mode
#
# Public API:
#   handheld_flow()   — Blocks; event loop for handheld (1 slot, Deck controls only)
#   docked_flow()     — Blocks; event loop for docked (up to 4 slots, external controllers)
#   main()            — Detects mode (handheld/docked), runs the correct flow
#   cleanup()         — Stops watchdog, tears down all instances, restores panels
#
# Dependencies:
#   dock_detection.sh, controller_monitor.sh, instance_lifecycle.sh,
#   window_manager.sh, watchdog.sh
# =============================================================================

# ── Module-level constants ───────────────────────────────────────────────────
readonly ORCHESTRATOR_MAX_SLOTS=4
readonly ORCHESTRATOR_SPAWN_DELAY_S=3
# FIFO read timeout — also the cadence of the per-iteration liveness reap (H9).
readonly ORCHESTRATOR_FIFO_READ_TIMEOUT_S=5
# docked_flow: number of consecutive empty (zero active slots) loop iterations to tolerate
# AFTER at least one player has joined before ending the session. Gives a short grace
# (~ticks × FIFO read timeout) so a disconnect-then-reconnect doesn't kill the session.
readonly ORCHESTRATOR_EMPTY_EXIT_TICKS=2
# docked_flow startup: poll this long for already-connected controllers before handing
# off to the hotplug monitor. A short window (not a single one-shot scan) because Steam
# Input creates its 28de:11ff virtual pads with a delay and staggered. If NONE appear in
# this window, docked has no player (can't play on the built-in pad) → clean exit.
readonly ORCHESTRATOR_CONTROLLER_ACQUIRE_TIMEOUT_S=5

# PID tracking for background workers
_WATCHDOG_PID=""
_CONTROLLER_MONITOR_PID=""
_DOCK_MONITOR_PID=""
# N2: PIDs of backgrounded spawn_instance brace groups. _handle_msg appends here so
# cleanup() can kill any orphan spawn subshell that would otherwise keep polling for
# a window (up to 120s) and map it AFTER teardown.
_SPAWN_PIDS=()
# H10: set by _reflow_layout on failure; the event loop retries while this is 1.
_REFLOW_NEEDED=0

# =============================================================================
# HELPER: read a single message from the FIFO
# Handles the named pipe in non-blocking mode with a timeout,
# so we can also check PID aliveness in the loop.
# =============================================================================
_read_fifo_msg() {
    local fifo="${SPLITSCREEN_FIFO:-}"
    local timeout_s="${1:-5}"
    [[ -z "$fifo" ]] && return 1
    [[ -p "$fifo" ]] || return 1

    # Open the FIFO read-WRITE (<>) rather than read-only (<).  A read-only open
    # of a FIFO blocks in open() until some process opens the write end — and that
    # block happens BEFORE `read -t` starts counting, so a read-only open with no
    # writer present hangs forever (the -t timeout never engages).  This was the
    # root cause of orchestrator iterations wedging permanently and piling up
    # hung subshells.  Opening read-write keeps a writer reference on this fd, so
    # open() returns immediately and the -t timeout governs the wait as intended.
    IFS= read -r -t "$timeout_s" msg <> "$fifo" 2>/dev/null || return 1
    echo "$msg"
    return 0
}

# =============================================================================
# HELPER: get the current mode from SPLITSCREEN_STATE
# =============================================================================
_get_mode() {
    local state="$SPLITSCREEN_STATE"
    jq -r '.mode // "docked"' "$state" 2>/dev/null || echo "docked"
}

# =============================================================================
# HELPER: set the mode in SPLITSCREEN_STATE
# =============================================================================
_set_mode() {
    local mode="$1"
    local state="$SPLITSCREEN_STATE"
    # #40 (fixes a regression from the H3/L2 flock change, 2026-06-27): the flock version
    # below hard `exit 1`s (inside a `set -e` subshell) whenever the state file is missing
    # or unparseable — e.g. main() invoked without going through launchProdFromPlasma's
    # state-file init. Under `set -e` that killed the WHOLE launcher on first call. The
    # original was tolerant (`jq ... || true`); restore that tolerance while KEEPING the H3
    # lock/unique-temp fix: initialize a default state file if it's missing/invalid instead
    # of failing, so _set_mode can never be the thing that crashes a legitimate launch.
    # #50: derived from the SAME single-resolved state path as every other site
    # (use-time, not source-time: tests legitimately re-point SPLITSCREEN_STATE
    # after modules load, and the lock must follow the file actually locked).
    local lock_file="${state}.lock"
    (
        flock -w 5 9 || { echo "[orchestrator] WARNING: state lock timeout in _set_mode — skipping" >&2; exit 0; }
        if [[ ! -f "$state" ]] || ! jq -e . "$state" >/dev/null 2>&1; then
            echo "[orchestrator] _set_mode: state file missing/invalid at $state — initializing default" >&2
            _atomic_write "$state" '{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null}}}'
        fi
        local updated
        updated=$(jq --arg mode "$mode" '.mode = $mode' "$state" 2>/dev/null) || { echo "[orchestrator] WARNING: _set_mode jq failed — leaving state untouched" >&2; exit 0; }
        _atomic_write "$state" "$updated"
    ) 9>"$lock_file"
}

# =============================================================================
# HELPER: find the first free slot (1–ORCHESTRATOR_MAX_SLOTS)
# Returns slot number on stdout, empty string if all slots full
# =============================================================================
_find_free_slot() {
    for slot in $(seq 1 "$ORCHESTRATOR_MAX_SLOTS"); do
        if ! slot_is_active "$slot" 2>/dev/null; then
            echo "$slot"
            return 0
        fi
    done
    return 1
}

# =============================================================================
# HELPER: map a removed controller's event node back to the active slot it owns.
# controller_monitor emits "CONTROLLER_REMOVE <event_node>" (a /dev/input/event*
# path), so the remove handler must look the slot up by that node — it is NOT a
# slot number. Returns the slot on stdout, empty if no active slot owns the node.
# =============================================================================
_find_slot_by_event_node() {
    local node="$1"
    local state="$SPLITSCREEN_STATE"
    [[ -n "$node" && -f "$state" ]] || return 0
    jq -r --arg n "$node" \
        'first(.slots | to_entries[] | select(.value.active == true and .value.event_node == $n) | .key) // empty' \
        "$state" 2>/dev/null
}

# =============================================================================
# HELPER: collect (event_node, js_node) pairs for every ACTIVE slot OTHER than
# the given one, for bwrap controller masking. Emits one "<event> <js>" line per
# such slot, using the literal "null" for an unset field. _build_bwrap_command's
# `-e` guard skips non-existent / "null" paths, and always emitting BOTH fields
# keeps the (event, js) pairing aligned for its 2-fields-at-a-time consumer.
# =============================================================================
_collect_mask_pairs() {
    local current="$1"
    local state="$SPLITSCREEN_STATE"
    [[ -f "$state" ]] || return 0
    jq -r --arg cur "$current" \
        '.slots | to_entries[]
         | select(.value.active == true and .key != $cur)
         | "\(.value.event_node // "null") \(.value.js_node // "null")"' \
        "$state" 2>/dev/null
}

# =============================================================================
# HELPER: compute and persist the reflowed layout for all active slots
# Writes new kwinrulesrc and calls sync_apply_layout to reposition windows.
# =============================================================================
_reflow_layout() {
    local active
    active=$(get_active_slots)
    [[ -z "$active" ]] && return 0

    # M4: robust dimension parse. The old `awk $2 | cut` chain returned empty (not the
    # fallback) when xdpyinfo was missing or its format differed, because the pipe's
    # exit status came from `cut` succeeding on empty input. Parse with sed, then
    # validate each is an integer and fall back otherwise.
    local ruleW ruleH dims
    dims=$(xdpyinfo 2>/dev/null | sed -n 's/.*dimensions:[[:space:]]*\([0-9]\+x[0-9]\+\).*/\1/p' | head -1)
    ruleW="${dims%x*}"
    ruleH="${dims#*x}"
    [[ "$ruleW" =~ ^[0-9]+$ ]] || ruleW=1280
    [[ "$ruleH" =~ ^[0-9]+$ ]] || ruleH=800

    # Reflow via the window manager.
    # NOTE: stderr is intentionally NOT suppressed (was `2>/dev/null`).  The
    # window-positioning diagnostics ("[window_manager] Repositioning…", dex
    # strategy + geometry readback) are essential for debugging reflow failures
    # such as a window being left unmapped — discarding them made the slot-1
    # unmap bug invisible in the debug log.
    # H10: surface a reflow failure (return non-zero) instead of swallowing it with
    # `|| true`. Setting _REFLOW_NEEDED lets the event loop actually RETRY it on the
    # next iteration (~ORCHESTRATOR_FIFO_READ_TIMEOUT_S cadence) instead of just logging
    # once and leaving the layout wrong until the next unrelated reflow trigger — the
    # retry that was "advertised" (per the comment history) but never implemented.
    if ! sync_apply_layout "$active" "$ruleW" "$ruleH"; then
        echo "[orchestrator] WARNING: reflow (sync_apply_layout) failed for slots: $active" >&2
        _REFLOW_NEEDED=1
        return 1
    fi
    _REFLOW_NEEDED=0
    return 0
}

# =============================================================================
# _check_monitor_heartbeats — H9. The watchdog/controller_monitor/dock_monitor
# background PIDs feed the FIFO; previously, if one died silently (crash, unhandled
# error) nothing noticed — the session just stopped reacting to that class of event
# (e.g. controller_monitor dying means a newly-connected pad never spawns a player)
# with no diagnostic and no recovery. Called once per event-loop iteration in BOTH
# flows: log + best-effort restart any monitor whose PID we expect to be running but
# isn't. Not rate-limited beyond the FIFO read-timeout cadence (~5s) — a monitor that
# repeatedly dies immediately is a real bug worth being loud about, not silent.
# =============================================================================
_check_monitor_heartbeats() {
    if [[ -n "$_CONTROLLER_MONITOR_PID" ]] && ! kill -0 "$_CONTROLLER_MONITOR_PID" 2>/dev/null; then
        echo "[orchestrator] WARNING: controller monitor (PID $_CONTROLLER_MONITOR_PID) is dead — restarting" >&2
        if type start_controller_monitor >/dev/null 2>&1; then
            CONTROLLER_MONITOR_SKIP_INITIAL_EMIT=1 start_controller_monitor "$(_get_mode)" &
            _CONTROLLER_MONITOR_PID=$!
            echo "[orchestrator] Controller monitor restarted — new PID $_CONTROLLER_MONITOR_PID" >&2
        fi
    fi
    if [[ -n "$_DOCK_MONITOR_PID" ]] && ! kill -0 "$_DOCK_MONITOR_PID" 2>/dev/null; then
        echo "[orchestrator] WARNING: dock monitor (PID $_DOCK_MONITOR_PID) is dead — restarting" >&2
        if type watch_display_mode >/dev/null 2>&1; then
            watch_display_mode &
            _DOCK_MONITOR_PID=$!
            echo "[orchestrator] Dock monitor restarted — new PID $_DOCK_MONITOR_PID" >&2
        fi
    fi
    if [[ -n "$_WATCHDOG_PID" ]] && ! kill -0 "$_WATCHDOG_PID" 2>/dev/null; then
        echo "[orchestrator] WARNING: watchdog (PID $_WATCHDOG_PID) is dead — restarting" >&2
        if type start_watchdog >/dev/null 2>&1; then
            start_watchdog &
            _WATCHDOG_PID=$!
            echo "[orchestrator] Watchdog restarted — new PID $_WATCHDOG_PID" >&2
        fi
    fi
}

# =============================================================================
# _reap_dead_slots — orchestrator-side liveness safety net (H9).
# The watchdog normally emits SLOT_DIED, but slot_is_active() only reads the state
# flag, so if the watchdog dies the event loop would spin forever with slots marked
# active long after their processes exited (gamescope stuck on the spinner, never
# returning to Steam). Independently verify each active slot's process and tear down
# any whose bwrap leader + java are both gone. Skips slots still launching (no
# bwrap_pid recorded yet) so it never races spawn_instance.
# =============================================================================
_reap_dead_slots() {
    local active slot
    active=$(get_active_slots)
    [[ -z "$active" ]] && return 0
    for slot in $active; do
        local bwrap_pid java_pid
        bwrap_pid=$(get_bwrap_pid "$slot")
        # No bwrap pid yet → instance is still launching; leave it alone.
        [[ -z "$bwrap_pid" ]] && continue
        kill -0 "$bwrap_pid" 2>/dev/null && continue
        # bwrap leader is dead; confirm java is gone too before reaping.
        java_pid=$(get_java_pid "$slot")
        if [[ -n "$java_pid" ]] && kill -0 "$java_pid" 2>/dev/null; then
            continue
        fi
        echo "[orchestrator] Slot $slot processes gone (watchdog may be down) — reaping" >&2
        teardown_instance "$slot" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
        _reflow_layout || echo "[orchestrator] WARNING: reflow after reap failed (slot $slot)" >&2
    done
}

# =============================================================================
# DISPATCHER: handle a single FIFO message
# Returns 0 if the event loop should continue, 1 if it should exit cleanly
# =============================================================================
_handle_msg() {
    local msg="$1"
    [[ -z "$msg" ]] && return 0

    local msg_type="${msg%% *}"
    local msg_arg="${msg#* }"
    [[ "$msg_type" == "$msg_arg" ]] && msg_arg=""

    case "$msg_type" in
        CONTROLLER_ADD)
            local slot
            slot=$(_find_free_slot)
            if [[ -z "$slot" ]]; then
                echo "[orchestrator] All $ORCHESTRATOR_MAX_SLOTS slots full — ignoring controller add" >&2
                return 0
            fi
            echo "[orchestrator] CONTROLLER_ADD → slot $slot (spawning instance)" >&2

            # Reserve the slot synchronously NOW — before backgrounding spawn_instance,
            # which is what normally marks it active. Without this, a rapid back-to-back
            # CONTROLLER_ADD (the startup acquisition loop, or several pads connecting at
            # once) could have the next _find_free_slot hand out THIS same slot before the
            # backgrounded spawn marks it → two instances on one slot. spawn_instance still
            # writes the full preliminary state (event/js/pid/bwrap) right after.
            update_slot_state "$slot" '{"active": true}'

            # Extract controller fields from the CONTROLLER_ADD arg if provided.
            # Format (controller_monitor emits 4 fields):
            #   "CONTROLLER_ADD /dev/input/eventX /dev/input/jsX <vendor> <product>"
            # The old `${msg_arg#* }` parse took "everything after the first space" as
            # js_node, which polluted it with the trailing vendor/product on the real
            # 4-field message (audit C1). The test harness injected only 2 fields so it
            # never caught this. read -r splits all fields cleanly; trailing vendor/
            # product are captured (unused for now) instead of leaking into js_node.
            # Under CONTROLLER_MONITOR_RAW_BINDING, event_node/js_node are the pad's RAW
            # nodes: spawn_instance binds the jsN into the sandbox and records the eventN
            # as slot identity only (for CONTROLLER_REMOVE matching) — the eventN is NOT
            # bound. The docked producer is js-gated, so it ALWAYS emits BOTH event and js
            # (never a js-less line), which makes the event==js sentinel below and
            # spawn_instance's js-empty branch docked-UNREACHABLE under the flag. We keep
            # them for the handheld/legacy paths and do NOT thread a vendor arg (that would
            # collide with the variadic mask-pair tail).
            local event_node="" js_node="" phys_vendor="" phys_product=""
            if [[ -n "$msg_arg" ]]; then
                read -r event_node js_node phys_vendor phys_product <<< "$msg_arg"
                # Single-arg form sentinel: monitor sets js_node==event_node when there
                # is no distinct js node — blank it so spawn_instance skips the js bind.
                [[ "$event_node" == "$js_node" ]] && js_node=""
            fi

            # ── Controller isolation ──────────────────────────────────────────
            # Mask every OTHER active slot's controller nodes inside this sandbox
            # so only THIS player's pad reaches this instance. The masking itself
            # lives in _build_bwrap_command (--bind /dev/null per node); here we
            # collect the other active slots' (event_node, js_node) pairs from the
            # state file and forward them as trailing args to spawn_instance.
            # Non-existent / "null" paths are skipped by the builder's -e guard, and
            # SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1 is already set per-slot.
            # NOTE (pre-existing limitation): bwrap mounts are fixed at launch, so a
            # slot that spawned earlier cannot retroactively mask a later joiner —
            # isolation is strongest for the most-recently-joined player. Full
            # symmetric isolation would require re-spawning earlier slots.
            local -a _mask_pairs=()
            local _mp_ev _mp_js
            while read -r _mp_ev _mp_js; do
                [[ -z "$_mp_ev" ]] && continue
                _mask_pairs+=("$_mp_ev" "$_mp_js")
            done < <(_collect_mask_pairs "$slot")

            # Run spawn_instance in the background so the FIFO event loop is
            # never blocked — spawn_instance polls for java+window for up to
            # 120s, and any SLOT_DIED fired while it runs must be processed
            # immediately (not after a 2-minute wait).
            local _slot="$slot" _en="$event_node" _jn="$js_node"
            {
                # M1: mktemp can fail (full /tmp) → empty path. M2: this brace group runs
                # in a backgrounded subshell, so an EXIT trap reaps the temp even if the
                # subshell is signalled. Fall back to streaming directly if mktemp fails.
                local _si_log _si_rc
                _si_log=$(mktemp "${TMPDIR:-/tmp}/spawn_instance_slot${_slot}_XXXXXX.log") || _si_log=""
                trap '[[ -n "$_si_log" ]] && rm -f "$_si_log"' EXIT
                # N1: capture spawn_instance's REAL exit status (the old `|| true` swallowed
                # it). On failure the slot was reserved active:true above but never gets a
                # bwrap_pid, so _reap_dead_slots skips it forever ("still launching") and one
                # of the 4 slots is permanently dead. Clear the reservation to free the slot.
                if [[ -n "$_si_log" ]]; then
                    spawn_instance "$_slot" "$_en" "$_jn" "${_mask_pairs[@]}" >"$_si_log" 2>&1
                    _si_rc=$?
                    sed 's/^/[orchestrator] /' < "$_si_log" >&2
                else
                    spawn_instance "$_slot" "$_en" "$_jn" "${_mask_pairs[@]}" 2>&1 | sed 's/^/[orchestrator] /' >&2
                    _si_rc=${PIPESTATUS[0]}
                fi
                if (( _si_rc != 0 )); then
                    echo "[orchestrator] spawn_instance failed for slot $_slot — slot released" >&2
                    update_slot_state "$_slot" '{"active": false, "pid": null, "bwrap_pid": null, "event_node": null, "js_node": null, "wid": null}'
                else
                    sleep "$ORCHESTRATOR_SPAWN_DELAY_S"
                    _reflow_layout || echo "[orchestrator] WARNING: post-spawn reflow failed (slot $_slot)" >&2
                fi
            } &
            # N2: track the spawn subshell so cleanup() can kill it on teardown.
            _SPAWN_PIDS+=($!)
            ;;

        CONTROLLER_REMOVE)
            # #37: a controller disconnect (dead battery / idle power-off) is NOT "the
            # player is done." Tearing the instance down here would kill a player
            # mid-session and, if they host the LAN world, end it for everyone. So we
            # PRESERVE the instance and do NOT reflow. Player-leave is instead detected
            # from the game WINDOW being destroyed (watchdog window-gone → SLOT_DIED).
            # bwrap mounts are fixed at launch, so a controller returning as a new node
            # can't be live-rebound in v1 — but the instance/world survives the dropout.
            #
            # HONEST DISCLOSURE (pre-existing defect, UNCHANGED here, OUT OF SCOPE): this
            # deliberate no-op means a reused-eventN fast-flap, or a jsN that vanishes with
            # NO udev remove (driver crash / USB autosuspend), leaves a STILL-ALIVE zombie
            # slot that neither _reap_dead_slots (the bwrap leader is still up) nor
            # window-death ever reaps — leaking 1 of 4 slots. This is IDENTICAL under the
            # old virtual path and under raw binding; it is NOT claimed fixed. Tracked
            # follow-up for the real fix: on a detected replacement, RELAUNCH the SAME slot
            # (teardown_instance then respawn with the new node), since v1 bwrap mounts
            # cannot be live-rebound.
            #
            # Format-aware (kept for the log): controller_monitor emits the removed
            # device's EVENT NODE ("CONTROLLER_REMOVE /dev/input/eventX"); the test
            # harness may pass a bare slot number. Resolve both to name the slot.
            local slot=""
            if [[ "$msg_arg" =~ ^[1-9][0-9]*$ ]]; then
                slot="$msg_arg"                                   # explicit slot number
            elif [[ -n "$msg_arg" ]]; then
                slot=$(_find_slot_by_event_node "$msg_arg")       # device-node → slot
            fi
            if [[ -z "$slot" ]] || ! slot_is_active "$slot" 2>/dev/null; then
                echo "[orchestrator] CONTROLLER_REMOVE: no active slot for '$msg_arg' — ignoring" >&2
                return 0
            fi
            echo "[orchestrator] CONTROLLER_REMOVE → slot $slot controller disconnected — instance PRESERVED (no teardown)" >&2
            ;;

        SLOT_DIED)
            local slot="$msg_arg"
            if [[ -z "$slot" ]]; then
                echo "[orchestrator] SLOT_DIED: no slot specified" >&2
                return 0
            fi
            echo "[orchestrator] SLOT_DIED for slot $slot — cleaning up" >&2
            local _td_log
            _td_log=$(mktemp "${TMPDIR:-/tmp}/teardown_slot${slot}_XXXXXX.log") || _td_log=""
            if [[ -n "$_td_log" ]]; then
                teardown_instance "$slot" >"$_td_log" 2>&1 || true
                sed 's/^/[orchestrator] /' < "$_td_log" >&2
                rm -f "$_td_log"
            else
                teardown_instance "$slot" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
            fi
            _reflow_layout || echo "[orchestrator] WARNING: post-SLOT_DIED reflow failed (slot $slot)" >&2
            ;;

        DISPLAY_MODE_CHANGE)
            local new_mode="$msg_arg"
            echo "[orchestrator] DISPLAY_MODE_CHANGE → $new_mode" >&2
            case "$new_mode" in
                docked)
                    echo "[orchestrator] Switching to docked mode (external display detected)" >&2
                    _set_mode "docked"
                    ;;
                handheld)
                    echo "[orchestrator] Switching to handheld mode (built-in display only)" >&2
                    # ── Docked→Handheld guard ────────────────────────────────
                    # Keep slot 1 alive (it's P1 / Deck controls).
                    # Tear down ALL other active slots.
                    # Reflow to single-player layout if P1 remains.
                    local active_slots
                    active_slots=$(get_active_slots)
                    local _s
                    for _s in $active_slots; do
                        if [[ "$_s" != "1" ]]; then
                            echo "[orchestrator] Teardown slot $_s (docked→handheld transition)" >&2
                            teardown_instance "$_s" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
                        fi
                    done

                    _set_mode "handheld"

                    # If slot 1 survived, reflow to fullscreen single-player layout
                    if slot_is_active 1 2>/dev/null; then
                        echo "[orchestrator] Slot 1 survived — reflowing to single-player layout" >&2
                        _reflow_layout
                    fi
                    # Return 1 so the caller can re-enter handheld_flow
                    return 1
                    ;;
            esac
            ;;

        *)
            echo "[orchestrator] Unknown message: $msg" >&2
            ;;
    esac
    return 0
}

# =============================================================================
# handheld_flow
# Event loop for handheld mode.
# - 1 slot only (slot 1)
# - Only the Deck's built-in controls (no external controllers)
# - Spawns slot 1 on entry, exits when it dies
# - On DISPLAY_MODE_CHANGE docked, switches to docked_flow
# =============================================================================
handheld_flow() {
    set +e
    echo "[orchestrator] Starting handheld flow" >&2
    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        echo "[orchestrator] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    # ── Write state: handheld mode
    _set_mode "handheld"

    # ── NO controller monitor in handheld mode (deliberate).
    # Handheld is a single FIXED player on the Deck's built-in controls, which reach the
    # game as the built-in's own Steam 28de:11ff virtual. If we ran the hotplug monitor it
    # would detect that very virtual and emit CONTROLLER_ADD → _handle_msg spawns a DUPLICATE
    # slot 2 (two windows for one player — the handheld bug). One screen ⇒ one player, so
    # there is no controller hotplug to service; dock→handheld/handheld→dock transitions are
    # handled by watch_display_mode below. _CONTROLLER_MONITOR_PID stays empty so cleanup()
    # skips it. (External pads connected while undocked are simply ignored — no second seat.)
    _CONTROLLER_MONITOR_PID=""

    # ── Start dock detection (watch for docked→handheld transitions)
    if type watch_display_mode >/dev/null 2>&1; then
        watch_display_mode &
        _DOCK_MONITOR_PID=$!
        echo "[orchestrator] Dock monitor PID: $_DOCK_MONITOR_PID" >&2
    fi

    # ── Start watchdog (monitor process aliveness)
    if type start_watchdog >/dev/null 2>&1; then
        start_watchdog &
        _WATCHDOG_PID=$!
        echo "[orchestrator] Watchdog PID: $_WATCHDOG_PID" >&2
    fi

    # ── Spawn slot 1 (single player)
    # No controller masking needed — only one instance, one controller.
    echo "[orchestrator] Spawning single instance for handheld mode" >&2
    # N3: docked→handheld keeps slot 1 alive and re-enters handheld_flow; spawning again
    # would double-spawn over the survivor. Only spawn when slot 1 isn't already active.
    if ! slot_is_active 1 2>/dev/null; then
        spawn_instance 1 "" "" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
    else
        echo "[orchestrator] handheld: slot 1 already active — not respawning" >&2
    fi

    # ── Event loop
    while true; do
        # Independent liveness reap (don't rely solely on the watchdog — H9).
        _reap_dead_slots
        _check_monitor_heartbeats

        # Check if the main instance is still alive
        if ! slot_is_active 1 2>/dev/null; then
            echo "[orchestrator] Slot 1 is no longer active — exiting handheld flow" >&2
            break
        fi

        local msg
        if msg=$(_read_fifo_msg "$ORCHESTRATOR_FIFO_READ_TIMEOUT_S"); then
            echo "[orchestrator] FIFO message: $msg" >&2
            _handle_msg "$msg" || break
        fi
    done

    cleanup
}

# =============================================================================
# docked_flow
# Event loop for docked mode (external display connected).
# - Up to 4 slots (1 controller → 4 players max)
# - Controllers mapped to individual slots via bwrap isolation
# - Spawns instances as controllers connect, tears down as they disconnect
# - On DISPLAY_MODE_CHANGE handheld (undock), tears down all and exits
# =============================================================================
docked_flow() {
    set +e
    echo "[orchestrator] Starting docked flow" >&2
    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        echo "[orchestrator] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    # ── Write state: docked mode
    _set_mode "docked"

    # ── Listen for eligible controllers already present at startup
    # If controllers are already plugged in when flow starts, they'll
    # be picked up by the controller_monitor's initial scan → CONTROLLER_ADD.
    # ── Controller isolation note ──────────────────────────────────────
    # The built-in is excluded by ENUMERATION, not by masking: it exposes no raw js
    # gamepad node, so under raw binding (_list_raw_external_pads) it is structurally
    # unselectable, and under the legacy virtual mapper its 28de virtual is never claimed.
    # External controllers are assigned one-per-slot. (The old comment here referenced
    # _identify_internal_virtual_index() + per-sandbox --bind /dev/null masking of the
    # built-in; that function is now DEAD and slated for the deferred cleanup commit, and
    # the cross-slot mask is inert under --dev /dev + js-only binding — see
    # _build_bwrap_command.)
    # ────────────────────────────────────────────────────────────────────

    # ── Startup controller acquisition (the START bookend).
    # Spawn instances for controllers ALREADY connected at launch — the common case in
    # docked mode (you plug pads in, then launch). We poll for a short window rather than
    # a single one-shot scan because Steam Input creates its 28de:11ff virtual pads with a
    # delay and staggered, so one scan races and can miss them ("nothing spawns at start").
    # Each newly-seen controller is dispatched immediately (first one spawns at t=0); the
    # window just catches stragglers. If NONE appear, docked has no player → clean exit
    # (you can't play docked on the built-in pad).
    local -A _acquired=()
    local _aq_t=0 _aq_line _aq_ev
    while (( _aq_t < ORCHESTRATOR_CONTROLLER_ACQUIRE_TIMEOUT_S )); do
        while IFS= read -r _aq_line; do
            [[ -z "$_aq_line" ]] && continue
            _aq_ev=$(echo "$_aq_line" | awk '{print $1}')
            [[ -n "${_acquired[$_aq_ev]:-}" ]] && continue   # dedup across poll iterations
            _acquired[$_aq_ev]=1
            echo "[orchestrator] startup-acquire → CONTROLLER_ADD $_aq_line" >&2
            _handle_msg "CONTROLLER_ADD $_aq_line"
        done < <(list_eligible_controllers docked 2>/dev/null)
        sleep 1
        _aq_t=$((_aq_t + 1))
    done
    if (( ${#_acquired[@]} == 0 )); then
        echo "[orchestrator] No controller within ${ORCHESTRATOR_CONTROLLER_ACQUIRE_TIMEOUT_S}s — docked needs an external controller; exiting to Steam" >&2
        cleanup
        return 0
    fi

    # ── Start controller monitor (HOTPLUG-ONLY: skip its one-shot initial emit since we
    # just acquired the already-connected pads above; it still snapshots the baseline so
    # its udev diff doesn't re-add them → no double-spawn).
    if type start_controller_monitor >/dev/null 2>&1; then
        CONTROLLER_MONITOR_SKIP_INITIAL_EMIT=1 start_controller_monitor docked &
        _CONTROLLER_MONITOR_PID=$!
        echo "[orchestrator] Controller monitor PID: $_CONTROLLER_MONITOR_PID (hotplug-only)" >&2
    fi

    # ── Start dock detection (watch for docked→handheld transitions)
    if type watch_display_mode >/dev/null 2>&1; then
        watch_display_mode &
        _DOCK_MONITOR_PID=$!
        echo "[orchestrator] Dock monitor PID: $_DOCK_MONITOR_PID" >&2
    fi

    # ── Start watchdog (monitor process aliveness for each slot)
    if type start_watchdog >/dev/null 2>&1; then
        start_watchdog &
        _WATCHDOG_PID=$!
        echo "[orchestrator] Watchdog PID: $_WATCHDOG_PID" >&2
    fi

    # ── Event loop
    # Session-end latch (the END bookend). Acquisition above guarantees ≥1 controller, but
    # the spawn it triggers is backgrounded, so the slot may not read active for the first
    # iteration or two — don't exit on a transient empty. Only once a slot has actually
    # read active (had_players) does a sustained return to zero mean "everyone quit → end
    # the session" — mirroring handheld_flow, which exits when its single slot dies. A short
    # grace (ORCHESTRATOR_EMPTY_EXIT_TICKS) also keeps a disconnect-then-reconnect from
    # tearing the session down.
    local had_players=false
    local empty_ticks=0
    while true; do
        local msg
        if msg=$(_read_fifo_msg "$ORCHESTRATOR_FIFO_READ_TIMEOUT_S"); then
            echo "[orchestrator] FIFO message: $msg" >&2
            _handle_msg "$msg" || {
                local exit_code=$?
                echo "[orchestrator] _handle_msg returned $exit_code — switching flow" >&2
                # If 1, DISPLAY_MODE_CHANGE handheld → re-enter handheld_flow
                if (( exit_code == 1 )); then
                    return 1
                fi
                # Otherwise clean exit
                break
            }
        fi

        # Independent liveness reap (don't rely solely on the watchdog — H9).
        _reap_dead_slots
        _check_monitor_heartbeats

        # H10: retry a previously-failed reflow instead of leaving the layout wrong
        # until the next unrelated trigger.
        if [[ "$_REFLOW_NEEDED" == "1" ]]; then
            echo "[orchestrator] Retrying previously-failed reflow" >&2
            _reflow_layout
        fi

        # Session-end check: exit once everyone who joined has quit.
        local active
        active=$(get_active_slots)
        if [[ -n "$active" ]]; then
            had_players=true
            empty_ticks=0
        elif [[ "$had_players" == true ]]; then
            empty_ticks=$((empty_ticks + 1))
            echo "[orchestrator] No active slots after players joined — empty tick ${empty_ticks}/${ORCHESTRATOR_EMPTY_EXIT_TICKS}" >&2
            if (( empty_ticks >= ORCHESTRATOR_EMPTY_EXIT_TICKS )); then
                echo "[orchestrator] All players have quit — ending docked session" >&2
                break
            fi
        fi
        # (Before any player joins, an empty active set is the normal startup state — idle.)
    done

    cleanup
}

# =============================================================================
# main — Entry point: detect mode and run the correct flow
# =============================================================================
main() {
    echo "[orchestrator] main() starting — PID=$$" >&2
    # NOTE (H4): the cleanup trap is installed by the LAUNCHER (launchProdFromPlasma in
    # minecraftSplitscreen.sh), NOT here — main() runs in the launcher's shell, so setting a
    # trap here would CLOBBER the launcher's essential EXIT trap (_restore_session_env +
    # _end_nested_session). The launcher's trap now also calls cleanup() (instance teardown)
    # and fires on INT/TERM/HUP. cleanup() is re-entrancy-guarded.

    # ── Ensure FIFO exists
    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        fifo="/tmp/minecraft-splitscreen.fifo"
        export SPLITSCREEN_FIFO="$fifo"
    fi
    if [[ ! -p "$fifo" ]]; then
        mkfifo "$fifo" 2>/dev/null || true
    fi

    # ── Source all dependent modules
    # The file sourcing this is expected to have already sourced:
    #   dock_detection.sh, controller_monitor.sh, instance_lifecycle.sh,
    #   window_manager.sh, watchdog.sh

    # ── Detect mode
    local display_mode
    if type get_display_mode >/dev/null 2>&1; then
        display_mode=$(get_display_mode)
    elif [[ -n "${SPLITSCREEN_MODE:-}" ]]; then
        display_mode="$SPLITSCREEN_MODE"
    else
        # Default: check if external display is connected via DRM sysfs
        if is_docked 2>/dev/null; then
            display_mode="docked"
        else
            display_mode="handheld"
        fi
    fi

    echo "[orchestrator] Display mode: $display_mode" >&2
    _set_mode "$display_mode"

    # ── Run the appropriate flow
    case "$display_mode" in
        handheld)
            handheld_flow
            ;;
        docked)
            docked_flow || {
                local rc=$?
                if (( rc == 1 )); then
                    echo "[orchestrator] docked_flow requested re-entry as handheld" >&2
                    handheld_flow
                fi
            }
            ;;
        *)
            echo "[orchestrator] Unknown display mode: $display_mode — defaulting to docked" >&2
            docked_flow
            ;;
    esac

    echo "[orchestrator] main() exiting" >&2
}

# =============================================================================
# cleanup — Teardown everything and kill background processes
# =============================================================================
cleanup() {
    # H4 (UNTESTED 2026-06-27): re-entrancy guard. cleanup() now runs from BOTH the
    # end-of-flow path AND the EXIT/signal trap (see main()); without this guard it would
    # double-run — killing already-dead PIDs and tearing down twice.
    [[ -n "${_CLEANUP_DONE:-}" ]] && return 0
    _CLEANUP_DONE=1
    echo "[orchestrator] cleanup() starting" >&2

    # ── Kill watchdog
    if [[ -n "$_WATCHDOG_PID" ]] && kill -0 "$_WATCHDOG_PID" 2>/dev/null; then
        kill -TERM "$_WATCHDOG_PID" 2>/dev/null || true
        sleep 0.5
        kill -KILL "$_WATCHDOG_PID" 2>/dev/null || true
        echo "[orchestrator] Watchdog PID $_WATCHDOG_PID killed" >&2
    fi

    # ── Kill controller monitor
    if [[ -n "$_CONTROLLER_MONITOR_PID" ]] && kill -0 "$_CONTROLLER_MONITOR_PID" 2>/dev/null; then
        kill -TERM "$_CONTROLLER_MONITOR_PID" 2>/dev/null || true
        kill -KILL "$_CONTROLLER_MONITOR_PID" 2>/dev/null || true
        echo "[orchestrator] Controller monitor PID $_CONTROLLER_MONITOR_PID killed" >&2
    fi

    # ── Kill dock monitor
    # N15: watch_display_mode's `inotifywait` is a DIRECT CHILD of this backgrounded
    # function, not something it further backgrounds — killing only the parent PID
    # leaves inotifywait to be reparented (to init) and survive teardown, still holding
    # the FIFO write-end open (which can keep a reader from ever seeing EOF across
    # runs). Kill children first (via _kill_tree if the launcher defined it in this
    # same process — bash sourcing shares the function namespace — else a plain
    # pkill -P fallback), then the parent itself.
    if [[ -n "$_DOCK_MONITOR_PID" ]] && kill -0 "$_DOCK_MONITOR_PID" 2>/dev/null; then
        if type _kill_tree >/dev/null 2>&1; then
            _kill_tree "$_DOCK_MONITOR_PID" TERM
        else
            pkill -TERM -P "$_DOCK_MONITOR_PID" 2>/dev/null || true
        fi
        kill -TERM "$_DOCK_MONITOR_PID" 2>/dev/null || true
        sleep 0.2
        pkill -KILL -P "$_DOCK_MONITOR_PID" 2>/dev/null || true
        kill -KILL "$_DOCK_MONITOR_PID" 2>/dev/null || true
        echo "[orchestrator] Dock monitor PID $_DOCK_MONITOR_PID (+ children) killed" >&2
    fi

    # ── Kill any in-flight spawn subshells (N2)
    # A backgrounded spawn_instance brace group polls for java+window up to 120s; if one
    # is still running at teardown it could map a window AFTER cleanup. Kill them all.
    local _sp
    for _sp in "${_SPAWN_PIDS[@]}"; do
        if [[ -n "$_sp" ]] && kill -0 "$_sp" 2>/dev/null; then
            kill -TERM "$_sp" 2>/dev/null || true
            sleep 0.2
            kill -KILL "$_sp" 2>/dev/null || true
            echo "[orchestrator] Spawn subshell PID $_sp killed" >&2
        fi
    done
    _SPAWN_PIDS=()

    # ── Tear down all instances
    if type teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
    fi

    # ── Restore panels
    if type restorePanels >/dev/null 2>&1; then
        restorePanels 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
    fi

    # M7: dex.sh deliberately does NOT EXIT-trap its own generated backend script (it must
    # survive across many dex_* calls within this one shell — see dex.sh's DEX_PY_SCRIPT
    # comment), and adding a trap there would risk clobbering the caller's own EXIT trap
    # (the exact H4 class of bug). $DEX_PY_SCRIPT is a plain shell var set when dex.sh was
    # sourced into this SAME process, so it's still in scope here — clean it up once, on
    # the way out, from the one place that already owns end-of-session teardown. Matters
    # most for the $XDG_RUNTIME_DIR-unset fallback path (plain /tmp, not an auto-cleaned
    # per-session tmpfs).
    [[ -n "${DEX_PY_SCRIPT:-}" ]] && rm -f "$DEX_PY_SCRIPT" 2>/dev/null

    echo "[orchestrator] cleanup() complete" >&2
}

# ── Guard: only define functions when sourced, run main() when executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
