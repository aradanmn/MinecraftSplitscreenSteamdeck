#!/bin/bash
# Fired by udev on any DRM hotplug event (ACTION=change, HOTPLUG=1).
#
# Restarts gamescope whenever a DP connector is connected with valid EDID.
# Covers both failure modes:
#   1. MST probe race (EDID missing on first connect after boot)
#   2. Steam not rendering to the external despite gamescope detecting it
#
# Key: we POLL for a stable EDID (up to MAX_WAIT seconds) before restarting.
# A flat sleep isn't enough — the MST hub can take 20-35s to enumerate after
# a dock connect, and restarting gamescope while DP-1 is still mid-enumeration
# causes it to fall back to eDP-1 and then fail to drive the external output.
#
# A 60s cooldown stamp prevents rapid-fire restarts during repeated reconnects.

MAX_WAIT=45
STAMP=/tmp/gamescope-hotplug-restart-stamp

# Cooldown check — bail if we restarted within the last 60s.
if [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $(( now - last )) -lt 60 ] && exit 0
fi

# Poll until a DP connector is connected AND has valid EDID, or timeout.
# If no DP connector is connected at all (unplug event), exit immediately.
stable=0
for i in $(seq 1 $MAX_WAIT); do
    any_connected=0
    for status_file in /sys/class/drm/card0/card0-DP-*/status; do
        [ -f "$status_file" ] || continue
        if [ "$(cat "$status_file" 2>/dev/null)" = "connected" ]; then
            any_connected=1
            edid_size=$(wc -c < "$(dirname "$status_file")/edid" 2>/dev/null || echo 0)
            if [ "$edid_size" -gt 0 ]; then
                stable=1
                break 2
            fi
        fi
    done
    # No DP connectors connected at all — this is a disconnect event, exit.
    [ "$any_connected" -eq 0 ] && exit 0
    sleep 1
done

# If we timed out with a connected-but-no-EDID state, still restart —
# that's the broken MST probe case and gamescope needs a kick anyway.

date +%s > "$STAMP"

# Clear any stale WAYLAND_DISPLAY/DISPLAY/XAUTHORITY before restarting.
# A leaked WAYLAND_DISPLAY forces gamescope into the nested backend and
# crash-loops it (ValveSoftware/SteamOS#2467).
su -s /bin/bash deck -c \
    "XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
     systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY; \
     systemctl --user restart gamescope-session.target" 2>/dev/null || true

exit 0
