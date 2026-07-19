#!/bin/bash
# =============================================================================
# Hardware Test Helper Library
# =============================================================================
# Sourced by all stage scripts. Provides logging, assertions, operator prompts,
# diagnostic dumps, and orchestrator lifecycle helpers.
#
# Expected exported variables (set by run_all.sh before sourcing):
#   HW_LOG            — path to the master log file
#   REPO_ROOT         — absolute path to the repo
#   HW_PASSED         — running pass counter (integer)
#   HW_FAILED         — running fail counter (integer)
#   HW_SKIPPED        — running skip counter (integer)
#   SPLITSCREEN_STATE — path to state JSON file
#   SPLITSCREEN_FIFO  — path to orchestrator FIFO
# =============================================================================

# Guard against double-sourcing
[[ -n "${_HW_HELPERS_LOADED:-}" ]] && return 0
readonly _HW_HELPERS_LOADED=1

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# hw_log: timestamp + message → stdout + logfile
hw_log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[${ts}] $*"
    echo "$msg" | tee -a "${HW_LOG:-/dev/stderr}"
}

# hw_info: [INFO] prefix
hw_info() {
    hw_log "[INFO] $*"
}

# hw_warn: [WARN] prefix
hw_warn() {
    hw_log "[WARN] $*"
}

# hw_section: section header with === delimiters
hw_section() {
    local line="============================================================"
    hw_log "$line"
    hw_log "  $*"
    hw_log "$line"
}

# ---------------------------------------------------------------------------
# Test result counters
# ---------------------------------------------------------------------------

# hw_pass: print [PASS] and increment counter
hw_pass() {
    hw_log "[PASS] $*"
    HW_PASSED=$(( ${HW_PASSED:-0} + 1 ))
}

# hw_fail: print [FAIL] and increment counter
hw_fail() {
    hw_log "[FAIL] $*"
    HW_FAILED=$(( ${HW_FAILED:-0} + 1 ))
}

# hw_skip: print [SKIP] and increment counter
hw_skip() {
    hw_log "[SKIP] $*"
    HW_SKIPPED=$(( ${HW_SKIPPED:-0} + 1 ))
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# hw_assert_eq LABEL EXPECTED ACTUAL
hw_assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        hw_pass "${label} — expected=${expected} actual=${actual}"
    else
        hw_fail "${label} — expected=\"${expected}\" actual=\"${actual}\""
    fi
}

# hw_assert_match LABEL REGEX ACTUAL
hw_assert_match() {
    local label="$1"
    local regex="$2"
    local actual="$3"
    if [[ "$actual" =~ $regex ]]; then
        hw_pass "${label} — matched /${regex}/ in \"${actual}\""
    else
        hw_fail "${label} — \"${actual}\" did not match /${regex}/"
    fi
}

# hw_assert_nonempty LABEL VALUE
hw_assert_nonempty() {
    local label="$1"
    local value="$2"
    if [[ -n "$value" ]]; then
        hw_pass "${label} — value is non-empty"
    else
        hw_fail "${label} — value is EMPTY (expected non-empty)"
    fi
}

# hw_assert_empty LABEL VALUE
hw_assert_empty() {
    local label="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        hw_pass "${label} — value is empty (as expected)"
    else
        hw_fail "${label} — expected empty, got \"${value}\""
    fi
}

# hw_assert_cmd LABEL COMMAND...
# Passes if COMMAND exits 0, fails otherwise.
hw_assert_cmd() {
    local label="$1"
    shift
    hw_log "Running: $*"
    local rc=0
    "$@" >> "${HW_LOG:-/dev/stderr}" 2>&1 || rc=$?
    if (( rc == 0 )); then
        hw_pass "${label} — command exited 0"
    else
        hw_fail "${label} — command exited ${rc}"
    fi
}

# ---------------------------------------------------------------------------
# Operator prompt
# ---------------------------------------------------------------------------

# hw_prompt ACTION_DESCRIPTION
# Prints what the operator needs to do, waits for Enter.
# Returns 1 if operator types 'skip', 0 otherwise.
hw_prompt() {
    local action="$1"
    echo "" | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log ">>> OPERATOR ACTION REQUIRED <<<"
    hw_log ">>> ${action}"
    hw_log ">>> Press Enter when done, or type 'skip' and Enter to skip this step."
    echo "" | tee -a "${HW_LOG:-/dev/stderr}"

    local response
    if ! read -r response 2>/dev/null; then
        hw_warn "hw_prompt: stdin closed, treating as skip"
        return 1
    fi
    hw_log ">>> Operator response: \"${response}\""

    if [[ "${response,,}" == "skip" ]]; then
        return 1
    fi
    return 0
}

