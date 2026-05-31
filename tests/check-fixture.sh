#!/usr/bin/env bash
# Validates the committed fixture of the generated launcher script.
#
# Usage:
#   bash tests/check-fixture.sh
#
# Also called by .github/workflows/check-generated-script.yml on every push/PR.
# Mirrors the logic of verify_generated_script() in launcher_script_generator.sh
# but runs standalone without sourcing the installer modules.

set -uo pipefail

FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/minecraftSplitscreen.sh"
FAILURES=0

pass() { printf "  PASS  %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; (( FAILURES++ )) || true; }

echo "=== check-fixture: $FIXTURE ==="
echo ""

if [[ ! -f "$FIXTURE" ]]; then
    echo "ERROR: fixture not found."
    echo "       Regenerate with: bash tools/update-fixture.sh"
    exit 1
fi

# 1. Bash syntax
if bash -n "$FIXTURE" 2>/dev/null; then
    pass "bash -n syntax"
else
    bash -n "$FIXTURE"  # re-run to surface the error message
    fail "bash -n syntax"
fi

# 2. Unreplaced generator placeholders (format: __LAUNCHER_NAME__ etc.)
if grep -q '__LAUNCHER_' "$FIXTURE"; then
    echo "       Found: $(grep -o '__LAUNCHER_[A-Z_]*__' "$FIXTURE" | sort -u | tr '\n' ' ')"
    fail "no unreplaced __LAUNCHER_* placeholders"
else
    pass "no unreplaced __LAUNCHER_* placeholders"
fi

# 3. No real user home directories (only /home/testuser is permitted in the fixture)
bad_paths=$(grep -oE '/home/[a-zA-Z0-9_-]+' "$FIXTURE" 2>/dev/null \
    | grep -v '^/home/testuser$' | sort -u || true)
if [[ -n "$bad_paths" ]]; then
    echo "       Found: $bad_paths"
    fail "no real user home paths (only /home/testuser is allowed in the fixture)"
else
    pass "no real user home paths"
fi

# 4. Executable bit
if [[ -x "$FIXTURE" ]]; then
    pass "executable bit set"
else
    fail "executable bit set (run: chmod +x $FIXTURE)"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All checks passed."
else
    printf "%d check(s) failed.\n" "$FAILURES"
    exit 1
fi
