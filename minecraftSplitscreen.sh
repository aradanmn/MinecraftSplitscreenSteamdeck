#!/bin/bash
# minecraftSplitscreen.sh — controller isolation visual test
#
# Same Steam shortcut, no arguments needed.
# Auto-detects context (gamescope → nested KWin, KDE → run test).
#
# Two windows inside nested KWin:
#   P1 top    (red):  button presses from inside slot-1 bwrap sandbox
#   P2 bottom (blue): button presses from inside slot-2 bwrap sandbox
#
# Each bwrap uses --dev /dev (minimal devtmpfs) then re-binds only its
# assigned js+event pair. Button presses are read from the event device
# INSIDE the sandbox — so you can see if isolation is working.

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
runIsolationTest() {
    rm -f ~/.config/autostart/splitscreen-test.desktop 2>/dev/null || true
    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    export GDK_BACKEND=x11

    local RES W H HALF_H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"; HALF_H=$(( H / 2 ))

    # Write the event reader script — runs inside bwrap, streams button presses
    cat > /tmp/event_reader.py <<'PYEOF'
import struct, sys, datetime, signal, os

BUTTONS = {
    304: 'A',      305: 'B',      307: 'X',      308: 'Y',
    310: 'L1',     311: 'R1',     312: 'L2',     313: 'R2',
    314: 'Select', 315: 'Start',  316: 'Guide',
    317: 'L3',     318: 'R3',
    544: 'D-Up',   545: 'D-Down', 546: 'D-Left', 547: 'D-Right',
}
EV_KEY = 1

dev = sys.argv[1] if len(sys.argv) > 1 else '/dev/input/event0'
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
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

    # Detect controller pairs
    local -a pairs=()
    while IFS= read -r line; do pairs+=("$line"); done < <(find_controller_pairs)

    local P1_JS P1_EV P2_JS P2_EV
    P1_JS=$(awk '{print $1}' <<< "${pairs[0]:-}")
    P1_EV=$(awk '{print $2}' <<< "${pairs[0]:-}")
    P2_JS=$(awk '{print $1}' <<< "${pairs[1]:-}")
    P2_EV=$(awk '{print $2}' <<< "${pairs[1]:-}")

    echo "[test] P1: $P1_JS $P1_EV  |  P2: $P2_JS $P2_EV" >> "$LOG"

    # bwrap prefix for each slot: minimal /dev + only its own devices
    local BWRAP1="bwrap --dev-bind / / --dev /dev"
    [[ -c "$P1_EV" ]] && BWRAP1+=" --dev-bind $P1_EV $P1_EV"
    [[ -c "$P1_JS" ]] && BWRAP1+=" --dev-bind $P1_JS $P1_JS"

    local BWRAP2="bwrap --dev-bind / / --dev /dev"
    [[ -c "$P2_EV" ]] && BWRAP2+=" --dev-bind $P2_EV $P2_EV"
    [[ -c "$P2_JS" ]] && BWRAP2+=" --dev-bind $P2_JS $P2_JS"

    # Long-running event reader inside each sandbox
    local READ1="$BWRAP1 -- python3 /tmp/event_reader.py ${P1_EV:-/dev/null}"
    local READ2="$BWRAP2 -- python3 /tmp/event_reader.py ${P2_EV:-/dev/null}"

    # One-shot device listing for the header
    local LIST1="$BWRAP1 -- find /dev/input -maxdepth 1 | sort | tr '\n' '  '"
    local LIST2="$BWRAP2 -- find /dev/input -maxdepth 1 | sort | tr '\n' '  '"

    echo "[test] READ1: $READ1" >> "$LOG"
    echo "[test] READ2: $READ2" >> "$LOG"

    # ── P1: red, top half ────────────────────────────────────────────────────
    GDK_BACKEND=x11 python3 -c "
import gi, subprocess, os, fcntl
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

W, H       = ${W}, ${HALF_H}
read_cmd   = '''${READ1}'''
list_cmd   = '''${LIST1}'''

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
    label  { color: #ff6666; font-size: 13px; padding: 2px 6px; }
    textview, textview text {
        background-color: #1a0000; color: #ffaaaa;
        font-family: monospace; font-size: 14px; }
''')
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)

try:
    devs = subprocess.check_output(['bash', '-c', list_cmd], text=True, timeout=4).strip()
except Exception:
    devs = '(detection failed)'
hdr = Gtk.Label(label=f'SLOT 1  —  sandbox devices: {devs}')
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

proc = subprocess.Popen(['bash', '-c', read_cmd],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
fd = proc.stdout.fileno()
fcntl.fcntl(fd, fcntl.F_SETFL,
            fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)

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
" &
    local P1_PID=$!

    sleep 1

    # ── P2: blue, bottom half ────────────────────────────────────────────────
    GDK_BACKEND=x11 python3 -c "
import gi, subprocess, os, fcntl
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

W, H       = ${W}, ${HALF_H}
read_cmd   = '''${READ2}'''
list_cmd   = '''${LIST2}'''

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
    label  { color: #6666ff; font-size: 13px; padding: 2px 6px; }
    textview, textview text {
        background-color: #00001a; color: #aaaaff;
        font-family: monospace; font-size: 14px; }
''')
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)

try:
    devs = subprocess.check_output(['bash', '-c', list_cmd], text=True, timeout=4).strip()
except Exception:
    devs = '(detection failed)'
hdr = Gtk.Label(label=f'SLOT 2  —  sandbox devices: {devs}')
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

proc = subprocess.Popen(['bash', '-c', read_cmd],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
fd = proc.stdout.fileno()
fcntl.fcntl(fd, fcntl.F_SETFL,
            fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)

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
