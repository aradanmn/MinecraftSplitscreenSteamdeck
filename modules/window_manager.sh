#!/bin/bash
set -euo pipefail

# =============================================================================
# WINDOW MANAGER MODULE
# =============================================================================
# Computes window geometry for splitscreen Minecraft instances and applies
# layout via xdotool. Maintains black placeholder windows for vacant slots.
#
# Public API:
#   compute_grid_mode(active_slots)          — stdout: "full", "half", or "quad"
#   compute_slot_geometry(slot, grid, W, H)  — stdout: "x y w h"
#   apply_layout(active_slots, W, H)         — repositions active windows (KWin scripting)
#
# Globals CONSUMED (from runtime_context.sh unless noted): MCSS_SCREEN_W,
#   MCSS_SCREEN_H, MCSS_MAX_PLAYERS, MCSS_WINDOW_TITLE_PREFIX, MCSS_GEOM_DIR.
#   Legacy override: SPLITSCREEN_SCREEN_W/H. Tuning overrides:
#   MCSS_REASSERT, MCSS_REASSERT_DELAY_S, MCSS_SKIP_UNCHANGED (and their
#   WINDOW_MANAGER_-prefixed aliases, checked first — see apply_layout).
#
# Inputs:  state JSON via instance_lifecycle accessors (get_window_id,
#          get_java_pid), KWin scripting via kwin_positioner.sh.
# Outputs: repositioned windows (dex/KWin), per-slot geom cache files under
#          MCSS_GEOM_DIR, stderr `[window_manager]` prefix.
#
# Environment overrides:
#   SPLITSCREEN_SCREEN_W, SPLITSCREEN_SCREEN_H — force screen dimensions
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.4 2026-07-17  Fix #86: dead-constant cleanup; #51/D11 state accessors
#   v1.3 2026-07-09  #45/#53: screen/prefix/geom-dir globals via
#                    runtime_context.sh
#   v1.2 2026-07-05  Fix #57 (UNTESTED): settle+re-assert covers full mode too
#   v1.1 2026-06-27  Override_redirect cycle restored as PRIMARY path
#                    (repaints occluded tiles)
#   v1.0 2026-06-13  Initial extraction: KWin-scripting geometry + layout
# =============================================================================

# #45: window-title prefix, slot count, and geom dir are owned by
# runtime_context.sh. Sourcing it here is idempotent (process-local sentinels)
# and makes standalone sourcing (unit tests) behave like the launcher prologue.
source "$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh"

# --- Module-level constants ---
# Fix #86: WINDOW_MANAGER_WINDOW_WAIT_TIMEOUT_S deleted — zero references
# repo-wide (dead constant, #86 item c).

# --- Internal functions ---

# _apply_override_redirect_cycle: Unmap → set override_redirect → move/resize → remap.
# Uses Python + ctypes X11 directly (avoids xdotool which gamescope may ignore).
# The unmap/remap cycle forces the X server to forget the window's WM-managed state;
# setting override_redirect between them makes it unmanaged so gamescope's WM
# won't intercept the MapRequest and force its own geometry.
#
# Inputs:
#   $1 — WID (decimal or hex), $2 — x, $3 — y, $4 — w, $5 — h
# Outputs:
#   return — 0 if the cycle succeeded (verified by post-check), 1 if it
#     failed (dex.sh not sourced, or the remap readback was empty)
#   side effects — stderr readback/failure diagnostics, `[window_manager]`
#     prefix
_apply_override_redirect_cycle() {
    local wid="$1" x="$2" y="$3" w="$4" h="$5"

    # Delegate to dex.sh — the single, verified X11 layer (ctypes via libX11).
    # This replaced earlier divergent inline ctypes copies of the same logic,
    # which is exactly how the pointer-truncation / valuemask / struct bugs crept
    # in.  dex's move/resize is confirmed on-Deck to position windows in the
    # nested XWayland (override_redirect + XConfigure).
    if ! type dex_move_resize_remap >/dev/null 2>&1; then
        echo "[window_manager] ERROR: dex.sh not sourced — cannot position window $wid" >&2
        return 1
    fi

    # Full cycle: unmap → set override_redirect → move/resize → map → raise.
    # Setting override_redirect on a live KWin-managed window makes KWin unmanage
    # and UNMAP it, and the change only applies at the next map (ICCCM).  The old
    # code set override_redirect + XConfigure but never remapped, so reflowed
    # windows ended up with the correct geometry but UNMAPPED (invisible) — the
    # "windows disappear when a second player joins" bug.  dex_move_resize_remap
    # performs the whole cycle and echoes the geometry readback.
    local geo
    geo=$(dex_move_resize_remap "$wid" "$x" "$y" "$w" "$h" 2>/dev/null || echo "")
    echo "[window_manager] dex remap: window $wid → ${w}x${h}+${x}+${y} readback=[${geo:-?}]" >&2

    [[ -n "$geo" ]] && return 0
    echo "[window_manager] dex remap FAILED for window $wid" >&2
    return 1
}

