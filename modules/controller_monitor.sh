#!/bin/bash
set -euo pipefail

# =============================================================================
# CONTROLLER MONITOR MODULE
# =============================================================================
# Enumerates gamepad devices and monitors for controller add/remove events via
# udevadm. Emits structured messages to the named pipe at $SPLITSCREEN_FIFO.
#
# Docked enumeration has TWO selectable sources (gated by CONTROLLER_MONITOR_RAW_BINDING):
#   - flag == 1 (DEFAULT): _list_raw_external_pads — emits each REAL external pad's OWN raw
#     js node (js-gated, gamepad+vendor gated, shared-parent deduped, ordered by
#     (inputN,eventN); the built-in / Steam 28de and the puck are STRUCTURALLY EXCLUDED —
#     they expose no raw js gamepad node, so they can never be claimed by a player).
#   - flag == 0 (fallback): legacy _map_external_player_virtuals — maps each external pad to
#     the Steam virtual gamepad (28de:11ff) via inputN creation order. UNRELIABLE: Steam
#     pre-creates a virtual POOL whose inputN order doesn't track physical connection order,
#     so a pad can claim the WRONG virtual (incl. the built-in's) — the §3b leak. Kept only
#     as an escape hatch (CONTROLLER_MONITOR_RAW_BINDING=0).
#
# VALIDATED 2026-06-26 on a Deck: 4 DS4s (3x 09cc + 1x 05c4), incremental 1->4 add, each
# pad bound to its own distinct raw js, built-in + Steam Controller dead in all instances,
# input alive through the raw js with Steam Input ON, identity honest ("Wireless Controller").
# Raw is now the DEFAULT. See docs/RAW-CONTROLLER-BIND-PLAN.md and [[controller-isolation-sdl-udev-leak]].
#
# Public API:
#   list_eligible_controllers(mode)     — stdout: "event_node js_node vendor product" lines
#   start_controller_monitor(mode)      — blocks; writes CONTROLLER_ADD/REMOVE to FIFO
#   get_controller_by_index(index, mode) — stdout: "event_node js_node" or empty
#
# Globals PROVIDED:
#   CONTROLLER_MONITOR_DEFAULT_PROC_PATH — readonly, default /proc path
#   CONTROLLER_MONITOR_DEBOUNCE_MS       — readonly, add-event debounce window
#   CONTROLLER_MONITOR_STEAM_VENDOR/PRODUCT — readonly legacy aliases for
#     MCSS_STEAM_VENDOR_ID/PRODUCT_ID (one-release deprecation; see below)
#
# Globals CONSUMED: MCSS_MAX_PLAYERS, MCSS_RAW_BINDING, MCSS_STEAM_VENDOR_ID,
#   MCSS_STEAM_PRODUCT_ID (from runtime_context.sh); SPLITSCREEN_FIFO (from
#   runtime_context.sh's mcss_resolve_paths). Legacy aliases still referenced
#   internally: CONTROLLER_MONITOR_STEAM_VENDOR/PRODUCT (this module's own
#   readonly copies of the MCSS_* ids). Test-only overrides listed below in
#   Environment overrides: CONTROLLER_MONITOR_UDEVADM_CMD,
#   CONTROLLER_MONITOR_SKIP_INITIAL_EMIT, CONTROLLER_MONITOR_DEBOUNCE_MS,
#   PROC_INPUT_DEVICES, INPUTPLUMBER_DBUS_AVAILABLE.
#
# Inputs:  /proc/bus/input/devices, `udevadm monitor` events, InputPlumber
#          D-Bus (referenced by the env override name; not queried directly
#          in this file's current enumeration paths).
# Outputs: CONTROLLER_ADD/CONTROLLER_REMOVE lines to $SPLITSCREEN_FIFO,
#          eligible-controller data to stdout (list_eligible_controllers,
#          get_controller_by_index), stderr `[controller_monitor]` prefix.
#
# Environment overrides (for testing):
#   PROC_INPUT_DEVICES              — override /proc/bus/input/devices path
#   INPUTPLUMBER_DBUS_AVAILABLE     — set to "0" to force enumeration fallback
#   CONTROLLER_MONITOR_UDEVADM_CMD  — override udevadm command
#   CONTROLLER_MONITOR_RAW_BINDING  — "1"/unset (DEFAULT) = docked uses raw external js
#                                     nodes; "0" = legacy virtual mapper (escape hatch)
#   CONTROLLER_MONITOR_SKIP_INITIAL_EMIT — "1" = baseline already-connected
#                                     pads without emitting CONTROLLER_ADD
#   CONTROLLER_MONITOR_DEBOUNCE_MS  — override the add-event debounce window
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.4 2026-07-15  Fix #51 (D13): parse_input_device_blocks (/proc parser)
#   v1.3 2026-07-09  #45: vendor/product/slot/raw-binding globals via
#                    runtime_context.sh
#   v1.2 2026-07-06  dex backend temp lifecycle; Java-25/MC-26.x support
#                    (#19, #28, #48)
#   v1.1 2026-06-26  Raw external-js binding promoted to DEFAULT; VALIDATED
#                    on a Deck with 4 DS4s
#   v1.0 2026-06-13  Initial extraction: Steam-virtual enumeration + udevadm
#                    monitor
# =============================================================================

# #45: slot count, Deck vendor/product ids, and the raw-binding flag are owned
# by runtime_context.sh (MCSS_MAX_PLAYERS, MCSS_STEAM_VENDOR_ID/PRODUCT_ID,
# MCSS_RAW_BINDING — the latter resolved ONCE from CONTROLLER_MONITOR_RAW_BINDING
# so enumeration and instance_lifecycle's sandbox masking can never disagree).
# Sourcing it here is idempotent (process-local sentinels) and makes standalone
# sourcing (unit tests) behave like the launcher prologue, which sources it first.
source "$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh"

