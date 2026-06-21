#!/bin/bash
# resume-display-restore.sh — oneshot worker, triggered on resume by the
# system-sleep hook /etc/systemd/system-sleep/deck-display-resume.sh.
#
# Why this exists: after suspend/resume while docked, gamescope sometimes
# fails to re-drive the external display, so we give it a nudge. CRITICALLY,
# we first clear any stale WAYLAND_DISPLAY/DISPLAY/XAUTHORITY from the user
# manager environment — a leaked WAYLAND_DISPLAY makes the embedded gamescope
# pick the *nested* backend and crash-loop forever (both screens black).
# See ValveSoftware/SteamOS#2467. start-gamescope-session clears DISPLAY and
# XAUTHORITY but NOT WAYLAND_DISPLAY, and a `systemctl --user restart` of the
# target bypasses start-gamescope-session entirely — so we must do it here.
#
# Set RESUME_RESTORE_DRYRUN=1 to log decisions without touching gamescope.

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"

LOG=/tmp/resume-display-restore.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

DRYRUN="${RESUME_RESTORE_DRYRUN:-0}"

sanitize_env() {
    if [ "$DRYRUN" = "1" ]; then
        log "[dry-run] would: systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY"
        log "[dry-run] WAYLAND_DISPLAY currently: $(systemctl --user show-environment 2>/dev/null | grep -i '^WAYLAND_DISPLAY=' || echo '(unset)')"
        return
    fi
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY 2>/dev/null || true
    log "cleared stale WAYLAND_DISPLAY/DISPLAY/XAUTHORITY"
}

restart_gamescope() {
    if [ "$DRYRUN" = "1" ]; then
        log "[dry-run] would: systemctl --user restart gamescope-session.target"
        return
    fi
    systemctl --user restart gamescope-session.target 2>/dev/null || true
}

log "resume worker started (dryrun=$DRYRUN)"

# Give DRM / dock / MST time to re-enumerate after thaw.
[ "$DRYRUN" = "1" ] || sleep 8

# 1. Always sanitize stale display vars BEFORE any restart.
sanitize_env

# 2. Only nudge gamescope when an external display is attached. Undocked, the
#    internal panel resumes on its own and a restart just causes a flash.
external=0
for status_file in /sys/class/drm/card0/card0-DP-*/status; do
    [ -f "$status_file" ] || continue
    [ "$(cat "$status_file" 2>/dev/null)" = "connected" ] && external=1
done

if [ "$external" -eq 1 ]; then
    log "external display connected -> restarting gamescope to re-drive output"
    restart_gamescope
elif ! systemctl --user is-active --quiet gamescope-session.target; then
    log "no external display, but session inactive -> restarting"
    restart_gamescope
else
    log "no external display, session healthy -> no action"
fi

log "done"
exit 0
