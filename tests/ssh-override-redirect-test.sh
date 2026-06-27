#!/bin/bash
# =============================================================================
# SSH-based Override Redirect Test Runner for Steam Deck
# =============================================================================
# Run this from your dev machine to test the override_redirect cycle on Deck
# via SSH while the Deck is in Game Mode.
#
# Usage:
#   ./tests/ssh-override-redirect-test.sh [deck-hostname]
#
# Default hostname: deck@steamdeck.home.twoshins.net
# =============================================================================

DECK_HOST="${1:-deck@steamdeck.home.twoshins.net}"
REMOTE_SCRIPT="/tmp/override-redirect-test.sh"
LOCAL_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/gamescope-override-redirect-test.sh"

if [[ ! -f "$LOCAL_SCRIPT" ]]; then
    echo "ERROR: Test script not found at $LOCAL_SCRIPT"
    echo "Run this from the repository root."
    exit 1
fi

echo "=== Deploying override redirect test to $DECK_HOST ==="
echo "Local script: $LOCAL_SCRIPT"
echo "Remote path:  $REMOTE_SCRIPT"

# Copy the test script to the Deck
scp "$LOCAL_SCRIPT" "${DECK_HOST}:${REMOTE_SCRIPT}" || {
    echo "ERROR: Failed to copy script to Deck"
    exit 1
}

echo "=== Script deployed. Run it with: ==="
echo "ssh ${DECK_HOST} 'DISPLAY=:0 XAUTHORITY=/run/user/1000/xauth_* bash ${REMOTE_SCRIPT} [--with-dex]'"
echo ""
echo "Or directly:"
echo "ssh ${DECK_HOST} 'DISPLAY=:0 XAUTHORITY=$(ssh ${DECK_HOST} "ls /run/user/1000/xauth_* 2>/dev/null | head -1" 2>/dev/null) bash ${REMOTE_SCRIPT}'"
echo ""

# Check if the script is executable
ssh "$DECK_HOST" "chmod +x '${REMOTE_SCRIPT}'" 2>/dev/null || true

# Run it
echo "=== Running test... (will take ~15 seconds) ==="
ssh "$DECK_HOST" "DISPLAY=:0 bash '${REMOTE_SCRIPT}'" 2>&1

echo ""
echo "=== Test complete ==="
echo "Results also saved to: ssh ${DECK_HOST} 'cat ~/splitscreen-override-redirect-test.txt'"