# --- Module-level constants ---
readonly CONTROLLER_MONITOR_DEBOUNCE_MS=500
readonly CONTROLLER_MONITOR_DEFAULT_PROC_PATH="/proc/bus/input/devices"
# One-release deprecation aliases for the ids (external consumers/tests);
# internal reads use the MCSS names. Guarded: re-sourcing must not re-readonly.
if [[ ! -v CONTROLLER_MONITOR_STEAM_VENDOR ]]; then
    readonly CONTROLLER_MONITOR_STEAM_VENDOR="$MCSS_STEAM_VENDOR_ID"
    readonly CONTROLLER_MONITOR_STEAM_PRODUCT="$MCSS_STEAM_PRODUCT_ID"
fi

# --- Internal data structures ---
# We maintain a global associative array (bash 4+) for debounce tracking.
# Keys are event node paths, values are epoch milliseconds of last add.
declare -A _CONTROLLER_MONITOR_DEBOUNCE_MAP

# _get_epoch_ms: Return current time in milliseconds since epoch.
_get_epoch_ms() {
    local epoch_ns
    epoch_ns=$(date +%s%N 2>/dev/null || echo "0")
    # #27: non-GNU `date` (BusyBox, BSD/macOS) doesn't support %N and emits it back
    # LITERALLY (e.g. "1751328000N"), which would corrupt the arithmetic below into a
    # garbage debounce timestamp instead of erroring. SteamOS ships GNU coreutils, so
    # this is defensive rather than an observed failure — fall back to seconds-since-
    # epoch padded to millisecond precision when %N wasn't expanded to digits.
    [[ "$epoch_ns" =~ ^[0-9]+$ ]] || epoch_ns="$(date +%s 2>/dev/null || echo 0)000000000"
    echo $(( epoch_ns / 1000000 ))
}

# _get_proc_input_path: Return the proc input devices path (with override support).
_get_proc_input_path() {
    echo "${PROC_INPUT_DEVICES:-$CONTROLLER_MONITOR_DEFAULT_PROC_PATH}"
}

# parse_input_device_blocks: THE /proc/bus/input/devices block parser.
# Fix #51 (D13): five hand-rolled copies of the blank-line block splitter
# (each duplicating the "file may not end in a blank line" tail) collapse
# into this one reader. Public API — instance_lifecycle's _vendor_of_js_node
# consumes it too (controller_monitor sources first per runtime_modules.list).
# Keying/filtering stays with each caller: this only captures blocks.
# Inputs:
#   $1 — proc file path (default: _get_proc_input_path)
# Outputs:
#   stdout — one line per device block, fields separated by the ASCII unit
#     separator \x1f (NOT tab/space: those are IFS whitespace, so empty
#     fields would collapse and shift columns on read):
#     vendor, product, name, handlers, sysfs, phys, keybits
#     vendor/product: 4-hex lowercase or empty if unparsed; name/handlers/
#     sysfs/phys: the raw N:/H:/S:/P: values (may be empty); keybits: the
#     "B: KEY=" bitmap only (other B: lines ignored). Consume with:
#     while IFS=$'\x1f' read -r vendor product name handlers sysfs phys \
#         keybits; do ...
#   return — 1 if the proc file is missing/unreadable
parse_input_device_blocks() {
    local proc_path="${1:-$(_get_proc_input_path)}"
    [[ -r "$proc_path" ]] || return 1

    local in_block=0 line
    local vendor="" product="" name="" handlers="" sysfs="" phys="" keybits=""
    _emit_block() {
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$vendor" \
            "$product" "$name" "$handlers" "$sysfs" "$phys" "$keybits"
    }
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            (( in_block )) && _emit_block
            in_block=0
            vendor=""; product=""; name=""; handlers=""; sysfs=""; phys=""
            keybits=""
            continue
        fi
        in_block=1
        case "$line" in
            I:*)
                [[ "$line" =~ Vendor=([0-9a-fA-F]{4}) ]] \
                    && vendor="${BASH_REMATCH[1],,}"
                [[ "$line" =~ Product=([0-9a-fA-F]{4}) ]] \
                    && product="${BASH_REMATCH[1],,}"
                ;;
            N:*) name="${line#N: Name=}" ;;
            H:*) handlers="${line#H: Handlers=}" ;;
            S:*) sysfs="${line#S: Sysfs=}" ;;
            P:*) phys="${line#P: Phys=}" ;;
            B:*)
                # Only the KEY bitmap matters; ignore ABS=/REL=/MSC= etc.
                [[ "$line" == "B: KEY="* ]] && keybits="${line#B: KEY=}"
                ;;
        esac
    done < "$proc_path"
    (( in_block )) && _emit_block
    unset -f _emit_block
    return 0
}

# _parse_steam_virtual_devices: Extract all 28de:11ff devices with jsN
# handlers, in order of appearance (ascending eventN on real systems).
# Inputs:
#   Globals: MCSS_STEAM_VENDOR_ID, MCSS_STEAM_PRODUCT_ID (read); reads from
#     the path returned by _get_proc_input_path
# Outputs:
#   stdout — one line per device: "<eventN> <jsN>"
#   return — 1 if the proc path is missing
_parse_steam_virtual_devices() {
    local proc_path
    proc_path=$(_get_proc_input_path)

    if [[ ! -f "$proc_path" ]]; then
        echo "[controller_monitor] ERROR: $proc_path not found" >&2
        return 1
    fi

    # Fix #51 (D13): block capture via parse_input_device_blocks; this
    # function keeps only its own keying (28de:11ff filter, LAST event/js
    # token — no break, matching the original).
    local vendor product name handlers sysfs phys keybits _h
    while IFS=$'\x1f' read -r vendor product name handlers sysfs phys \
        keybits; do
        [[ "$vendor" == "$MCSS_STEAM_VENDOR_ID" ]] || continue
        [[ "$product" == "$MCSS_STEAM_PRODUCT_ID" ]] || continue
        local eventN="" jsN=""
        for _h in $handlers; do
            case "$_h" in
                event*) eventN="${_h#event}" ;;
                js*)    jsN="${_h#js}" ;;
            esac
        done
        if [[ -n "$eventN" && -n "$jsN" ]]; then
            echo "$eventN $jsN"
        fi
    done < <(parse_input_device_blocks "$proc_path")
    return 0
}