# hw_confirm QUESTION
# Asks a yes/no question. Returns 0 for yes, 1 for no/skip.
hw_confirm() {
    local question="$1"
    echo "" | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log ">>> CONFIRM: ${question} [y/N]"

    local response
    if ! read -r response 2>/dev/null; then
        hw_warn "hw_confirm: stdin closed, treating as no"
        return 1
    fi
    hw_log ">>> Operator confirmed: \"${response}\""

    if [[ "${response,,}" =~ ^y ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Diagnostic dumps
# ---------------------------------------------------------------------------

# hw_dump_state: jq-pretty-print the state file
hw_dump_state() {
    hw_log "--- STATE FILE DUMP: ${SPLITSCREEN_STATE} ---"
    if [[ -f "${SPLITSCREEN_STATE:-}" ]]; then
        jq '.' "${SPLITSCREEN_STATE}" 2>&1 | tee -a "${HW_LOG:-/dev/stderr}"
    else
        hw_log "(state file does not exist)"
    fi
    hw_log "--- END STATE DUMP ---"
}

# hw_dump_processes: pgrep -af for bwrap/PolyMC/latestUpdate
hw_dump_processes() {
    hw_log "--- PROCESS DUMP ---"
    {
        echo "[bwrap processes]"
        pgrep -af 'bwrap' 2>/dev/null || echo "  <none>"
        echo "[PolyMC/latestUpdate processes]"
        pgrep -af 'PolyMC\.AppImage|latestUpdate' 2>/dev/null || echo "  <none>"
        echo "[java processes]"
        pgrep -af 'java.*latestUpdate' 2>/dev/null || echo "  <none>"
    } | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log "--- END PROCESS DUMP ---"
}

# hw_dump_input_devices: cat /proc/bus/input/devices filtered to 28de:11ff
hw_dump_input_devices() {
    hw_log "--- INPUT DEVICES (28de:11ff) ---"
    {
        awk '
            /^$/ { in_block=0; vendor=""; product="" }
            /Vendor=28de/ { vendor="28de" }
            /Product=11ff/ { product="11ff" }
            { if (!in_block) { block="" }; block=block"\n"$0; in_block=1 }
            /^$/ { if (vendor=="28de" && product=="11ff") print block }
        ' /proc/bus/input/devices 2>/dev/null || echo "  <unable to read /proc/bus/input/devices>"
    } | tee -a "${HW_LOG:-/dev/stderr}"
    hw_log "--- END INPUT DEVICES ---"
}

# ---------------------------------------------------------------------------
# Wait for condition
# ---------------------------------------------------------------------------

# hw_wait_for LABEL TIMEOUT_S COMMAND...
# Polls COMMAND every 1s. hw_pass if exits 0 within TIMEOUT_S, hw_fail otherwise.
# Does NOT abort on timeout — returns 1 so caller can continue.
hw_wait_for() {
    local label="$1"
    local timeout_s="$2"
    shift 2
    local cmd=("$@")

    hw_log "Waiting up to ${timeout_s}s for: ${label}"
    hw_log "  Check command: ${cmd[*]}"

    local elapsed=0
    while (( elapsed < timeout_s )); do
        local rc=0
        "${cmd[@]}" >> "${HW_LOG:-/dev/stderr}" 2>&1 || rc=$?
        if (( rc == 0 )); then
            hw_pass "${label} (after ${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    hw_fail "${label} — timed out after ${timeout_s}s"
    return 1
}

# ---------------------------------------------------------------------------
# Screen and window geometry
# ---------------------------------------------------------------------------

# hw_nested_display: resolve the display the game windows actually live on.
# The orchestrator runs INSIDE the nested session, so its windows are on the
# nested KWin's Xwayland — NOT on the ambient gamescope display this harness
# runs under (found on-Deck 2026-07-05: every window assert failed on :1
# while the SplitscreenP1 window sat fullscreen on :2).
# Fix #83: the old heuristic (last `pgrep -a Xwayland` line carrying
# '-auth') resolved the OUTER gamescope Xwayland when both servers were up:
# every geometry assert then measured the outer root (1920x1080 TV) while
# the windows tiled on the nested 1280x720 root (2026-07-15 run; earlier
# passes were coincidence — both roots happened to be 1280x720). Resolve
# from the nested session's OWN record instead, mirroring the production
# discrimination rather than process-list order:
#   1. OUR nested kwin_wayland's cmdline --xwayland-display /
#      --xwayland-xauthority ("ours" iff its environ carries
#      SPLITSCREEN_DEBUG_LOG= — the #58 marker hw_reap_stale_session
#      already scopes by; same cmdline source instance_lifecycle's
#      _detect_xauthority uses for the cookie).
#   2. The environ of a marked process INSIDE the nested session
#      (MCSS_NESTED_SESSION non-0 — the runtime's own inside-the-session
#      discriminator, set on every re-invoke Exec/env line): prefer its
#      MCSS_DISPLAY (mcss_set_display's single-writer value), else the
#      DISPLAY the nested kwin spawned it with. The bare-kwin testNested
#      path needs this leg: kwin auto-picks the X display and ignores
#      --xwayland-display (see launchNested).
# Sets HW_XDO_DISPLAY / HW_XDO_XAUTH; falls back to ambient when no nested
# session is up. Re-resolved per call (via hw_xdo) so a session restart
# mid-stage picks up the fresh display/auth pair.
hw_nested_display() {
    HW_XDO_DISPLAY=""
    HW_XDO_XAUTH=""
    local _pid _args _env _disp=""
    local _re_disp='--xwayland-display[= ](:[0-9]+)'
    local _re_auth='--xwayland-xauthority[= ]([^ ]+)'
    # 1. Our nested kwin's own cmdline record. Last match wins — highest
    #    pid is the freshest if a dying predecessor lingers mid-restart.
    for _pid in $(pgrep -x kwin_wayland 2>/dev/null || true); do
        grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/${_pid}/environ" \
            2>/dev/null || continue
        _args=$(tr '\0' ' ' < "/proc/${_pid}/cmdline" 2>/dev/null || true)
        [[ "$_args" =~ $_re_disp ]] && HW_XDO_DISPLAY="${BASH_REMATCH[1]}"
        [[ "$_args" =~ $_re_auth ]] && HW_XDO_XAUTH="${BASH_REMATCH[1]}"
    done
    # 2. Environ of a marked process inside the nested session (the
    #    re-invoked prodFromPlasma / testFromPlasma / _nestedSession).
    if [[ -z "$HW_XDO_DISPLAY" ]]; then
        for _pid in $(pgrep -f 'minecraftSplitscreen' 2>/dev/null || true); do
            _env=$(tr '\0' '\n' < "/proc/${_pid}/environ" 2>/dev/null \
                || true)
            [[ -n "$_env" ]] || continue
            grep -q '^SPLITSCREEN_DEBUG_LOG=' <<<"$_env" || continue
            grep -q '^MCSS_NESTED_SESSION=' <<<"$_env" || continue
            grep -q '^MCSS_NESTED_SESSION=0$' <<<"$_env" && continue
            if [[ -z "$HW_XDO_XAUTH" ]]; then
                HW_XDO_XAUTH=$(sed -n 's/^XAUTHORITY=//p' <<<"$_env" \
                    | head -1)
            fi
            HW_XDO_DISPLAY=$(sed -n 's/^MCSS_DISPLAY=//p' <<<"$_env" \
                | head -1)
            [[ -n "$HW_XDO_DISPLAY" ]] && break
            if [[ -z "$_disp" ]]; then
                _disp=$(sed -n 's/^DISPLAY=//p' <<<"$_env" | head -1)
            fi
        done
        HW_XDO_DISPLAY="${HW_XDO_DISPLAY:-$_disp}"
    fi
    # 3. No nested session found — ambient display (pre-launch stages).
    HW_XDO_DISPLAY="${HW_XDO_DISPLAY:-${DISPLAY:-:0}}"
    HW_XDO_XAUTH="${HW_XDO_XAUTH:-${XAUTHORITY:-}}"
}

# hw_xdo CMD [ARGS...]: run an X client (xdotool/xdpyinfo/...) against the
# nested game display resolved by hw_nested_display.
hw_xdo() {
    hw_nested_display
    DISPLAY="$HW_XDO_DISPLAY" XAUTHORITY="$HW_XDO_XAUTH" "$@"
}

# hw_window_visible TITLE: true if a visible window with TITLE exists on the
# nested game display. Usable directly as a hw_wait_for check command.
hw_window_visible() {
    hw_xdo xdotool search --onlyvisible --name "$1" >/dev/null 2>&1
}

# hw_get_screen_resolution: echo "WxH" (e.g. "1920x1080") for the display the
# game windows tile on (the nested session root when one is up).
hw_get_screen_resolution() {
    local res
    res=$(hw_xdo xdpyinfo 2>/dev/null \
        | awk '/dimensions:/{print $2}' | head -1 || true)
    [[ -n "$res" ]] && { echo "$res"; return 0; }
    res=$(hw_xdo xrandr 2>/dev/null \
        | awk '/\*/{print $1}' | head -1 || true)
    [[ -n "$res" ]] && { echo "$res"; return 0; }
    hw_warn "hw_get_screen_resolution: could not detect resolution, assuming 1280x800"
    echo "1280x800"
}

# hw_expected_slot_geometry SLOT ACTIVE_SLOTS SCREEN_W SCREEN_H
# Prints: "X Y W H" for the expected window position of SLOT given the set
# of active slots and screen dimensions. Matches compute_slot_geometry logic.
hw_expected_slot_geometry() {
    local slot="$1" active="$2" sw="$3" sh="$4"

    local count
    count=$(echo "$active" | wc -w)

    # Determine grid mode (mirrors compute_grid_mode in window_manager.sh)
    local grid="full"
    if (( count >= 2 )); then
        grid="half"
        local s
        for s in $active; do
            if (( s >= 3 )); then grid="quad"; break; fi
        done
    fi
    if (( count >= 3 )); then grid="quad"; fi

    local hw=$(( sw / 2 ))
    local hh=$(( sh / 2 ))

    case "$grid" in
        full) echo "0 0 ${sw} ${sh}" ;;
        half)
            case "$slot" in
                1) echo "0 0 ${sw} ${hh}" ;;
                2) echo "0 ${hh} ${sw} ${hh}" ;;
                *) echo "0 0 ${sw} ${sh}" ;;
            esac ;;
        quad)
            case "$slot" in
                1) echo "0 0 ${hw} ${hh}" ;;
                2) echo "${hw} 0 ${hw} ${hh}" ;;
                3) echo "0 ${hh} ${hw} ${hh}" ;;
                4) echo "${hw} ${hh} ${hw} ${hh}" ;;
                *) echo "0 0 ${sw} ${sh}" ;;
            esac ;;
    esac
}

