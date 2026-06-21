#!/bin/bash
# Fired by udev on any DRM hotplug event (ACTION=change, HOTPLUG=1).
#
# Restarts gamescope whenever a DP connector is connected with valid EDID.
# This covers both failure modes:
#   1. MST probe race (EDID missing on first connect after boot)
#   2. Steam not rendering to the external despite gamescope detecting it
# On disconnect events the connector status reads "disconnected" so we exit
# early and don't restart.
#
# A 60s cooldown stamp prevents rapid-fire restarts during repeated reconnects.

sleep 8

STAMP=/tmp/gamescope-hotplug-restart-stamp
if [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $(( now - last )) -lt 60 ] && exit 0
fi

# Act if any DP connector is connected (with or without EDID — missing EDID
# is the MST race case and we still want to restart to re-probe).
needs_restart=0
for status_file in /sys/class/drm/card0/card0-DP-*/status; do
    [ -f "$status_file" ] || continue
    [ "$(cat "$status_file" 2>/dev/null)" = "connected" ] && needs_restart=1 && break
done

[ "$needs_restart" -eq 0 ] && exit 0

date +%s > "$STAMP"

# Clear any stale WAYLAND_DISPLAY/DISPLAY/XAUTHORITY before restarting.
# A leaked WAYLAND_DISPLAY forces gamescope into the nested backend and
# crash-loops it (ValveSoftware/SteamOS#2467). A target restart bypasses
# start-gamescope-session, which would otherwise sanitize DISPLAY/XAUTHORITY.
su -s /bin/bash deck -c \
    "XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
     systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY; \
     systemctl --user restart gamescope-session.target" 2>/dev/null || true

exit 0
