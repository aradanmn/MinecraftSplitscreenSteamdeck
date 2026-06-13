#!/bin/bash
# =============================================================================
# Hardware Test Helper Library
# =============================================================================
# Sourced by all stage scripts. Provides logging, assertions, operator prompts,
# diagnostic dumps, and orchestrator lifecycle helpers.
#
# Expected exported variables (set by run_all.sh before sourcing):
#   HW_LOG            — path to the master log file
#   REPO_ROOT         — absolute path to the repo
#   HW_PASSED         — running pass counter (integer)
#   HW_FAILED         — running fail counter (integer)
#   HW_SKIPPED        — running skip counter (integer)
#   SPLITSCREEN_STATE — path to state JSON file
#   SPLITSCREEN_FIFO  — path to orchestrator FIFO
# =============================================================================

# Guard against double-sourcing
[[ -n "${_HW_HELPERS_LOADED:-}" ]] && return 0
readonly _HW_HELPERS_LOADED=1

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# hw_log: timestamp + message → stdout + logfile
hw_log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[${ts}] $*"
    echo "$msg" | tee -a "${HW_LOG:-/dev/stderr}"
}

# hw_info: [INFO] prefix
hw_info() {
    hw_log "[INFO] $*"
}

# hw_warn: [WARN] prefix
hw_warn() {
    hw_log "[WARN] $*"
}

# hw_section: section header with === delimiters
hw_section() {
    local line="============================================================"
    hw_log "$line"
    hw_log "  $*"
    hw_log "$line"
}

# ---------------------------------------------------------------------------
# Test result counters
# ---------------------------------------------------------------------------

# hw_pass: print [PASS] and increment counter
hw_pass() {
    hw_log "[PASS] $*"
    HW_PASSED=$(( ${HW_PASSED:-0} + 1 ))
}

# hw_fail: print [FAIL] and increment counter
hw_fail() {
    hw_log "[FAIL] $*"
    HW_FAILED=$(( ${HW_FAILED:-0} + 1 ))
}

# hw_skip: print [SKIP] and increment counter
hw_skip() {
    hw_log "[SKIP] $*"
    HW_SKIPPED=$(( ${HW_SKIPPED:-0} + 1 ))
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# hw_assert_eq LABEL EXPECTED ACTUAL
hw_assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        hw_pass "${label} — expected=${expected} actual=${actual}"
    else
        hw_fail "${label} — expected=\"${expected}\" actual=\"${actual}\""
    fi
}

# hw_assert_match LABEL REGEX ACTUAL
hw_assert_match() {
    local label="$1"
    local regex="$2"
    local actual="$3"
    if [[ "$actual" =~ $regex ]]; then
        hw_pass "${label} — matched /${regex}/ in \"${actual}\""
    else
        hw_fail "${label} — \"${actual}\" did not match /${regex}/"
    fi
}

# hw_assert_nonempty LABEL VALUE
hw_assert_nonempty() {
    local label="$1"
    local value="$2"
    if [[ -n "$value" ]]; then
        hw_pass "${label} — value is non-empty"
    else
        hw_fail "${label} — value is EMPTY (expected non-empty)"
    fi
}

# hw_assert_empty LABEL VALUE
hw_assert_empty() {
    local label="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        hw_pass "${label} — value is empty (as expected)"
    else
        hw_fail "${label} — expected empty, got \"${value}\""
    fi
}

# hw_assert_cmd LABEL COMMAND...
# Passes if COMMAND exits 0, fails otherwise.
hw_assert_cmd() {
    local label="$1"
    shift
    hw_log "Running: $*"
    local rc=0
    "$@" >> "${HW_LOG:-/dev/stderr}" 2>&1 || rc=$?
    if (( rc == 0 )); then
        hw_pass "${label} — command exited 0"
    else
        hw_fail "${label} — command exited ${rc}"
    fi
}

# ---------------------------------------------------------------------------
# Operator prompt
# ---------------------------------------------------------------------------