# _parse_all_gamepad_devices: Extract ALL devices with jsN handlers (any
# VID:PID). Used for handheld mode (accepts any gamepad) and physical source
# matching.
# Inputs:
#   reads from the path returned by _get_proc_input_path
# Outputs:
#   stdout — one line per device:
#     "<eventN> <jsN> <vendor> <product> <sysfs> <phys>"
#   return — 1 if the proc path is missing
_parse_all_gamepad_devices() {
    local proc_path
    proc_path=$(_get_proc_input_path)

    if [[ ! -f "$proc_path" ]]; then
        echo "[controller_monitor] ERROR: $proc_path not found" >&2
        return 1
    fi

    # Fix #51 (D13): block capture via parse_input_device_blocks; this
    # function keeps only its own keying (any block with a js handler,
    # FIRST event/js token — break, matching the original).
    local vendor product name handlers sysfs phys keybits _h
    while IFS=$'\x1f' read -r vendor product name handlers sysfs phys \
        keybits; do
        local jsN=""
        for _h in $handlers; do
            case "$_h" in
                js*) jsN="${_h#js}" ; break ;;
            esac
        done
        [[ -n "$jsN" ]] || continue
        local eventN=""
        for _h in $handlers; do
            case "$_h" in
                event*) eventN="${_h#event}" ; break ;;
            esac
        done
        echo "$eventN $jsN ${vendor:-0000} ${product:-0000} ${sysfs:-} ${phys:-}"
    done < <(parse_input_device_blocks "$proc_path")
    return 0
}

# (_find_internal_by_pad_name deleted — Fix #51 (D13): the legacy
# "pad 0"-name-scan heuristic had zero callers, superseded by
# _map_external_player_virtuals' inputN creation-order mapping. Name-keyed
# scans, if ever needed again, ride parse_input_device_blocks' name field.)

# _eventN_to_virtual_idx: Convert eventN to 1-based position in the sorted
# virtual device list.
# Inputs: $1 — target eventN
# Outputs:
#   stdout — 1-based index on match
#   return — 0 on match, 1 if not found (no stdout emitted on failure)
_eventN_to_virtual_idx() {
    local target="$1" idx=1 vline
    while IFS= read -r vline; do
        local ven
        ven=$(echo "$vline" | awk '{print $1}')
        if [[ "$ven" == "$target" ]]; then
            echo "$idx"
            return 0
        fi
        idx=$((idx + 1))
    done < <(_parse_steam_virtual_devices)
    return 1
}


# --- Public API ---


