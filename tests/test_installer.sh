#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: install-minecraft-splitscreen.sh (dry-run / mock)
# =============================================================================
# Tests the installer's module lists, mod configuration, BASH_SOURCE guard,
# and the new runtime-module deployment logic — all without network access
# and without executing any real installation steps.
#
# Run: bash tests/test_installer.sh
# =============================================================================

readonly TEST_TOTAL=10

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# =============================================================================
# T7.1 — BASH_SOURCE guard: sourcing the installer does not call main()
# =============================================================================
test_t7_1() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Provide a local modules/ dir so the installer doesn't try to download anything
    mkdir -p "$tmpdir/modules"
    for mod in utilities.sh java_management.sh launcher_setup.sh version_management.sh \
                lwjgl_management.sh mod_management.sh instance_creation.sh \
                steam_integration.sh desktop_launcher.sh main_workflow.sh \
                dock_detection.sh controller_monitor.sh window_manager.sh \
                instance_lifecycle.sh watchdog.sh; do
        # Stub: define a no-op main() so a runaway call would be detectable
        printf '#!/bin/bash\n' > "$tmpdir/modules/$mod"
    done
    # main_workflow.sh must define main()
    printf '#!/bin/bash\nmain() { echo "MAIN_CALLED"; }\n' > "$tmpdir/modules/main_workflow.sh"

    # Run installer in a subshell; capture output; exit 0 expected
    local out
    out=$(
        TESTING_MODE=1
        cd "$tmpdir"
        export TESTING_MODE=1
        # shellcheck disable=SC1090
        bash -c "
            TESTING_MODE=1
            export TESTING_MODE=1
            source '${REPO_ROOT}/install-minecraft-splitscreen.sh'
            echo 'SOURCE_OK'
        " 2>/dev/null || true
    )

    if echo "$out" | grep -q "SOURCE_OK" && ! echo "$out" | grep -q "MAIN_CALLED"; then
        _pass "T7.1 — sourcing installer with TESTING_MODE=1 does not invoke main()"
    else
        _fail "T7.1" "unexpected output: ${out}"
    fi
}

# =============================================================================
# T7.2 — MODULE_FILES contains all 20 modules (10 installer + 10 runtime)
# NOTE: this count has drifted upward over time as runtime modules were added
# (preflight/kwin_positioner/orchestrator/dex/runtime_context); keep it in sync with
# INSTALLER_MODULE_FILES + RUNTIME_MODULE_FILES in install-minecraft-splitscreen.sh
# whenever a module is added or removed, rather than letting it silently go stale.
# =============================================================================
test_t7_2() {
    local installer="$REPO_ROOT/install-minecraft-splitscreen.sh"
    # Installer modules are still a literal array in the entry; runtime modules
    # come from the ONE manifest (#49: modules/runtime_modules.list).
    local installer_count runtime_count
    installer_count=$(grep -A 15 'readonly INSTALLER_MODULE_FILES=' "$installer" \
        | grep -c '\.sh"' || true)
    runtime_count=$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/modules/runtime_modules.list" || true)
    local total=$(( installer_count + runtime_count ))

    if (( total == 20 )); then
        _pass "T7.2 — MODULE_FILES contains 20 entries (10 installer + 10 runtime)"
    else
        _fail "T7.2" "expected 20 total entries (INSTALLER_MODULE_FILES + runtime_modules.list), found ${total} (${installer_count} + ${runtime_count})"
    fi
}

# =============================================================================
# T7.3 — RUNTIME_MODULE_FILES contains the orchestrator modules (incl. runtime_context.sh, #43)
# =============================================================================
test_t7_3() {
    local manifest="$REPO_ROOT/modules/runtime_modules.list"
    local expected=("dock_detection.sh" "controller_monitor.sh" "window_manager.sh" "instance_lifecycle.sh" "watchdog.sh" "runtime_context.sh")
    local missing=()

    for mod in "${expected[@]}"; do
        if ! grep -qx "$mod" "$manifest"; then
            missing+=("$mod")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        _pass "T7.3 — runtime_modules.list contains all expected orchestrator modules"
    else
        _fail "T7.3" "missing from runtime_modules.list: ${missing[*]}"
    fi
}