# (#45/D7: _get_screen_resolution DELETED — mcss_resolve_screen in
# runtime_context.sh is the one cascade, env-override-FIRST. This module's copy
# checked the SPLITSCREEN_SCREEN_W/H override only AFTER all four probes, so a
# test harness's forced dimensions lost to the live display; it also carried
# the eDP-before-head kscreen ordering bug. Callers read MCSS_SCREEN_W/H.)

# NOTE: black placeholder windows were removed 2026-06-23. They existed only to mask
# the desktop showing through empty quad cells, but the splitscreen session kills
# plasmashell (black backdrop), so empty cells are already black. The leaked ones
# (their PIDs didn't survive apply_layout's background subshells) were covering the
# real game windows. Empty cells now simply show the black backdrop.

# _verify_window_geometry: After applying positioning, query the actual
# position/size via ctypes and log it.
# Inputs:
#   $1 — slot label (e.g. "1"), $2 — window WID
#   $3 — expected_x, $4 — expected_y, $5 — expected_w, $6 — expected_h
# Outputs:
#   side effects — WARNING/OK line to stderr; no return-code contract (always
#     returns 0, this is a diagnostic-only check)
_verify_window_geometry() {
    local slot="$1" wid="$2"
    local ex="$3" ey="$4" ew="$5" eh="$6"
    local ax ay aw ah
    local geo
    # ONE query captures all four fields atomically. The previous code re-queried for
    # ah on a second line (H4), pairing a stale aw with a fresh ah and inverting the
    # match whenever the window moved between the two reads.
    geo=$(dex_getgeometry "$wid" 2>/dev/null || echo "")
    read -r ax ay aw ah <<< "$geo"
    # H5: require all four to be integers before any numeric comparison — a partial or
    # empty read would otherwise crash the [[ -ne ]] test with "operand expected".
    if [[ "$ax" =~ ^-?[0-9]+$ && "$ay" =~ ^-?[0-9]+$ && "$aw" =~ ^[0-9]+$ && "$ah" =~ ^[0-9]+$ ]]; then
        if [[ "$ax" -ne "$ex" || "$ay" -ne "$ey" || "$aw" -ne "$ew" || "$ah" -ne "$eh" ]]; then
            echo "[window_manager] WARNING: slot $slot geometry mismatch: wanted ${ex},${ey} ${ew}x${eh} but got ${ax},${ay} ${aw}x${ah}" >&2
        else
            echo "[window_manager] Verify slot $slot: geometry OK (${ax},${ay} ${aw}x${ah})" >&2
        fi
    else
        echo "[window_manager] WARNING: slot $slot geometry check failed — could not query window $wid (got '${geo}')" >&2
    fi
}

# _get_wid_from_state: Read a slot's WID from the state JSON file, or fall back
# to dex window-name search if missing.
# Inputs:
#   $1 — slot (1-4)
#   Globals: MCSS_WINDOW_TITLE_PREFIX (read)
# Outputs:
#   stdout — WID, or empty string on failure
_get_wid_from_state() {
    local slot="$1"
    local wid=""
    # Fix #51 (D11/D12): the state read goes through the instance_lifecycle
    # accessor (dex.sh's fallback-less copy of this lookup is deleted); the
    # dex window-name search stays as this module's fallback.
    wid=$(get_window_id "$slot" 2>/dev/null || true)
    [[ -z "$wid" ]] && wid=$(dex_search --name "${MCSS_WINDOW_TITLE_PREFIX}${slot}" 2>/dev/null || true)
    echo "$wid"
}

# _get_pid_from_state: Read a slot's Minecraft (java) PID from the state JSON.
# The KWin positioner matches windows by PID (window.windowId is undefined in
# KWin 6.x), so this is the primary identifier for Path-B positioning.
# Inputs: $1 — slot (1-4)
# Outputs: stdout — PID, or empty string
_get_pid_from_state() {
    # Fix #51 (D11): thin alias over the instance_lifecycle accessor.
    get_java_pid "$1" 2>/dev/null || true
}