# _map_external_player_virtuals: Positively identify external player controllers and map
# each to the Steam virtual gamepad (28de:11ff) Steam created for it, via the kernel
# `inputN` creation-order counter.
#
# Why this approach (2026-06-25, grounded in live Deck recon):
#   - On a real Deck the built-in pad AND the puck / external Steam Controller expose NO
#     joystick (jsN) node — only mouse/keyboard at the raw level. So the ONLY jsN-bearing
#     devices are the 28de:11ff virtuals and REAL external pads (e.g. a DS4 054c:05c4).
#   - Steam mints a fresh 28de:11ff virtual immediately AFTER an external connects, so that
#     virtual carries a higher `inputN` than the external's own device. `/proc/bus/input/
#     devices` (and `inputN`) are creation-ordered.
#   So: enumerate real external pads + virtuals (each with inputN); per external (oldest
#   first) claim the lowest-inputN UNCLAIMED virtual whose inputN exceeds that external's —
#   the one Steam made for it. The built-in's virtual (oldest, made at session start) and
#   any startup-pool phantoms are never claimed → the built-in can't leak in and phantoms
#   can't spawn ghost players. If an external's virtual doesn't exist yet (Steam staggers
#   creation), it's skipped this pass and the acquisition poll retries.
#
# Replaces the old InputPlumber-D-Bus (dead on SteamOS — service disabled, autostart skips
# Valve) / "pad 0 == built-in" name-scan / "first-in-list" heuristics, all of which
# mis-identified the built-in (SPEC §3b leak).
#
# NOTE: an external Steam Controller (via the puck) has no evdev jsN gamepad node, so it
# cannot be enumerated as a player here — that is a known limitation (Steam-Input-API only).
# DS4 / Xbox-class externals (real evdev gamepad) are the supported case.
#
# DO NOT key identity on `uniq`/MAC/serial: some DS4 units report the SAME Bluetooth MAC,
# so two of them would collide. We match purely by inputN creation order + device nodes,
# which stays correct even for same-MAC pads (each still gets its own inputN/event/js).
#
# Inputs:
#   Globals: MCSS_STEAM_VENDOR_ID, MCSS_STEAM_PRODUCT_ID, MCSS_MAX_PLAYERS
#     (read)
# Outputs:
#   stdout — one line per claimed virtual:
#     "<eventN> <jsN> <ext_vendor> <ext_product>" (event/js are the
#     VIRTUAL's; vendor/product are the matched external's). Capped at
#     MCSS_MAX_PLAYERS.
#   side effects — diagnostic enumeration lines to stderr, plus a
#     `[vpad-probe]` tagged line per claim (grep'd by
#     tests/probe-controller-reconnect.sh)
_map_external_player_virtuals() {
    local -a virtuals=()   # "inputN eventN jsN"
    local -a externals=()  # "inputN eventN jsN vendor product"
    local ev js vnd prd sysfs phys inputn line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r ev js vnd prd sysfs phys <<< "$line"
        inputn=""
        [[ "$sysfs" =~ input([0-9]+)$ ]] && inputn="${BASH_REMATCH[1]}"
        [[ -z "$inputn" || -z "$ev" || -z "$js" ]] && continue
        if [[ "$vnd" == "$MCSS_STEAM_VENDOR_ID" && "$prd" == "$MCSS_STEAM_PRODUCT_ID" ]]; then
            virtuals+=("$inputn $ev $js")
        else
            externals+=("$inputn $ev $js ${vnd:-0000} ${prd:-0000}")
        fi
    done < <(_parse_all_gamepad_devices)

    # Sort both lists ascending by inputN (creation order, oldest first).
    local -a v_sorted=() e_sorted=()
    (( ${#virtuals[@]}  )) && mapfile -t v_sorted < <(printf '%s\n' "${virtuals[@]}"  | sort -n -k1,1)
    (( ${#externals[@]} )) && mapfile -t e_sorted < <(printf '%s\n' "${externals[@]}" | sort -n -k1,1)

    echo "[controller_monitor] enumeration: ${#e_sorted[@]} external pad(s), ${#v_sorted[@]} virtual(s)" >&2
    local _row
    for _row in "${e_sorted[@]}"; do
        echo "[controller_monitor]   external: input${_row%% *} [$(awk '{print $4":"$5}' <<<"$_row")] event$(awk '{print $2}' <<<"$_row") js$(awk '{print $3}' <<<"$_row")" >&2
    done
    for _row in "${v_sorted[@]}"; do
        echo "[controller_monitor]   virtual : input${_row%% *} event$(awk '{print $2}' <<<"$_row") js$(awk '{print $3}' <<<"$_row")" >&2
    done

    # Proximity match: per external (oldest first), claim the lowest-inputN unclaimed
    # virtual whose inputN > the external's inputN.
    local -a claimed=()
    local count=0 ei vi
    for ei in "${!e_sorted[@]}"; do
        (( count >= MCSS_MAX_PLAYERS )) && break
        local e_input e_ev e_js e_ven e_prod
        read -r e_input e_ev e_js e_ven e_prod <<< "${e_sorted[$ei]}"
        local picked=-1
        for vi in "${!v_sorted[@]}"; do
            local already=0 c
            for c in "${claimed[@]}"; do [[ "$c" == "$vi" ]] && { already=1; break; }; done
            (( already )) && continue
            local v_input v_ev v_js
            read -r v_input v_ev v_js <<< "${v_sorted[$vi]}"
            if (( v_input > e_input )); then picked=$vi; break; fi
        done
        if (( picked >= 0 )); then
            claimed+=("$picked")
            local pv_input pv_ev pv_js
            read -r pv_input pv_ev pv_js <<< "${v_sorted[$picked]}"
            echo "[controller_monitor]   → external input${e_input} [${e_ven}:${e_prod}] claims virtual input${pv_input} (event${pv_ev} js${pv_js})" >&2
            # [vpad-probe]: distinctly-tagged, timestamped line (does NOT change any
            # decision-making — this is purely so a maintainer can `grep '\[vpad-probe\]'`
            # across a session's debug log and see, per external vendor:product, whether
            # the SAME virtual event/js gets claimed again after a physical unplug/replug,
            # or whether Steam minted a fresh one (new numbers) — see the reconnect-identity
            # research doc and issue #38. Reused by tests/probe-controller-reconnect.sh.
            echo "[vpad-probe] t=$(_get_epoch_ms) ext=${e_ven}:${e_prod} ext_input=${e_input} virtual_input=${pv_input} virtual_event=${pv_ev} virtual_js=${pv_js}" >&2
            echo "${pv_ev} ${pv_js} ${e_ven} ${e_prod}"
            count=$((count + 1))
        else
            echo "[controller_monitor]   → external input${e_input} [${e_ven}:${e_prod}] has NO virtual yet — skipped (acquisition poll will retry)" >&2
        fi
    done
}

# _has_gamepad_buttons: inclusive bit-test of a `B: KEY=` bitmap (passed WHOLE as $1).
# Inputs: $1 — the raw `B: KEY=` bitmap value (whitespace-delimited hex words)
# ACCEPT (return 0) if BTN_SOUTH (0x130) OR BTN_JOYSTICK (0x120) is set, OR if the bitmap
# is empty / has fewer than 5 whitespace-delimited words (FAIL-OPEN — never false-negative
# a real pad). REJECT (return 1) only when the bitmap parses AND neither bit is set.
#
# The kernel omits leading-zero most-significant words, so we count words from the END:
# word[-1]=bits 0-63, word[-2]=64-127, word[-3]=128-191, word[-4]=192-255, word[-5]=bits
# 256-319 — where both BTN_GAMEPAD/BTN_SOUTH (0x130=304) and BTN_JOYSTICK (0x120=288) live.
# Within that 5th-from-end word BTN_SOUTH is bit 48 (304-256) and BTN_JOYSTICK is bit 32
# (288-256).
#
# ASSUMES 64-bit words (SteamOS is x86-64: /proc/bus/input/devices prints `unsigned long`
# words = 64-bit on amd64). Uses the SIGN-SAFE mask form `(word & (1<<N))`, NOT a
# right-shift — a right-shift would arithmetic-shift-sign-extend a 64-bit word whose bit
# 63 is set and corrupt the test.
_has_gamepad_buttons() {
    local keybits="$1"
    # FAIL-OPEN on an empty/whitespace-only bitmap.
    [[ -z "${keybits// /}" ]] && return 0
    local -a words=($keybits)
    local n=${#words[@]}
    # FAIL-OPEN when the BTN_ range word was never emitted (fewer than 5 words).
    (( n < 5 )) && return 0
    local word="0x${words[$((n - 5))]}"
    # mask form: 0x<hex> is parsed as a 64-bit intmax_t; bit 63 set → negative, but `&`
    # with a positive mask stays correct (no sign-extension as a shift would have).
    if (( (word & (1 << 48)) != 0 )); then return 0; fi   # BTN_SOUTH  0x130
    if (( (word & (1 << 32)) != 0 )); then return 0; fi   # BTN_JOYSTICK 0x120
    echo "[controller_monitor]   reject: KEY word '${words[$((n - 5))]}' has neither BTN_SOUTH nor BTN_JOYSTICK" >&2
    return 1
}

# _list_raw_external_pads: NEW self-contained docked enumerator (selected by
# list_eligible_controllers when CONTROLLER_MONITOR_RAW_BINDING==1). Emits each REAL
# external pad's OWN raw nodes — "<eventN> <jsN> <vendor> <product>" — one per line.
#
# It does its OWN single-pass /proc parse (MIRRORS the block structure of
# _parse_all_gamepad_devices) and does NOT touch that shared 6-field parser, so the
# multi-word `B: KEY=` bitmap never crosses a `read` boundary in the shared contract.
#
# Per-block capture, then the 10-step enumeration algorithm:
#   1) JS-GATE: require a jsN handler (drops DS4/DualSense touchpad+motion event-only
#      nodes and the lizard-mode built-in/puck, which expose no js); extract eventN too.
#   2) GAMEPAD-CAPABILITY GATE (inclusive, via _has_gamepad_buttons): BTN_SOUTH OR
#      BTN_JOYSTICK OR unparseable bitmap → accept.
#   3) VENDOR GATE: drop vendor == CONTROLLER_MONITOR_STEAM_VENDOR (28de) — both 11ff
#      virtuals AND any 1205 that bears a js. All other vendors kept (do NOT hardcode 054c).
#   4) inputN parsed from the sysfs tail; skip rows missing inputN/eventN/jsN.
#   5) collect internal records (sysfs+phys kept ONLY for in-pass dedup; never emitted).
#   6) SHARED-PARENT DEDUP: parent key = sysfs with a trailing /input/inputN (or bare
#      /inputN) stripped, phys fallback when sysfs empty; keep the LOWEST jsN per key
#      (collapses an 8BitDo dual-js under one uhid). NOTE: a BT uhid key is per-CONNECTION
#      (not durable across reconnect — in-pass only); it does NOT collapse one pad on two
#      USB interfaces nor USB+BT simultaneously (two parents → two pads).
#   7) SORT `sort -n -k1,1 -k2,2` (inputN, eventN tiebreaker) — a TOTAL deterministic
#      order. Two guarantees: (i) deterministic ordering for unchanged sets (load-bearing
#      for prev_nodes diffing and the acquire poll); (ii) cold-start creation order for
#      initial slot assignment (cosmetic, NOT preserved across reconnect — a reconnected
#      pad gets a higher inputN). NO 'stable across reconnect' claim. Identity NEVER keys
#      on uniq/MAC (shared-MAC DS4 constraint); the orchestrator dedups by event_node path.
#   8) DUAL-TRANSPORT GUARD: if 2+ survivors share the SAME vendor:product, emit ONE loud
#      >&2 warning (possible same pad on USB+BT OR two identical pads). Do NOT auto-collapse
#      (VID:PID dedup would wrongly merge two identical same-MAC DS4s).
#   9) CAP at MCSS_MAX_PLAYERS AFTER the sort.
#  10) EMIT "<eventN> <jsN> <vendor> <product>" — the pad's OWN raw nodes (the
#      list_eligible_controllers docked branch prefixes /dev/input/event and /dev/input/js,
#      preserving the 4-field public contract). keybits/sysfs/phys are NEVER emitted.
# Inputs:
#   Globals: MCSS_STEAM_VENDOR_ID, MCSS_MAX_PLAYERS (read)
# Outputs:
#   stdout — one line per surviving pad: "<eventN> <jsN> <vendor> <product>"
#   return — 1 if the proc path is missing
_list_raw_external_pads() {
    local proc_path
    proc_path=$(_get_proc_input_path)

    if [[ ! -f "$proc_path" ]]; then
        echo "[controller_monitor] ERROR: $proc_path not found" >&2
        return 1
    fi

    local -a records=()   # surviving internal rows: "inputN eventN jsN vendor product sysfs phys"

    # _consider: apply per-block gates (steps 1-5) to the just-parsed block; on survival
    # append an internal record. Reads the block-capture locals (handlers, vendor, …) via
    # bash dynamic scope and appends to the caller's `records` array.
    _consider() {
        # step 1: JS-GATE — need a jsN handler; grab the first event*/js* tokens.
        local _h _jsN="" _eventN=""
        for _h in $handlers; do
            case "$_h" in
                js*)    [[ -z "$_jsN" ]]    && _jsN="${_h#js}" ;;
                event*) [[ -z "$_eventN" ]] && _eventN="${_h#event}" ;;
            esac
        done
        [[ -z "$_jsN" ]] && return 0   # no js → drop (touchpad/motion/lizard puck/built-in)
        # step 2: GAMEPAD-CAPABILITY GATE (inclusive, fail-open).
        if ! _has_gamepad_buttons "$keybits"; then
            echo "[controller_monitor]   raw: drop event${_eventN} js${_jsN} [${vendor}:${product}] — no gamepad buttons" >&2
            return 0
        fi
        # step 3: VENDOR GATE — drop the Steam vendor (28de:11ff virtuals AND 1205-with-js).
        if [[ "$vendor" == "$MCSS_STEAM_VENDOR_ID" ]]; then
            echo "[controller_monitor]   raw: drop event${_eventN} js${_jsN} [${vendor}:${product}] — Steam vendor (built-in/virtual)" >&2
            return 0
        fi
        # step 4: inputN from the sysfs tail (mirrors _map_external_player_virtuals).
        local _inputn=""
        [[ "$sysfs" =~ input([0-9]+)$ ]] && _inputn="${BASH_REMATCH[1]}"
        [[ -z "$_inputn" || -z "$_eventN" || -z "$_jsN" ]] && return 0
        # step 5: collect (sysfs+phys retained for dedup ONLY).
        records+=("$_inputn $_eventN $_jsN ${vendor:-0000} ${product:-0000} ${sysfs:-} ${phys:-}")
    }

    # Fix #51 (D13): block capture via parse_input_device_blocks — the read
    # vars keep their names so _consider's dynamic-scope reads are unchanged.
    # Process substitution (not a pipe): _consider appends to `records` and
    # must run in THIS shell (see the subshell-trap note at the top).
    local vendor product name handlers sysfs phys keybits
    while IFS=$'\x1f' read -r vendor product name handlers sysfs phys \
        keybits; do
        _consider
    done < <(parse_input_device_blocks "$proc_path")
    unset -f _consider

    # step 6: SHARED-PARENT DEDUP — keep the lowest jsN per parent device.
    local -A _best_js=()    # parent key → lowest jsN seen
    local -A _best_row=()   # parent key → emit row "inputN eventN jsN vendor product"
    local _rec
    for _rec in "${records[@]}"; do
        local r_input r_ev r_js r_vn r_pr r_sysfs r_phys
        read -r r_input r_ev r_js r_vn r_pr r_sysfs r_phys <<< "$_rec"
        local _key="$r_sysfs"
        if [[ -n "$_key" ]]; then
            # strip a trailing /input/inputN (or bare /inputN) → the device-node parent path
            _key=$(sed -E 's#/input/input[0-9]+$##; s#/input[0-9]+$##' <<< "$_key")
        else
            _key="$r_phys"
        fi
        [[ -z "$_key" ]] && _key="input${r_input}"   # last-resort unique key
        local _prev_js="${_best_js[$_key]:-}"
        if [[ -z "$_prev_js" ]] || (( r_js < _prev_js )); then
            _best_js[$_key]="$r_js"
            _best_row[$_key]="$r_input $r_ev $r_js $r_vn $r_pr"
        fi
    done

    # step 7: SORT survivors by (inputN, eventN) — total deterministic order.
    local -a _survivors=()
    local _k
    for _k in "${!_best_row[@]}"; do
        _survivors+=("${_best_row[$_k]}")
    done
    local -a _sorted=()
    (( ${#_survivors[@]} )) && mapfile -t _sorted < <(printf '%s\n' "${_survivors[@]}" | sort -n -k1,1 -k2,2)

    # step 8: DUAL-TRANSPORT GUARD — warn (do NOT collapse) on shared VID:PID.
    local -A _vidpid_count=()
    local _row s_input s_ev s_js s_vn s_pr
    for _row in "${_sorted[@]}"; do
        read -r s_input s_ev s_js s_vn s_pr <<< "$_row"
        _vidpid_count["$s_vn:$s_pr"]=$(( ${_vidpid_count["$s_vn:$s_pr"]:-0} + 1 ))
    done
    local _vp
    for _vp in "${!_vidpid_count[@]}"; do
        if (( ${_vidpid_count[$_vp]} >= 2 )); then
            echo "[controller_monitor] WARNING: ${_vidpid_count[$_vp]} pads share VID:PID ${_vp} — possible SAME pad on USB+BT, OR two identical pads. Spawning BOTH; if a ghost player appears, disconnect the idle transport." >&2
        fi
    done

    # diagnostics mirroring _map_external_player_virtuals' >&2 style.
    echo "[controller_monitor] raw enumeration: ${#_sorted[@]} external raw pad(s) after js+gamepad+vendor gate and shared-parent dedup" >&2

    # steps 9 + 10: cap at MAX_PLAYERS, then emit "<eventN> <jsN> <vendor> <product>".
    local _count=0 o_input o_ev o_js o_vn o_pr
    for _row in "${_sorted[@]}"; do
        (( _count >= MCSS_MAX_PLAYERS )) && break
        read -r o_input o_ev o_js o_vn o_pr <<< "$_row"
        echo "[controller_monitor]   raw pad: input${o_input} [${o_vn}:${o_pr}] event${o_ev} js${o_js}" >&2
        echo "${o_ev} ${o_js} ${o_vn} ${o_pr}"
        _count=$((_count + 1))
    done
}

# list_eligible_controllers: Write the current eligible device list to
# stdout.
# In docked mode the SOURCE is flag-gated by CONTROLLER_MONITOR_RAW_BINDING:
#   - unset/0 (DEFAULT): _map_external_player_virtuals — external pads mapped to their
#     Steam virtual by inputN creation order (built-in + phantoms excluded; max 4).
#   - == 1: _list_raw_external_pads — each external pad's OWN raw js node (js-gated,
#     gamepad+vendor gated, deduped, ordered by (inputN,eventN); built-in/28de excluded).
# Either source emits the IDENTICAL 4-field contract; only the source differs.
# In handheld mode: exactly one line — the first gamepad-capable device (any VID:PID).
# Inputs:
#   $1 — mode ("handheld" or "docked")
#   Globals: MCSS_RAW_BINDING (read)
# Outputs:
#   stdout — one line per eligible device:
#     "<event_node> <js_node> <physical_vendor> <physical_product>"
#   return — 1 if mode is neither "handheld" nor "docked"
list_eligible_controllers() {
    local mode="${1:-}"
    if [[ "$mode" != "handheld" && "$mode" != "docked" ]]; then
        echo "[controller_monitor] ERROR: list_eligible_controllers requires 'handheld' or 'docked' mode" >&2
        return 1
    fi

    if [[ "$mode" == "handheld" ]]; then
        # Handheld: first gamepad-capable device (any VID:PID, lowest jsN)
        local first
        first=$(_parse_all_gamepad_devices | head -1)
        if [[ -z "$first" ]]; then
            echo "[controller_monitor] No gamepad-capable device found for handheld mode" >&2
            return 0
        fi
        local eventN jsN vendor product
        eventN=$(echo "$first" | awk '{print $1}')
        jsN=$(echo "$first" | awk '{print $2}')
        vendor=$(echo "$first" | awk '{print $3}')
        product=$(echo "$first" | awk '{print $4}')
        echo "/dev/input/event$eventN /dev/input/js$jsN $vendor $product"
        return 0
    fi

    # Docked mode: pick the enumeration SOURCE based on CONTROLLER_MONITOR_RAW_BINDING.
    #   - flag == 1: _list_raw_external_pads (each pad's OWN raw js node).
    #   - unset/0 (DEFAULT): _map_external_player_virtuals — external pads mapped to their
    #     Steam virtual by inputN creation order; built-in (no jsN) + startup-pool phantoms
    #     are never claimed, so they can't leak in.
    # Both sources emit the IDENTICAL 4-field internal contract; the formatting below is
    # unchanged, so the public stdout contract is the same regardless of the flag.
    local src
    if [[ "$MCSS_RAW_BINDING" == "1" ]]; then
        src=_list_raw_external_pads
    else
        src=_map_external_player_virtuals
    fi
    local _line _ev _js _vn _pr
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        read -r _ev _js _vn _pr <<< "$_line"
        echo "/dev/input/event${_ev} /dev/input/js${_js} ${_vn} ${_pr}"
    done < <("$src")
}

# get_controller_by_index: Return the event node and js node for the Nth
# eligible controller (1-based).
# Inputs:
#   $1 — index (1-4), $2 — mode ("handheld" or "docked")
# Outputs:
#   stdout — "<event_node> <js_node>", or empty string if not found
#   return — 1 if index is not a positive integer
get_controller_by_index() {
    local index="${1:-1}"
    local mode="${2:-}"

    # M5: validate the index before feeding it to `sed -n "${index}p"` — a blank or
    # non-numeric value would make sed error or behave unexpectedly.
    if ! [[ "$index" =~ ^[1-9][0-9]*$ ]]; then
        echo "[controller_monitor] WARNING: get_controller_by_index bad index '$index'" >&2
        return 1
    fi

    local line
    line=$(list_eligible_controllers "$mode" | sed -n "${index}p")
    if [[ -n "$line" ]]; then
        echo "$line" | awk '{print $1, $2}'
    fi
}

# _check_devices_changed: Compare current eligible device list against a
# previously stored snapshot (tracked by event node).
# Writes CONTROLLER_ADD or CONTROLLER_REMOVE messages to $SPLITSCREEN_FIFO.
# N16/H1: ALSO echoes the current event-node set to STDOUT (space-separated) — the
# ONE enumeration this function does (line ~792 below) is now the SOLE source for both
# the diff AND the caller's next `prev_nodes` baseline. Previously start_controller_monitor
# enumerated a SECOND time itself (`new_nodes`) after calling this, so the diff and the
# stored baseline came from two scans taken ms apart; if a device transiently appeared or
# vanished between them, prev_nodes could be poisoned with a node that was never actually
# diffed against, permanently hiding a real controller. Callers MUST now do
# `prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")` instead of re-enumerating.
# Inputs:
#   $1 — mode
#   $2 — space-separated list of previously seen event nodes (by path)
#   Globals: SPLITSCREEN_FIFO (read), _CONTROLLER_MONITOR_DEBOUNCE_MAP
#     (read/write)
# Outputs:
#   stdout — the authoritative current event-node set (space-separated) —
#     the caller's next prev_nodes baseline (see N16/H1 above)
#   return — 1 if SPLITSCREEN_FIFO is not set
#   side effects — CONTROLLER_ADD/CONTROLLER_REMOVE lines to the FIFO
_check_devices_changed() {
    local mode="$1"
    local prev_nodes="$2"
    local fifo="${SPLITSCREEN_FIFO:-}"

    if [[ -z "$fifo" ]]; then
        echo "[controller_monitor] ERROR: SPLITSCREEN_FIFO not set" >&2
        return 1
    fi

    local current_output
    current_output=$(list_eligible_controllers "$mode")

    # Build current event node list
    local -A current_nodes
    local cline
    while IFS= read -r cline; do
        [[ -z "$cline" ]] && continue
        local ev_node
        ev_node=$(echo "$cline" | awk '{print $1}')
        current_nodes["$ev_node"]="$cline"
    done <<< "$current_output"

    # Find added devices (in current but not in previous)
    local prev_array=($prev_nodes)
    local ev
    for ev in "${!current_nodes[@]}"; do
        local found=0
        local pev
        for pev in "${prev_array[@]}"; do
            if [[ "$ev" == "$pev" ]]; then
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            # Check debounce
            local now_ms
            now_ms=$(_get_epoch_ms)
            local last_ms="${_CONTROLLER_MONITOR_DEBOUNCE_MAP["$ev"]:-0}"
            if (( now_ms - last_ms <= CONTROLLER_MONITOR_DEBOUNCE_MS )); then
                echo "[controller_monitor] Debounced add event for $ev (${CONTROLLER_MONITOR_DEBOUNCE_MS}ms window)" >&2
                continue
            fi
            _CONTROLLER_MONITOR_DEBOUNCE_MAP["$ev"]=$now_ms

            local js_node phys_vendor phys_product
            js_node=$(echo "${current_nodes[$ev]}" | awk '{print $2}')
            phys_vendor=$(echo "${current_nodes[$ev]}" | awk '{print $3}')
            phys_product=$(echo "${current_nodes[$ev]}" | awk '{print $4}')

            echo "[controller_monitor] Controller added: $ev $js_node $phys_vendor $phys_product" >&2
            echo "CONTROLLER_ADD $ev $js_node $phys_vendor $phys_product" >> "$fifo"
        fi
    done

    # Find removed devices (in previous but not in current)
    for pev in "${prev_array[@]}"; do
        [[ -z "$pev" ]] && continue
        if [[ -z "${current_nodes["$pev"]:-}" ]]; then
            echo "[controller_monitor] Controller removed: $pev" >&2
            echo "CONTROLLER_REMOVE $pev" >> "$fifo"
            # Clear debounce entry
            unset '_CONTROLLER_MONITOR_DEBOUNCE_MAP[$pev]'
        fi
    done

    # N16/H1: authoritative node set for the caller's next prev_nodes — see the docstring
    # above. This is the function's ONLY stdout output (everything else goes to >&2/$fifo).
    echo "${!current_nodes[*]}"
}

# start_controller_monitor: Start monitoring. Blocks. Must be run as a
# background process by the orchestrator.
# Inputs:
#   $1 — mode ("handheld" or "docked")
#   Globals: SPLITSCREEN_FIFO (read); CONTROLLER_MONITOR_UDEVADM_CMD,
#     CONTROLLER_MONITOR_SKIP_INITIAL_EMIT (test overrides)
# Outputs:
#   return — 1 if mode is invalid or SPLITSCREEN_FIFO is not set (never
#     returns otherwise — blocks forever in the monitor loop)
#   side effects — CONTROLLER_ADD/CONTROLLER_REMOVE lines to the FIFO
start_controller_monitor() {
    local mode="${1:-}"
    if [[ "$mode" != "handheld" && "$mode" != "docked" ]]; then
        echo "[controller_monitor] ERROR: start_controller_monitor requires 'handheld' or 'docked' mode" >&2
        return 1
    fi

    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        echo "[controller_monitor] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    # Determine udevadm command (with test override)
    local udevadm_cmd="${CONTROLLER_MONITOR_UDEVADM_CMD:-udevadm}"

    echo "[controller_monitor] Starting controller monitor in $mode mode" >&2

    # Initial device snapshot. EMIT a CONTROLLER_ADD for each ALREADY-connected eligible
    # controller — the udevadm loop below only reacts to NEW connect/disconnect events, so
    # without this a controller plugged in BEFORE launch never spawns an instance. This was
    # the production launchFromPlasma "black screen / nothing launches" bug (2026-06-23):
    # the scan logged "Initial devices" but emitted no ADD, so the orchestrator waited
    # forever. (The test harness injects CONTROLLER_ADD into the FIFO directly, so it never
    # exercised this path.)
    # CONTROLLER_MONITOR_SKIP_INITIAL_EMIT=1: still snapshot the baseline (prev_nodes) so
    # the udev diff below won't re-add already-present pads, but do NOT emit CONTROLLER_ADD
    # for them. docked_flow sets this because it now does the already-connected acquisition
    # itself (the START bookend), so emitting here too would double-spawn. When unset (e.g.
    # handheld_flow), this scan both baselines AND emits, preserving the original behavior.
    local skip_emit="${CONTROLLER_MONITOR_SKIP_INITIAL_EMIT:-0}"
    local prev_nodes=""
    local cline
    while IFS= read -r cline; do
        [[ -z "$cline" ]] && continue
        local ev js_node phys_vendor phys_product
        ev=$(echo "$cline" | awk '{print $1}')
        js_node=$(echo "$cline" | awk '{print $2}')
        phys_vendor=$(echo "$cline" | awk '{print $3}')
        phys_product=$(echo "$cline" | awk '{print $4}')
        prev_nodes="$prev_nodes $ev"
        if [[ "$skip_emit" != "1" ]]; then
            echo "[controller_monitor] Initial controller present: $ev $js_node $phys_vendor $phys_product" >&2
            echo "CONTROLLER_ADD $ev $js_node $phys_vendor $phys_product" >> "$fifo"
        else
            echo "[controller_monitor] Initial controller present (baseline only, emit skipped): $ev" >&2
        fi
    done < <(list_eligible_controllers "$mode")

    echo "[controller_monitor] Initial devices:$prev_nodes" >&2

    # Monitor loop using udevadm
    if command -v "$udevadm_cmd" >/dev/null 2>&1; then
        echo "[controller_monitor] Using $udevadm_cmd for device monitoring" >&2
        # NOTE: process substitution (NOT a pipe) so the loop runs in THIS shell and
        # `prev_nodes` persists across iterations. With `udevadm | while …` the loop is a
        # subshell — prev_nodes resets every event and device-change detection breaks after
        # the first add/remove (audit H1, 2026-06-23).
        while IFS= read -r raw_line; do
            # udevadm output lines (real format):
            # UDEV  [1701234567.123456] add      /devices/virtual/input/input652 (input)
            # UDEV  [1701234567.456789] remove   /devices/virtual/input/input652 (input)
            # Extract action from column 3
            # #27: also react to "change" (e.g. a Bluetooth pad's link re-key on
            # wake-from-idle drops/restores its js node without a clean remove/add
            # pair — previously invisible to this monitor since only add/remove were
            # matched). "bind"/"unbind" (driver attach/detach, not device presence)
            # are intentionally still not matched — add/remove/change cover every case
            # where eligibility can actually change.
            local action=""
            if [[ "$raw_line" =~ ^UDEV[[:space:]]+\[[0-9.]+\][[:space:]]+(add|remove|change) ]]; then
                action="${BASH_REMATCH[1]}"
            fi

            if [[ "$action" == "add" || "$action" == "remove" || "$action" == "change" ]]; then
                # Brief settle time for the device to appear in /proc
                sleep 0.1

                # N16/H1: single enumeration inside _check_devices_changed feeds BOTH the
                # diff AND the new baseline (its stdout) — no separate re-enumeration here.
                prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")
            fi
        done < <("$udevadm_cmd" monitor --subsystem-match=input --udev 2>/dev/null)
    else
        # Fallback: poll
        echo "[controller_monitor] $udevadm_cmd not available, polling every 2s" >&2
        while true; do
            sleep 2

            # N16/H1: see the udevadm branch above — single enumeration, no re-scan.
            prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")
        done
    fi
}
