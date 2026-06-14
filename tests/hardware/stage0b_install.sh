#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 0b: Full Installer Verification
# =============================================================================
# Runs the actual install-minecraft-splitscreen.sh on real hardware and then
# verifies every artifact the installer is supposed to create.
#
# IMPORTANT: This stage MUST be run before the other hardware stages.
# It is idempotent — re-running the installer over an existing installation
# is safe (PolyMC AppImage presence check skips re-download).
#
# Automated checks:
#   - Installer exits 0
#   - TARGET_DIR/minecraftSplitscreen.sh installed and executable
#   - TARGET_DIR/modules/ contains all 5 runtime modules
#   - All runtime modules pass bash -n syntax check
#   - bwrap is available after installer completes
#   - PolyMC AppImage present and executable
#   - 4 instance directories exist
#
# Human-in-loop checks:
#   - Installer output looks correct (no unexpected errors)
#   - Mod selection completed without issues
#
# Run standalone:
#   bash tests/hardware/stage0b_install.sh
# =============================================================================

_STAGE0B_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [[ -z "${HW_LOG:-}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"
    export REPO_ROOT="$(cd "$_STAGE0B_SCRIPT_DIR/../.." && pwd)"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0
    export HW_FAILED=0
    export HW_SKIPPED=0
fi

source "$_STAGE0B_SCRIPT_DIR/lib/helpers.sh"

# ---------------------------------------------------------------------------
run_stage0b_install() {
    hw_section "Stage 0b: Full Installer Verification"

    local target_dir="$HOME/.local/share/PolyMC"
    local installer="$REPO_ROOT/install-minecraft-splitscreen.sh"
    local runtime_mods=(
        "dock_detection.sh"
        "controller_monitor.sh"
        "window_manager.sh"
        "instance_lifecycle.sh"
        "watchdog.sh"
    )

    # -----------------------------------------------------------------------
    # I0b.1 — Verify installer script is present and syntactically valid
    # -----------------------------------------------------------------------
    hw_info "I0b.1 — Verifying installer script"
    hw_log "Installer path: ${installer}"

    if [[ ! -f "$installer" ]]; then
        hw_fail "I0b.1 installer script NOT FOUND: ${installer}"
        hw_log "ABORT: Cannot continue without installer"
        return 1
    fi
    hw_pass "I0b.1 installer script exists"

    local bash_n_out
    bash_n_out=$(bash -n "$installer" 2>&1 || true)
    if bash -n "$installer" 2>/dev/null; then
        hw_pass "I0b.1 installer passes bash -n syntax check"
    else
        hw_fail "I0b.1 installer FAILED syntax check: ${bash_n_out}"
        return 1
    fi

    # -----------------------------------------------------------------------
    # I0b.2 — Syntax check all 15 module files in repo
    # -----------------------------------------------------------------------
    hw_info "I0b.2 — Syntax checking all modules in repo"
    local all_mods_ok=1
    for mod in "$REPO_ROOT/modules/"*.sh; do
        local mod_name
        mod_name=$(basename "$mod")
        local mod_err
        mod_err=$(bash -n "$mod" 2>&1 || true)
        if bash -n "$mod" 2>/dev/null; then
            hw_pass "I0b.2 modules/${mod_name} syntax OK"
        else
            hw_fail "I0b.2 modules/${mod_name} FAILED syntax: ${mod_err}"
            all_mods_ok=0
        fi
    done
    (( all_mods_ok == 1 )) && hw_info "All module files pass bash -n"

    # -----------------------------------------------------------------------
    # I0b.3 — Run the installer (operator confirms prompts)
    # -----------------------------------------------------------------------
    hw_info "I0b.3 — Running installer"
    hw_log "Command: bash ${installer}"

    if ! hw_prompt "The installer will now run interactively.
  You will be asked about mod selection, Steam integration, and desktop launcher.
  Answer the prompts as you normally would.
  When the installer finishes (success or failure), press Enter here.
  Press Enter to launch the installer now (or type 'skip' to skip this stage)."; then
        hw_skip "Stage 0b skipped by operator"
        return 0
    fi

    local install_exit=0
    bash "$installer" 2>&1 | tee -a "${HW_LOG}" || install_exit=$?
    hw_log "Installer exit code: ${install_exit}"

    if (( install_exit == 0 )); then
        hw_pass "I0b.3 installer exited 0"
    else
        hw_fail "I0b.3 installer exited ${install_exit}"
        hw_info "Check ${HW_LOG} for details. Continuing with artifact verification..."
    fi

    # -----------------------------------------------------------------------
    # I0b.4 — Orchestrator deployed to TARGET_DIR
    # -----------------------------------------------------------------------
    hw_info "I0b.4 — Verifying orchestrator deployment"
    local orch="$target_dir/minecraftSplitscreen.sh"
    hw_log "Expected: ${orch}"
    if [[ -f "$orch" && -x "$orch" ]]; then
        hw_pass "I0b.4 orchestrator deployed and executable: ${orch}"
    elif [[ -f "$orch" ]]; then
        hw_fail "I0b.4 orchestrator deployed but NOT executable: ${orch}"
    else
        hw_fail "I0b.4 orchestrator NOT deployed: ${orch}"
    fi

    # -----------------------------------------------------------------------
    # I0b.5 — Runtime modules deployed to TARGET_DIR/modules/
    # -----------------------------------------------------------------------
    hw_info "I0b.5 — Verifying runtime module deployment"
    local modules_dir="$target_dir/modules"
    hw_log "Expected modules dir: ${modules_dir}"

    if [[ -d "$modules_dir" ]]; then
        hw_pass "I0b.5 runtime modules directory exists: ${modules_dir}"
    else
        hw_fail "I0b.5 runtime modules directory MISSING: ${modules_dir}"
    fi

    for mod in "${runtime_mods[@]}"; do
        local mod_path="$modules_dir/$mod"
        if [[ -f "$mod_path" ]]; then
            local mod_err
            mod_err=$(bash -n "$mod_path" 2>&1 || true)
            if bash -n "$mod_path" 2>/dev/null; then
                hw_pass "I0b.5 runtime module OK: ${mod}"
            else
                hw_fail "I0b.5 runtime module syntax error: ${mod}: ${mod_err}"
            fi
        else
            hw_fail "I0b.5 runtime module MISSING: ${mod_path}"
        fi
    done

    # -----------------------------------------------------------------------
    # I0b.6 — bwrap available after install
    # -----------------------------------------------------------------------
    hw_info "I0b.6 — Verifying bwrap availability"
    if command -v bwrap >/dev/null 2>&1; then
        hw_pass "I0b.6 bwrap available: $(command -v bwrap)"
    else
        hw_fail "I0b.6 bwrap NOT available after install"
        hw_info "Install manually: sudo pacman -S bubblewrap"
    fi

    # -----------------------------------------------------------------------
    # I0b.7 — PolyMC AppImage deployed
    # -----------------------------------------------------------------------
    hw_info "I0b.7 — Verifying PolyMC AppImage"
    local appimage="$target_dir/PolyMC.AppImage"
    if [[ -f "$appimage" && -x "$appimage" ]]; then
        hw_pass "I0b.7 PolyMC AppImage present and executable"
    elif [[ -f "$appimage" ]]; then
        hw_fail "I0b.7 PolyMC AppImage present but NOT executable"
    else
        hw_fail "I0b.7 PolyMC AppImage NOT found: ${appimage}"
    fi

    # -----------------------------------------------------------------------
    # I0b.8 — 4 instance directories created
    # -----------------------------------------------------------------------
    hw_info "I0b.8 — Verifying 4 Minecraft instance directories"
    local instance_ok=1
    for n in 1 2 3 4; do
        local idir="$target_dir/instances/latestUpdate-${n}"
        if [[ -d "$idir" ]]; then
            hw_pass "I0b.8 instance dir exists: latestUpdate-${n}"
        else
            hw_fail "I0b.8 instance dir MISSING: ${idir}"
            instance_ok=0
        fi
    done
    (( instance_ok == 1 )) && hw_info "All 4 instance directories present"

    # -----------------------------------------------------------------------
    # I0b.9 — Post-install smoke test: source orchestrator, verify key functions
    # -----------------------------------------------------------------------
    hw_info "I0b.9 — Post-install smoke test: source orchestrator"

    local smoke_out
    smoke_out=$(
        cd "$target_dir"
        bash -c "
            # Stub functions that the orchestrator calls at source time indirectly
            detectLauncher() { return 0; }
            selfUpdate() { return 0; }
            isSteamDeckGameMode() { return 1; }
            get_display_mode() { echo handheld; }
            source '$orch' 2>&1 || echo SMOKE_FAIL
        " 2>&1 || true
    )
    hw_log "Smoke test output: ${smoke_out}"

    if echo "$smoke_out" | grep -q "SMOKE_FAIL"; then
        hw_fail "I0b.9 orchestrator failed to source from TARGET_DIR: ${smoke_out}"
    else
        # Check that key functions are available after sourcing
        local funcs_ok=1
        for fn in handheld_flow docked_flow start_watchdog spawn_instance teardown_instance \
                  get_display_mode list_eligible_controllers apply_layout; do
            if ! bash -c "
                detectLauncher() { return 0; }
                selfUpdate() { return 0; }
                isSteamDeckGameMode() { return 1; }
                get_display_mode() { echo handheld; }
                source '$orch' 2>/dev/null
                declare -f $fn >/dev/null 2>&1
            "; then
                hw_fail "I0b.9 function not defined after source: ${fn}"
                funcs_ok=0
            fi
        done
        (( funcs_ok == 1 )) && hw_pass "I0b.9 orchestrator sources cleanly; all key functions defined"
    fi

    # -----------------------------------------------------------------------
    # I0b.10 — Operator confirms installer output looked correct
    # -----------------------------------------------------------------------
    hw_info "I0b.10 — Operator confirmation"
    if hw_prompt "Review the installer output above (also in ${HW_LOG}).
  Did the installer complete without unexpected errors?"; then
        hw_pass "I0b.10 operator confirmed installer output looks correct"
    else
        hw_fail "I0b.10 operator reported installer output had unexpected errors"
    fi

    hw_info "Stage 0b complete."
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage0b_install
fi
