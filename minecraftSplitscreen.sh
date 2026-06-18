#!/bin/bash
# minecraftSplitscreen.sh — windowing position test
# Debug mode: every step logs to /tmp/splitscreen-debug.log

LOG=/tmp/splitscreen-debug.log
exec 2>>"$LOG"
set -x   # trace every command to stderr (goes to $LOG)

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

echo "=== $(date) arg=${1:-<none>} DISPLAY=${DISPLAY:-unset} USER=$USER ===" >> "$LOG"

nestedPlasma() {
    echo "[nestedPlasma] start" >> "$LOG"

    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    echo "[nestedPlasma] RES=$RES" >> "$LOG"
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"
    H="${RES#*x}"
    HALF_H=$(( H / 2 ))
    echo "[nestedPlasma] W=$W H=$H HALF_H=$HALF_H" >> "$LOG"

    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    # Disable KDE 6 auto-tiling
    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true
    echo "[nestedPlasma] kwriteconfig6 done" >> "$LOG"

    # KWin window rules: force exact positions
    mkdir -p ~/.config
    cat > ~/.config/kwinrulesrc <<RULESEOF
[General]
count=2

[1]
Description=SplitscreenP1
title=SplitscreenP1
titlematch=1
position=0,0
positionrule=3
size=${W},${HALF_H}
sizerule=3

[2]
Description=SplitscreenP2
title=SplitscreenP2
titlematch=1
position=0,${HALF_H}
positionrule=3
size=${W},${HALF_H}
sizerule=3
RULESEOF
    echo "[nestedPlasma] kwinrulesrc written" >> "$LOG"

    # KWin resolution wrapper
    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH
    echo "[nestedPlasma] kwin_wayland_wrapper written" >> "$LOG"

    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/splitscreen-test.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen Test
Exec=${SCRIPT_PATH} launchFromPlasma
Type=Application
X-KDE-AutostartScript=true
DEOF
    echo "[nestedPlasma] autostart written, about to exec dbus-run-session startplasma-wayland" >> "$LOG"

    exec dbus-run-session startplasma-wayland
    echo "[nestedPlasma] SHOULD NOT REACH HERE" >> "$LOG"
}

launchWindowTest() {
    echo "[launchWindowTest] start" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"
    H="${RES#*x}"
    HALF_H=$(( H / 2 ))
    echo "[launchWindowTest] W=$W H=$H HALF_H=$HALF_H" >> "$LOG"

    qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true
    sleep 0.5

    echo "[launchWindowTest] launching P1 (red)" >> "$LOG"
    python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
win = Gtk.Window()
win.set_title('SplitscreenP1')
win.set_decorated(False)
win.set_default_size(${W}, ${HALF_H})
win.move(0, 0)
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.75, 0, 0, 1))
lbl = Gtk.Label(label='P1  TOP HALF\n(0, 0)  ${W}x${HALF_H}')
lbl.override_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1, 1, 1, 1))
win.add(lbl)
win.show_all()
GLib.timeout_add_seconds(60, Gtk.main_quit)
Gtk.main()
" &
    local P1_PID=$!
    echo "[launchWindowTest] P1 PID=$P1_PID" >> "$LOG"

    sleep 1

    echo "[launchWindowTest] launching P2 (blue)" >> "$LOG"
    python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
win = Gtk.Window()
win.set_title('SplitscreenP2')
win.set_decorated(False)
win.set_default_size(${W}, ${HALF_H})
win.move(0, ${HALF_H})
win.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0.75, 1))
lbl = Gtk.Label(label='P2  BOTTOM HALF\n(0, ${HALF_H})  ${W}x${HALF_H}')
lbl.override_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1, 1, 1, 1))
win.add(lbl)
win.show_all()
GLib.timeout_add_seconds(60, Gtk.main_quit)
Gtk.main()
" &
    local P2_PID=$!
    echo "[launchWindowTest] P2 PID=$P2_PID" >> "$LOG"

    sleep 2

    if command -v wmctrl >/dev/null 2>&1; then
        echo "[launchWindowTest] running wmctrl loop" >> "$LOG"
        for _attempt in 1 2 3; do
            wmctrl -r "SplitscreenP1" -e "0,0,0,${W},${HALF_H}"          2>/dev/null || true
            wmctrl -r "SplitscreenP2" -e "0,0,${HALF_H},${W},${HALF_H}"  2>/dev/null || true
            sleep 1
        done
    fi

    echo "[launchWindowTest] waiting for windows to close" >> "$LOG"
    wait $P1_PID $P2_PID 2>/dev/null || true
    echo "[launchWindowTest] done" >> "$LOG"
}

echo "[main] dispatching on arg=${1:-<none>}" >> "$LOG"
case "${1:-}" in
    nested)
        nestedPlasma
        ;;
    launchFromPlasma)
        launchWindowTest
        ;;
    *)
        echo "Usage: $(basename "$0") {nested|launchFromPlasma}" | tee -a "$LOG" >&2
        exit 1
        ;;
esac
