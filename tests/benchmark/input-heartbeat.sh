#!/bin/bash
# =============================================================================
# input-heartbeat.sh — keep splitscreen instances rendering at full rate
# =============================================================================
# The Deck ramps clocks/render down when a session sees no input ("in-game
# AFK", observed 2026-07-17: standing FPS settles to the idle floor and jumps
# on any button press). Protocol v2 has NO piloted input at all, so scored
# segments would otherwise measure the idle floor, not the renderer.
#
# This taps an unbound key (F7 — no vanilla/mod binding in our set) on every
# ACTIVE slot's window every INTERVAL seconds, window-targeted on the nested
# X display. Usage:
#   input-heartbeat.sh start   — background loop; pidfile in $HOME/.cache
#   input-heartbeat.sh stop
# X display/auth are re-derived per invocation (auth files rotate per session).
# Whether synthetic X input actually defeats the ramp-down is verified at the
# MangoHud probe (operator watches the counter); if it does not, fall back to
# pinning governors (needs root) or documenting the floor as symmetric.
# =============================================================================
set -uo pipefail

INTERVAL="${MCSS_HEARTBEAT_INTERVAL_S:-8}"
PIDFILE="$HOME/.cache/mcss-input-heartbeat.pid"
STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"

_derive_x() {
    local line
    line=$(pgrep -a Xwayland | grep -- '-auth' | grep -oE ':[0-9]+ -auth [^ ]+' \
        | head -1) || return 1
    DISPLAY=$(cut -d' ' -f1 <<<"$line")
    XAUTHORITY=$(cut -d' ' -f3 <<<"$line")
    export DISPLAY XAUTHORITY
}

case "${1:-}" in
start)
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && {
        echo "[heartbeat] already running ($(cat "$PIDFILE"))"; exit 0; }
    mkdir -p "$(dirname "$PIDFILE")"
    (
        while sleep "$INTERVAL"; do
            _derive_x || continue
            for wid in $(jq -r \
                '.slots[] | select(.active==true) | .wid // empty' \
                "$STATE" 2>/dev/null); do
                xdotool key --window "$wid" F7 2>/dev/null || true
            done
        done
    ) &
    echo $! > "$PIDFILE"
    echo "[heartbeat] started (pid $(cat "$PIDFILE"), every ${INTERVAL}s)"
    ;;
stop)
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "[heartbeat] stopped"
    fi
    ;;
*)  echo "usage: $0 start|stop" >&2; exit 1 ;;
esac