# hw_slot_wid SLOT: the window id the orchestrator recorded for SLOT in the
# state file — the product's own source of truth. Title-based lookup is only
# valid during boot: Minecraft RENAMES its window (SplitscreenPn -> "Minecraft*
# <version>") once fully loaded (observed on-Deck 2026-07-05).
hw_slot_wid() {
    jq -r ".slots[\"${1}\"].wid // empty" "${SPLITSCREEN_STATE}" 2>/dev/null || true
}

# hw_slot_window_visible SLOT: true when SLOT's recorded window is viewable on
# the nested game display. Usable as a hw_wait_for check command.
hw_slot_window_visible() {
    local wid
    wid=$(hw_slot_wid "$1")
    [[ -n "$wid" && "$wid" != "null" ]] || return 1
    hw_xdo xwininfo -id "$wid" 2>/dev/null | grep -q "Map State: IsViewable"
}

# hw_assert_slot_window_at LABEL SLOT EXP_X EXP_Y EXP_W EXP_H [TOL] [BUDGET_S]
# Geometry assert against SLOT's recorded wid, RETRYING until the window
# converges on the expected box or the budget runs out — placement is
# asynchronous (initial 854x480 window, layout re-asserts seconds later), so a
# single-shot read races it (on-Deck 2026-07-05). Records once; returns 0.
hw_assert_slot_window_at() {
    local label="$1" slot="$2" exp_x="$3" exp_y="$4" exp_w="$5" exp_h="$6"
    local tol="${7:-50}" budget="${8:-45}"
    local elapsed=0 wid geom X Y WIDTH HEIGHT SCREEN WINDOW dx dy dw dh
    while (( elapsed < budget )); do
        wid=$(hw_slot_wid "$slot")
        if [[ -n "$wid" && "$wid" != "null" ]]; then
            geom=$(hw_xdo xdotool getwindowgeometry --shell "$wid" 2>/dev/null || true)
            if [[ -n "$geom" ]]; then
                X=0; Y=0; WIDTH=0; HEIGHT=0; SCREEN=0; WINDOW=0
                eval "$geom"
                dx=$(( X - exp_x ));      (( dx < 0 )) && dx=$(( -dx ))
                dy=$(( Y - exp_y ));      (( dy < 0 )) && dy=$(( -dy ))
                dw=$(( WIDTH - exp_w ));  (( dw < 0 )) && dw=$(( -dw ))
                dh=$(( HEIGHT - exp_h )); (( dh < 0 )) && dh=$(( -dh ))
                if (( dx <= tol && dy <= tol && dw <= tol && dh <= tol )); then
                    hw_pass "${label} — slot ${slot} wid ${wid} at ${X},${Y} ${WIDTH}x${HEIGHT} (converged after ${elapsed}s)"
                    return 0
                fi
            fi
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    hw_fail "${label} — slot ${slot} did not reach ${exp_x},${exp_y} ${exp_w}x${exp_h} within ${budget}s (last: ${X:-?},${Y:-?} ${WIDTH:-?}x${HEIGHT:-?}, wid ${wid:-none})"
    return 0
}