# _position_slot: Position a slot's window to an exact cell.
# Path B (preferred): KWin scripting — the window stays KWin-MANAGED and KWin sets
# frameGeometry itself, so there is no override_redirect and nothing to fight. For
# XWayland (X11) windows KWin has synchronous geometry authority, so this is
# reliable (deep-research 2026-06-22). Falls back to the legacy override_redirect
# cycle only if KWin scripting is unreachable. See [[windowing-solution-confirmed]].
# Inputs:
#   $1 — slot, $2 — x, $3 — y, $4 — w, $5 — h
# Outputs:
#   return — 0 on success, 1 if no wid/pid was available to position (or the
#     chosen positioning path itself failed)
#   side effects — repositions the window (dex or KWin scripting), stderr
#     PATH-CAPTURE diagnostic line
_position_slot() {
    local slot="$1" x="$2" y="$3" w="$4" h="$5"
    local pid wid
    pid=$(_get_pid_from_state "$slot")
    wid=$(_get_wid_from_state "$slot")

    # PATH A (2026-06-27): the override_redirect cycle is now the PRIMARY positioning path.
    # It does a real unmap→remap, which FORCES the client to repaint — the managed
    # frameGeometry path does NOT, so an occluded tile stayed black (proven via PATH-CAPTURE:
    # both tiles MANAGED, the occluded one black; raise/resize-jiggle/minimize-toggle all
    # failed). This is the mechanism that originally fixed "windows disappear when a second
    # player joins"; the 2026-06-22 switch to managed frameGeometry re-introduced the
    # black-out. Use override_redirect CONSISTENTLY (every placement) so we never mix managed
    # and override on the same window — that mixing is the code-review's H2 one-way-unmanage
    # concern. Managed (frameGeometry) is kept ONLY as a fallback when no WID is known.
    if [[ -n "$wid" ]] && type dex_move_resize_remap >/dev/null 2>&1; then
        echo "[window_manager] PATH-CAPTURE slot=$slot pid=${pid:-none} wid=$wid → OVERRIDE-REDIRECT(repaints,PRIMARY) target=${w}x${h}+${x}+${y}" >&2
        _apply_override_redirect_cycle "$wid" "$x" "$y" "$w" "$h"
        return $?
    fi
    if [[ -n "$pid" ]] && type kwin_place_windows >/dev/null 2>&1 && kwin_positioner_available; then
        echo "[window_manager] PATH-CAPTURE slot=$slot pid=$pid wid=none → MANAGED-frameGeometry(FALLBACK,no-repaint) target=${w}x${h}+${x}+${y}" >&2
        kwin_place_windows "$pid $x $y $w $h"
        echo "[window_manager] KWin-positioned slot $slot (pid $pid) → ${w}x${h}+${x}+${y} (managed, frameGeometry)" >&2
        return 0
    fi
    echo "[window_manager] slot $slot: no wid or pid available to position" >&2
    return 1
}

# --- Public API ---

