#!/usr/bin/env bash
# Deploy the Steam Deck display/suspend fixes. Run this ON the Steam Deck.
# Needs sudo for the system-sleep hook in /etc.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
USER_BIN="$HOME/.local/bin"
USER_SYSD="$HOME/.config/systemd/user"
mkdir -p "$USER_BIN" "$USER_SYSD"

# Stop+disable the OLD persistent journalctl-tail service before overwriting it.
systemctl --user disable --now resume-display-restore.service 2>/dev/null || true

install -m 0755 "$HERE/resume-display-restore.sh"      "$USER_BIN/resume-display-restore.sh"
install -m 0755 "$HERE/dock-display-hotplug.sh"        "$USER_BIN/dock-display-hotplug.sh"
install -m 0644 "$HERE/resume-display-restore.service" "$USER_SYSD/resume-display-restore.service"

systemctl --user daemon-reload

# Root: the system-sleep hook is the robust resume trigger.
sudo install -m 0755 "$HERE/deck-display-resume.sh" /etc/systemd/system-sleep/deck-display-resume.sh

echo "Installed."
echo " - resume worker:   $USER_BIN/resume-display-restore.sh (oneshot, on-demand)"
echo " - resume trigger:  /etc/systemd/system-sleep/deck-display-resume.sh (fires on resume)"
echo " - dock hotplug:    $USER_BIN/dock-display-hotplug.sh (env-sanitize added)"
echo "Test (no gamescope restart):  RESUME_RESTORE_DRYRUN=1 $USER_BIN/resume-display-restore.sh && cat /tmp/resume-display-restore.log"