# hw_assert_window_at LABEL TITLE EXP_X EXP_Y EXP_W EXP_H [TOLERANCE_PX]
# Fails if the named window is not found or is not within TOLERANCE of the
# expected position. Tolerates window-manager decoration offsets.
# Like every hw_assert_*, this records the failure and RETURNS 0 — the stage
# scripts run under set -euo pipefail and call asserts bare, so a nonzero
# return here killed the whole run at the first failed assert (on-Deck
# 2026-07-05; the suite's contract is count-and-continue, summary at exit).
hw_assert_window_at() {
    local label="$1" title="$2" exp_x="$3" exp_y="$4" exp_w="$5" exp_h="$6"
    local tol="${7:-50}"

    local wid
    wid=$(hw_xdo xdotool search --onlyvisible --name "$title" \
        2>/dev/null | head -1 || true)

    if [[ -z "$wid" ]]; then
        hw_fail "${label} — window '${title}' not visible on DISPLAY=${HW_XDO_DISPLAY:-?} (nested game display)"
        return 0
    fi

    local geom
    geom=$(hw_xdo xdotool getwindowgeometry --shell "$wid" \
        2>/dev/null || true)

    if [[ -z "$geom" ]]; then
        hw_fail "${label} — could not read geometry for window '${title}' (id ${wid})"
        return 0
    fi

    # geom sets X, Y, WIDTH, HEIGHT, SCREEN, WINDOW
    local X=0 Y=0 WIDTH=0 HEIGHT=0 SCREEN=0 WINDOW=0
    eval "$geom"

    hw_log "${label}: '${title}' (id ${wid}) → actual=${X},${Y} ${WIDTH}x${HEIGHT}"
    hw_log "${label}: expected=${exp_x},${exp_y} ${exp_w}x${exp_h} (tolerance ±${tol}px)"

    local ok=1

    local dx=$(( X - exp_x )); [[ $dx -lt 0 ]] && dx=$(( -dx ))
    local dy=$(( Y - exp_y )); [[ $dy -lt 0 ]] && dy=$(( -dy ))
    local dw=$(( WIDTH - exp_w )); [[ $dw -lt 0 ]] && dw=$(( -dw ))
    local dh=$(( HEIGHT - exp_h )); [[ $dh -lt 0 ]] && dh=$(( -dh ))

    if (( dx > tol )); then
        hw_fail "${label} — X off: expected ${exp_x} got ${X} (Δ${dx}px > ±${tol})"; ok=0; fi
    if (( dy > tol )); then
        hw_fail "${label} — Y off: expected ${exp_y} got ${Y} (Δ${dy}px > ±${tol})"; ok=0; fi
    if (( dw > tol )); then
        hw_fail "${label} — WIDTH off: expected ${exp_w} got ${WIDTH} (Δ${dw}px > ±${tol})"; ok=0; fi
    if (( dh > tol )); then
        hw_fail "${label} — HEIGHT off: expected ${exp_h} got ${HEIGHT} (Δ${dh}px > ±${tol})"; ok=0; fi

    if (( ok == 1 )); then
        hw_pass "${label} — '${title}' at correct position (${X},${Y} ${WIDTH}x${HEIGHT})"
    fi
}