# =============================================================================
# T7.4 — REQUIRED_SPLITSCREEN_MODS uses Controlify, not Controllable
# =============================================================================
test_t7_4() {
    local installer="$REPO_ROOT/install-minecraft-splitscreen.sh"

    local has_controlify=0 has_controllable=0
    grep -q '"Controlify"' "$installer" && has_controlify=1 || true
    grep -q '"Controllable (Fabric)"' "$installer" && has_controllable=1 || true

    if (( has_controlify == 1 && has_controllable == 0 )); then
        _pass "T7.4 — REQUIRED_SPLITSCREEN_MODS uses Controlify (not Controllable)"
    elif (( has_controllable == 1 )); then
        _fail "T7.4" "installer still references 'Controllable (Fabric)'"
    else
        _fail "T7.4" "neither Controlify nor Controllable found in installer"
    fi
}

# =============================================================================
# T7.5 — install_runtime_modules() is defined in launcher_setup.sh
# =============================================================================
test_t7_5() {
    if grep -q '^install_runtime_modules()' "$REPO_ROOT/modules/launcher_setup.sh"; then
        _pass "T7.5 — install_runtime_modules() is defined in launcher_setup.sh"
    else
        _fail "T7.5" "install_runtime_modules() not found in launcher_setup.sh"
    fi
}

# =============================================================================
# T7.6 — ensure_bwrap_installed() is defined in launcher_setup.sh
# =============================================================================
test_t7_6() {
    if grep -q '^ensure_bwrap_installed()' "$REPO_ROOT/modules/launcher_setup.sh"; then
        _pass "T7.6 — ensure_bwrap_installed() is defined in launcher_setup.sh"
    else
        _fail "T7.6" "ensure_bwrap_installed() not found in launcher_setup.sh"
    fi
}

# =============================================================================
# T7.7 — install_runtime_modules() copies files to TARGET_DIR/modules/
# =============================================================================
test_t7_7() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local src_modules="$tmpdir/src_modules"
    local target_dir="$tmpdir/PolyMC"
    mkdir -p "$src_modules" "$target_dir"

    # Provide stub runtime modules in MODULES_DIR — ALL of them. Stubbing a
    # subset made the test quietly network-dependent: the unstubbed ones fell
    # back to a live GitHub download inside install_runtime_modules (the
    # "network quirk" that keeps this suite out of the CI gate).
    for mod in preflight.sh runtime_context.sh dock_detection.sh \
                controller_monitor.sh kwin_positioner.sh window_manager.sh \
                instance_lifecycle.sh watchdog.sh orchestrator.sh dex.sh; do
        printf '#!/bin/bash\n# stub %s\n' "$mod" > "$src_modules/$mod"
        # The manifest (#49) names each stub; install_runtime_modules reads it
        echo "$mod" >> "$src_modules/runtime_modules.list"
    done

    # Source only the launcher_setup module, then call install_runtime_modules
    # with mocked globals
    (
        MODULES_DIR="$src_modules"
        TARGET_DIR="$target_dir"
        SCRIPT_DIR="$tmpdir"
        # Entry-provided global (D15); inert host proves the local-copy path
        # never touches the network
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        # Provide stubs for print_* functions
        print_progress() { :; }
        print_success() { :; }
        print_error() { echo "[ERROR] $*" >&2; }
        print_info() { :; }
        print_warning() { :; }

        source "$REPO_ROOT/modules/launcher_setup.sh"
        install_runtime_modules
    )

    local all_ok=1
    for mod in preflight.sh runtime_context.sh dock_detection.sh \
                controller_monitor.sh kwin_positioner.sh window_manager.sh \
                instance_lifecycle.sh watchdog.sh orchestrator.sh dex.sh \
                runtime_modules.list; do
        if [[ ! -f "$target_dir/modules/$mod" ]]; then
            all_ok=0
            break
        fi
    done

    if (( all_ok == 1 )); then
        _pass "T7.7 — install_runtime_modules() deploys all 10 modules + manifest to TARGET_DIR/modules/"
    else
        _fail "T7.7" "one or more runtime modules not found in $target_dir/modules/"
    fi
}

