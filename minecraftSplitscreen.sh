#!/bin/bash
# minecraftSplitscreen.sh — windowing position test
#
# Steam shortcut launches this with no arguments.
# Auto-detects context:
#   gamescope session → nestedPlasma (start nested KDE inside gamescope)
#   KDE session       → launchWindowTest (already inside KWin, create windows)

LOG=/tmp/splitscreen-debug.log
exec 2>>"$LOG"
set -x

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
echo "=== $(date) XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-unset} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# ─────────────────────────────────────────────────────────────────────────────
nestedPlasma() {
    echo "[nestedPlasma] start" >> "$LOG"
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"; HALF_H=$(( H / 2 ))
    echo "[nestedPlasma] W=$W H=$H HALF_H=$HALF_H" >> "$LOG"

    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true

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

    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH

    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/splitscreen-test.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen Test
Exec=${SCRIPT_PATH}
Type=Application
X-KDE-AutostartScript=true
DEOF
    echo "[nestedPlasma] autostart written, exec-ing startplasma-wayland" >> "$LOG"

    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
launchWindowTest() {
    echo "[launchWindowTest] start" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    # Kill plasmashell — we only want KWin as WM, not the full desktop
    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"; HALF_H=$(( H / 2 ))
    echo "[launchWindowTest] W=$W H=$H HALF_H=$HALF_H" >> "$LOG"

    # P1: red, top half.
    # override_redirect=True makes KWin treat this as an unmanaged window —
    # it positions itself exactly at move() coords, bypassing KWin's placement.
    python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
win = Gtk.Window()
win.set_title('SplitscreenP1')
win.set_default_size(${W}, ${HALF_H})
win.realize()
gdkwin = win.get_window()
if gdkwin:
    gdkwin.set_override_redirect(True)
win.move(0, 0)
lbl = Gtk.Label(label='P1  TOP HALF\n(0, 0)  ${W}x${HALF_H}')
win.add(lbl)
css = Gtk.CssProvider()
css.load_from_data(b'window { background-color: #cc0000; color: white; }')
win.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
win.show_all()
GLib.timeout_add_seconds(60, Gtk.main_quit)
Gtk.main()
" &
    local P1_PID=$!
    echo "[launchWindowTest] P1 PID=$P1_PID" >> "$LOG"

    sleep 1

    # P2: blue, bottom half.
    python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
win = Gtk.Window()
win.set_title('SplitscreenP2')
win.set_default_size(${W}, ${HALF_H})
win.realize()
gdkwin = win.get_window()
if gdkwin:
    gdkwin.set_override_redirect(True)
win.move(0, ${HALF_H})
lbl = Gtk.Label(label='P2  BOTTOM HALF\n(0, ${HALF_H})  ${W}x${HALF_H}')
win.add(lbl)
css = Gtk.CssProvider()
css.load_from_data(b'window { background-color: #0000cc; color: white; }')
win.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
win.show_all()
GLib.timeout_add_seconds(60, Gtk.main_quit)
Gtk.main()
" &
    local P2_PID=$!
    echo "[launchWindowTest] P2 PID=$P2_PID" >> "$LOG"

    sleep 2

    # Belt-and-suspenders: xdotool by PID to reinforce positions
    local WID1 WID2
    WID1=$(xdotool search --pid "$P1_PID" 2>/dev/null | head -1 || true)
    WID2=$(xdotool search --pid "$P2_PID" 2>/dev/null | head -1 || true)
    echo "[launchWindowTest] xdotool WID1=$WID1 WID2=$WID2" >> "$LOG"
    for _attempt in 1 2 3; do
        [[ -n "$WID1" ]] && xdotool windowmove "$WID1" 0 0            2>/dev/null || true
        [[ -n "$WID1" ]] && xdotool windowsize "$WID1" "$W" "$HALF_H" 2>/dev/null || true
        [[ -n "$WID2" ]] && xdotool windowmove "$WID2" 0 "$HALF_H"   2>/dev/null || true
        [[ -n "$WID2" ]] && xdotool windowsize "$WID2" "$W" "$HALF_H" 2>/dev/null || true
        sleep 1
    done

    echo "[launchWindowTest] waiting for windows to close" >> "$LOG"
    wait $P1_PID $P2_PID 2>/dev/null || true
    echo "[launchWindowTest] done" >> "$LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto-detect: gamescope = initial launch, KDE = inside nested KWin
if [[ "${XDG_SESSION_DESKTOP:-}" == "KDE" || "${XDG_CURRENT_DESKTOP:-}" == "KDE" ]]; then
    echo "[main] KDE session detected — launchWindowTest" >> "$LOG"
    launchWindowTest
else
    echo "[main] gamescope session detected — nestedPlasma" >> "$LOG"
    nestedPlasma
fi