# hw_prompt ACTION_DESCRIPTION
# Prints what the operator needs to do, waits for Enter.
# Returns 1 if operator types 'skip', 0 otherwise.
hw_prompt() {
    local action="$1"
    echo "" | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log ">>> OPERATOR ACTION REQUIRED <<<"
    hw_log ">>> ${action}"
    hw_log ">>> Press Enter when done, or type 'skip' and Enter to skip this step."
    echo "" | tee -a "${HW_LOG:-/dev/stderr}"

    local response
    if ! read -r response 2>/dev/null; then
        hw_warn "hw_prompt: stdin closed, treating as skip"
        return 1
    fi
    hw_log ">>> Operator response: \"${response}\""

    if [[ "${response,,}" == "skip" ]]; then
        return 1
    fi
    return 0
}

# hw_confirm QUESTION
# Asks a yes/no question. Returns 0 for yes, 1 for no/skip.
hw_confirm() {
    local question="$1"
    echo "" | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log ">>> CONFIRM: ${question} [y/N]"

    local response
    if ! read -r response 2>/dev/null; then
        hw_warn "hw_confirm: stdin closed, treating as no"
        return 1
    fi
    hw_log ">>> Operator confirmed: \"${response}\""

    if [[ "${response,,}" =~ ^y ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Diagnostic dumps
# ---------------------------------------------------------------------------

# hw_dump_state: jq-pretty-print the state file
hw_dump_state() {
    hw_log "--- STATE FILE DUMP: ${SPLITSCREEN_STATE} ---"
    if [[ -f "${SPLITSCREEN_STATE:-}" ]]; then
        jq '.' "${SPLITSCREEN_STATE}" 2>&1 | tee -a "${HW_LOG:-/dev/stderr}"
    else
        hw_log "(state file does not exist)"
    fi
    hw_log "--- END STATE DUMP ---"
}

# hw_dump_processes: pgrep -af for bwrap/PolyMC/latestUpdate
hw_dump_processes() {
    hw_log "--- PROCESS DUMP ---"
    {
        echo "[bwrap processes]"
        pgrep -af 'bwrap' 2>/dev/null || echo "  <none>"
        echo "[PolyMC/latestUpdate processes]"
        pgrep -af 'PolyMC\.AppImage|latestUpdate' 2>/dev/null || echo "  <none>"
        echo "[java processes]"
        pgrep -af 'java.*latestUpdate' 2>/dev/null || echo "  <none>"
    } | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log "--- END PROCESS DUMP ---"
}

# hw_dump_input_devices: cat /proc/bus/input/devices filtered to 28de:11ff
hw_dump_input_devices() {
    hw_log "--- INPUT DEVICES (28de:11ff) ---"
    {
        awk '
            /^$/ { in_block=0; vendor=""; product="" }
            /Vendor=28de/ { vendor="28de" }
            /Product=11ff/ { product="11ff" }
            { if (!in_block) { block="" }; block=block"\n"$0; in_block=1 }
            /^$/ { if (vendor=="28de" && product=="11ff") print block }
        ' /proc/bus/input/devices 2>/dev/null || echo "  <unable to read /proc/bus/input/devices>"
    } | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log "--- END INPUT DEVICES ---"
}

# ---------------------------------------------------------------------------
# Wait for condition
# ---------------------------------------------------------------------------

# hw_wait_for LABEL TIMEOUT_S COMMAND...
# Polls COMMAND every 1s. hw_pass if exits 0 within TIMEOUT_S, hw_fail otherwise.
# Does NOT abort on timeout — returns 1 so caller can continue.
hw_wait_for() {
    local label="$1"
    local timeout_s="$2"
    shift 2
    local cmd=("$@")

    hw_log "Waiting up to ${timeout_s}s for: ${label}"
    hw_log "  Check command: ${cmd[*]}"

    local elapsed=0
    while (( elapsed < timeout_s )); do
        local rc=0
        "${cmd[@]}" >> "${HW_LOG:-/dev/stderr}" 2>&1 || rc=$?
        if (( rc == 0 )); then
            hw_pass "${label} (after ${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    hw_fail "${label} — timed out after ${timeout_s}s"
    return 1
}

# ---------------------------------------------------------------------------
# Display environment
# ---------------------------------------------------------------------------

# hw_detect_display: set/export DISPLAY if not already set, for xdotool/xrandr
hw_detect_display() {
    if [[ -n "${DISPLAY:-}" ]]; then
        hw_info "DISPLAY already set: ${DISPLAY}"
        return 0
    fi

    # Try common values
    local candidate
    for candidate in :0 :1 :0.0; do
        if DISPLAY="$candidate" xdotool getactivewindow >/dev/null 2>&1; then
            export DISPLAY="$candidate"
            hw_info "Auto-detected DISPLAY=${DISPLAY}"
            return 0
        fi
    done

    # Fallback: parse Xauthority
    local auth_display
    auth_display=$(who 2>/dev/null | grep -oP ':\d+' | head -1 || true)
    if [[ -n "$auth_display" ]]; then
        export DISPLAY="$auth_display"
        hw_info "DISPLAY set from who output: ${DISPLAY}"
        return 0
    fi

    # Last resort fallback
    export DISPLAY=":0"
    hw_warn "Could not auto-detect DISPLAY, defaulting to :0"
    return 0
}

# ---------------------------------------------------------------------------
# Orchestrator lifecycle
# ---------------------------------------------------------------------------

# HW_ORCH_PID — exported PID of the running orchestrator
HW_ORCH_PID=""

# hw_launch_orchestrator MODE
# Launches minecraftSplitscreen.sh launchFromPlasma with SPLITSCREEN_MODE set.
# Waits up to 5s for FIFO to appear. Exports HW_ORCH_PID.
hw_launch_orchestrator() {
    local mode="${1:-}"
    if [[ "$mode" != "handheld" && "$mode" != "docked" ]]; then
        hw_fail "hw_launch_orchestrator: invalid mode '${mode}' (must be handheld or docked)"
        return 1
    fi

    local orch_log="${HW_LOG}.orch"
    hw_info "Launching orchestrator in ${mode} mode (log: ${orch_log})"
    hw_info "Running: SPLITSCREEN_MODE=${mode} bash ${REPO_ROOT}/minecraftSplitscreen.sh launchFromPlasma"

    SPLITSCREEN_MODE="$mode" \
    bash "${REPO_ROOT}/minecraftSplitscreen.sh" launchFromPlasma \
        >> "$orch_log" 2>&1 &
    HW_ORCH_PID=$!
    export HW_ORCH_PID

    hw_info "Orchestrator started with PID ${HW_ORCH_PID}"

    # Wait up to 5s for FIFO to appear
    local elapsed=0
    while (( elapsed < 5 )); do
        if [[ -p "${SPLITSCREEN_FIFO:-}" ]]; then
            hw_info "FIFO appeared after ${elapsed}s: ${SPLITSCREEN_FIFO}"
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    hw_warn "FIFO did not appear within 5s — orchestrator may still be starting"
    return 0
}

# hw_stop_orchestrator: send SIGTERM to the orchestrator and wait for it to exit
hw_stop_orchestrator() {
    if [[ -z "${HW_ORCH_PID:-}" ]]; then
        hw_warn "hw_stop_orchestrator: HW_ORCH_PID is not set"
        return 0
    fi

    hw_info "Stopping orchestrator PID ${HW_ORCH_PID}"

    if kill -0 "${HW_ORCH_PID}" 2>/dev/null; then
        kill "${HW_ORCH_PID}" 2>/dev/null || true
        local elapsed=0
        while (( elapsed < 15 )); do
            if ! kill -0 "${HW_ORCH_PID}" 2>/dev/null; then
                hw_info "Orchestrator exited after ${elapsed}s"
                HW_ORCH_PID=""
                return 0
            fi
            sleep 1
            elapsed=$(( elapsed + 1 ))
        done
        hw_warn "Orchestrator did not exit within 15s — sending SIGKILL"
        kill -9 "${HW_ORCH_PID}" 2>/dev/null || true
    else
        hw_info "Orchestrator PID ${HW_ORCH_PID} already exited"
    fi
    HW_ORCH_PID=""
    return 0
}
