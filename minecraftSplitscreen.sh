#!/bin/bash
# minecraftSplitscreen.sh — multi-window position test
#
# Steam shortcut launches this with no arguments.
# Auto-detects context:
#   gamescope session → nestedPlasma (start nested KDE inside gamescope)
#   KDE session       → launchWindowTest (already inside KWin, create N windows)
#
# NUM_SLOTS controls how many windows to open (default 4).
# Each window is a colored GTK placeholder — replace with Minecraft instances
# once windowing is confirmed working.

NUM_SLOTS=4

LOG=/tmp/splitscreen-debug.log
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-unset} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# ─────────────────────────────────────────────────────────────────────────────
# compute_geometry slot total W H  →  stdout "x y w h"
#
# Layouts:
#   1 slot : full screen
#   2 slots: top half / bottom half
#   3 slots: use 4-slot 2×2 grid, slot 4 position left empty
#   4 slots: 2×2 grid
# ─────────────────────────────────────────────────────────────────────────────
compute_geometry() {
    local slot=$1 total=$2 W=$3 H=$4
    local hw=$(( W / 2 )) hh=$(( H / 2 ))
    case $total in
        1) echo "0 0 $W $H" ;;
        2) [[ $slot -eq 1 ]] && echo "0 0 $W $hh" || echo "0 $hh $W $hh" ;;
        3|4)
            case $slot in
                1) echo "0 0 $hw $hh" ;;
                2) echo "$hw 0 $hw $hh" ;;
                3) echo "0 $hh $hw $hh" ;;
                4) echo "$hw $hh $hw $hh" ;;
            esac ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# write_python_helpers — writes /tmp/splitscreen_window.py
#
# The window script takes: slot x y w h
# Displays the slot number and geometry in a color-coded window.
# Optional js_dev ev_dev args (used by the isolation test, ignored here).
# ─────────────────────────────────────────────────────────────────────────────
write_python_helpers() {
    cat > /tmp/splitscreen_window.py <<'PYEOF'
import gi, sys, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

COLORS = {
    '1': ('#1a0000', '#ff6666'),   # dark red   / red    (top-left)
    '2': ('#00001a', '#6666ff'),   # dark blue  / blue   (top-right)
    '3': ('#001a00', '#66ff66'),   # dark green / green  (bottom-left)
    '4': ('#1a1400', '#ffdd44'),   # dark gold  / yellow (bottom-right)
}

slot   = sys.argv[1]
x      = int(sys.argv[2])
y      = int(sys.argv[3])
width  = int(sys.argv[4])
height = int(sys.argv[5])
# argv[6], argv[7] = js_dev, ev_dev (used by isolation test, ignored here)

bg, fg = COLORS.get(slot, ('#111111', '#ffffff'))

win = Gtk.Window()
win.set_title(f'SplitscreenP{slot}')
win.set_default_size(width, height)
win.realize()
gdk = win.get_window()
if gdk:
    gdk.set_override_redirect(True)
win.move(x, y)

css = Gtk.CssProvider()
css.load_from_data(f"""
    window {{ background-color: {bg}; }}
    label  {{ color: {fg}; font-size: 28px; font-weight: bold; }}
""".encode())
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

lbl = Gtk.Label(label=f'P{slot}\n({x},{y})  {width}×{height}')
win.add(lbl)
win.show_all()
GLib.timeout_add_seconds(300, Gtk.main_quit)
Gtk.main()
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
nestedPlasma() {
    echo "[nestedPlasma] start" >> "$LOG"
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    echo "[nestedPlasma] W=$W H=$H NUM_SLOTS=$NUM_SLOTS" >> "$LOG"

    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true

    # Write KWin window rules for all slots so KWin enforces geometry as a fallback
    {
        echo "[General]"
        echo "count=$NUM_SLOTS"
        for slot in $(seq 1 "$NUM_SLOTS"); do
            read x y w h < <(compute_geometry "$slot" "$NUM_SLOTS" "$W" "$H")
            echo ""
            echo "[$slot]"
            echo "Description=SplitscreenP${slot}"
            echo "title=SplitscreenP${slot}"
            echo "titlematch=1"
            echo "position=${x},${y}"
            echo "positionrule=3"
            echo "size=${w},${h}"
            echo "sizerule=3"
        done
    } > ~/.config/kwinrulesrc
    echo "[nestedPlasma] kwinrulesrc written for $NUM_SLOTS slots" >> "$LOG"

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
    echo "[launchWindowTest] start NUM_SLOTS=$NUM_SLOTS" >> "$LOG"
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true

    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    echo "[launchWindowTest] W=$W H=$H" >> "$LOG"

    export GDK_BACKEND=x11
    write_python_helpers

    local -a PIDS=()
    for slot in $(seq 1 "$NUM_SLOTS"); do
        read x y w h < <(compute_geometry "$slot" "$NUM_SLOTS" "$W" "$H")
        echo "[launchWindowTest] slot=$slot x=$x y=$y w=$w h=$h" >> "$LOG"
        GDK_BACKEND=x11 python3 /tmp/splitscreen_window.py "$slot" "$x" "$y" "$w" "$h" &
        PIDS+=($!)
        sleep 0.5
    done

    echo "[launchWindowTest] waiting — PIDs: ${PIDS[*]}" >> "$LOG"
    wait "${PIDS[@]}" 2>/dev/null || true
    echo "[launchWindowTest] windows closed — tearing down KWin session" >> "$LOG"

    # Kill the nested KDE session so gamescope returns to the Steam launcher
    pkill -TERM kwin_wayland 2>/dev/null || true
    sleep 2
    pkill -KILL kwin_wayland 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
if [[ "${XDG_SESSION_DESKTOP:-}" == "KDE" || "${XDG_CURRENT_DESKTOP:-}" == "KDE" ]]; then
    echo "[main] KDE session detected — launchWindowTest" >> "$LOG"
    launchWindowTest
else
    echo "[main] gamescope session detected — nestedPlasma" >> "$LOG"
    nestedPlasma
fi