# compute_grid_mode: Determine grid mode from the COUNT of active slots (NOT
# the highest slot number).
# Count-based so the layout collapses correctly on scale-down: e.g. 2 players in
# slots {2,4} → "half" (two halves), 1 player in slot 4 → "full" (fullscreen).
# (Was highest-slot-based, which left {2,4} as "quad" and a lone slot-4 in a corner.)
# Inputs:
#   $1 — space-separated list of active slot numbers, e.g. "2 4"
#   Globals: MCSS_MAX_PLAYERS (read)
# Outputs:
#   stdout — "full" (1 active), "half" (2), or "quad" (3-4); empty → "full"
compute_grid_mode() {
    local active_slots="${1:-}"
    active_slots=$(echo "$active_slots" | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$active_slots" ]]; then
        echo "full"
        return 0
    fi

    local count=0 slot
    for slot in $active_slots; do
        [[ "$slot" =~ ^[1-${MCSS_MAX_PLAYERS}]$ ]] && count=$(( count + 1 ))
    done

    if   (( count <= 1 )); then echo "full"
    elif (( count == 2 )); then echo "half"
    else                        echo "quad"
    fi
}

# compute_slot_geometry: Compute geometry for a CELL INDEX (1-based position
# in the grid) in a grid mode. Callers pass the slot's ORDER among active
# slots (not the slot number), so active slots fill cells top-to-bottom /
# left-to-right.
# Inputs:
#   $1 — cell (1-4), $2 — grid_mode (full|half|quad)
#   $3 — screen_w, $4 — screen_h
# Outputs:
#   stdout — "x y w h"
#   return — 1 on an unknown grid_mode (still emits a full-screen fallback)
compute_slot_geometry() {
    local slot="${1:-1}"
    local grid_mode="${2:-full}"
    local screen_w="${3:-${MCSS_SCREEN_W:-1280}}"
    local screen_h="${4:-${MCSS_SCREEN_H:-800}}"

    case "$grid_mode" in
        full)
            echo "0 0 $screen_w $screen_h"
            ;;
        half)
            local half_h=$(( screen_h / 2 ))
            case "$slot" in
                1) echo "0 0 $screen_w $half_h" ;;
                2) echo "0 $half_h $screen_w $half_h" ;;
                *) echo "0 0 $screen_w $screen_h" ;; # fallback for invalid slot
            esac
            ;;
        quad)
            local half_w=$(( screen_w / 2 ))
            local half_h=$(( screen_h / 2 ))
            case "$slot" in
                1) echo "0 0 $half_w $half_h" ;;
                2) echo "$half_w 0 $half_w $half_h" ;;
                3) echo "0 $half_h $half_w $half_h" ;;
                4) echo "$half_w $half_h $half_w $half_h" ;;
                *) echo "0 0 $screen_w $screen_h" ;; # fallback for invalid slot
            esac
            ;;
        *)
            echo "[window_manager] ERROR: unknown grid mode '$grid_mode'" >&2
            echo "0 0 $screen_w $screen_h"
            return 1
            ;;
    esac
}

