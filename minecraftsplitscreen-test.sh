#!/bin/bash
# Wrapper script for Phase B testing in gamescope mode.
# Runs the Phase B lifecycle test inside a nested KDE session.
# Steam shortcut calls this instead of the default minecraftSplitscreen.sh.
set -euo pipefail

REPO_DIR="$HOME/MinecraftSplitscreenSteamdeck"

# Ensure repo is up to date
cd "$REPO_DIR" && git pull -q 2>/dev/null || true

# Run the prototype in test mode
exec "$REPO_DIR/minecraftSplitscreen.sh" test
