#!/bin/bash
# tests/isolation-test.sh — controller isolation visual test
#
# Point the Steam shortcut at THIS script (no arguments needed).
# Shows two windows inside nested KWin:
#   P1 (top, red):    /dev/input visible inside slot-1 bwrap sandbox
#   P2 (bottom, blue): /dev/input visible inside slot-2 bwrap sandbox
#
# Each sandbox uses --dev /dev (minimal devtmpfs) then explicitly re-binds
# only its assigned controller pair — so you can see exactly what each slot
# can and cannot see. Auto-refreshes every 3 seconds.

LOG=/tmp/isolation-test.log
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# ─────────────────────────────────────────────────────────────────────────────
# Start nested KDE Plasma inside gamescope.
# gamescope sees the KWin compositor as one fullscreen surface.
# ─────────────────────────────────────────────────────────────────────────────
nestedPlasma() {
    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH || true

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"

    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true

    cat > /tmp/kwin_wayland_wrapper <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x /tmp/kwin_wayland_wrapper
    export PATH=/tmp:$PATH

    local SELF
    SELF="$(readlink -f "$0")"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/isolation-test.desktop <<DEOF
[Desktop Entry]
Name=Controller Isolation Test
Exec=${SELF}
Type=Application
X-KDE-AutostartScript=true
DEOF

    exec dbus-run-session startplasma-wayland
}

# ─────────────────────────────────────────────────────────────────────────────
# Find js→event pairs via sysfs.
# Prints lines: "/dev/input/jsN /dev/input/eventM"
# ─────────────────────────────────────────────────────────────────────────────
find_controller_pairs() {
    for js in /dev/input/js*; do
        [[ -c "$js" ]] || continue
        local jsnum="${js##*js}"
        local sysdir="/sys/class/input/js${jsnum}/device"
        [[ -d "$sysdir" ]] || continue
        local evname
        evname=$(ls "$sysdir/" 2>/dev/null | grep '^event' | head -1)
        [[ -n "$evname" ]] && echo "$js /dev/input/$evname"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Build a bwrap command string that:
#   - starts with a minimal /dev (--dev /dev, no input devices)
#   - explicitly re-binds only the given js + event nodes
# Then runs "find /dev/input -maxdepth 1 | sort" inside the sandbox.
# ─────────────────────────────────────────────────────────────────────────────
make_bwrap_cmd() {
    local js_dev="$1"
    local ev_dev="$2"
    local cmd="bwrap --dev-bind / / --dev /dev"
    [[ -n "$js_dev" && -c "$js_dev" ]] && cmd+=" --dev-bind $js_dev $js_dev"
    [[ -n "$ev_dev" && -c "$ev_dev" ]] && cmd+=" --dev-bind $ev_dev $ev_dev"
    cmd+=" -- find /dev/input -maxdepth 1 | sort"
    echo "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# Create one GTK window showing a live /dev/input listing from inside bwrap.
# Args: slot (1|2)  y_pos  width  height  bwrap_cmd  bg_color  fg_color
# ─────────────────────────────────────────────────────────────────────────────
launch_window() {
    local slot="$1" y="$2" W="$3" H="$4" bwrap_cmd="$5" bg="$6" fg="$7"

    GDK_BACKEND=x11 python3 -c "
import gi, subprocess
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

slot    = '${slot}'
y       = ${y}
W, H    = ${W}, ${H}
bwrap   = '''${bwrap_cmd}'''
bg, fg  = '${bg}', '${fg}'

win = Gtk.Window()
win.set_title('SplitscreenP' + slot)
win.set_default_size(W, H)
win.realize()
gdk = win.get_window()
if gdk:
    gdk.set_override_redirect(True)
win.move(0, y)

screen = Gdk.Screen.get_default()
css = Gtk.CssProvider()
css.load_from_data(f'''
    window    {{ background-color: {bg}; }}
    label     {{ color: {fg}; font-size: 15px; padding: 4px; }}
    textview,
    textview text {{ background-color: {bg}; color: {fg};
                     font-family: monospace; font-size: 13px; }}
'''.encode())
Gtk.StyleContext.add_provider_for_screen(
    screen, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
hdr = Gtk.Label(label=f'SLOT {slot}  —  /dev/input inside bwrap sandbox  (refresh every 3s)')
hdr.set_xalign(0.0)
tv  = Gtk.TextView()
tv.set_editable(False)
tv.set_monospace(True)
buf = tv.get_buffer()
sw  = Gtk.ScrolledWindow()
sw.add(tv)
box.pack_start(hdr, False, False, 0)
box.pack_start(sw,  True,  True,  0)
win.add(box)

def refresh():
    try:
        r = subprocess.run(['bash', '-c', bwrap],
                           capture_output=True, text=True, timeout=5)
        out = r.stdout.strip()
        if not out:
            out = r.stderr.strip() or '(no output)'
    except Exception as e:
        out = 'ERROR: ' + str(e)
    buf.set_text(out)
    return True

GLib.timeout_add_seconds(3, refresh)
refresh()
win.show_all()
GLib.timeout_add_seconds(120, Gtk.main_quit)
Gtk.main()
" &
    echo $!
}

# ─────────────────────────────────────────────────────────────────────────────
# Main test: detect controllers, build sandboxes, launch windows.
# ─────────────────────────────────────────────────────────────────────────────
runIsolationTest() {
    rm -f ~/.config/autostart/isolation-test.desktop 2>/dev/null || true
    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"; HALF_H=$(( H / 2 ))

    export GDK_BACKEND=x11

    # Detect controller pairs
    local -a pairs=()
    while IFS= read -r line; do pairs+=("$line"); done < <(find_controller_pairs)

    local P1_JS P1_EV P2_JS P2_EV
    P1_JS=$(awk '{print $1}' <<< "${pairs[0]:-}")
    P1_EV=$(awk '{print $2}' <<< "${pairs[0]:-}")
    P2_JS=$(awk '{print $1}' <<< "${pairs[1]:-}")
    P2_EV=$(awk '{print $2}' <<< "${pairs[1]:-}")

    echo "[test] P1: js=$P1_JS ev=$P1_EV" >> "$LOG"
    echo "[test] P2: js=$P2_JS ev=$P2_EV" >> "$LOG"
    echo "[test] All pairs detected: ${pairs[*]:-none}" >> "$LOG"

    local CMD1 CMD2
    CMD1=$(make_bwrap_cmd "$P1_JS" "$P1_EV")
    CMD2=$(make_bwrap_cmd "$P2_JS" "$P2_EV")

    echo "[test] bwrap P1: $CMD1" >> "$LOG"
    echo "[test] bwrap P2: $CMD2" >> "$LOG"

    local P1_PID P2_PID
    P1_PID=$(launch_window 1 0         "$W" "$HALF_H" "$CMD1" "#1a0000" "#ff8888")
    sleep 1
    P2_PID=$(launch_window 2 "$HALF_H" "$W" "$HALF_H" "$CMD2" "#00001a" "#8888ff")

    echo "[test] P1_PID=$P1_PID P2_PID=$P2_PID" >> "$LOG"
    wait "$P1_PID" "$P2_PID" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
if [[ "${XDG_CURRENT_DESKTOP:-}" == "KDE" || "${XDG_SESSION_DESKTOP:-}" == "KDE" ]]; then
    runIsolationTest
else
    nestedPlasma
fi