# apply_layout: Apply the full layout for the current active slots. Grid mode
# is by active COUNT; active slots fill cells by order (so scale-down
# collapses correctly).
# Inputs:
#   $1 — active_slots (space-separated), $2 — screen_w, $3 — screen_h
#   Globals: MCSS_MAX_PLAYERS, MCSS_GEOM_DIR, MCSS_WINDOW_TITLE_PREFIX (read)
# Outputs:
#   side effects — repositions the active Minecraft windows (dex/KWin
#     scripting), writes per-slot geom cache files, stderr
#     `[window_manager]`/`[orchestrator]` diagnostic lines
apply_layout() {
    local active_slots="${1:-}"
    local screen_w="${2:-}"
    local screen_h="${3:-}"

    # Resolve screen dimensions if not provided (#45: canonical resolver)
    if [[ -z "$screen_w" || -z "$screen_h" ]]; then
        mcss_resolve_screen
        screen_w="$MCSS_SCREEN_W"
        screen_h="$MCSS_SCREEN_H"
    fi

    local grid_mode
    grid_mode=$(compute_grid_mode "$active_slots")

    echo "[window_manager] Applying layout: active_slots='$active_slots', grid=$grid_mode, ${screen_w}x${screen_h}" >&2

    # List visible windows for debugging (via dex — the single X11 layer).
    # Best-effort; never use xdotool here (its search/getwindowname can block
    # indefinitely inside gamescope's XWayland, freezing the synchronous caller).
    if type dex_list_windows >/dev/null 2>&1; then
        echo "[window_manager] All visible windows (via dex):" >&2
        dex_list_windows 2>/dev/null | while read -r w name; do
            echo "  $w: $name" >&2
        done
    fi

    # Cell assignment (2026-06-27, user request — stable quadrants):
    #   QUAD (3-4 players): cell = SLOT NUMBER → each player pinned to a FIXED quadrant
    #     (P1=UL, P2=UR, P3=LL, P4=LR). A join/leave in quad mode never reshuffles the
    #     others — P4 joining only fills LR; P3 leaving only empties LL.
    #   HALF/FULL (1-2 players): cell = ORDER among active slots → a scale-down collapses
    #     cleanly (2 survivors → top/bottom halves, 1 → fullscreen) regardless of WHICH
    #     slot numbers remain (compute_slot_geometry's half mode only defines cells 1-2).
    # compute_slot_geometry maps a cell index → rectangle (quad cell1=UL..cell4=LR).
    local -a active_array=($active_slots)
    local slot cell geometry x y w h wid order=0
    # MCSS_GEOM_DIR is path-group (set by mcss_resolve_paths, not at source
    # time) — resolve idempotently here so standalone callers get the canonical
    # value instead of an unbound-variable abort.
    mcss_resolve_paths
    local _gd="$MCSS_GEOM_DIR"
    local -a _positioned=()

    for slot in "${active_array[@]}"; do
        [[ "$slot" =~ ^[1-${MCSS_MAX_PLAYERS}]$ ]] || continue
        order=$((order+1))
        if [[ "$grid_mode" == "quad" ]]; then cell="$slot"; else cell="$order"; fi
        geometry=$(compute_slot_geometry "$cell" "$grid_mode" "$screen_w" "$screen_h")
        read -r x y w h <<< "$geometry"
        wid=$(_get_wid_from_state "$slot")

        # Skip a window already at its target (same WID + same geom): re-running the
        # override_redirect cycle on an unchanged window would needlessly unmap/remap it
        # (a visible flicker) — the user's "don't move the windows in quad mode". WID-keyed
        # so a NEW instance reusing this slot (different WID) is still positioned; per-slot
        # file so it survives the orchestrator's subshells. Disable via WINDOW_MANAGER_SKIP_UNCHANGED=0 (#53: MCSS_ prefix now means runtime_context-owned; old MCSS_ names honored one release).
        local _gf="$_gd/slot${slot}"
        local _sig="${wid:-nowid} $x $y $w $h $grid_mode"
        if [[ "${WINDOW_MANAGER_SKIP_UNCHANGED:-${MCSS_SKIP_UNCHANGED:-1}}" == "1" && -n "$wid" && "$(cat "$_gf" 2>/dev/null)" == "$_sig" ]]; then
            echo "[window_manager] slot $slot already at ${w}x${h}+${x}+${y} ($grid_mode) — skip reposition (no flicker)" >&2
            continue
        fi

        echo "[window_manager] Repositioning slot $slot → cell $cell ${w}x${h}+${x}+${y} ($grid_mode)" >&2
        _position_slot "$slot" "$x" "$y" "$w" "$h"
        mkdir -p "$_gd" 2>/dev/null; printf '%s' "$_sig" > "$_gf" 2>/dev/null
        echo "[orchestrator] WINDOW ${MCSS_WINDOW_TITLE_PREFIX}${slot}: ${x},${y} ${w}x${h} ($grid_mode cell $cell) [kwin frameGeometry]" >&2
        [[ -n "$wid" ]] && _verify_window_geometry "$slot" "$wid" "$x" "$y" "$w" "$h"
        _positioned+=("$slot:$x:$y:$w:$h")
    done

    # Settle + single re-assert (the "let it settle, then position" fix) — ONLY for slots
    # actually (re)positioned this round. A freshly-mapped Minecraft/XWayland window is still
    # finishing setup when first positioned, so KWin can drop the geometry; one re-assert
    # after a short settle makes it hold. Skipped/unchanged tiles are already settled and
    # must NOT be re-cycled (that would re-introduce the flicker we just avoided).
    # Fix #57 (2026-07-05, UNTESTED): re-assert for FULL mode too. Previously gated to
    # non-full, which left the single handheld window without the settle+re-assert that
    # catches a freshly-mapped window dropping its geometry/map — an early contributor to
    # the black-screen-with-audio bug (the LATE unmap is handled by spawn_instance's
    # map-keeper). The _positioned guard already limits this to slots actually
    # (re)positioned this round, so unchanged tiles are never re-cycled (no flicker).
    if [[ "${WINDOW_MANAGER_REASSERT:-${MCSS_REASSERT:-1}}" == "1" && ${#_positioned[@]} -gt 0 ]]; then
        sleep "${WINDOW_MANAGER_REASSERT_DELAY_S:-${MCSS_REASSERT_DELAY_S:-1.2}}"
        local _p
        for _p in "${_positioned[@]}"; do
            IFS=: read -r slot x y w h <<< "$_p"
            _position_slot "$slot" "$x" "$y" "$w" "$h"
        done
        echo "[window_manager] re-asserted ${#_positioned[@]} (re)positioned slot(s)" >&2
    fi
}

# (kill_all_placeholders removed 2026-06-23 — placeholders no longer exist.)

# sync_apply_layout: thin wrapper around apply_layout, kept so existing callers
# don't need to change. (It used to branch to the gamescope-windowing approach,
# now removed — window positioning is always done by apply_layout on nested KWin.)
# Inputs: same as apply_layout — $1=active_slots, $2=screen_w, $3=screen_h
sync_apply_layout() {
    apply_layout "${1:-}" "${2:-}" "${3:-}"
}
