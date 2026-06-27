#!/bin/bash
set -euo pipefail

# =============================================================================
# Minecraft Splitscreen Hardware Test Suite — Master Runner
# =============================================================================
# Usage:
#   bash run_all.sh              # run all stages 0–5
#   bash run_all.sh stage2       # run only stage 2
#   bash run_all.sh --help       # print usage
#
# All output is logged to ~/splitscreen-hwtest-TIMESTAMP.log
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'USAGE'
Usage:
  bash run_all.sh              Run all stages (0–5) in order.
  bash run_all.sh stage<N>     Run only the specified stage (e.g. stage2).
  bash run_all.sh --help       Print this help.

Stages:
  stage0   Prerequisites check (automated)
  stage0b  Full installer verification (operator + automated) — run before stage1
  stage1   Module smoke tests (automated)
  stage2   Handheld mode (operator prompts)
  stage3   Docked hot-plug (operator prompts)
  stage4   Controller isolation verification
  stage5   Crash recovery (mostly automated)

Environment:
  DISPLAY      X display to use (auto-detected if not set)
USAGE
    exit 0
fi

# --- Log file ---
export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"

# --- Exported variables ---
export REPO_ROOT
export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
export HW_PASSED=0
export HW_FAILED=0
export HW_SKIPPED=0

# Source helpers
source "$SCRIPT_DIR/lib/helpers.sh"

# --- Banner ---
hw_section "Minecraft Splitscreen Hardware Test Suite"
hw_log "  Log:  ${HW_LOG}"
hw_log "  Date: $(date)"
hw_log "  Host: $(hostname)"
hw_log "  Repo: ${REPO_ROOT}"
hw_log "============================================================"

hw_detect_display

# ---------------------------------------------------------------------------
# Stage runner helpers
# ---------------------------------------------------------------------------

_stage_passed=0
_stage_failed=0
_stage_skipped=0

_reset_stage_counters() {
    _stage_passed="$HW_PASSED"
    _stage_failed="$HW_FAILED"
    _stage_skipped="$HW_SKIPPED"
}

_print_stage_summary() {
    local stage_name="$1"
    local p=$(( HW_PASSED  - _stage_passed  ))
    local f=$(( HW_FAILED  - _stage_failed  ))
    local s=$(( HW_SKIPPED - _stage_skipped ))
    hw_log ""
    hw_log "--- Stage summary: ${stage_name} — ${p} passed, ${f} failed, ${s} skipped ---"
    hw_log ""
}

run_stage() {
    local stage_name="$1"
    local stage_file="$SCRIPT_DIR/${stage_name}.sh"

    if [[ ! -f "$stage_file" ]]; then
        hw_warn "Stage file not found: ${stage_file} — skipping"
        return 0
    fi

    _reset_stage_counters
    hw_section "Running ${stage_name}"

    # Each stage script defines a run_<stagename>() function and we call it.
    # We source rather than exec so counters stay in scope.
    # shellcheck source=/dev/null
    source "$stage_file"

    local fn_name
    fn_name="run_${stage_name//-/_}"   # e.g. stage0_prereqs → run_stage0_prereqs
    # Fallback: some stages use the file basename without suffix
    if ! declare -f "$fn_name" >/dev/null 2>&1; then
        fn_name="run_${stage_name%%.*}"
    fi

    if declare -f "$fn_name" >/dev/null 2>&1; then
        "$fn_name" || true
    else
        hw_warn "No entry-point function '${fn_name}' found in ${stage_file}"
    fi

    _print_stage_summary "$stage_name"
}

# ---------------------------------------------------------------------------
# Determine which stages to run
# ---------------------------------------------------------------------------

SINGLE_STAGE="${1:-}"

if [[ -n "$SINGLE_STAGE" ]]; then
    # Run only the specified stage
    run_stage "$SINGLE_STAGE"
else
    # Run all stages in order; abort on stage0 failure
    run_stage "stage0_prereqs"

    if (( HW_FAILED > 0 )); then
        hw_log ""
        hw_log "ABORT: Prerequisites failed — fix above errors before running hardware tests"
        hw_log "Log file: ${HW_LOG}"
        exit 1
    fi

    run_stage "stage0b_install"
    run_stage "stage1_modules"
    run_stage "stage2_handheld"
    run_stage "stage3_hotplug"
    run_stage "stage4_isolation"
    run_stage "stage5_crash"
fi

# ---------------------------------------------------------------------------
# Grand total
# ---------------------------------------------------------------------------
hw_log ""
hw_section "GRAND TOTAL"
hw_log "  Passed:  ${HW_PASSED}"
hw_log "  Failed:  ${HW_FAILED}"
hw_log "  Skipped: ${HW_SKIPPED}"
hw_log "  Log:     ${HW_LOG}"
hw_log "============================================================"

if (( HW_FAILED > 0 )); then
    exit 1
fi
exit 0
