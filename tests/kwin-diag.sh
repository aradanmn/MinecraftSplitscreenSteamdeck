#!/bin/bash
# =============================================================================
# kwin-diag.sh — dump KWin's view of EVERY active slot's window + test if
#                frameGeometry sticks (per window, to its own correct cell)
# =============================================================================
# Both override_redirect AND KWin's frameGeometry setter fail to move slot 2
# (KWin reports "placed" but the window stays at 1280x359+0+361). To find out
# WHY — and why slot 1 moves but 2/3/4 don't — we ask KWin directly about ALL
# active windows: moveable/resizeable/tile/maximizeMode/min-max size + geometry,
# then set each to its grid cell and read frameGeometry back INSIDE the script.
#
#   geomAfterSet == the target cell -> KWin accepted; something reverts post-script
#   geomAfterSet unchanged          -> KWin REFUSED the set (see resize/min/max/tile)
#
# Usage:  bash tests/kwin-diag.sh         (all active slots; during a live run)
#         bash tests/kwin-diag.sh 2       (just slot 2)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
MODULES="${MCSS_MODULES:-$HOME/.local/share/PolyMC/modules}"
# shellcheck source=/dev/null
source "$MODULES/kwin_positioner.sh" 2>/dev/null || source "$HERE/../modules/kwin_positioner.sh"
if ! kwin_positioner_available; then echo "!! KWin scripting not reachable"; exit 1; fi

# Screen size from the nested XWayland (fallback 1280x720).
SCREEN_W=1280; SCREEN_H=720
for p in $(pgrep -x java 2>/dev/null); do
    d=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
    a=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^XAUTHORITY=//p' | head -1)
    [[ -n "$d" ]] && { dims=$(DISPLAY="$d" XAUTHORITY="${a:-}" xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
        [[ "$dims" =~ ([0-9]+)x([0-9]+) ]] && { SCREEN_W="${BASH_REMATCH[1]}"; SCREEN_H="${BASH_REMATCH[2]}"; }; break; }
done
HW=$(( SCREEN_W/2 )); HH=$(( SCREEN_H/2 ))

mapfile -t ACTIVE < <(jq -r '.slots|to_entries[]|select(.value.active==true)|.key' "$STATE" 2>/dev/null)
[[ "${1:-}" =~ ^[0-9]+$ ]] && ACTIVE=("$1")   # explicit single slot if numeric arg
N=${#ACTIVE[@]}
cell() { local s="$1" c="$2"
    if   (( c<=1 )); then echo "0 0 $SCREEN_W $SCREEN_H"
    elif (( c==2 )); then case "$s" in 1) echo "0 0 $SCREEN_W $HH";; 2) echo "0 $HH $SCREEN_W $HH";; esac
    else case "$s" in 1) echo "0 0 $HW $HH";; 2) echo "$HW 0 $HW $HH";; 3) echo "0 $HH $HW $HH";; 4) echo "$HW $HH $HW $HH";; esac; fi; }

# Build targets JS: [{pid,slot,x,y,w,h}, ...]
targets="["
echo "=== KWin diag : ${N} active slots (${ACTIVE[*]:-none}) , ${SCREEN_W}x${SCREEN_H} ==="
for s in "${ACTIVE[@]}"; do
    pid=$(jq -r ".slots[\"$s\"].pid // empty" "$STATE" 2>/dev/null); [[ -z "$pid" ]] && continue
    read -r x y w h <<< "$(cell "$s" "$N")"
    echo "  slot $s pid $pid -> cell $x,$y ${w}x${h}"
    targets+="{pid:${pid},slot:${s},x:${x},y:${y},w:${w},h:${h}},"
done
targets="${targets%,}]"

name="mcss_diag_$$_${RANDOM}"; jsfile="/tmp/${name}.js"
cat > "$jsfile" <<KWINJS
(function () {
    var targets = ${targets};
    var wins = (typeof workspace.windowList === "function") ? workspace.windowList() : workspace.clientList();
    var out = [];
    for (var t = 0; t < targets.length; t++) {
        var tg = targets[t], matched = 0;
        for (var i = 0; i < wins.length; i++) {
            var w = wins[i];
            if (!w || w.pid !== tg.pid) continue;
            matched++;
            var b = Object.assign({}, w.frameGeometry);
            var line = "slot" + tg.slot + " winId=" + w.windowId + " cap='" + w.caption + "'" +
                " normal=" + w.normalWindow + " special=" + w.specialWindow +
                " move=" + w.moveable + " resize=" + w.resizeable +
                " full=" + w.fullScreen + " maxMode=" + w.maximizeMode +
                " tile=" + (w.tile ? "SET" : "null") +
                " min=" + (w.minSize ? (w.minSize.width + "x" + w.minSize.height) : "?") +
                " max=" + (w.maxSize ? (w.maxSize.width + "x" + w.maxSize.height) : "?") +
                " before=" + b.width + "x" + b.height + "+" + b.x + "+" + b.y;
            try { w.tile = null; } catch (e) { line += " [tileErr]"; }
            try { if (typeof w.setMaximize === "function") w.setMaximize(false, false); } catch (e) {}
            try { w.fullScreen = false; } catch (e) {}
            try { w.noBorder = true; } catch (e) {}
            var g = Object.assign({}, w.frameGeometry); g.x = tg.x; g.y = tg.y; g.width = tg.w; g.height = tg.h;
            w.frameGeometry = g;
            var a = Object.assign({}, w.frameGeometry);
            line += " AFTERSET=" + a.width + "x" + a.height + "+" + a.x + "+" + a.y +
                    " want=" + tg.w + "x" + tg.h + "+" + tg.x + "+" + tg.y;
            out.push(line);
        }
        if (matched === 0) out.push("slot" + tg.slot + " NOMATCH pid=" + tg.pid);
    }
    print("[kwin_diag] " + out.join("  |||  "));
})();
KWINJS

id=$(kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$jsfile" "$name" 2>/dev/null | tr -dc '0-9')
echo "loadScript id=$id"
kwin_qdbus org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script.run >/dev/null 2>&1 || \
  kwin_qdbus org.kde.KWin "/${id}" org.kde.kwin.Script.run >/dev/null 2>&1
sleep 0.5
kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1
rm -f "$jsfile"
echo "=== KWin diag output (journal) — one line per window ==="
journalctl --user -t kwin_wayland --since "10 sec ago" 2>/dev/null | grep -a kwin_diag | tail -3 | tr '|' '\n'
