#!/bin/bash
# minecraftSplitscreen.sh — controller isolation visual test
#
# Same Steam shortcut, no arguments needed.
# Auto-detects context (gamescope → nested KWin, KDE → run test).
#
# Two windows inside nested KWin:
#   P1 top    (red):  /dev/input visible inside slot-1 bwrap sandbox
#   P2 bottom (blue): /dev/input visible inside slot-2 bwrap sandbox
#
# Each bwrap uses --dev /dev (minimal devtmpfs) then re-binds only its
# assigned js+event pair — so you can see exactly what's isolated vs leaked.
# Refreshes every 3 seconds.

LOG=/tmp/splitscreen-debug.log
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# ─────────────────────────────────────────────────────────────────────────────
# nestedPlasma: start nested KDE Plasma inside gamescope.
# gamescope sees KWin as one fullscreen surface; we manage windows inside it.
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
    cat > ~/.config/autostart/splitscreen-test.desktop <<DEOF
[Desktop Entry]
Name=Splitscreen Test
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
# Build a bwrap command that gives a minimal /dev and re-binds only the
# given js+event nodes, then lists /dev/input inside the sandbox.
# ─────────────────────────────────────────────────────────────────────────────
make_bwrap_cmd() {
    local js_dev="$1" ev_dev="$2"
    local cmd="bwrap --dev-bind / / --dev /dev"
    [[ -n "$js_dev" && -c "$js_dev" ]] && cmd+=" --dev-bind $js_dev $js_dev"
    [[ -n "$ev_dev" && -c "$ev_dev" ]] && cmd+=" --dev-bind $ev_dev $ev_dev"
    cmd+=" -- find /dev/input -maxdepth 1 | sort"
    echo "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run the isolation test: two GTK windows showing live bwrap /dev/input output.
# Called from KDE autostart once nested KWin is up.
# ─────────────────────────────────────────────────────────────────────────────
runIsolationTest() {
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true
    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    export GDK_BACKEND=x11

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"; HALF_H=$(( H / 2 ))

    # Detect controller pairs
    local -a pairs=()
    while IFS= read -r line; do pairs+=("$line"); done < <(find_controller_pairs)

    local P1_JS P1_EV P2_JS P2_EV
    P1_JS=$(awk '{print $1}' <<< "${pairs[0]:-}")
    P1_EV=$(awk '{print $2}' <<< "${pairs[0]:-}")
    P2_JS=$(awk '{print $1}' <<< "${pairs[1]:-}")
    P2_EV=$(awk '{print $2}' <<< "${pairs[1]:-}")

    echo "[test] detected pairs: ${pairs[*]:-none}" >> "$LOG"
    echo "[test] P1: $P1_JS $P1_EV  |  P2: $P2_JS $P2_EV" >> "$LOG"

    local CMD1 CMD2
    CMD1=$(make_bwrap_cmd "$P1_JS" "$P1_EV")
    CMD2=$(make_bwrap_cmd "$P2_JS" "$P2_EV")

    echo "[test] CMD1: $CMD1" >> "$LOG"
    echo "[test] CMD2: $CMD2" >> "$LOG"

    # P1: red, top half
    GDK_BACKEND=x11 python3 -c "
import gi, subprocess
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

W, H = ${W}, ${HALF_H}
bwrap = '''${CMD1}'''

win = Gtk.Window()
win.set_title('SplitscreenP1')
win.set_default_size(W, H)
win.realize()
gdk = win.get_window()
if gdk:
    gdk.set_override_redirect(True)
win.move(0, 0)

css = Gtk.CssProvider()
css.load_from_data(b'''
    window { background-color: #1a0000; }
    label  { color: #ff8888; font-size: 15px; padding: 4px; }
    textview, textview text {
        background-color: #1a0000; color: #ff8888;
        font-family: monospace; font-size: 13px; }
''')
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
hdr = Gtk.Label(label='SLOT 1  —  /dev/input inside bwrap sandbox  (refreshes every 3s)')
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
        r = subprocess.run(['bash', '-c', bwrap], capture_output=True, text=True, timeout=5)
        out = r.stdout.strip() or r.stderr.strip() or '(no output)'
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
    local P1_PID=$!

    sleep 1

    # P2: blue, bottom half
    GDK_BACKEND=x11 python3 -c "
import gi, subprocess
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

W, H = ${W}, ${HALF_H}
bwrap = '''${CMD2}'''

win = Gtk.Window()
win.set_title('SplitscreenP2')
win.set_default_size(W, H)
win.realize()
gdk = win.get_window()
if gdk:
    gdk.set_override_redirect(True)
win.move(0, ${HALF_H})

css = Gtk.CssProvider()
css.load_from_data(b'''
    window { background-color: #00001a; }
    label  { color: #8888ff; font-size: 15px; padding: 4px; }
    textview, textview text {
        background-color: #00001a; color: #8888ff;
        font-family: monospace; font-size: 13px; }
''')
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
hdr = Gtk.Label(label='SLOT 2  —  /dev/input inside bwrap sandbox  (refreshes every 3s)')
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
        r = subprocess.run(['bash', '-c', bwrap], capture_output=True, text=True, timeout=5)
        out = r.stdout.strip() or r.stderr.strip() or '(no output)'
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
    local P2_PID=$!

    echo "[test] P1_PID=$P1_PID P2_PID=$P2_PID" >> "$LOG"
    wait "$P1_PID" "$P2_PID" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
if [[ "${XDG_CURRENT_DESKTOP:-}" == "KDE" || "${XDG_SESSION_DESKTOP:-}" == "KDE" ]]; then
    runIsolationTest
else
    nestedPlasma
fi
