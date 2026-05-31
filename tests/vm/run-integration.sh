#!/usr/bin/env bash
# =============================================================================
# Integration test runner — intended to be run inside the Vagrant VM.
# Usage (from the VM): cd /project && tests/vm/run-integration.sh
# Usage (from host):   vagrant ssh -c "cd /project && tests/vm/run-integration.sh"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTS_DIR="$PROJECT_DIR/tests"

# Find bats
if [[ -x "$TESTS_DIR/bats-install/bin/bats" ]]; then
    BATS="$TESTS_DIR/bats-install/bin/bats"
elif command -v bats >/dev/null 2>&1; then
    BATS=$(command -v bats)
else
    echo "[ERROR] bats not found. Run: git clone --depth=1 https://github.com/bats-core/bats-core tests/bats && tests/bats/install.sh tests/bats-install"
    exit 1
fi

echo ""
echo "=== Minecraft Splitscreen Integration Tests ==="
echo "    bats: $($BATS --version)"
echo "    host: $(hostname)"
echo ""

# Run unit tests first (fast, no side effects)
echo "--- Unit Tests ---"
"$BATS" "$TESTS_DIR/unit/"*.bats
echo ""

# Run integration tests (modify real files under /tmp)
echo "--- Integration Tests ---"
if ls "$TESTS_DIR/integration/"*.bats >/dev/null 2>&1; then
    "$BATS" "$TESTS_DIR/integration/"*.bats
else
    echo "  (no integration .bats files yet)"
fi

echo ""
echo "=== All tests passed ==="
