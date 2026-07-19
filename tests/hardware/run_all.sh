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
  bash run_all.sh              Run all stages (0-5) in order.
  bash run_all.sh <stage>      Run only one stage: its full file name
                                (e.g. stage2_handheld) or a short form
                                (e.g. stage2) that resolves via glob to
                                the one matching stage*.sh file. An
                                unmatched or ambiguous short form is a
                                hard error — never a silent no-op.
  bash run_all.sh --help       Print this help.

Stages (full name / short form):
  stage0_prereqs   / stage0    Prerequisites check (automated)
  stage0b_install  / stage0b   Full installer verification (operator +
                                automated) — run before stage1
  stage1_modules   / stage1    Module smoke tests (automated)
  stage2_handheld  / stage2    Handheld mode (operator prompts)
  stage3_hotplug   / stage3    Docked hot-plug (operator prompts)
  stage4_isolation / stage4    Controller isolation verification
  stage5_crash     / stage5    Crash recovery (mostly automated)

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
hw_log "  Host: ${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
hw_log "  Repo: ${REPO_ROOT}"
hw_log "============================================================"

hw_detect_display

# ---------------------------------------------------------------------------
# Deploy-freshness gate (issue #54): git pull is not a deploy. The launcher
# runs from ~/.local/share/PolyMC/, and testing a stale deployed tree has
# produced false results twice. Refuse to run stages against drift.
# Override (e.g. when stage0b is about to run the full installer anyway):
#   HW_SKIP_FRESHNESS=1 bash run_all.sh ...
# ---------------------------------------------------------------------------
if [[ "${HW_SKIP_FRESHNESS:-0}" != "1" ]]; then
    if [[ -x "$REPO_ROOT/deploy.sh" ]]; then
        hw_log "Checking deployed tree freshness (deploy.sh --check)..."
        if ! "$REPO_ROOT/deploy.sh" --check 2>&1 | tee -a "$HW_LOG"; then
            hw_log ""
            hw_log "ABORT: deployed tree is stale — run $REPO_ROOT/deploy.sh first,"
            hw_log "       or set HW_SKIP_FRESHNESS=1 to run against it anyway."
            exit 1
        fi
    else
        hw_warn "deploy.sh not found in repo root — skipping freshness check"
    fi
fi

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
        # HW-1 (2026-07-18): a short arg like "stage2" doesn't match any
        # file exactly (the real file is stage2_handheld.sh). This used
        # to just WARN and `return 0` — a silent no-op that let the suite
        # print an all-zero GRAND TOTAL as if it had passed (happened
        # twice live). Resolve short names by globbing instead; only an
        # unambiguous single match is trusted.
        local -a matches
        matches=("$SCRIPT_DIR/${stage_name}"*.sh)
        if [[ ${#matches[@]} -eq 1 && -f "${matches[0]}" ]]; then
            stage_file="${matches[0]}"
            stage_name="$(basename "$stage_file" .sh)"
            hw_log "Resolved stage arg to: ${stage_name}"
        else
            hw_log ""
            hw_log "ABORT: '${1}' does not match exactly one stage file."
            hw_log "Available stages:"
            local f
            for f in "$SCRIPT_DIR"/stage*.sh; do
                hw_log "  $(basename "$f" .sh)"
            done
            exit 1
        fi
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
