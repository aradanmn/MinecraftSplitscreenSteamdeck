#!/bin/bash
# minecraftSplitscreen.sh — controller isolation visual test
#
# Auto-detects context: gamescope → nested KWin, KDE → run test.
# Python window code is written to /tmp files to avoid shell quoting issues.

LOG=/tmp/splitscreen-debug.log
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

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
write_python_helpers() {
    # event_reader.py: runs inside bwrap, streams button press/release to stdout
    cat > /tmp/event_reader.py <<'PYEOF'
import struct, sys, datetime, signal

BUTTONS = {
    304: 'A',      305: 'B',      307: 'X',      308: 'Y',
    310: 'L1',     311: 'R1',     312: 'L2',     313: 'R2',
    314: 'Select', 315: 'Start',  316: 'Guide',
    317: 'L3',     318: 'R3',
    544: 'D-Up',   545: 'D-Down', 546: 'D-Left', 547: 'D-Right',
}
EV_KEY = 1

dev = sys.argv[1] if len(sys.argv) > 1 else '/dev/input/event0'
signal.signal(signal.SIGINT,  lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

try:
    with open(dev, 'rb') as f:
        while True:
            data = f.read(24)
            if len(data) < 24:
                break
            _, _, type_, code, value = struct.unpack('llHHi', data)
            if type_ == EV_KEY and value in (0, 1):
                name  = BUTTONS.get(code, f'BTN_{code:#05x}')
                state = 'PRESS' if value == 1 else 'release'
                t     = datetime.datetime.now().strftime('%H:%M:%S')
                print(f'[{t}]  {name:10s}  {state}', flush=True)
except Exception as e:
    print(f'ERROR: {e}', flush=True)
PYEOF

    # splitscreen_window.py: GTK window; takes args: slot y w h js_dev ev_dev
    cat > /tmp/splitscreen_window.py <<'PYEOF'
import gi, subprocess, os, fcntl, sys
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

slot   = sys.argv[1]
y_pos  = int(sys.argv[2])
width  = int(sys.argv[3])
height = int(sys.argv[4])
js_dev = sys.argv[5] if len(sys.argv) > 5 else ''
ev_dev = sys.argv[6] if len(sys.argv) > 6 else ''

is_p1  = (slot == '1')
bg_win = '#1a0000' if is_p1 else '#00001a'
fg_lbl = '#ff6666' if is_p1 else '#6666ff'
fg_txt = '#ffaaaa' if is_p1 else '#aaaaff'

bwrap_base = ['bwrap', '--dev-bind', '/', '/', '--dev', '/dev']
if js_dev and os.path.exists(js_dev):
    bwrap_base += ['--dev-bind', js_dev, js_dev]
if ev_dev and os.path.exists(ev_dev):
    bwrap_base += ['--dev-bind', ev_dev, ev_dev]

list_cmd = bwrap_base + ['--', 'find', '/dev/input', '-maxdepth', '1']
read_cmd = bwrap_base + ['--', 'python3', '/tmp/event_reader.py', ev_dev or '/dev/null']

win = Gtk.Window()
win.set_title(f'SplitscreenP{slot}')
win.set_default_size(width, height)
win.realize()
gdk = win.get_window()
if gdk:
    gdk.set_override_redirect(True)
win.move(0, y_pos)

css = Gtk.CssProvider()
css.load_from_data(f"""
    window {{ background-color: {bg_win}; }}
    label  {{ color: {fg_lbl}; font-size: 13px; padding: 2px 6px; }}
    textview, textview text {{
        background-color: {bg_win}; color: {fg_txt};
        font-family: monospace; font-size: 14px; }}
""".encode())
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)

try:
    result = subprocess.run(list_cmd, capture_output=True, text=True, timeout=4)
    devs   = '  '.join(sorted(result.stdout.split()))
except Exception as e:
    devs   = f'(detection failed: {e})'

hdr = Gtk.Label(label=f'SLOT {slot}  —  sandbox sees: {devs}')
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

log_lines = []

proc = subprocess.Popen(read_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
fd   = proc.stdout.fileno()
fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)

def on_input(source, condition):
    try:
        data = os.read(source, 4096).decode('utf-8', errors='replace')
        for line in data.splitlines():
            line = line.strip()
            if line:
                log_lines.insert(0, line)
        del log_lines[60:]
        buf.set_text('\n'.join(log_lines))
    except BlockingIOError:
        pass
    except Exception:
        pass
    return True

GLib.io_add_watch(fd, GLib.IOCondition.IN, on_input)
win.show_all()
GLib.timeout_add_seconds(120, Gtk.main_quit)
Gtk.main()
proc.terminate()
PYEOF
}

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

    write_python_helpers

    local -a pairs=()
    while IFS= read -r line; do pairs+=("$line"); done < <(find_controller_pairs)

    local P1_JS P1_EV P2_JS P2_EV
    P1_JS=$(awk '{print $1}' <<< "${pairs[0]:-}")
    P1_EV=$(awk '{print $2}' <<< "${pairs[0]:-}")
    P2_JS=$(awk '{print $1}' <<< "${pairs[1]:-}")
    P2_EV=$(awk '{print $2}' <<< "${pairs[1]:-}")

    echo "[test] P1: $P1_JS $P1_EV  |  P2: $P2_JS $P2_EV" >> "$LOG"

    GDK_BACKEND=x11 python3 /tmp/splitscreen_window.py 1 0 "$W" "$HALF_H" "$P1_JS" "$P1_EV" &
    local P1_PID=$!
    sleep 1
    GDK_BACKEND=x11 python3 /tmp/splitscreen_window.py 2 "$HALF_H" "$W" "$HALF_H" "$P2_JS" "$P2_EV" &
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
