#!/bin/bash
# minecraftSplitscreen.sh — 8-hour windowing test harness
#
# Steam shortcut launches this with no arguments.
# Auto-detects context:
#   gamescope session → nestedPlasma (start nested KDE inside gamescope)
#   KDE session       → launchWindowTest (already inside KWin, run harness)
#
# The harness simulates Minecraft player join/quit events:
#   Phase 1: sequential join  P1→P2→P3→P4  (2-min loading delay each)
#   Phase 2: sequential quit  P4→P3→P2     (P1 always survives)
#   Phase 3: random events    every 5/15/30 min for the remainder of 8h
#
# Layout rules:
#   4 active  → 2×2 quad
#   3 active  → 2×2 quad, empty slot filled with black box
#   2 active  → top/bottom halves (lower player# on top)
#   1 active  → full screen
#
# Join rule: always fills lowest inactive slot whose prerequisite (N-1) is active.
# Quit rule: any active player except the last one.

LOG=/tmp/splitscreen-debug.log
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-unset} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# ─────────────────────────────────────────────────────────────────────────────
# compute_geometry  slot total W H  →  stdout "x y w h"
# Used by nestedPlasma() to write kwinrulesrc (KWin fallback).
# The Python harness has its own layout engine.
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
# write_python_helpers — writes /tmp/splitscreen_test_harness.py
# ─────────────────────────────────────────────────────────────────────────────
write_python_helpers() {
    cat > /tmp/splitscreen_test_harness.py <<'PYEOF'
#!/usr/bin/env python3
"""
8-hour splitscreen windowing test harness.

Simulates Minecraft player join/quit events using GTK windows as stand-ins.

Usage: python3 /tmp/splitscreen_test_harness.py W H
"""

import gi, sys, os, random, time, signal
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

# ── Configuration ─────────────────────────────────────────────────────────────

JOIN_DELAY_S     = 120       # 2-minute loading simulation
TEST_DURATION_S  = 28800     # 8 hours
SEQ_QUIT_GAP_S   = 5         # gap between sequential quits
LABEL_REFRESH_S  = 30        # how often to refresh active-time labels
RANDOM_INTERVALS = [5*60, 15*60, 30*60]   # random phase event intervals

PLAYER_BG = {1: '#1a0000', 2: '#00001a', 3: '#001a00', 4: '#1a1400'}
PLAYER_FG = {1: '#ff4444', 2: '#4466ff', 3: '#44dd44', 4: '#ffcc00'}
BLACK_BOX_BG = '#0a0a0a'
BLACK_BOX_FG = '#333333'

LOG_PATH = '/tmp/splitscreen-debug.log'

# ── Logging ───────────────────────────────────────────────────────────────────

def log(msg):
    ts = time.strftime('%H:%M:%S')
    line = f'[harness {ts}] {msg}'
    try:
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass
    print(line, flush=True)

# ── Layout computation ────────────────────────────────────────────────────────

def compute_layout(active_set, W, H):
    """
    Returns (player_geom, bb_geom) — dicts of {player: (x,y,w,h)}.

    Rules:
      1 active  → full screen
      2 active  → top / bottom halves (lower player# on top)
      3 active  → 2×2 quad; the one empty slot gets a black box entry in bb_geom
      4 active  → 2×2 quad; no black boxes
    """
    hw, hh = W // 2, H // 2
    QUAD = {1: (0, 0, hw, hh), 2: (hw, 0, hw, hh),
            3: (0, hh, hw, hh), 4: (hw, hh, hw, hh)}
    n = len(active_set)

    if n == 0:
        return {}, {}
    if n == 1:
        p = min(active_set)
        return {p: (0, 0, W, H)}, {}
    if n == 2:
        sp = sorted(active_set)
        return {sp[0]: (0, 0, W, hh), sp[1]: (0, hh, W, hh)}, {}
    # n == 3 or 4
    geom   = {p: QUAD[p] for p in active_set}
    bb_geo = {p: QUAD[p] for p in range(1, 5) if p not in active_set}
    return geom, bb_geo

# ── GTK window helpers ────────────────────────────────────────────────────────

def _base_window(title, x, y, w, h):
    win = Gtk.Window()
    win.set_title(title)
    win.set_default_size(w, h)
    win.realize()
    gdk = win.get_window()
    if gdk:
        gdk.set_override_redirect(True)
    win.move(x, y)
    return win

def _rgba(hex_str):
    c = Gdk.RGBA()
    c.parse(hex_str)
    return c

def _make_player_window(p, x, y, w, h):
    win = _base_window(f'SplitscreenP{p}', x, y, w, h)
    ebox = Gtk.EventBox()
    ebox.override_background_color(Gtk.StateFlags.NORMAL, _rgba(PLAYER_BG[p]))
    lbl = Gtk.Label()
    lbl.override_color(Gtk.StateFlags.NORMAL, _rgba(PLAYER_FG[p]))
    lbl.set_markup(f'<span size="xx-large" weight="bold">P{p}</span>')
    lbl.set_justify(Gtk.Justification.CENTER)
    ebox.add(lbl)
    win.add(ebox)
    win._lbl  = lbl
    win._join = time.time()
    win.show_all()
    return win

def _make_black_box(p, x, y, w, h):
    win = _base_window(f'BlackBoxP{p}', x, y, w, h)
    ebox = Gtk.EventBox()
    ebox.override_background_color(Gtk.StateFlags.NORMAL, _rgba(BLACK_BOX_BG))
    lbl = Gtk.Label()
    lbl.override_color(Gtk.StateFlags.NORMAL, _rgba(BLACK_BOX_FG))
    lbl.set_markup(f'<span size="large">P{p}\nempty</span>')
    lbl.set_justify(Gtk.Justification.CENTER)
    ebox.add(lbl)
    win.add(ebox)
    win.show_all()
    return win

def _update_label(win, p, x, y, w, h):
    elapsed = int(time.time() - win._join)
    m, s = divmod(elapsed, 60)
    win._lbl.set_markup(
        f'<span size="xx-large" weight="bold">P{p}</span>\n'
        f'<span size="small">({x},{y})  {w}×{h}\n{m:02d}:{s:02d}</span>'
    )

# ── Harness ───────────────────────────────────────────────────────────────────

class Harness:
    def __init__(self, W, H):
        self.W, self.H  = W, H
        self.active     = {}   # {player: Gtk.Window}
        self.bb_wins    = {}   # {player: Gtk.Window}  black-box placeholders
        self.pending    = set()# players mid 2-min join delay
        self.start_time = time.time()
        self._seq_join  = [2, 3, 4]
        self._seq_quit  = [4, 3, 2]
        self._random_on = False

    # ── Layout ─────────────────────────────────────────────────────────────

    def _reposition(self):
        active_set = set(self.active.keys())
        geom, bb_geom = compute_layout(active_set, self.W, self.H)

        for p, (x, y, w, h) in geom.items():
            win = self.active[p]
            win.resize(w, h)
            win.move(x, y)
            _update_label(win, p, x, y, w, h)

        needed  = set(bb_geom.keys())
        current = set(self.bb_wins.keys())

        for p in current - needed:
            self.bb_wins[p].destroy()
            del self.bb_wins[p]

        for p in needed - current:
            x, y, w, h = bb_geom[p]
            self.bb_wins[p] = _make_black_box(p, x, y, w, h)

        for p in needed & current:
            x, y, w, h = bb_geom[p]
            self.bb_wins[p].resize(w, h)
            self.bb_wins[p].move(x, y)

        layout_desc = f'active={sorted(active_set)} bb={sorted(bb_geom.keys())}'
        log(f'LAYOUT {layout_desc}')

    # ── Join / Quit ─────────────────────────────────────────────────────────

    def _next_join_candidate(self):
        """Lowest inactive player whose prerequisite (N-1) is active."""
        occupied = set(self.active.keys()) | self.pending
        for p in [1, 2, 3, 4]:
            if p not in occupied:
                if p == 1 or (p - 1) in occupied:
                    return p
        return None

    def _quit_candidates(self):
        if len(self.active) <= 1:
            return []
        return sorted(self.active.keys())

    def _trigger_join(self, p):
        self.pending.add(p)
        log(f'JOIN_EVENT P{p} loading (completes in {JOIN_DELAY_S}s)')
        GLib.timeout_add_seconds(JOIN_DELAY_S, self._join_complete, p)

    def _join_complete(self, p):
        self.pending.discard(p)
        # Compute where P's window should go in the new layout
        active_set = set(self.active.keys()) | {p}
        geom, _ = compute_layout(active_set, self.W, self.H)
        x, y, w, h = geom.get(p, (0, 0, self.W, self.H))
        self.active[p] = _make_player_window(p, x, y, w, h)
        self._reposition()
        log(f'JOIN_COMPLETE P{p} → active={sorted(self.active.keys())}')
        return False

    def _trigger_quit(self, p):
        log(f'QUIT P{p} active_before={sorted(self.active.keys())}')
        if p in self.active:
            self.active[p].destroy()
            del self.active[p]
        self._reposition()
        log(f'QUIT P{p} active_after={sorted(self.active.keys())}')

    # ── Phase 1: sequential join ────────────────────────────────────────────

    def _next_seq_join(self):
        if self._seq_join:
            p = self._seq_join.pop(0)
            self._trigger_join(p)
            # Next join fires after this one completes (+2s buffer)
            GLib.timeout_add_seconds(JOIN_DELAY_S + 2, self._next_seq_join)
        else:
            # All 4 joined — pause then start sequential quits
            log('SEQ_JOIN complete — pausing 15s before sequential quit')
            GLib.timeout_add_seconds(15, self._next_seq_quit)
        return False

    # ── Phase 2: sequential quit ────────────────────────────────────────────

    def _next_seq_quit(self):
        if self._seq_quit and len(self.active) > 1:
            p = self._seq_quit.pop(0)
            if p in self.active:
                self._trigger_quit(p)
            GLib.timeout_add_seconds(SEQ_QUIT_GAP_S, self._next_seq_quit)
        else:
            # Sequential phase done
            log('SEQ_QUIT complete — starting random phase')
            self._random_on = True
            self._schedule_random()
        return False

    # ── Phase 3: random events ──────────────────────────────────────────────

    def _schedule_random(self):
        interval = random.choice(RANDOM_INTERVALS)
        log(f'RANDOM next event in {interval // 60}min')
        GLib.timeout_add_seconds(interval, self._random_event)

    def _random_event(self):
        join_p   = self._next_join_candidate()
        quit_ps  = self._quit_candidates()

        options = []
        if join_p is not None:
            options.append(('join', join_p))
        for p in quit_ps:
            options.append(('quit', p))

        if options:
            action, p = random.choice(options)
            log(f'RANDOM action={action} player={p}')
            if action == 'join':
                self._trigger_join(p)
            else:
                self._trigger_quit(p)

        self._schedule_random()
        return False

    # ── Label refresh ───────────────────────────────────────────────────────

    def _refresh_labels(self):
        active_set = set(self.active.keys())
        geom, _ = compute_layout(active_set, self.W, self.H)
        for p, win in self.active.items():
            if p in geom:
                x, y, w, h = geom[p]
                _update_label(win, p, x, y, w, h)
        return True   # repeat

    # ── Start / End ─────────────────────────────────────────────────────────

    def start(self):
        log(f'TEST_START W={self.W} H={self.H} duration=8h')
        # P1 appears immediately (no loading delay for the first player)
        self._join_complete(1)
        # Kick off sequential joins for P2, P3, P4
        GLib.timeout_add_seconds(1, self._next_seq_join)
        # Periodic label refresh
        GLib.timeout_add_seconds(LABEL_REFRESH_S, self._refresh_labels)
        # Auto-exit after 8h
        GLib.timeout_add_seconds(TEST_DURATION_S, self._end_test)

    def _end_test(self):
        elapsed = int(time.time() - self.start_time)
        log(f'TEST_COMPLETE elapsed={elapsed}s')
        Gtk.main_quit()
        return False

# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    W = int(sys.argv[1]) if len(sys.argv) > 1 else 1280
    H = int(sys.argv[2]) if len(sys.argv) > 2 else 800

    log(f'HARNESS init W={W} H={H}')
    signal.signal(signal.SIGINT,  lambda *_: Gtk.main_quit())
    signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())

    h = Harness(W, H)
    GLib.idle_add(h.start)
    Gtk.main()
    log('HARNESS exit')

if __name__ == '__main__':
    main()
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
    echo "[nestedPlasma] W=$W H=$H" >> "$LOG"

    kwriteconfig6 --file kwinrc --group Tiling --key EnableTilingByDefault false 2>/dev/null || true

    # Write KWin rules for all 4 slots as a quad fallback
    {
        echo "[General]"
        echo "count=4"
        for slot in 1 2 3 4; do
            read x y w h < <(compute_geometry "$slot" 4 "$W" "$H")
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

    pkill plasmashell 2>/dev/null || true
    sleep 0.5

    local RES W H
    RES=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}') || true
    [[ -z "$RES" ]] && RES="1280x800"
    W="${RES%x*}"; H="${RES#*x}"
    echo "[launchWindowTest] W=$W H=$H" >> "$LOG"

    export GDK_BACKEND=x11
    write_python_helpers

    GDK_BACKEND=x11 python3 /tmp/splitscreen_test_harness.py "$W" "$H"
    echo "[launchWindowTest] harness exited" >> "$LOG"

    # Tear down nested KDE session — gamescope returns to Steam launcher
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
