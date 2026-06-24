#!/bin/bash
set -euo pipefail

# =============================================================================
# CONTROLLER MONITOR MODULE
# =============================================================================
# Enumerates Steam virtual gamepad devices (28de:11ff) and monitors for
# controller add/remove events via udevadm. Emits structured messages
# to the named pipe at $SPLITSCREEN_FIFO.
#
# Public API:
#   list_eligible_controllers(mode)     — stdout: "event_node js_node vendor product" lines
#   start_controller_monitor(mode)      — blocks; writes CONTROLLER_ADD/REMOVE to FIFO
#   get_controller_by_index(index, mode) — stdout: "event_node js_node" or empty
#
# Environment overrides (for testing):
#   PROC_INPUT_DEVICES              — override /proc/bus/input/devices path
#   INPUTPLUMBER_DBUS_AVAILABLE     — set to "0" to force enumeration fallback
#   CONTROLLER_MONITOR_UDEVADM_CMD  — override udevadm command
# =============================================================================

# --- Module-level constants ---
readonly CONTROLLER_MONITOR_MAX_PLAYERS=4
readonly CONTROLLER_MONITOR_DEBOUNCE_MS=500
readonly CONTROLLER_MONITOR_DEFAULT_PROC_PATH="/proc/bus/input/devices"
readonly CONTROLLER_MONITOR_STEAM_VENDOR="28de"
readonly CONTROLLER_MONITOR_STEAM_PRODUCT="11ff"

# --- Internal data structures ---
# We maintain a global associative array (bash 4+) for debounce tracking.
# Keys are event node paths, values are epoch milliseconds of last add.
declare -A _CONTROLLER_MONITOR_DEBOUNCE_MAP

# _get_epoch_ms: Return current time in milliseconds since epoch.
_get_epoch_ms() {
    local epoch_ns
    epoch_ns=$(date +%s%N 2>/dev/null || echo "0")
    echo $(( epoch_ns / 1000000 ))
}

# _get_proc_input_path: Return the proc input devices path (with override support).
_get_proc_input_path() {
    echo "${PROC_INPUT_DEVICES:-$CONTROLLER_MONITOR_DEFAULT_PROC_PATH}"
}

# _parse_steam_virtual_devices: Extract all 28de:11ff devices with jsN handlers.
# Reads from the path returned by _get_proc_input_path.
# Output: one line per device: "<eventN> <jsN>"
# Devices are output in order of appearance (ascending eventN on real systems).
_parse_steam_virtual_devices() {
    local proc_path
    proc_path=$(_get_proc_input_path)

    if [[ ! -f "$proc_path" ]]; then
        echo "[controller_monitor] ERROR: $proc_path not found" >&2
        return 1
    fi

    local in_block=0
    local vendor="" product=""
    local handlers=""

    local line
    while IFS= read -r line; do
        # Blank line terminates a block
        if [[ -z "$line" ]]; then
            if (( in_block == 1 )) && [[ "$vendor" == "$CONTROLLER_MONITOR_STEAM_VENDOR" ]] && [[ "$product" == "$CONTROLLER_MONITOR_STEAM_PRODUCT" ]]; then
                local eventN=""
                local jsN=""
                # Parse handlers: "event29 js1" → extract eventN and jsN
                for _h in $handlers; do
                    case "$_h" in
                        event*) eventN="${_h#event}" ;;
                        js*)    jsN="${_h#js}" ;;
                    esac
                done
                if [[ -n "$eventN" && -n "$jsN" ]]; then
                    echo "$eventN $jsN"
                fi
            fi
            in_block=0
            vendor=""
            product=""
            handlers=""
            continue
        fi

        in_block=1

        case "$line" in
            I:*)
                # Parse Vendor=XXXX Product=XXXX
                if [[ "$line" =~ Vendor=([0-9a-fA-F]{4}) ]]; then
                    vendor="${BASH_REMATCH[1],,}"  # lowercase
                fi
                if [[ "$line" =~ Product=([0-9a-fA-F]{4}) ]]; then
                    product="${BASH_REMATCH[1],,}"  # lowercase
                fi
                ;;
            H:*)
                handlers="${line#H: Handlers=}"
                ;;
        esac
    done < "$proc_path"

    # Handle the last block (if file doesn't end with blank line)
    if (( in_block == 1 )) && [[ "$vendor" == "$CONTROLLER_MONITOR_STEAM_VENDOR" ]] && [[ "$product" == "$CONTROLLER_MONITOR_STEAM_PRODUCT" ]]; then
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
    fi
}

