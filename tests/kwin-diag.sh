#!/bin/bash
# =============================================================================
# kwin-diag.sh — dump KWin's view of a slot's window + test if frameGeometry sticks
# =============================================================================
# Both override_redirect AND KWin's frameGeometry setter fail to move slot 2
# (KWin reports "placed" but the window stays at 1280x359+0+361). This means the
# window is pinned by some KWin/X state. This script asks KWin directly: for every
# window matching a pid, print moveable/resizeable/tile/maximizeMode/min-max size
# (fixed-hint detection) + frameGeometry, then SET frameGeometry to 640,0 640x360
# and read it back INSIDE the script.
#
#   geomAfterSet == 640x360+640+0  -> KWin accepted; something reverts post-script
#   geomAfterSet unchanged         -> KWin REFUSED the set (see resize/min/max/tile)
#
# Usage:  bash tests/kwin-diag.sh [slot]     (default slot 2, during a live run)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
MODULES="${MCSS_MODULES:-$HOME/.local/share/PolyMC/modules}"
SLOT="${1:-2}"
# shellcheck source=/dev/null
source "$MODULES/kwin_positioner.sh" 2>/dev/null || source "$HERE/../modules/kwin_positioner.sh"

if ! kwin_positioner_available; then echo "!! KWin scripting not reachable"; exit 1; fi
pid=$(jq -r ".slots[\"$SLOT\"].pid // empty" "$STATE" 2>/dev/null)
[[ -z "$pid" ]] && { echo "!! slot $SLOT has no pid in state"; exit 1; }
echo "=== KWin diag for slot $SLOT (pid $pid) ==="

name="mcss_diag_$$_${RANDOM}"; jsfile="/tmp/${name}.js"
cat > "$jsfile" <<KWINJS
(function () {
    var pid = ${pid};
    var wins = (typeof workspace.windowList === "function") ? workspace.windowList() : workspace.clientList();
    var out = [];
    for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        if (!w || w.pid !== pid) continue;
        var b = Object.assign({}, w.frameGeometry);
        var line = "WIN winId=" + w.windowId + " internalId=" + w.internalId +
            " cap='" + w.caption + "' cls=" + w.resourceClass +
            " normal=" + w.normalWindow + " special=" + w.specialWindow +
            " move=" + w.moveable + " resize=" + w.resizeable +
            " full=" + w.fullScreen + " maxMode=" + w.maximizeMode +
            " tile=" + (w.tile ? "SET" : "null") +
            " min=" + (w.minSize ? (w.minSize.width + "x" + w.minSize.height) : "?") +
            " max=" + (w.maxSize ? (w.maxSize.width + "x" + w.maxSize.height) : "?") +
            " geomBefore=" + b.width + "x" + b.height + "+" + b.x + "+" + b.y;
        try { w.tile = null; } catch (e) { line += " [tileErr:" + e + "]"; }
        try { if (typeof w.setMaximize === "function") w.setMaximize(false, false); } catch (e) { line += " [maxErr]"; }
        try { w.fullScreen = false; } catch (e) {}
        try { w.noBorder = true; } catch (e) {}
        var g = Object.assign({}, w.frameGeometry); g.x = 640; g.y = 0; g.width = 640; g.height = 360;
        w.frameGeometry = g;
        var a = Object.assign({}, w.frameGeometry);
        line += " geomAfterSet=" + a.width + "x" + a.height + "+" + a.x + "+" + a.y;
        out.push(line);
    }
    if (out.length === 0) out.push("NOMATCH pid=" + pid + " (window not in KWin list)");
    print("[kwin_diag] " + out.join(" ||| "));
})();
KWINJS

id=$(kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$jsfile" "$name" 2>/dev/null | tr -dc '0-9')
echo "loadScript id=$id"
kwin_qdbus org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script.run >/dev/null 2>&1 || \
  kwin_qdbus org.kde.KWin "/${id}" org.kde.kwin.Script.run >/dev/null 2>&1
sleep 0.5
kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1
rm -f "$jsfile"
echo "=== KWin diag output (journal) ==="
journalctl --user -t kwin_wayland --since "8 sec ago" 2>/dev/null | grep -a kwin_diag | tail -5
