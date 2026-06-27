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
# finds each target window by PID, clears any tile/maximize/fullscreen state (only
# when set), and sets frameGeometry to the exact cell. KWin is the one moving the
# window, so there is no race and nothing to re-grab. We deliberately do NOT toggle
# noBorder in the PER-REFLOW place path (it makes KWin recreate the frame → unmaps the
# client + clobbers geometry). Decoration is handled separately by kwin_set_noborder,
# called ONCE per window at spawn (before positioning).
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
#   kwin_place_windows "PID X Y W H" ... -> place each (pid -> cell) via frameGeometry
#   kwin_set_noborder <pid>              -> strip title bar/border once (at spawn)
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
        # H7: validate every field is an integer before interpolating into the JS
        # literal. A blank/garbage field would otherwise emit e.g. `pid:abc` — a bare
        # identifier that throws or silently matches nothing inside the KWin script.
        if ! [[ "$pid" =~ ^[0-9]+$ && "$x" =~ ^-?[0-9]+$ && "$y" =~ ^-?[0-9]+$ \
                && "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
            echo "[kwin_positioner] WARNING: skipping malformed target spec '$spec'" >&2
            continue
        fi
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
            // Clear any state that would override geometry — but ONLY when actually
            // set, so we never trigger a no-op state change. Crucially we do NOT
            // toggle w.noBorder: setting it makes KWin destroy+recreate the window
            // frame, which unmaps the client and clobbers the geometry we set in the
            // same pass (the unmap / not-sticking bug). Decoration is handled once via
            // a window rule if needed; the inherent ~1px border is tolerated.
            try { if (w.tile) w.tile = null; } catch (e) {}
            try { if (typeof w.setMaximize === "function" && w.maximizeMode !== 0) w.setMaximize(false, false); } catch (e) {}
            try { if (w.fullScreen) w.fullScreen = false; } catch (e) {}
            var g = Object.assign({}, w.frameGeometry);
            g.x = tgt.x; g.y = tgt.y; g.width = tgt.w; g.height = tgt.h;
            w.frameGeometry = g;
            // Force a REPAINT of a possibly-occluded (black) tile. Research 2026-06-27: when a
            // window is fully occluded, KWin (Wayland) withholds wl_surface.frame callbacks
            // and the client stops painting; on uncover it can keep a stale/black buffer. A
            // position-only frameGeometry change is a repaint NO-OP (matches what we saw); a
            // RESIZE forces XWayland to recreate its buffer; a raise is racy (helped at 3
            // windows, not 4). So nudge the SIZE by 1px and back to force a reconfigure. The
            // REAL fix is the forced-centered map rule (no tile ever fully occluded) — this is
            // the fallback. (UNTESTED — Deck unavailable. If still black, escalate to a
            // minimize toggle: w.minimized = true; w.minimized = false;)
            try {
                var gj = Object.assign({}, g); gj.width = tgt.w + 1;
                w.frameGeometry = gj;
                w.frameGeometry = g;
                if (typeof workspace.raiseWindow === "function") workspace.raiseWindow(w);
            } catch (e) {}
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
    # H8: do NOT strip non-digits with `tr -dc '0-9'` — that turns an error reply like
    # "ERROR: 123" into the bogus script id "123". Capture raw, then require the whole
    # trimmed string to be a plain integer.
    id=$(kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$jsfile" "$name" 2>/dev/null)
    id="${id//[$'\t\r\n ']/}"
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
        echo "[kwin_positioner] ERROR: loadScript returned no valid id (got '${id}')" >&2
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

# kwin_set_noborder <pid>: strip the title bar/border from the window(s) owned by <pid>
# via KWin scripting (w.noBorder = true), ONCE. Setting noBorder makes KWin recreate the
# decoration (a brief reparent), so call this exactly once when the window first appears —
# NOT per reflow (repeated recreates unmap/clobber geometry). Replaces the at-map "No
# titlebar and frame" window rule, which is unreliable because Minecraft sets its caption/
# WM_CLASS only AFTER mapping, so the rule has nothing to match at evaluation time.
kwin_set_noborder() {
    local pid="$1"
    [[ -z "$pid" ]] && return 1
    if ! _kwin_import_session_env; then
        echo "[kwin_positioner] ERROR: org.kde.KWin not reachable (noborder)" >&2
        return 1
    fi
    local name="mcss_noborder_${pid}_${RANDOM}" jsfile="/tmp/${name}.js"
    cat > "$jsfile" <<KWINJS
(function () {
    var wins = (typeof workspace.windowList === "function") ? workspace.windowList() : workspace.clientList();
    var n = 0;
    for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        if (!w || w.pid !== ${pid}) continue;
        if (w.specialWindow || w.desktopWindow || w.dock) continue;
        try { w.noBorder = true; n++; } catch (e) {}
    }
    print("[kwin_noborder] pid=${pid} set noBorder on " + n + " window(s)");
})();
KWINJS
    local id
    # H8: do NOT strip non-digits with `tr -dc '0-9'` — that turns an error reply like
    # "ERROR: 123" into the bogus script id "123". Capture raw, then require the whole
    # trimmed string to be a plain integer.
    id=$(kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$jsfile" "$name" 2>/dev/null)
    id="${id//[$'\t\r\n ']/}"
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
        echo "[kwin_positioner] ERROR: loadScript returned no valid id (got '${id}')" >&2
        rm -f "$jsfile"
        return 1
    fi

    kwin_qdbus org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script.run >/dev/null 2>&1 \
        || kwin_qdbus org.kde.KWin "/${id}" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 0.2
    kwin_qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1
    rm -f "$jsfile"
    return 0
}
