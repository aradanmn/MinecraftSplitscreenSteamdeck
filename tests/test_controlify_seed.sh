#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: Controlify out_of_focus_input seed + re-assert (#95)
# =============================================================================
# Fix #95: a fresh instance's TRUE first launch used to race Controlify's own
# first-boot default write (out_of_focus_input:false) and lose — instance_
# creation.sh wrote nothing (no config file existed yet) and Controlify's
# default went unchallenged. The fix is belt-and-suspenders:
#   (a) instance_creation.sh seeds config/controlify.json BEFORE first boot
#       (install_fabric_and_mods)
#   (b) instance_lifecycle.sh re-asserts the flag on every spawn regardless
#       (spawn_instance — pre-existing coverage gap; no prior test exercised
#       this write at all)
# This is a dedicated file (not folded into test_instance_lifecycle.sh or
# test_installer.sh) so those suites' pinned regression counts stay untouched.
# Run: bash tests/test_controlify_seed.sh
# =============================================================================

readonly TEST_TOTAL=3

# Fixture PID for the mock pgrep below. spawn_instance stores it as the
# slot's "pid" in the state file; per repo convention (see
# tests/test_orchestrator.sh's guard comments) any fake PID in a fixture
# must exceed kernel.pid_max so it can never resolve to a real (or
# group-killable) process.
readonly FIXTURE_JAVA_PID=4999930

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/modules/utilities.sh"
source "$REPO_ROOT/modules/instance_creation.sh"
# Same order as test_instance_lifecycle.sh: controller_monitor before
# window_manager before instance_lifecycle (D13 dependency chain).
source "$REPO_ROOT/modules/controller_monitor.sh"
source "$REPO_ROOT/modules/window_manager.sh"
source "$REPO_ROOT/modules/instance_lifecycle.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
    echo "[PASS] $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_fail() {
    echo "[FAIL] $1 — $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# =============================================================================
# Test T95.1 — fresh instance (no prior controlify.json): install_fabric_and_
# mods seeds out_of_focus_input=true before first boot
# =============================================================================
test_t95_1() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    MC_VERSION="1.20.4"
    FABRIC_VERSION="0.15.11"
    LWJGL_VERSION="3.3.2"
    TARGET_DIR="$tmpdir"

    local instance_dir="$tmpdir/instances/latestUpdate-2"
    local cfg="$instance_dir/.minecraft/config/controlify.json"

    install_fabric_and_mods "$instance_dir" "latestUpdate-2" "false" \
        >/dev/null 2>&1

    if [[ ! -f "$cfg" ]]; then
        _fail "T95.1" "controlify.json was not created: $cfg"
        return
    fi

    local flag
    flag=$(jq -r '.global.out_of_focus_input' "$cfg" 2>/dev/null || echo "ERR")
    if [[ "$flag" == "true" ]]; then
        _pass "T95.1 — fresh instance seeded with out_of_focus_input=true"
    else
        _fail "T95.1" "expected true, got '$flag' in $(cat "$cfg")"
    fi
}

# =============================================================================
# Test T95.2 — re-install over an EXISTING controlify.json (flag false, other
# keys present): install_fabric_and_mods flips the flag true WITHOUT
# clobbering the rest of the file
# =============================================================================
test_t95_2() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    MC_VERSION="1.20.4"
    FABRIC_VERSION="0.15.11"
    LWJGL_VERSION="3.3.2"
    TARGET_DIR="$tmpdir"

    local instance_dir="$tmpdir/instances/latestUpdate-2"
    local cfg="$instance_dir/.minecraft/config/controlify.json"
    mkdir -p "$(dirname "$cfg")"
    cat > "$cfg" <<'JSON'
{"global":{"out_of_focus_input":false,"showStatusHudElement":true},"version":3}
JSON

    install_fabric_and_mods "$instance_dir" "latestUpdate-2" "false" \
        >/dev/null 2>&1

    local flag other version
    flag=$(jq -r '.global.out_of_focus_input' "$cfg" 2>/dev/null || echo "ERR")
    other=$(jq -r '.global.showStatusHudElement' "$cfg" 2>/dev/null \
        || echo "ERR")
    version=$(jq -r '.version' "$cfg" 2>/dev/null || echo "ERR")

    if [[ "$flag" == "true" && "$other" == "true" && "$version" == "3" ]]; then
        _pass "T95.2 — re-install re-asserts true, keeps other keys"
    else
        local msg="flag=$flag other=$other version=$version"
        msg+=" — $(cat "$cfg")"
        _fail "T95.2" "$msg"
    fi
}

# =============================================================================
# Test T95.3 — spawn_instance (runtime re-assert) with an EXISTING
# controlify.json (flag false, other keys present): flips the flag true
# WITHOUT clobbering the rest, on every launch (not just after install)
# =============================================================================
test_t95_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"
    MCSS_LAUNCHER_ROOT="$tmpdir"

    local cfg
    cfg="$tmpdir/instances/latestUpdate-2/.minecraft/config/controlify.json"
    mkdir -p "$(dirname "$cfg")"
    cat > "$cfg" <<'JSON'
{"global":{"out_of_focus_input":false,"showStatusHudElement":true},"version":3}
JSON

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/bwrap" <<'MOCKBWRAP'
#!/bin/bash
echo "mock bwrap: $@" >&2
exit 0
MOCKBWRAP
    chmod +x "$mock_bin/bwrap"

    cat > "$mock_bin/pgrep" <<MOCKPGREP
#!/bin/bash
echo "$FIXTURE_JAVA_PID"
MOCKPGREP
    chmod +x "$mock_bin/pgrep"

    cat > "$mock_bin/xdotool" <<'MOCKXDOTOOL'
#!/bin/bash
echo "99999"
MOCKXDOTOOL
    chmod +x "$mock_bin/xdotool"

    cat > "$tmpdir/PolyMC.AppImage" <<'MOCKPOLY'
#!/bin/bash
exit 0
MOCKPOLY
    chmod +x "$tmpdir/PolyMC.AppImage"

    set +e
    BWRAP_CMD="$mock_bin/bwrap" \
        MCSS_LAUNCHER_EXEC="$tmpdir/PolyMC.AppImage" \
        PATH="$mock_bin:$PATH" \
        spawn_instance 2 /dev/input/event4 /dev/input/js1 >/dev/null 2>&1
    set -e

    local flag other version
    flag=$(jq -r '.global.out_of_focus_input' "$cfg" 2>/dev/null || echo "ERR")
    other=$(jq -r '.global.showStatusHudElement' "$cfg" 2>/dev/null \
        || echo "ERR")
    version=$(jq -r '.version' "$cfg" 2>/dev/null || echo "ERR")

    if [[ "$flag" == "true" && "$other" == "true" && "$version" == "3" ]]; then
        _pass "T95.3 — spawn_instance re-asserts true, keeps other keys"
    else
        local msg="flag=$flag other=$other version=$version"
        msg+=" — $(cat "$cfg")"
        _fail "T95.3" "$msg"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== Controlify seed/re-assert (#95) test suite ==="
echo ""

test_t95_1
test_t95_2
test_t95_3

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
