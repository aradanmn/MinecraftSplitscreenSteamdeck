#!/bin/sh
# systemd-sleep hook -> /etc/systemd/system-sleep/deck-display-resume.sh
#
# Robust resume trigger for the display-restore worker. systemd-sleep invokes
# every executable here during suspend/resume with:
#   $1 = pre | post
#   $2 = suspend | hibernate | suspend-then-hibernate | ...
# Because the hook is run BY the resume sequence, it cannot be frozen/missed
# the way a `journalctl -f` tail can.
#
# Must NOT block: systemd-sleep waits for all post hooks to finish before
# completing resume, so we fire the user oneshot with --no-block and return.

[ "$1" = "post" ] || exit 0

su -s /bin/bash deck -c \
    "XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
     systemctl --user start --no-block resume-display-restore.service" \
    >/dev/null 2>&1 || true

exit 0
