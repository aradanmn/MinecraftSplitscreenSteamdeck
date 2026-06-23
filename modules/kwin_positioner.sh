#!/bin/bash
# =============================================================================
# kwin_positioner.sh — position windows by working WITH KWin (Plasma 6)
# =============================================================================
# Replaces the override_redirect "wrestle the window away from KWin" approach,
# which only ever won for the first window (test 4, 2026-06-22: slots 2/3/4 kept
# KWin's ±1 decoration frame and were re-grabbed/re-placed by KWin every time —
# slot 2 never moved a single pixel). See [[windowing-solution-confirmed]] /
# TODO Issue A.
#
# Instead we drive KWin's OWN scripting API over D-Bus: load a one-shot JS that
# finds each target window by PID, detaches it from any tile, unmaximizes it,
# removes its border (noBorder), and sets frameGeometry to the exact cell. KWin
# is the one moving the window, so there is no race and nothing to re-grab.
#
# ONE-SHOT by design: we load → run → unload each call. We do NOT install a
# persistent windowAdded hook — the old persistent "Border Enforcer" KWin script
# caused the Game Mode memory-leak race (see MEMORY). Re-assert on each reflow.
#
# Requires: KWin 6.x (Plasma 6) reachable as org.kde.KWin on the session bus, and
# qdbus6 (or qdbus). In production the orchestrator runs INSIDE the nested Plasma
# session, so org.kde.KWin is already on its ambient bus. For external testing
# (SSH), _kwin_import_session_env pulls the nested session's bus from the running
# kwin_wayland's /proc/environ.
#
# Public API:
#   kwin_positioner_available            -> 0 if KWin scripting is reachable
#   kwin_place_windows "PID X Y W H" ... -> place each (pid -> cell), borderless
# =============================================================================

# qdbus wrapper — prefer the Qt6 build (Plasma 6).
kwin_qdbus() {
    if command -v qdbus6 >/dev/null 2>&1; then qdbus6 "$@"
    elif command -v qdbus >/dev/null 2>&1; then qdbus "$@"
    else return 127; fi
}

# Ensure org.kde.KWin is reachable. In-session this is a no-op (the ambient bus
# IS the nested Plasma session bus). Externally (test harness over SSH) we import
# DBUS_SESSION_BUS_ADDRESS + XDG_RUNTIME_DIR from a nested-session process so qdbus
# talks to the SAME bus KWin is on. We try every candidate process and VERIFY each
# address actually reaches org.kde.KWin before committing — the process tree is
# kwin_wayland_wrapper -> kwin_wayland and `pgrep -x` on the bare comm is flaky, so
# match cmdlines and probe.
_kwin_import_session_env() {
    if kwin_qdbus org.kde.KWin >/dev/null 2>&1; then return 0; fi

    local p addr rtd
    for p in $(pgrep -af 'kwin_wayland|startplasma-wayland|plasma_session' 2>/dev/null | awk '{print $1}'); do
        [[ -r "/proc/$p/environ" ]] || continue
        addr=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)
        [[ -z "$addr" ]] && continue
        rtd=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^XDG_RUNTIME_DIR=//p' | head -1)
        if DBUS_SESSION_BUS_ADDRESS="$addr" XDG_RUNTIME_DIR="${rtd:-${XDG_RUNTIME_DIR:-}}" \
               kwin_qdbus org.kde.KWin >/dev/null 2>&1; then
            export DBUS_SESSION_BUS_ADDRESS="$addr"
            [[ -n "$rtd" ]] && export XDG_RUNTIME_DIR="$rtd"
            return 0
        fi
    done
    return 1
}

kwin_positioner_available() {
    command -v qdbus6 >/dev/null 2>&1 || command -v qdbus >/dev/null 2>&1 || return 1
    _kwin_import_session_env
}

# kwin_place_windows "PID X Y W H" ["PID X Y W H" ...]
# Generates a one-shot KWin script that places each matched window and prints a
# per-target report (placed / NOMATCH) to the KWin journal. Returns 0 if the
# script loaded+ran, 1 otherwise. Geometry is verified separately (wintree).
kwin_place_windows() {
    if ! _kwin_import_session_env; then
        echo "[kwin_positioner] ERROR: org.kde.KWin not reachable (Plasma 6 session up?)" >&2
        return 1
    fi
    if [[ $# -eq 0 ]]; then return 0; fi

    # Build the targets JS array literal: [{pid:N,x:..,y:..,w:..,h:..}, ...]
    local targets_js="[" spec pid x y w h
    for spec in "$@"; do
        read -r pid x y w h <<< "$spec"
        [[ -z "$pid" || -z "$h" ]] && continue
        targets_js+="{pid:${pid},x:${x},y:${y},w:${w},h:${h}},"
    done
    targets_js="${targets_js%,}]"
    [[ "$targets_js" == "[]" ]] && return 0

    # Unique plugin name + temp file per invocation (loadScript won't reload a
    # name that's already loaded; unique avoids that and accumulation).
    local name jsfile
    name="mcss_place_$$_${RANDOM}"
    jsfile="/tmp/${name}.js"

    cat > "$jsfile" <<KWINJS
(function () {
    var targets = ${targets_js};
    var wins = (typeof workspace.windowList === "function")
             ? workspace.windowList() : workspace.clientList();
    var report = [];
    for (var t = 0; t < targets.length; t++) {
        var tgt = targets[t];
        var placed = 0;
        for (var i = 0; i < wins.length; i++) {
            var w = wins[i];
            if (!w || w.pid !== tgt.pid) continue;
            if (w.specialWindow || w.desktopWindow || w.dock) continue;
            try { w.tile = null; } catch (e) {}
            try { if (typeof w.setMaximize === "function") w.setMaximize(false, false); } catch (e) {}
            try { w.fullScreen = false; } catch (e) {}
            try { w.noBorder = true; } catch (e) {}
            try { w.keepAbove = false; } catch (e) {}
            var g = Object.assign({}, w.frameGeometry);
            g.x = tgt.x; g.y = tgt.y; g.width = tgt.w; g.height = tgt.h;
            w.frameGeometry = g;
            placed++;
            report.push("placed pid=" + tgt.pid + " -> " + tgt.x + "," + tgt.y +
                        " " + tgt.w + "x" + tgt.h + " [" + w.caption + "]");
        }
        if (placed === 0) report.push("NOMATCH pid=" + tgt.pid);
    }
    print("[kwin_positioner] " + report.join(" | "));
})();
KWINJS

    local id
    id=$(kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$jsfile" "$name" 2>/dev/null | tr -dc '0-9')
    if [[ -z "$id" ]]; then
        echo "[kwin_positioner] ERROR: loadScript returned no id" >&2
        rm -f "$jsfile"
        return 1
    fi

    # Plasma 6 script object path is /Scripting/Script<id>; fall back to /<id>.
    if ! kwin_qdbus org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script.run >/dev/null 2>&1; then
        kwin_qdbus org.kde.KWin "/${id}" org.kde.kwin.Script.run >/dev/null 2>&1
    fi
    # Let run() apply the geometry before we unload (unload can abort a live run).
    sleep 0.2
    kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1
    rm -f "$jsfile"
    return 0
}