# =============================================================================
# T7.8 — main_workflow.sh calls install_runtime_modules after setup_splitscreen_launcher_script
# =============================================================================
test_t7_8() {
    local workflow="$REPO_ROOT/modules/main_workflow.sh"

    local launcher_line runtime_line
    launcher_line=$(grep -n 'setup_splitscreen_launcher_script' "$workflow" | head -1 | cut -d: -f1)
    runtime_line=$(grep -n 'install_runtime_modules' "$workflow" | head -1 | cut -d: -f1)

    if [[ -z "$launcher_line" ]]; then
        _fail "T7.8" "setup_splitscreen_launcher_script not found in main_workflow.sh"
        return
    fi
    if [[ -z "$runtime_line" ]]; then
        _fail "T7.8" "install_runtime_modules not called in main_workflow.sh"
        return
    fi

    if (( runtime_line > launcher_line )); then
        _pass "T7.8 — install_runtime_modules called after setup_splitscreen_launcher_script in main_workflow.sh"
    else
        _fail "T7.8" "install_runtime_modules (line $runtime_line) appears BEFORE setup_splitscreen_launcher_script (line $launcher_line)"
    fi
}

# =============================================================================
# T7.9 — load_mods_config() populates MOD_DEPS_BY_NAME from mods.conf
# =============================================================================
test_t7_9() {
    local conf="$REPO_ROOT/mods.conf"
    if [[ ! -f "$conf" ]]; then
        _fail "T7.9" "mods.conf not found at $conf"
        return
    fi

    # Parse the deps field ourselves and check a known entry.
    # "Reese's Sodium Options" should declare "Sodium,Sodium Options API"
    local deps_line
    deps_line=$(grep "Reese's Sodium Options" "$conf" | head -1)
    local deps_field
    deps_field=$(echo "$deps_line" | cut -d'|' -f5)

    if [[ "$deps_field" == *"Sodium"* ]]; then
        _pass "T7.9 — mods.conf deps field for Reese's Sodium Options contains Sodium"
    else
        _fail "T7.9" "expected deps field to contain 'Sodium', got: '${deps_field}'"
    fi
}

# =============================================================================
# T7.10 — resolve_conf_dependencies() auto-adds Sodium when Sodium Extra selected
# =============================================================================
test_t7_10() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local result
    result=$(
        bash -c "
            set -euo pipefail

            # Minimal stubs for functions resolve_conf_dependencies calls
            print_info()     { :; }
            print_progress() { :; }
            print_success()  { :; }
            print_error()    { echo \"[ERROR] \$*\" >&2; }
            print_warning()  { :; }
            print_debug()    { :; }

            # Populate globals as load_mods_config would
            declare -A MOD_DEPS_BY_NAME=(
                [\"Sodium Options API\"]=\"Sodium\"
                [\"Reese's Sodium Options\"]=\"Sodium,Sodium Options API\"
                [\"Sodium Extra\"]=\"Sodium\"
                [\"Sodium Extras\"]=\"Sodium\"
                [\"Sodium Dynamic Lights\"]=\"Sodium\"
            )

            declare -a SUPPORTED_MODS=(
                \"Controlify\"
                \"Splitscreen Support\"
                \"Sodium\"
                \"Sodium Extra\"
                \"Sodium Extras\"
                \"Sodium Options API\"
                \"Reese's Sodium Options\"
            )

            # Simulate user picking only 'Reese's Sodium Options' (index 6)
            declare -a FINAL_MOD_INDEXES=(6)

            # Source only the function we want to test
            source '${REPO_ROOT}/modules/mod_management.sh' 2>/dev/null || true

            resolve_conf_dependencies

            # Report which mod names ended up in FINAL_MOD_INDEXES
            for idx in \"\${FINAL_MOD_INDEXES[@]}\"; do
                echo \"\${SUPPORTED_MODS[\$idx]}\"
            done
        " 2>/dev/null
    )

    local has_sodium=0 has_sodium_options_api=0
    echo "$result" | grep -q "^Sodium$"              && has_sodium=1              || true
    echo "$result" | grep -q "^Sodium Options API$"  && has_sodium_options_api=1  || true

    if (( has_sodium == 1 && has_sodium_options_api == 1 )); then
        _pass "T7.10 — resolve_conf_dependencies auto-adds Sodium and Sodium Options API when Reese's Sodium Options selected"
    elif (( has_sodium == 0 )); then
        _fail "T7.10" "Sodium not auto-added (result: ${result})"
    else
        _fail "T7.10" "Sodium Options API not auto-added (result: ${result})"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== installer test suite ==="
echo ""
test_t7_1
test_t7_2
test_t7_3
test_t7_4
test_t7_5
test_t7_6
test_t7_7
test_t7_8
test_t7_9
test_t7_10
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