# _parse_all_gamepad_devices: Extract ALL devices with jsN handlers (any VID:PID).
# Output: one line per device: "<eventN> <jsN> <vendor> <product> <sysfs> <phys>"
# Used for handheld mode (accepts any gamepad) and physical source matching.
_parse_all_gamepad_devices() {
    local proc_path
    proc_path=$(_get_proc_input_path)

    if [[ ! -f "$proc_path" ]]; then
        echo "[controller_monitor] ERROR: $proc_path not found" >&2
        return 1
    fi

    local in_block=0
    local vendor="" product=""
    local handlers="" sysfs="" phys=""

    local line
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if (( in_block == 1 )); then
                local jsN=""
                for _h in $handlers; do
                    case "$_h" in
                        js*) jsN="${_h#js}" ; break ;;
                    esac
                done
                if [[ -n "$jsN" ]]; then
                    local eventN=""
                    for _h in $handlers; do
                        case "$_h" in
                            event*) eventN="${_h#event}" ; break ;;
                        esac
                    done
                    echo "$eventN $jsN ${vendor:-0000} ${product:-0000} ${sysfs:-} ${phys:-}"
                fi
            fi
            in_block=0
            vendor=""; product=""; handlers=""; sysfs=""; phys=""
            continue
        fi

        in_block=1

        case "$line" in
            I:*)
                if [[ "$line" =~ Vendor=([0-9a-fA-F]{4}) ]]; then
                    vendor="${BASH_REMATCH[1],,}"
                fi
                if [[ "$line" =~ Product=([0-9a-fA-F]{4}) ]]; then
                    product="${BASH_REMATCH[1],,}"
                fi
                ;;
            H:*)
                handlers="${line#H: Handlers=}"
                ;;
            S:*)
                sysfs="${line#S: Sysfs=}"
                ;;
            P:*)
                phys="${line#P: Phys=}"
                ;;
        esac
    done < "$proc_path"

    # Last block
    if (( in_block == 1 )); then
        local jsN=""
        for _h in $handlers; do
            case "$_h" in
                js*) jsN="${_h#js}" ; break ;;
            esac
        done
        if [[ -n "$jsN" ]]; then
            local eventN=""
            for _h in $handlers; do
                case "$_h" in
                    event*) eventN="${_h#event}" ; break ;;
                esac
            done
            echo "$eventN $jsN ${vendor:-0000} ${product:-0000} ${sysfs:-} ${phys:-}"
        fi
    fi
}

# _find_internal_by_pad_name: Scan /proc/bus/input/devices for the 28de:11ff
# entry whose Name line contains "pad 0" — Steam always names the built-in Deck
# control "Microsoft X-Box 360 pad 0" regardless of enumeration order.
# Returns the raw eventN number (no /dev/input/ prefix) or empty + return 1 on failure.
_find_internal_by_pad_name() {
    local proc_path
    proc_path=$(_get_proc_input_path)
    [[ ! -f "$proc_path" ]] && return 1

    local in_block=0 vendor="" product="" devname="" handlers=""
    local line
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if (( in_block == 1 )) \
               && [[ "$vendor" == "$CONTROLLER_MONITOR_STEAM_VENDOR" ]] \
               && [[ "$product" == "$CONTROLLER_MONITOR_STEAM_PRODUCT" ]] \
               && [[ "$devname" == *"pad 0"* ]]; then
                local eventN="" _h
                for _h in $handlers; do
                    case "$_h" in event*) eventN="${_h#event}"; break ;; esac
                done
                if [[ -n "$eventN" ]]; then
                    echo "$eventN"
                    return 0
                fi
            fi
            in_block=0; vendor=""; product=""; devname=""; handlers=""
            continue
        fi
        in_block=1
        case "$line" in
            I:*)
                [[ "$line" =~ Vendor=([0-9a-fA-F]{4}) ]] && vendor="${BASH_REMATCH[1],,}"
                [[ "$line" =~ Product=([0-9a-fA-F]{4}) ]] && product="${BASH_REMATCH[1],,}"
                ;;
            N:*) devname="${line#N: Name=}" ;;
            H:*) handlers="${line#H: Handlers=}" ;;
        esac
    done < "$proc_path"
    return 1
}

# _eventN_to_virtual_idx: Convert eventN to 1-based position in the sorted
# virtual device list. Returns the index (1-based) or 1 on failure.
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