# hw_assert_splitscreen_properties LABEL SLOT EXPECTED_MODE [LAUNCHER_DIR]
# Verifies the splitscreen.properties file written by the orchestrator
# contains the expected mode value before Minecraft reads it.
hw_assert_splitscreen_properties() {
    local label="$1" slot="$2" expected_mode="$3"
    # The Splitscreen Support mod that consumed splitscreen.properties was removed
    # 2026-06-23 (_write_splitscreen_properties deleted with it); KWin does the
    # tiling, and layout correctness is asserted via hw_assert_window_at geometry.
    # Kept as a recorded skip so stage logs keep their check IDs (found asserting
    # against the removed file during first on-Deck stage3 runs, 2026-07-05).
    hw_skip "${label} — splitscreen.properties retired 2026-06-23 (mode ${expected_mode}, slot ${slot} covered by window geometry assert)"
    return 0
}

# ---------------------------------------------------------------------------
# Structured operator checklist
# ---------------------------------------------------------------------------

# hw_checklist TITLE ITEM [ITEM ...]
# Presents each item to the operator one at a time.
# Operator types: y=confirmed, n=NOT seen/wrong, s=skip.
# Increments HW_PASSED/FAILED/SKIPPED for each item.
# Returns number of failed items.
hw_checklist() {
    local title="$1"
    shift
    local -a items=("$@")
    local failed=0

    hw_log ""
    hw_log "━━━ CHECKLIST: ${title} ━━━"
    hw_log "    For each item type: y=yes/confirmed  n=no/wrong  s=skip"
    hw_log ""

    local i
    for i in "${!items[@]}"; do
        local num=$(( i + 1 ))
        local item="${items[$i]}"

        echo "" | tee -a "${HW_LOG:-/dev/stderr}"
        hw_log "  [${num}/${#items[@]}] ${item}"
        hw_log "  → y / n / s :"

        local response=""
        if ! read -r response 2>/dev/null; then
            hw_warn "stdin closed — treating remaining checklist items as skip"
            hw_skip "${title} [${num}]: ${item}"
            continue
        fi
        hw_log "  Operator: '${response}'"

        case "${response,,}" in
            y|yes)  hw_pass "${title} [${num}]: ${item}" ;;
            s|skip) hw_skip "${title} [${num}]: ${item}" ;;
            *)
                hw_fail "${title} [${num}]: ${item}"
                failed=$(( failed + 1 ))
                ;;
        esac
    done

    hw_log "━━━ End checklist: ${title} ━━━"
    hw_log ""
    # Record-and-continue: failures are already counted via hw_fail. Returning
    # the failed-count made a single 'n' answer kill the whole run under the
    # stage scripts' set -euo pipefail (same errexit class as #58/#60).
    return 0
}

