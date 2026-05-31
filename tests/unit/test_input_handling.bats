#!/usr/bin/env bats
# =============================================================================
# Unit tests: installer input handling + Controlify version checking
# =============================================================================

setup() {
    PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_DIR
    # Source utilities with logging disabled so print_* don't fail
    LOG_FILE=""
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/modules/utilities.sh" 2>/dev/null
}

# ---------------------------------------------------------------------------
# QUIT_PATTERN: q / quit / exit halt; valid installer inputs do not
# ---------------------------------------------------------------------------

@test "QUIT_PATTERN matches quit tokens (case-insensitive, trimmed)" {
    for inp in q Q quit QUIT exit EXIT "  q  " "quit "; do
        [[ "${inp,,}" =~ $QUIT_PATTERN ]] || {
            echo "FAIL: '$inp' should match QUIT_PATTERN"
            return 1
        }
    done
}

@test "QUIT_PATTERN does NOT match valid installer inputs" {
    for inp in "" 0 1 -1 latest custom 1.21.4 "1 3 5" "1-5" y n hello; do
        if [[ "${inp,,}" =~ $QUIT_PATTERN ]]; then
            echo "FAIL: '$inp' should NOT match QUIT_PATTERN"
            return 1
        fi
    done
}

@test "graceful_quit exits 0" {
    run graceful_quit
    [[ "$status" -eq 0 ]]
}

@test "graceful_quit prints a cancellation message" {
    run graceful_quit
    [[ "$output" == *"cancelled by user"* ]]
}

# ---------------------------------------------------------------------------
# Controlify is the mod checked for MC version compatibility (not Controllable)
# ---------------------------------------------------------------------------

@test "version_management checks Controlify (DOUdJVEm) for compatibility" {
    grep -q 'DOUdJVEm.*modrinth' "$PROJECT_DIR/modules/version_management.sh"
}

@test "version_management no longer checks Controllable (317269)" {
    ! grep -q '"317269" "curseforge"' "$PROJECT_DIR/modules/version_management.sh"
}

@test "version selection display text says Controlify not Controllable" {
    grep -q "Controlify (controller support)" "$PROJECT_DIR/modules/version_management.sh"
    ! grep -q "Controllable (controller support)" "$PROJECT_DIR/modules/version_management.sh"
}
