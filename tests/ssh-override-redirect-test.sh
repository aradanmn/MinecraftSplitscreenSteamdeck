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
LOCAL_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LOCAL_SCRIPT="$LOCAL_DIR/gamescope-override-redirect-test.sh"
LOCAL_WORKDIR_LIB="$LOCAL_DIR/lib/workdir.sh"

# #122: the test resolves its results path through tests/lib/workdir.sh, so the
# lib has to travel with it — a bare scp of the script alone would land it next
# to no lib and die on the source. Everything goes under ONE remote dir, and
# MCSS_WORKDIR pins the scratch root to an absolute path inside it, so the run
# leaves nothing in the Deck's $HOME. /tmp clears on reboot.
REMOTE_DIR="/tmp/mcss-override-redirect-test"
REMOTE_SCRIPT="$REMOTE_DIR/gamescope-override-redirect-test.sh"
REMOTE_WORKDIR="$REMOTE_DIR/.workdir"

for f in "$LOCAL_SCRIPT" "$LOCAL_WORKDIR_LIB"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: required file not found at $f"
        echo "Run this from the repository root."
        exit 1
    fi
done

echo "=== Deploying override redirect test to $DECK_HOST ==="
echo "Local script: $LOCAL_SCRIPT"
echo "Remote path:  $REMOTE_SCRIPT"

ssh "$DECK_HOST" "mkdir -p '$REMOTE_DIR/lib'" || {
    echo "ERROR: Failed to create $REMOTE_DIR on Deck"
    exit 1
}

# Copy the test script AND its workdir lib to the Deck
scp "$LOCAL_SCRIPT" "${DECK_HOST}:${REMOTE_SCRIPT}" \
    && scp "$LOCAL_WORKDIR_LIB" "${DECK_HOST}:${REMOTE_DIR}/lib/workdir.sh" || {
    echo "ERROR: Failed to copy test files to Deck"
    exit 1
}

echo "=== Script deployed. Run it with: ==="
echo "ssh ${DECK_HOST} 'DISPLAY=:0 XAUTHORITY=/run/user/1000/xauth_* MCSS_WORKDIR=${REMOTE_WORKDIR} bash ${REMOTE_SCRIPT} [--with-dex]'"
echo ""
echo "Or directly:"
echo "ssh ${DECK_HOST} 'DISPLAY=:0 XAUTHORITY=$(ssh ${DECK_HOST} "ls /run/user/1000/xauth_* 2>/dev/null | head -1" 2>/dev/null) MCSS_WORKDIR=${REMOTE_WORKDIR} bash ${REMOTE_SCRIPT}'"
echo ""

# Check if the script is executable
ssh "$DECK_HOST" "chmod +x '${REMOTE_SCRIPT}'" 2>/dev/null || true

# Run it
echo "=== Running test... (will take ~15 seconds) ==="
ssh "$DECK_HOST" "DISPLAY=:0 MCSS_WORKDIR='${REMOTE_WORKDIR}' bash '${REMOTE_SCRIPT}'" 2>&1

echo ""
echo "=== Test complete ==="
echo "Results also saved to: ssh ${DECK_HOST} 'cat ${REMOTE_WORKDIR}/gamescope/splitscreen-override-redirect-test.txt'"
echo "Clean up with:         ssh ${DECK_HOST} 'rm -rf ${REMOTE_DIR}'"
