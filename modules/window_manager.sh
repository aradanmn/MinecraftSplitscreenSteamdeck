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
# Environment overrides:
#   SPLITSCREEN_SCREEN_W, SPLITSCREEN_SCREEN_H — force screen dimensions
# =============================================================================

# --- Module-level constants ---
readonly WINDOW_MANAGER_DEFAULT_SCREEN_W=1280
readonly WINDOW_MANAGER_DEFAULT_SCREEN_H=800
readonly WINDOW_MANAGER_WINDOW_WAIT_TIMEOUT_S=30

# --- Internal functions ---

# _apply_override_redirect_cycle: Unmap → set override_redirect → move/resize → remap.
# Uses Python + ctypes X11 directly (avoids xdotool which gamescope may ignore).
# The unmap/remap cycle forces the X server to forget the window's WM-managed state;
# setting override_redirect between them makes it unmanaged so gamescope's WM
# won't intercept the MapRequest and force its own geometry.
#
# Arguments: $1 = WID (decimal or hex), $2 = x, $3 = y, $4 = w, $5 = h
# Returns: 0 if the cycle succeeded (verified by post-check), 1 if it failed.
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

# _get_screen_resolution: Discover screen dimensions.
# Priority: wlr-randr → kscreen-doctor → xrandr → xdpyinfo → env override → fallback.
# Output: "W H" on stdout.
_get_screen_resolution() {
    # 1. wlr-randr
    if command -v wlr-randr >/dev/null 2>&1; then
        local wr_output
        wr_output=$(wlr-randr 2>/dev/null || true)
        if [[ -n "$wr_output" ]]; then
            # Parse lines like: "HDMI-A-1 ... 1920x1080@60 ... (current)"
            local wr_line
            wr_line=$(echo "$wr_output" | grep -m1 '(current)' || true)
            if [[ "$wr_line" =~ ([0-9]+)x([0-9]+) ]]; then
                echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
                echo "[window_manager] Screen resolution via wlr-randr: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
                return 0
            fi
        fi
    fi

    # 2. kscreen-doctor
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local ks_output
        ks_output=$(kscreen-doctor -o 2>/dev/null || true)
        if [[ -n "$ks_output" ]]; then
            # Look for enabled primary output's resolution
            local ks_line
            ks_line=$(echo "$ks_output" | grep -m1 'enabled' | grep -v 'eDP' || true)
            if [[ -z "$ks_line" ]]; then
                ks_line=$(echo "$ks_output" | grep -m1 'enabled' || true)
            fi
            if [[ "$ks_line" =~ ([0-9]+)x([0-9]+) ]]; then
                echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
                echo "[window_manager] Screen resolution via kscreen-doctor: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
                return 0
            fi
        fi
    fi

    # 3. xrandr
    if command -v xrandr >/dev/null 2>&1; then
        local xr_output
        xr_output=$(xrandr 2>/dev/null || true)
        if [[ -n "$xr_output" ]]; then
            # Parse the current mode line: "   1920x1080      60.00*+"
            local xr_line
            xr_line=$(echo "$xr_output" | grep -m1 '\*' || true)
            if [[ "$xr_line" =~ ([0-9]+)x([0-9]+) ]]; then
                echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
                echo "[window_manager] Screen resolution via xrandr: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
                return 0
            fi
        fi
    fi

    # 4. xdpyinfo
    if command -v xdpyinfo >/dev/null 2>&1; then
        local xd_output
        xd_output=$(xdpyinfo 2>/dev/null | grep 'dimensions:' || true)
        if [[ "$xd_output" =~ ([0-9]+)x([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
            echo "[window_manager] Screen resolution via xdpyinfo: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" >&2
            return 0
        fi
    fi

    # 5. Environment variable override
    if [[ -n "${SPLITSCREEN_SCREEN_W:-}" && -n "${SPLITSCREEN_SCREEN_H:-}" ]]; then
        echo "${SPLITSCREEN_SCREEN_W} ${SPLITSCREEN_SCREEN_H}"
        echo "[window_manager] Screen resolution via env override: ${SPLITSCREEN_SCREEN_W}x${SPLITSCREEN_SCREEN_H}" >&2
        return 0
    fi

    # 6. Fallback
    echo "[window_manager] All resolution detection methods failed, using fallback ${WINDOW_MANAGER_DEFAULT_SCREEN_W}x${WINDOW_MANAGER_DEFAULT_SCREEN_H}" >&2
    echo "${WINDOW_MANAGER_DEFAULT_SCREEN_W} ${WINDOW_MANAGER_DEFAULT_SCREEN_H}"
    return 0
}

# NOTE: black placeholder windows were removed 2026-06-23. They existed only to mask
# the desktop showing through empty quad cells, but the splitscreen session kills
# plasmashell (black backdrop), so empty cells are already black. The leaked ones
# (their PIDs didn't survive apply_layout's background subshells) were covering the
# real game windows. Empty cells now simply show the black backdrop.

# _verify_window_geometry: After applying positioning, query the actual
# position/size via ctypes and log it.
# $1 = slot label (e.g. "1"), $2 = window WID, $3 = expected_x, $4 = expected_y,
# $5 = expected_w, $6 = expected_h
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
# $1 = slot (1-4)
# Output: WID on stdout, or empty string on failure.
_get_wid_from_state() {
    local slot="$1"
    local sf="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    local wid=""
    # L3: --arg instead of string-interpolating $slot into the filter.
    [[ -f "$sf" ]] && wid=$(jq -r --arg slot "$slot" '.slots[$slot].wid // empty' "$sf" 2>/dev/null || true)
    [[ -z "$wid" ]] && wid=$(dex_search --name "SplitscreenP${slot}" 2>/dev/null || true)
    echo "$wid"
}

# _get_pid_from_state: Read a slot's Minecraft (java) PID from the state JSON.
# $1 = slot (1-4).  Output: PID on stdout, or empty string.
# The KWin positioner matches windows by PID (window.windowId is undefined in
# KWin 6.x), so this is the primary identifier for Path-B positioning.
_get_pid_from_state() {
    local slot="$1"
    local sf="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    # L3: --arg instead of string-interpolating $slot into the filter.
    [[ -f "$sf" ]] && jq -r --arg slot "$slot" '.slots[$slot].pid // empty' "$sf" 2>/dev/null || true
}

# _position_slot: Position a slot's window to an exact cell.
# Path B (preferred): KWin scripting — the window stays KWin-MANAGED and KWin sets
# frameGeometry itself, so there is no override_redirect and nothing to fight. For
# XWayland (X11) windows KWin has synchronous geometry authority, so this is
# reliable (deep-research 2026-06-22). Falls back to the legacy override_redirect
# cycle only if KWin scripting is unreachable. See [[windowing-solution-confirmed]].
# $1=slot $2=x $3=y $4=w $5=h
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

# Determine grid mode from the COUNT of active slots (NOT the highest slot number).
# Arguments: $1 = space-separated list of active slot numbers, e.g. "2 4"
# Output: "full" (1), "half" (2), or "quad" (3-4) on stdout. Empty → "full".
# Count-based so the layout collapses correctly on scale-down: e.g. 2 players in
# slots {2,4} → "half" (two halves), 1 player in slot 4 → "full" (fullscreen).
# (Was highest-slot-based, which left {2,4} as "quad" and a lone slot-4 in a corner.)
compute_grid_mode() {
    local active_slots="${1:-}"
    active_slots=$(echo "$active_slots" | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$active_slots" ]]; then
        echo "full"
        return 0
    fi

    local count=0 slot
    for slot in $active_slots; do
        [[ "$slot" =~ ^[1-4]$ ]] && (( count++ ))
    done

    if   (( count <= 1 )); then echo "full"
    elif (( count == 2 )); then echo "half"
    else                        echo "quad"
    fi
}

# Compute geometry for a CELL INDEX (1-based position in the grid) in a grid mode.
# Arguments: $1=cell(1-4), $2=grid_mode(full|half|quad), $3=screen_w, $4=screen_h
# Output: "x y w h" on stdout. Callers pass the slot's ORDER among active slots (not the
# slot number), so active slots fill cells top-to-bottom / left-to-right.
compute_slot_geometry() {
    local slot="${1:-1}"
    local grid_mode="${2:-full}"
    local screen_w="${3:-1280}"
    local screen_h="${4:-800}"

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

# Apply the full layout for the current active slots.
# Arguments: $1=active_slots (space-separated), $2=screen_w, $3=screen_h
# Effects: repositions the active Minecraft windows via KWin scripting. Grid mode is by
# active COUNT; active slots fill cells by order (so scale-down collapses correctly).
apply_layout() {
    local active_slots="${1:-}"
    local screen_w="${2:-}"
    local screen_h="${3:-}"

    # Resolve screen dimensions if not provided
    if [[ -z "$screen_w" || -z "$screen_h" ]]; then
        local dims
        dims=$(_get_screen_resolution)
        screen_w=$(echo "$dims" | awk '{print $1}')
        screen_h=$(echo "$dims" | awk '{print $2}')
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
    local _gd="${MCSS_GEOM_DIR:-/tmp/mcss-geom}"
    local -a _positioned=()

    for slot in "${active_array[@]}"; do
        [[ "$slot" =~ ^[1-4]$ ]] || continue
        order=$((order+1))
        if [[ "$grid_mode" == "quad" ]]; then cell="$slot"; else cell="$order"; fi
        geometry=$(compute_slot_geometry "$cell" "$grid_mode" "$screen_w" "$screen_h")
        read -r x y w h <<< "$geometry"
        wid=$(_get_wid_from_state "$slot")

        # Skip a window already at its target (same WID + same geom): re-running the
        # override_redirect cycle on an unchanged window would needlessly unmap/remap it
        # (a visible flicker) — the user's "don't move the windows in quad mode". WID-keyed
        # so a NEW instance reusing this slot (different WID) is still positioned; per-slot
        # file so it survives the orchestrator's subshells. Disable via MCSS_SKIP_UNCHANGED=0.
        local _gf="$_gd/slot${slot}"
        local _sig="${wid:-nowid} $x $y $w $h $grid_mode"
        if [[ "${MCSS_SKIP_UNCHANGED:-1}" == "1" && -n "$wid" && "$(cat "$_gf" 2>/dev/null)" == "$_sig" ]]; then
            echo "[window_manager] slot $slot already at ${w}x${h}+${x}+${y} ($grid_mode) — skip reposition (no flicker)" >&2
            continue
        fi

        echo "[window_manager] Repositioning slot $slot → cell $cell ${w}x${h}+${x}+${y} ($grid_mode)" >&2
        _position_slot "$slot" "$x" "$y" "$w" "$h"
        mkdir -p "$_gd" 2>/dev/null; printf '%s' "$_sig" > "$_gf" 2>/dev/null
        echo "[orchestrator] WINDOW SplitscreenP${slot}: ${x},${y} ${w}x${h} ($grid_mode cell $cell) [kwin frameGeometry]" >&2
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
    if [[ "${MCSS_REASSERT:-1}" == "1" && ${#_positioned[@]} -gt 0 ]]; then
        sleep "${MCSS_REASSERT_DELAY_S:-1.2}"
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
# Arguments: same as apply_layout — active_slots, screen_w, screen_h
sync_apply_layout() {
    apply_layout "${1:-}" "${2:-}" "${3:-}"
}