# ---------------------------------------------------------------------------
# Display environment
# ---------------------------------------------------------------------------

# hw_detect_display: set/export DISPLAY (and XAUTHORITY when found), for
# xdotool/xrandr, before any nested session exists — hw_nested_display takes
# over the discrimination once one is up (Fix #83 above).
# Fallback ladder, most to least trusted:
#   1. DISPLAY already set (operator/environment) — leave it alone.
#   2. A live Xwayland server's own cmdline: its ":N" arg, plus an -auth
#      path when the server carries one. HW-1 (2026-07-18): Game Mode's
#      gamescope Xwaylands are AUTHLESS —
#        Xwayland :0 -rootless -core -terminate -listenfd 90 ...
#        Xwayland :1 -rootless -core -terminate -listenfd 92 ...
#      — while Desktop Mode's Plasma Xwayland carries -auth (the shape
#      _detect_xauthority/instance_lifecycle.sh and input-heartbeat.sh's
#      _derive_x target). So ":N" is required, -auth is optional. Gamescope
#      runs one Xwayland per screen; prefer the lowest :N when several are
#      live and log the rest as candidates, not winners.
#   3. `who` — last resort only. HW-1 (2026-07-18): an SSH login row
#      polluted `who` and this picked a bogus :40 on-Deck, so this leg is
#      logged as a WARN rather than trusted silently.
hw_detect_display() {
    if [[ -n "${DISPLAY:-}" ]]; then
        hw_info "DISPLAY already set: ${DISPLAY}"
        return 0
    fi

    local xw_lines
    xw_lines=$(pgrep -af Xwayland 2>/dev/null || true)
    if [[ -n "$xw_lines" ]]; then
        local line disp best="" best_auth="" all=()
        while IFS= read -r line; do
            [[ "$line" =~ [[:space:]](:[0-9]+)([[:space:]]|$) ]] || continue
            disp="${BASH_REMATCH[1]}"
            all+=("$disp")
            if [[ -z "$best" ]] || (( ${disp#:} < ${best#:} )); then
                best="$disp"
                best_auth=""
                if [[ "$line" =~ -auth[[:space:]]+([^[:space:]]+) ]]; then
                    best_auth="${BASH_REMATCH[1]}"
                fi
            fi
        done <<<"$xw_lines"

        if [[ -n "$best" ]]; then
            export DISPLAY="$best"
            if [[ -n "$best_auth" ]]; then
                export XAUTHORITY="$best_auth"
                hw_info "DISPLAY derived from Xwayland cmdline" \
                    "(auth-bearing): ${DISPLAY}, XAUTHORITY=${XAUTHORITY}"
            else
                hw_info "DISPLAY derived from Xwayland cmdline" \
                    "(authless gamescope): ${DISPLAY}"
            fi
            if (( ${#all[@]} > 1 )); then
                hw_info "Live Xwayland displays: ${all[*]}" \
                    "(selected ${best})"
            fi
            return 0
        fi
    fi

    # Last resort: `who` (unreliable under SSH — see header comment above)
    local auth_display
    auth_display=$(who 2>/dev/null | grep -oP ':\d+' | head -1 || true)
    if [[ -n "$auth_display" ]]; then
        export DISPLAY="$auth_display"
        hw_warn "DISPLAY set from who output (last resort): ${DISPLAY}"
        return 0
    fi

    # Last resort fallback
    export DISPLAY=":0"
    hw_warn "Could not auto-detect DISPLAY, defaulting to :0"
    return 0
}

# ---------------------------------------------------------------------------
# Orchestrator lifecycle
# ---------------------------------------------------------------------------

# HW_ORCH_PID — exported PID of the running orchestrator
HW_ORCH_PID=""

# hw_launch_orchestrator MODE
# Launches minecraftSplitscreen.sh launchFromPlasma with SPLITSCREEN_MODE set.
# Waits up to 5s for FIFO to appear. Exports HW_ORCH_PID.
# hw_reap_stale_session: pre-launch hygiene. Back-to-back suite runs race the
# previous session's teardown: the new launch's STARTUP GUARD kills the old
# nested tree asynchronously while this harness's first checks read the OLD
# state file and probe the OLD (dying) windows — stale passes, then phantom
# fails (on-Deck 2026-07-05). Reap the old session HERE, synchronously, and
# reset the state file so every launch starts from a known-clean slate.
# Ours-only scoping mirrors the launcher's #58 guard: a process is ours iff
# its environ carries SPLITSCREEN_DEBUG_LOG=.
hw_reap_stale_session() {
    local _name _pid _tries
    # Stale run trees first (#60): a prior run's orchestrator/watchdog/monitor/
    # supervisor survives its session's death and keeps acting on the shared
    # state file/FIFO — one of them killed a fresh session's instance ~25s after
    # boot during the first on-Deck stage3 runs. Kill the actors before the
    # scenery. (This harness process doesn't match: its cmdline is the stage
    # script, not minecraftSplitscreen.sh, and it carries no marker.)
    for _pid in $(pgrep -f 'minecraftSplitscreen' 2>/dev/null || true); do
        grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$_pid/environ" 2>/dev/null \
            && kill -9 "$_pid" 2>/dev/null || true
    done
    # Stale Steam reaper for our shortcut: while it lives, Steam thinks the game
    # is still running and steam://rungameid/ won't relaunch it.
    pkill -9 -f 'SteamLaunch.*minecraftSplitscreen' 2>/dev/null || true
    pkill -9 -f 'latestUpdate' 2>/dev/null || true
    pkill -9 -f 'bwrap.*PolyMC' 2>/dev/null || true
    for _name in startplasma-wayland kwin_wayland plasma_session baloo_file Xwayland 'udevadm monitor' inotifywait; do
        for _pid in $(pgrep -f "$_name" 2>/dev/null || true); do
            grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$_pid/environ" 2>/dev/null \
                && kill -9 "$_pid" 2>/dev/null || true
        done
    done
    local _left
    for _tries in 1 2 3 4 5; do
        _left=""
        for _pid in $(pgrep -f 'startplasma-wayland' 2>/dev/null || true); do
            if grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$_pid/environ" 2>/dev/null; then
                _left="$_pid"
                break
            fi
        done
        [[ -z "$_left" ]] && break
        sleep 1
    done
    if [[ -n "${SPLITSCREEN_STATE:-}" ]]; then
        echo '{"mode":"unknown","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null,"wid":null}}}' > "$SPLITSCREEN_STATE"
        hw_info "hw_reap_stale_session: state file reset to all-inactive"
    fi
}

# hw_shortcut_gameid: resolve the Steam shortcut gameid for the splitscreen
# launcher from shortcuts.vdf (gameid = appid<<32 | 0x02000000). Empty if absent.
hw_shortcut_gameid() {
    python3 - <<'PYEOF' 2>/dev/null || true
import glob, struct
for path in glob.glob("/home/deck/.steam/steam/userdata/*/config/shortcuts.vdf"):
    data = open(path, "rb").read()
    appid, i = None, 0
    while i < len(data):
        b = data[i]
        if b == 0x02:
            end = data.index(b"\x00", i + 1)
            name = data[i + 1:end].decode(errors="replace").lower()
            val = struct.unpack("<I", data[end + 1:end + 5])[0]
            if name == "appid":
                appid = val
            i = end + 5
        elif b == 0x01:
            end = data.index(b"\x00", i + 1)
            end2 = data.index(b"\x00", end + 1)
            val = data[end + 1:end2].decode(errors="replace")
            if "minecraftSplitscreen.sh" in val and appid is not None:
                print((appid << 32) | 0x02000000)
                raise SystemExit
            i = end2 + 1
        else:
            i += 1
PYEOF
}

# hw_launch_orchestrator MODE
# Launches the splitscreen session THROUGH THE STEAM SHORTCUT. A directly
# spawned launchFromPlasma runs perfectly — orchestrator, instances, windows,
# all X11 checks green — but gamescope only DISPLAYS windows of the app Steam
# launched, so the TV keeps showing the Steam library while the game plays to
# an invisible compositor (operator watched the library for 40 minutes of
# "passing" runs, 2026-07-05). Steam launch is the only path that renders.
# MODE is advisory: the production launcher detects docked/handheld itself.
hw_launch_orchestrator() {
    local mode="${1:-}"
    if [[ "$mode" != "handheld" && "$mode" != "docked" ]]; then
        hw_fail "hw_launch_orchestrator: invalid mode '${mode}' (must be handheld or docked)"
        return 1
    fi

    # Steam-launched sessions use the production default paths — repoint our
    # checks (and the state reset in hw_reap_stale_session) at them.
    export SPLITSCREEN_FIFO="/tmp/minecraft-splitscreen.fifo"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"

    hw_reap_stale_session

    local gameid="${HW_STEAM_GAMEID:-$(hw_shortcut_gameid)}"
    if [[ -z "$gameid" ]]; then
        hw_fail "hw_launch_orchestrator: no Steam shortcut found for minecraftSplitscreen.sh — add it to Steam first (add-to-steam.py)"
        return 1
    fi

    hw_info "Launching via Steam shortcut (gameid ${gameid}) so gamescope displays the session; expecting ${mode} mode"
    steam "steam://rungameid/${gameid}" >/dev/null 2>&1 &
    HW_ORCH_PID=""
    export HW_ORCH_PID

    # Steam launch → reaper → launchFromPlasma → FIFO. Slower than a direct
    # spawn; allow 45s.
    local elapsed=0
    while (( elapsed < 45 )); do
        if [[ -p "${SPLITSCREEN_FIFO:-}" ]]; then
            hw_info "FIFO appeared after ${elapsed}s: ${SPLITSCREEN_FIFO}"
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    hw_warn "FIFO did not appear within 45s — Steam launch may have failed; check the TV"
    return 0
}

# hw_stop_orchestrator: end the session. Steam-launched sessions have no direct
# pid to signal — reap the marked run tree instead.
hw_stop_orchestrator() {
    if [[ -z "${HW_ORCH_PID:-}" ]]; then
        hw_info "hw_stop_orchestrator: Steam-launched session — reaping marked run tree"
        hw_reap_stale_session
        return 0
    fi

    hw_info "Stopping orchestrator PID ${HW_ORCH_PID}"

    if kill -0 "${HW_ORCH_PID}" 2>/dev/null; then
        kill "${HW_ORCH_PID}" 2>/dev/null || true
        local elapsed=0
        while (( elapsed < 15 )); do
            if ! kill -0 "${HW_ORCH_PID}" 2>/dev/null; then
                hw_info "Orchestrator exited after ${elapsed}s"
                HW_ORCH_PID=""
                return 0
            fi
            sleep 1
            elapsed=$(( elapsed + 1 ))
        done
        hw_warn "Orchestrator did not exit within 15s — sending SIGKILL"
        kill -9 "${HW_ORCH_PID}" 2>/dev/null || true
    else
        hw_info "Orchestrator PID ${HW_ORCH_PID} already exited"
    fi
    HW_ORCH_PID=""
    return 0
}