# _identify_internal_virtual_index: Return the 1-based index of the internal
# gamepad's 28de:11ff virtual device in the sorted virtual device list.
# Strategy: InputPlumber D-Bus → "pad 0" Name scan → last-in-list fallback.
_identify_internal_virtual_index() {
    # --- Strategy 1: InputPlumber D-Bus (most accurate) ---
    if [[ "${INPUTPLUMBER_DBUS_AVAILABLE:-}" != "0" ]] && command -v busctl >/dev/null 2>&1; then
        echo "[controller_monitor] Querying InputPlumber via D-Bus..." >&2
        local managed_output
        managed_output=$(busctl call org.shadowblip.InputPlumber \
            /org/shadowblip/InputPlumber \
            org.shadowblip.InputPlumber \
            GetManagedDevices 2>/dev/null || true)

        if [[ -n "$managed_output" ]]; then
            local object_paths
            object_paths=$(echo "$managed_output" | grep -oP '"/[^"]*"' | tr -d '"' || true)
            local op
            for op in $object_paths; do
                local source_output
                source_output=$(busctl get-property org.shadowblip.InputPlumber \
                    "$op" org.shadowblip.Input.CompositeDevice \
                    SourceDevicePaths 2>/dev/null || true)
                [[ -z "$source_output" ]] && continue
                if echo "$source_output" | grep -q "platform" \
                   || ! echo "$source_output" | grep -q "usb"; then
                    local target_output
                    target_output=$(busctl get-property org.shadowblip.InputPlumber \
                        "$op" org.shadowblip.Input.CompositeDevice \
                        TargetDevices 2>/dev/null || true)
                    if [[ "$target_output" =~ event([0-9]+) ]]; then
                        local internal_eventN="${BASH_REMATCH[1]}"
                        echo "[controller_monitor] InputPlumber: internal at event$internal_eventN" >&2
                        local found_idx
                        if found_idx=$(_eventN_to_virtual_idx "$internal_eventN"); then
                            echo "$found_idx"; return 0
                        fi
                        echo "[controller_monitor] event$internal_eventN not in virtual list" >&2
                    fi
                fi
            done
            echo "[controller_monitor] InputPlumber: could not locate internal event node" >&2
        else
            echo "[controller_monitor] InputPlumber D-Bus call failed" >&2
        fi
    fi

    # --- Strategy 2: Name scan ("pad 0" is always the built-in Deck control) ---
    local pad0_eventN
    if pad0_eventN=$(_find_internal_by_pad_name 2>/dev/null) && [[ -n "$pad0_eventN" ]]; then
        local found_idx
        if found_idx=$(_eventN_to_virtual_idx "$pad0_eventN"); then
            echo "[controller_monitor] Name-based: internal at index $found_idx (event$pad0_eventN)" >&2
            echo "$found_idx"; return 0
        fi
    fi

    # --- Strategy 3: Assume internal is FIRST (index 1) ---
    # The Steam Deck's built-in gamepad always enumerates before any
    # externally connected virtual gamepads (28de:11ff), so the first
    # virtual device is always the internal gamepad.
    echo "[controller_monitor] Fallback: assuming internal is first virtual device (index 1)" >&2
    echo "1"
    return 0
}
# _get_physical_devices: Return physical gamepad devices (not 28de:11ff, has jsN).
# Output: one line per device: "<vendor> <product>"
# Used to map external controller VID:PID by enumeration position.
_get_physical_devices() {
    # Collect all gamepad devices, exclude 28de:11ff virtual ones
    local line
    while IFS= read -r line; do
        local _vendor _product
        _vendor=$(echo "$line" | awk '{print $3}')
        _product=$(echo "$line" | awk '{print $4}')

        if [[ "$_vendor" != "$CONTROLLER_MONITOR_STEAM_VENDOR" || "$_product" != "$CONTROLLER_MONITOR_STEAM_PRODUCT" ]]; then
            echo "$_vendor $_product"
        fi
    done < <(_parse_all_gamepad_devices)
}

# --- Public API ---

# Return the event node path for the internal (built-in) Steam Deck gamepad.
# Output: "/dev/input/eventN" on stdout, or empty string if not found.
get_internal_event_node() {
    local pad0_eventN
    if pad0_eventN=$(_find_internal_by_pad_name 2>/dev/null) && [[ -n "$pad0_eventN" ]]; then
        echo "/dev/input/event$pad0_eventN"
        echo "[controller_monitor] Internal event node: /dev/input/event$pad0_eventN" >&2
        return 0
    fi
    # Fallback: get the first virtual device's event node
    local first_virtual
    first_virtual=$(_parse_steam_virtual_devices | head -1 | awk '{print $1}')
    if [[ -n "$first_virtual" ]]; then
        echo "/dev/input/event$first_virtual"
        echo "[controller_monitor] Internal event node (fallback): /dev/input/event$first_virtual" >&2
        return 0
    fi
    echo "[controller_monitor] WARNING: could not determine internal event node" >&2
    echo ""
    return 1
}

