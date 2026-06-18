#!/bin/bash
# minecraftSplitscreen.sh — windowing position test
#
# Steam shortcut passes "nested" → starts nested KDE session inside gamescope.
# KWin autostart calls "launchFromPlasma" → creates two colored test windows.
#
# Goal: P1 (red) fills top half of screen, P2 (blue) fills bottom half.
# Three-layer positioning fix for KDE 6 tiling:
#   1. kwriteconfig6 disables auto-tiling before KWin starts
#   2. kwinrulesrc rules force exact position+size at map-time
#   3. wmctrl loop hammers position after windows appear (belt-and-suspenders)
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# ─────────────────────────────────────────────────────────────────────────────
# nestedPlasma: configure KWin and launch the nested KDE Plasma session.
# gamescope sees the entire KWin compositor as one fullscreen "game" surface;
# our test windows are positioned inside KWin's own XWayland.
# ─────────────────────────────────────────────────────────────────────────────
nestedPlasma() {
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"
    H="${RES#*x}"
    HALF_H=$(( H / 2 ))

    # Clean up any stale autostart from a previous crashed run
    rm -f ~/.config/autostart/splitscreen-test.desktop

    # ── Layer 1: disable KDE 6 auto-tiling ──────────────────────────────────
    # KDE 6 can auto-tile windows as they appear; this prevents it from
    # fighting our positioned layout after map-time.
    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true

    # ── Layer 2: KWin window rules with forced position+size ─────────────────
    # positionrule=3 (Force) and sizerule=3 (Force) make KWin apply these
    # coordinates at map-time and whenever the WM would otherwise reposition.
    # titlematch=1 = exact title string match.
    mkdir -p ~/.config
    cat > ~/.config/kwinrulesrc <<EOF
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
EOF

    # ── KWin resolution wrapper ──────────────────────────────────────────────
    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH

    # ── KDE autostart: run launchFromPlasma once KWin session is up ──────────
    local SCRIPT_PATH
    SCRIPT_PATH="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/splitscreen-test.desktop <<EOF
[Desktop Entry]
Name=Splitscreen Test
Exec=${SCRIPT_PATH} launchFromPlasma
Type=Application
X-KDE-AutostartScript=true
EOF

    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
# launchWindowTest: create two colored test windows at explicit positions.
# Called from the KDE autostart .desktop once KWin is running.
# ─────────────────────────────────────────────────────────────────────────────
launchWindowTest() {
    rm -f ~/.config/autostart/splitscreen-test.desktop

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"
    H="${RES#*x}"
    HALF_H=$(( H / 2 ))

    # Tell KWin to reload rules written before it started
    qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true
    sleep 0.5

    # P1: red, top half — KWin rules force to (0, 0, W, HALF_H)
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

    sleep 1

    # P2: blue, bottom half — KWin rules force to (0, HALF_H, W, HALF_H)
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

    sleep 2

    # ── Layer 3: wmctrl reinforcement ────────────────────────────────────────
    # If KWin's placement overrode our move() hint (e.g. Smart placement
    # shifted the window), wmctrl sends _NET_MOVERESIZE_WINDOW which KWin
    # honors for managed X11 windows regardless of placement policy.
    if command -v wmctrl >/dev/null 2>&1; then
        for _attempt in 1 2 3; do
            wmctrl -r "SplitscreenP1" -e "0,0,0,${W},${HALF_H}"          2>/dev/null || true
            wmctrl -r "SplitscreenP2" -e "0,0,${HALF_H},${W},${HALF_H}"  2>/dev/null || true
            sleep 1
        done
    fi

    wait $P1_PID $P2_PID 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    nested)
        nestedPlasma
        ;;
    launchFromPlasma)
        launchWindowTest
        ;;
    *)
        echo "Usage: $(basename "$0") {nested|launchFromPlasma}" >&2
        echo "  nested           — Steam shortcut entry point (Game Mode)" >&2
        echo "  launchFromPlasma — called by KWin autostart inside nested session" >&2
        exit 1
        ;;
esac