# Write current eligible device list to stdout.
# Each line: "<event_node> <js_node> <physical_vendor> <physical_product>"
# $1 = mode ("handheld" or "docked")
# In docked mode: only 28de:11ff devices, excluding the internal gamepad, max 4.
# In handheld mode: exactly one line — the first gamepad-capable device (any VID:PID).
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

    # Docked mode: 28de:11ff virtual devices, exclude internal, max MAX_PLAYERS
    local internal_idx
    internal_idx=$(_identify_internal_virtual_index)

    # Build arrays of virtual devices and physical devices
    local -a virtual_events=()
    local -a virtual_js=()
    local vline
    while IFS= read -r vline; do
        virtual_events+=("$(echo "$vline" | awk '{print $1}')")
        virtual_js+=("$(echo "$vline" | awk '{print $2}')")
    done < <(_parse_steam_virtual_devices)

    local -a phys_vendors=()
    local -a phys_products=()
    local pline
    while IFS= read -r pline; do
        phys_vendors+=("$(echo "$pline" | awk '{print $1}')")
        phys_products+=("$(echo "$pline" | awk '{print $2}')")
    done < <(_get_physical_devices)

    local count=0
    local i
    for (( i = 0; i < ${#virtual_events[@]}; i++ )); do
        local v_idx=$((i + 1))  # 1-based

        # Skip the internal gamepad
        if (( v_idx == internal_idx )); then
            continue
        fi

        # Cap at MAX_PLAYERS
        if (( count >= CONTROLLER_MONITOR_MAX_PLAYERS )); then
            break
        fi

        # Map to physical device: the Nth eligible virtual (0-based count)
        # corresponds to the Nth physical device in enumeration order.
        # Since physical and virtual devices are interleaved in /proc/bus/input/devices,
        # and the internal gamepad's virtual is created before external virtuals,
        # eligible virtual at position `count` maps to physical at position `count`.
        local phys_vendor="0000"
        local phys_product="0000"
        if (( count < ${#phys_vendors[@]} )); then
            phys_vendor="${phys_vendors[$count]}"
            phys_product="${phys_products[$count]}"
        fi

        echo "/dev/input/event${virtual_events[$i]} /dev/input/js${virtual_js[$i]} $phys_vendor $phys_product"
        count=$((count + 1))
    done
}

# Return the event node and js node for the Nth eligible controller (1-based).
# $1 = index (1-4), $2 = mode ("handheld" or "docked")
# Output: "<event_node> <js_node>" on stdout, or empty string if not found.
get_controller_by_index() {
    local index="${1:-1}"
    local mode="${2:-}"

    local line
    line=$(list_eligible_controllers "$mode" | sed -n "${index}p")
    if [[ -n "$line" ]]; then
        echo "$line" | awk '{print $1, $2}'
    fi
}

# _check_devices_changed: Compare current eligible device list against a
# previously stored snapshot (tracked by event node).
# Writes CONTROLLER_ADD or CONTROLLER_REMOVE messages to $SPLITSCREEN_FIFO.
# $1 = mode
# $2 = space-separated list of previously seen event nodes (by path)
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
            if (( now_ms - last_ms < CONTROLLER_MONITOR_DEBOUNCE_MS )); then
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
}

# Start monitoring. Blocks. Writes CONTROLLER_ADD / CONTROLLER_REMOVE
# messages to the FIFO at $SPLITSCREEN_FIFO.
# Must be run as a background process by the orchestrator.
# $1 = mode ("handheld" or "docked")
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
        echo "[controller_monitor] Initial controller present: $ev $js_node $phys_vendor $phys_product" >&2
        echo "CONTROLLER_ADD $ev $js_node $phys_vendor $phys_product" >> "$fifo"
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
            local action=""
            if [[ "$raw_line" =~ ^UDEV[[:space:]]+\[[0-9.]+\][[:space:]]+(add|remove) ]]; then
                action="${BASH_REMATCH[1]}"
            fi

            if [[ "$action" == "add" || "$action" == "remove" ]]; then
                # Brief settle time for the device to appear in /proc
                sleep 0.1

                # Re-enumerate and check for changes
                local new_nodes=""
                local nline
                while IFS= read -r nline; do
                    [[ -z "$nline" ]] && continue
                    local ev
                    ev=$(echo "$nline" | awk '{print $1}')
                    new_nodes="$new_nodes $ev"
                done < <(list_eligible_controllers "$mode")

                _check_devices_changed "$mode" "$prev_nodes"
                prev_nodes="$new_nodes"
            fi
        done < <("$udevadm_cmd" monitor --subsystem-match=input --udev 2>/dev/null)
    else
        # Fallback: poll
        echo "[controller_monitor] $udevadm_cmd not available, polling every 2s" >&2
        while true; do
            sleep 2

            local new_nodes=""
            local nline
            while IFS= read -r nline; do
                [[ -z "$nline" ]] && continue
                local ev
                ev=$(echo "$nline" | awk '{print $1}')
                new_nodes="$new_nodes $ev"
            done < <(list_eligible_controllers "$mode")

            _check_devices_changed "$mode" "$prev_nodes"
            prev_nodes="$new_nodes"
        done
    fi
}
