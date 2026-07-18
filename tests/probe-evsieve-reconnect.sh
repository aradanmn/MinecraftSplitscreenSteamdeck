#!/bin/bash
# =============================================================================
# probe-evsieve-reconnect.sh — does an evsieve persistent virtual survive a
#                              DS4 battery-death power-cycle with a STABLE
#                              inode, faithfully mirror the pad's event
#                              stream, and (bonus) starve Steam's own
#                              virtual while grabbed?  (issue #38)
# =============================================================================
# Operator-interactive, single-session on-Deck probe. Owner has ONE external
# DS4 (BT or USB); Steam runs in Game Mode. Emits one grep-able VERDICT line
# per probe to stdout and appends them to a results file for pasting into
# #38.
#
# Why this probe exists: our bwrap sandbox --dev-binds a pad's
# /dev/input/eventN + /dev/input/jsN at launch (_build_bwrap_command in
# modules/instance_lifecycle.sh, lines ~325-380). A bind mount captures the
# INODE at launch. When a DS4 dies (battery) the inode is destroyed; a
# reconnect that reuses the same eventN NUMBER still gets a NEW inode the
# sandbox can never see (issue #62). evsieve proposes to fix this: it reads
# the physical evdev and re-emits through a PERSISTENT uinput virtual whose
# node we would bind instead. The persistence holds ONLY IF the virtual's
# node survives the physical power-cycle without being destroyed+recreated
# -- and uinput capabilities are IMMUTABLE after creation, so evsieve
# recreates (new inode, dead bind) if a reopened device's capabilities
# differ. This probe measures exactly that survival, plus stream fidelity,
# plus whether evsieve's exclusive grab starves Steam Input's own virtual.
# Evidence, never vibes (M4 house style).
#
# Research basis: docs/RESEARCH-CONTROLLER-VIRTUALIZATION-2026-07-17.md §3,
# §4.3 and the uinput-capability-immutability constraint.
#
# P0  UINPUT_OPEN     can the deck user open /dev/uinput via evsieve at all
# A   NODE_STABILITY  virtual node inode STABLE/CHANGED across power-cycle
# B   STREAM_FIDELITY physical vs virtual event vocab + axis ranges match
# BON STEAM_GRAB      does evsieve's grab silence the DS4's 28de:11ff
#                     virtual
#
# HARD RULES: no sudo; never grab/target 28de:* or the built-in; never kill
# Steam/gamescope; only kill evsieve PIDs THIS script started; trap cleanup
# leaves no lingering evsieve. See the #38 evsieve-probe work order.
#
# USAGE (on the Deck, Game Mode terminal or Desktop):
#   bash tests/probe-evsieve-reconnect.sh
#   Follow the on-screen prompts with ONE external DS4.
#
# Environment overrides (for testing):
#   MCSS_EVSIEVE_BIN   — path to evsieve (default ~/evsieve-src/target/
#                        release/evsieve)
#   MCSS_MODULES       — deployed module dir (default the house path)
#   MCSS_PROBE_RESULTS — results file (default $HOME/evsieve-probe-<ts>.txt)
#
# evsieve CLI note: this script targets evsieve 1.4.0's REAL flags --
# grab[=auto|force], persist=none|reopen|exit, create-link=PATH,
# name=NAME, device-id=VENDOR:PRODUCT. There is NO persist=full in this
# binary. Production ultimately wants persist=full (start-before-connect,
# cache-primed slot); that needs a source-branch check before it can be
# probed here -- see the A_NODE_STABILITY evidence string.
#
# Version history:
#   v1.0 2026-07-18  Initial evsieve reconnect probe for #38 (§4.3
#                    experiments)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="${MCSS_MODULES:-$HOME/.local/share/PolyMC/modules}"
# shellcheck source=/dev/null
source "$MODULES/controller_monitor.sh" 2>/dev/null \
    || source "$HERE/../modules/controller_monitor.sh"

_required_fn=""
for _required_fn in _parse_all_gamepad_devices _map_external_player_virtuals \
    _get_epoch_ms parse_input_device_blocks; do
    if ! declare -f "$_required_fn" >/dev/null 2>&1; then
        echo "ERROR: ${_required_fn} not found — controller_monitor.sh" \
             "failed to source" >&2
        exit 1
    fi
done
unset _required_fn

# controller_monitor.sh runs `set -euo pipefail` when sourced, silently
# turning errexit ON for this probe (2026-07-18: killed the script at
# Probe A's trailing `[[ -e ]] &&` WARN, so Probe B never ran). This is
# an operator-interactive probe: soft failures must reach their verdict
# lines, never abort the session. Re-assert our own mode.
set +e
set -uo pipefail

# --- Constants ---
readonly EVSIEVE_BIN="${MCSS_EVSIEVE_BIN:-$HOME/evsieve-src/target/release/\
evsieve}"
readonly DS4_VENDOR="054c"                        # Sony; the ONLY grab target
readonly STEAM_VENDOR="${MCSS_STEAM_VENDOR_ID:-28de}"  # NEVER a grab target
readonly CAPTURE_SECONDS=4       # per stream-capture window
readonly RECONNECT_WAIT_S=30     # max wait for the DS4 to reappear
LINK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcss-evsieve-probe.XXXXXX")"
readonly LINK_DIR
readonly CAPTURE_READER="$LINK_DIR/capture_reader.py"
RESULTS="${MCSS_PROBE_RESULTS:-$HOME/evsieve-probe-$(date +%Y%m%d-%H%M%S).txt}"
readonly RESULTS

# Module-private mutable array: every evsieve PID launched, tracked here.
# The EXIT/INT/TERM trap kills exactly these -- never pkill/killall.
declare -a _SPAWNED_EVSIEVE_PIDS=()
# Module-private mutable array: every background watcher PID launched
# (node-existence sampler, udevadm monitor), tracked here. Same
# tracked-PID-only kill discipline as _SPAWNED_EVSIEVE_PIDS -- never
# pkill/killall.
declare -a _SPAWNED_WATCHER_PIDS=()
# Set once _start_udev_watcher actually starts a udevadm monitor, so the
# wrap-up banner only claims a udev log exists when one really does.
_UDEV_WATCHER_STARTED=0

# --- Cleanup ---

# cleanup: Kill every tracked evsieve PID, verify none survive, and remove
# the mktemp-scoped LINK_DIR. Runs on EXIT/INT/TERM so Ctrl+C mid-prompt
# always reaches a clean state.
# Inputs:
#   Globals: _SPAWNED_EVSIEVE_PIDS (read), LINK_DIR (read)
# Outputs:
#   side effects — kills PIDs, removes LINK_DIR; stderr status lines
cleanup() {
    local pid alive=0
    for pid in "${_SPAWNED_EVSIEVE_PIDS[@]:-}" "${_SPAWNED_WATCHER_PIDS[@]:-}"
    do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true      # only OUR tracked PIDs
    done
    sleep 0.3
    # Report any survivor -- evidence the Deck is left clean.
    for pid in "${_SPAWNED_EVSIEVE_PIDS[@]:-}" "${_SPAWNED_WATCHER_PIDS[@]:-}"
    do
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            alive=1
        fi
    done
    [[ -n "${LINK_DIR:-}" && -d "$LINK_DIR" ]] && rm -rf "$LINK_DIR"
    (( alive )) && echo "[probe] WARN: force-killed a lingering tracked" \
        "process" >&2
    echo "[probe] cleanup done; no tracked evsieve/watcher left running" >&2
}
trap cleanup EXIT INT TERM

# --- Helper functions ---

# _extract_field: Pull "field=value" out of a space-joined key=value tally
# string, e.g. from record_virtual_node or capture_stream output.
# Inputs:
#   $1 — field name (no trailing '=')
#   $2 — the tally string to search
# Outputs:
#   stdout — the value (empty if the field is absent)
_extract_field() {
    local field="$1" str="$2" rest
    [[ "$str" == *"${field}="* ]] || { echo ""; return 0; }
    rest="${str#*"${field}"=}"
    echo "${rest%% *}"
}

# emit_verdict: Print a single grep-able VERDICT line to stdout AND append
# it to the results file.
# Inputs:
#   $1 — NAME (e.g. A_NODE_STABILITY)
#   $2 — VALUE (e.g. STABLE, CHANGED, PASS, FAIL)
#   $3 — evidence string (may be long; wraps are fine in the results file)
#   Globals: RESULTS (read)
# Outputs:
#   stdout — "VERDICT <NAME>=<VALUE> t=<epoch_ms> evidence=\"<...>\""
#   side effects — appends the same line to $RESULTS
emit_verdict() {
    local name="$1" value="$2" evidence="$3" ts line
    ts=$(_get_epoch_ms)
    line="VERDICT ${name}=${value} t=${ts} evidence=\"${evidence}\""
    echo "$line"
    echo "$line" >> "$RESULTS"
}

# find_ds4_event_node: Positively identify the external DS4's OWN js-bearing
# evdev node. NEVER returns a 28de node -- this is the guard that keeps
# every grab target honest.
#
# 2026-07-18 false positive: with more than one 054c pad connected, this
# used to WARN and silently grab "the first" one while the operator was
# actually handling a DIFFERENT pad -- every downstream verdict then
# measured the wrong device and still reported success. Multiple pads
# must now BLOCK the probe (loop with the operator) until exactly one
# remains, never guess.
# Inputs:
#   Globals: DS4_VENDOR (read); reads _parse_all_gamepad_devices, calls
#     prompt_operator when more than one pad is enumerated
# Outputs:
#   stdout — "/dev/input/eventN jsN" on success
#   return — 0 success; 1 (no stdout) if no 054c js-bearing pad is
#     present; 2 if the operator typed 'skip' while more than one pad
#     was still connected (caller should treat this as OPERATOR_ABORT)
find_ds4_event_node() {
    local ev js vnd prd sysfs phys
    local -a matches=()
    while true; do
        matches=()
        while IFS=' ' read -r ev js vnd prd sysfs phys; do
            [[ -z "$ev" ]] && continue
            [[ "$vnd" == "$DS4_VENDOR" ]] || continue
            matches+=("$ev $js")
        done < <(_parse_all_gamepad_devices 2>/dev/null)

        (( ${#matches[@]} == 0 )) && return 1
        (( ${#matches[@]} == 1 )) && break

        echo "[probe] BLOCK: ${#matches[@]} ${DS4_VENDOR} pads found;" \
             "this probe can only measure ONE pad at a time" >&2
        if ! prompt_operator "Power off or unplug all but ONE DS4," \
            " then press Enter when exactly ONE remains, or type" \
            " 'skip' and Enter to abort the probe."
        then
            return 2
        fi
    done

    local first_ev first_js
    first_ev="${matches[0]%% *}"
    first_js="${matches[0]#* }"
    echo "/dev/input/event${first_ev} js${first_js}"
}

# record_virtual_node: Resolve a create-link symlink to its real node and
# record identity fields. The INODE is the decisive stability signal -- a
# recreated node ALWAYS gets a new inode even if eventN reuses the number.
# Inputs:
#   $1 — LINKPATH the evsieve create-link path
#   $2 — DEVNAME the advertised output device name
# Outputs:
#   stdout — "realpath=<p> inode=<i> majmin=<m> js=<n|NONE>" (NONE tokens
#     when the link/node is unresolved or no jsN handler was found)
#   return — 1 if the link does not resolve to a live node
record_virtual_node() {
    local linkpath="$1" devname="$2"
    local real inode majmin jsn="NONE"
    real=$(readlink -f "$linkpath" 2>/dev/null) || real=""
    if [[ -z "$real" || ! -e "$real" ]]; then
        echo "realpath=NONE inode=NONE majmin=NONE js=NONE"
        return 1
    fi
    read -r inode majmin < <(stat -c '%i %t:%T' "$real" 2>/dev/null)
    inode="${inode:-NONE}"
    majmin="${majmin:-NONE}"

    local vendor product name handlers sysfs phys keybits _h stripped
    # shellcheck disable=SC2034  # vendor/product/sysfs/keybits are
    # positional fields of parse_input_device_blocks' fixed 7-column
    # contract; only name/handlers are used here but all must be read to
    # keep the later columns aligned.
    while IFS=$'\x1f' read -r vendor product name handlers sysfs phys \
        keybits; do
        stripped="${name#\"}"
        stripped="${stripped%\"}"
        [[ "$stripped" == "$devname" ]] || continue
        for _h in $handlers; do
            case "$_h" in
                js*) jsn="${_h#js}" ;;
            esac
        done
        break
    done < <(parse_input_device_blocks 2>/dev/null)

    echo "realpath=${real} inode=${inode} majmin=${majmin} js=${jsn}"
}

# _assert_not_steam_vendor: Hard safety belt -- refuse to grab a node
# whose vendor is STEAM_VENDOR (28de:*), even redundantly with
# find_ds4_event_node's own DS4_VENDOR-only filter. Never paper over this:
# a violation exits the whole script.
# Inputs:
#   $1 — evdev node path (e.g. /dev/input/eventN)
#   Globals: STEAM_VENDOR (read); reads _parse_all_gamepad_devices
_assert_not_steam_vendor() {
    local node="$1" target_ev="${1##*event}"
    local ev js vnd prd sysfs phys
    # shellcheck disable=SC2034  # prd/sysfs/phys are positional fields of
    # _parse_all_gamepad_devices' fixed 6-column contract; only ev/vnd are
    # used here but all must be read to keep columns aligned.
    while IFS=' ' read -r ev js vnd prd sysfs phys; do
        [[ "$ev" == "$target_ev" ]] || continue
        if [[ "$vnd" == "$STEAM_VENDOR" ]]; then
            echo "[probe] FATAL: refusing to grab ${node} -- vendor" \
                 "${vnd} matches STEAM_VENDOR (${STEAM_VENDOR}); never" \
                 "a grab target" >&2
            exit 1
        fi
        break
    done < <(_parse_all_gamepad_devices 2>/dev/null)
}

# _evsieve_logfile: Compute the persistent, timestamped log path for a
# given evsieve instance name. Lives next to $RESULTS (NOT in the mktemp
# LINK_DIR, which is rm -rf'd on exit) so operators can inspect evsieve's
# own stdout+stderr -- including "disconnected"/"reconnected" lines and
# this branch's new [<epoch>] persist: diagnostics -- after the session.
# Inputs: $1 — NAME (e.g. MCSS-probe-slotA)
#   Globals: RESULTS (read)
# Outputs: stdout — the log file path
_evsieve_logfile() {
    echo "${RESULTS%.txt}-evsieve-$1.log"
}

# _timestamp_stream: Filter stdin, prefixing each line with a wall-clock
# HH:MM:SS timestamp. Uses bash's printf builtin (no gawk dependency --
# stock SteamOS awk may not support strftime()) so it stays a cheap,
# dependency-free per-line stamp for a live evsieve stream.
# Inputs: stdin
# Outputs: stdout — "HH:MM:SS <original line>"
_timestamp_stream() {
    local line
    while IFS= read -r line; do
        printf '%(%H:%M:%S)T %s\n' -1 "$line"
    done
}

# start_evsieve: Launch evsieve forwarding EV_NODE to a persistent
# create-link virtual, in the background. Its combined stdout+stderr is
# timestamped line-by-line into a persistent log next to $RESULTS (see
# _evsieve_logfile) -- the evidence trail for P0's uinput-permission
# check and for A/B's disconnected/reconnected counts.
# Inputs:
#   $1 — GRAB: "grab" or "" (empty = no grab, needed for Probe B's dual
#        read of physical + virtual at once)
#   $2 — LINKPATH create-link target (must live under LINK_DIR)
#   $3 — DEVNAME advertised output name= value
#   $4 — EV_NODE the DS4's own physical evdev node
#   Globals: EVSIEVE_BIN (read), LINK_DIR (read), RESULTS (read),
#            _SPAWNED_EVSIEVE_PIDS (read/write)
# Outputs:
#   side effects — spawns a background evsieve; $! (evsieve's OWN pid,
#     not the log-filter's -- the `> >(...)` reader is a separate,
#     un-backgrounded process substitution) appended to
#     _SPAWNED_EVSIEVE_PIDS; combined stdout+stderr streams into
#     "$(_evsieve_logfile DEVNAME)"
start_evsieve() {
    local grab_flag="$1" linkpath="$2" devname="$3" ev_node="$4"
    local logfile
    logfile=$(_evsieve_logfile "$devname")
    [[ -n "$grab_flag" ]] && _assert_not_steam_vendor "$ev_node"
    if [[ -n "$grab_flag" ]]; then
        "$EVSIEVE_BIN" --input "$ev_node" grab persist=reopen \
            --output create-link="$linkpath" name="$devname" \
            > >(_timestamp_stream >> "$logfile") 2>&1 &
    else
        "$EVSIEVE_BIN" --input "$ev_node" persist=reopen \
            --output create-link="$linkpath" name="$devname" \
            > >(_timestamp_stream >> "$logfile") 2>&1 &
    fi
    _SPAWNED_EVSIEVE_PIDS+=("$!")
}

# _stop_last_evsieve: Kill (and reap) the most recently started tracked
# evsieve. Used between probe stages; the final EXIT trap re-verifies.
# Inputs: Globals: _SPAWNED_EVSIEVE_PIDS (read)
_stop_last_evsieve() {
    local n=${#_SPAWNED_EVSIEVE_PIDS[@]}
    (( n == 0 )) && return 0
    local pid="${_SPAWNED_EVSIEVE_PIDS[$((n - 1))]}"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# --- Physical-node lifecycle watchers (nodewatch + udevadm) ---
#
# These run alongside Probes A and B so a power-cycle's exact
# disappear/reappear timestamps -- and the new inode a reconnect gets --
# can be correlated against evsieve's own "disconnected"/"reconnected"
# lines. Both are tracked PIDs, killed only by cleanup()/_stop_watchers,
# never pkill. inotifywait is NOT assumed present (not guaranteed on
# stock SteamOS); this is a plain stat(1) poll loop instead.

# _start_node_watcher: Background loop sampling NODE's existence + inode
# every 0.5s, appending one line per sample to a persistent log next to
# $RESULTS. Watches the ORIGINAL physical path found at the start of
# Probe A for the rest of the session -- that is the same path evsieve
# itself watches under persist=reopen, so the two logs describe the same
# timeline from two independent vantage points.
# Inputs: $1 — NODE evdev path to watch
#   Globals: RESULTS (read), _SPAWNED_WATCHER_PIDS (read/write)
# Outputs:
#   side effects — spawns a tracked background loop; appends to
#     "$(_nodewatch_logfile)"; $! appended to _SPAWNED_WATCHER_PIDS
_nodewatch_logfile() {
    echo "${RESULTS%.txt}-nodewatch.log"
}
_start_node_watcher() {
    local node="$1" logfile
    logfile=$(_nodewatch_logfile)
    (
        while true; do
            local ts exists=0 inode="NONE"
            ts=$(_get_epoch_ms)
            if [[ -e "$node" ]]; then
                exists=1
                inode=$(stat -c '%i' "$node" 2>/dev/null || echo "NONE")
            fi
            echo "t=${ts} node=${node} exists=${exists} inode=${inode}"
            sleep 0.5
        done
    ) >> "$logfile" &
    _SPAWNED_WATCHER_PIDS+=("$!")
}

# _start_udev_watcher: Background `udevadm monitor --kernel --udev`,
# appending raw udev/kernel events to a persistent log next to $RESULTS.
# Guarded by `command -v udevadm` -- not guaranteed present, and never
# required for the probe's verdicts, only supplementary evidence.
# Inputs: none
#   Globals: RESULTS (read), _SPAWNED_WATCHER_PIDS (read/write),
#            _UDEV_WATCHER_STARTED (write)
# Outputs:
#   side effects — spawns a tracked background udevadm monitor (if
#     available); appends to "$(_udev_logfile)"; $! appended to
#     _SPAWNED_WATCHER_PIDS
_udev_logfile() {
    echo "${RESULTS%.txt}-udev.log"
}
_start_udev_watcher() {
    command -v udevadm >/dev/null 2>&1 || return 0
    local logfile
    logfile=$(_udev_logfile)
    udevadm monitor --kernel --udev >> "$logfile" 2>&1 &
    _SPAWNED_WATCHER_PIDS+=("$!")
    _UDEV_WATCHER_STARTED=1
}

# _stop_watchers: Kill (and reap) every tracked watcher PID. Called once
# near the end of the main flow so the wrap-up banner reports quiesced
# logs; the EXIT trap re-verifies (and is the only thing that runs at
# all if the operator Ctrl-C's mid-probe).
# Inputs: Globals: _SPAWNED_WATCHER_PIDS (read)
_stop_watchers() {
    local pid
    for pid in "${_SPAWNED_WATCHER_PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

# _count_matches: Case-insensitive count of PATTERN's occurrences in
# LOGFILE (0 if the file is missing or has none). Used to tally
# evsieve's own "disconnected"/"reconnected" lines for A/B evidence.
# Inputs: $1 — PATTERN, $2 — LOGFILE
# Outputs: stdout — integer count
_count_matches() {
    local pattern="$1" logfile="$2" n
    [[ -f "$logfile" ]] || { echo 0; return 0; }
    n=$(grep -ic "$pattern" "$logfile" 2>/dev/null)
    echo "${n:-0}"
}

# _last_reappear_ts: Scan a nodewatch log for the LAST exists=0 -> 1
# transition (i.e. the most recent moment the physical node came back
# after having been gone) and print its t= epoch-ms timestamp. Because
# the nodewatch log spans the whole session, the LAST such transition at
# the time this is called is the one from whichever probe just ran --
# this lets Probe B's evidence cite the exact ms its own reconnect was
# first observed, to line up against evsieve's disconnected/reconnected
# timestamps.
# Inputs: $1 — nodewatch LOGFILE path
# Outputs: stdout — epoch-ms timestamp, or "NONE" if undeterminable
_last_reappear_ts() {
    local logfile="$1" line exists ts last_gone=1 result="NONE"
    [[ -f "$logfile" ]] || { echo "NONE"; return 0; }
    while IFS= read -r line; do
        exists=$(_extract_field exists "$line")
        if [[ "$exists" == "0" ]]; then
            last_gone=1
        elif [[ "$exists" == "1" ]]; then
            if [[ "$last_gone" == "1" ]]; then
                ts=$(_extract_field t "$line")
                [[ -n "$ts" ]] && result="$ts"
            fi
            last_gone=0
        fi
    done < "$logfile"
    echo "$result"
}

# _write_capture_reader: Write the python3 evdev tally reader once into
# LINK_DIR (idempotent). See §6 of the work order for why python3 is
# PRIMARY here (evtest/evemu-record are not guaranteed on stock SteamOS;
# python3 is, and the evdev read ABI is a stable kernel contract).
_write_capture_reader() {
    [[ -f "$CAPTURE_READER" ]] && return 0
    cat > "$CAPTURE_READER" <<'PYEOF'
import struct, select, sys, time
node, secs = sys.argv[1], float(sys.argv[2])
FMT = 'llHHi'          # timeval(16) + type(2) + code(2) + value(4) = 24
SZ = struct.calcsize(FMT)
if SZ != 24:
    print("capture=BADSTRUCT size=%d" % SZ)
    sys.exit(0)
EV_ABS = 3
types = set()
codes = set()
rng = {}
end = time.time() + secs
fd = open(node, 'rb', buffering=0)
while time.time() < end:
    r, _, _ = select.select([fd], [], [], end - time.time())
    if not r:
        continue
    data = fd.read(SZ)
    if not data or len(data) < SZ:
        continue
    _s, _u, etype, code, value = struct.unpack(FMT, data)
    types.add(etype)
    codes.add((etype, code))
    if etype == EV_ABS:
        lo, hi = rng.get(code, (value, value))
        rng[code] = (min(lo, value), max(hi, value))
fd.close()
abs_items = sorted(rng.items())
abs_s = ",".join("%d:%d..%d" % (c, v[0], v[1]) for c, v in abs_items)
type_s = ",".join(str(t) for t in sorted(types))
print("types=%s codes=%d abs=%s" % (type_s, len(codes), abs_s or "none"))
PYEOF
}

# _capture_stream_evtest: Fallback tally via evtest when python3 is absent.
# Never passes --grab (would fight Probe B's dual-read design).
# Inputs: $1 — node, $2 — seconds, $3 — label
# Outputs: stdout — same "types=.. codes=.. abs=.." shape as the python
#   reader; return 1 on an empty capture
_capture_stream_evtest() {
    local node="$1" secs="$2" label="$3"
    local -a lines=()
    mapfile -t lines < <(timeout "${secs}s" evtest "$node" 2>/dev/null \
        | grep -E '^Event: ')
    if (( ${#lines[@]} == 0 )); then
        echo "capture=EMPTY tool=evtest label=${label}"
        return 1
    fi

    local -A seen_type=() seen_code=() absmin=() absmax=()
    local line ty code val
    for line in "${lines[@]}"; do
        [[ "$line" =~ type\ ([0-9]+)\ \([A-Z_]+\),\ code\ ([0-9]+) ]] \
            || continue
        ty="${BASH_REMATCH[1]}"
        code="${BASH_REMATCH[2]}"
        seen_type["$ty"]=1
        seen_code["${ty}:${code}"]=1
        if [[ "$ty" == "3" && "$line" =~ value\ (-?[0-9]+) ]]; then
            val="${BASH_REMATCH[1]}"
            if [[ -z "${absmin[$code]:-}" ]]; then
                absmin["$code"]="$val"
                absmax["$code"]="$val"
            else
                (( val < absmin[$code] )) && absmin["$code"]="$val"
                (( val > absmax[$code] )) && absmax["$code"]="$val"
            fi
        fi
    done

    local type_s abs_s="" c first=1
    type_s=$(printf '%s,' "${!seen_type[@]}" | sed 's/,$//')
    for c in "${!absmin[@]}"; do
        (( first )) || abs_s+=","
        abs_s+="${c}:${absmin[$c]}..${absmax[$c]}"
        first=0
    done
    echo "types=${type_s} codes=${#seen_code[@]} abs=${abs_s:-none}"
}

# capture_stream: Capture events from an evdev node for SECONDS and print a
# compact tally. Opening a node for READ never grabs it -- safe on the DS4
# physical node, the evsieve virtual, and (Bonus) the DS4's 28de virtual.
# Inputs:
#   $1 — NODE evdev path to read
#   $2 — SECONDS capture window
#   $3 — LABEL diagnostic-only tag
#   Globals: CAPTURE_READER (read)
# Outputs:
#   stdout — "types=<t,..> codes=<N> abs=<code:min..max,..>" or a
#     "capture=UNAVAILABLE|EMPTY|BADSTRUCT ..." failure line
#   return — 0 on a usable tally, 1 otherwise
capture_stream() {
    local node="$1" secs="$2" label="$3" out

    if command -v python3 >/dev/null 2>&1; then
        _write_capture_reader
        out=$(python3 "$CAPTURE_READER" "$node" "$secs" 2>/dev/null)
        if [[ -z "$out" ]]; then
            echo "capture=EMPTY tool=python3 label=${label}"
            return 1
        fi
        echo "$out"
        return 0
    fi

    if command -v evtest >/dev/null 2>&1; then
        _capture_stream_evtest "$node" "$secs" "$label"
        return "$?"
    fi

    echo "capture=UNAVAILABLE label=${label}"
    return 1
}

# _dual_capture: Run capture_stream on a physical node and a virtual node
# CONCURRENTLY (background + foreground, then wait) so one operator wiggle
# feeds both -- required because a plain grab-free forward is still a
# single physical stream, and pre/post captures must line up in time.
# Inputs: $1 — phys node, $2 — virt node
# Outputs: stdout — two lines, phys tally then virt tally
_dual_capture() {
    local phys_node="$1" virt_node="$2"
    local tmp_virt="$LINK_DIR/dual_virt.tmp"
    capture_stream "$virt_node" "$CAPTURE_SECONDS" virt > "$tmp_virt" &
    local bg_pid=$!
    capture_stream "$phys_node" "$CAPTURE_SECONDS" phys
    wait "$bg_pid"
    cat "$tmp_virt"
    rm -f "$tmp_virt"
}

# _fidelity_matches: Compare a physical and virtual capture_stream tally.
#
# 2026-07-18 false positive: two EMPTY captures (types= codes=0 abs=none
# on BOTH sides -- nobody wiggled, or the reader never saw an event) are
# byte-identical strings, so the equality check below "matched" them and
# the probe reported fidelity OK from a comparison of nothing against
# nothing. _run_probe_b now gates on CAPTURE_EMPTY before trusting this
# result, but this function guards the vacuous case itself too (defense
# in depth) so it can never be called and quietly return success again.
# Inputs: $1 — phys tally, $2 — virt tally
# Outputs: return — 0 if types/codes/abs all match and at least one side
#   captured a real event, 1 otherwise (including the double-empty case)
_fidelity_matches() {
    local phys="$1" virt="$2"
    local p_types v_types p_codes v_codes p_abs v_abs
    p_types=$(_extract_field types "$phys")
    v_types=$(_extract_field types "$virt")
    p_codes=$(_extract_field codes "$phys")
    v_codes=$(_extract_field codes "$virt")
    p_abs=$(_extract_field abs "$phys")
    v_abs=$(_extract_field abs "$virt")

    # Vacuous-match trap: don't let empty==empty count as a real match.
    if [[ -z "$p_types" && ( -z "$p_codes" || "$p_codes" == "0" ) \
        && -z "$v_types" && ( -z "$v_codes" || "$v_codes" == "0" ) ]]
    then
        return 1
    fi

    [[ "$p_types" == "$v_types" && "$p_codes" == "$v_codes" \
        && "$p_abs" == "$v_abs" ]]
}

# _tally_is_empty: True if a capture_stream tally recorded nothing --
# zero codes or no types -- regardless of whether the capture "succeeded"
# by returning a well-formed string. See the 2026-07-18 note on
# _fidelity_matches: an empty tally must never silently feed a
# fidelity comparison.
# Inputs: $1 — tally string (as produced by capture_stream)
# Outputs: return — 0 if empty, 1 otherwise
_tally_is_empty() {
    local tally="$1" types codes
    types=$(_extract_field types "$tally")
    codes=$(_extract_field codes "$tally")
    [[ -z "$types" || -z "$codes" || "$codes" == "0" ]]
}

# wait_for_ds4: Poll find_ds4_event_node until it reappears or TIMEOUT_S
# elapses. Used after the operator powers the DS4 back on.
# Inputs: $1 — TIMEOUT_S
# Outputs: return — 0 once the DS4 reappears, 1 on timeout
wait_for_ds4() {
    local timeout_s="$1" waited=0
    while (( waited < timeout_s )); do
        find_ds4_event_node >/dev/null 2>&1 && return 0
        sleep 1
        waited=$(( waited + 1 ))
    done
    return 1
}

# prompt_operator: Print MESSAGE to stderr and wait for the operator on the
# controlling tty. Mirrors tests/hardware/stage3_hotplug.sh's hw_prompt
# tone.
# Inputs: $1 — MESSAGE
# Outputs: return — 0 on Enter, 1 if the operator types 'skip' (or stdin
#   is closed, treated as skip)
prompt_operator() {
    # "$*": call sites split long prompts across several quoted args to
    # hold the 80-char rule — join them (2026-07-18: "$1" truncated every
    # multi-arg prompt mid-sentence on the Deck).
    local message="$*" response
    echo "" >&2
    echo ">>> OPERATOR ACTION REQUIRED <<<" >&2
    echo ">>> ${message}" >&2
    echo ">>> Press Enter when done, or type 'skip' and Enter to skip." >&2
    if ! read -r response < /dev/tty 2>/dev/null; then
        echo "[probe] WARN: stdin closed, treating as skip" >&2
        return 1
    fi
    [[ "${response,,}" == "skip" ]] && return 1
    return 0
}

# announce_wiggle: Countdown then return — the CAPTURE runs right after,
# so the operator wiggles DURING the window, not before it. (2026-07-18:
# the prompt-then-capture ordering measured post-wiggle idle noise; every
# tally showed center jitter, and BONUS_STEAM_GRAB=STARVED was an idle-
# deadzone artifact — the operator's screen kept responding via hidraw.)
# Inputs:
#   $* — instruction text
#   Globals: CAPTURE_SECONDS (read)
announce_wiggle() {
    echo "" >&2
    echo ">>> ${*}" >&2
    echo ">>> Starting in 3s... wiggle for the FULL" \
         "${CAPTURE_SECONDS}s window." >&2
    sleep 3
    echo ">>> GO <<<" >&2
}

# --- Results-file header + CLI-surface confirmation ---

# _confirm_cli_flags: CONFIRM-ON-DECK check that the built binary's --help
# still advertises the flag tokens this script relies on. Diagnostic only
# -- never aborts, per the work order's "note and keep going" rule.
_confirm_cli_flags() {
    local help_text flag
    local -a expected=("grab" "persist=" "create-link=" "name=")
    help_text=$("$EVSIEVE_BIN" --help 2>&1 || true)
    for flag in "${expected[@]}"; do
        if ! grep -qF "$flag" <<< "$help_text"; then
            echo "[probe] DIAGNOSTIC: expected CLI token '${flag}' not" \
                 "found in --help; script assumes it exists per the" \
                 "work order's CONFIRM-ON-DECK note" >&2
        fi
    done
}

# _write_results_header: Write date, evsieve --version/--help, uinput ACL,
# kernel version, and the persist=full CLI-gap note once at start.
_write_results_header() {
    {
        echo "==================================================="
        echo "evsieve reconnect probe (#38) — $(date -Is 2>/dev/null \
            || date)"
        echo "kernel: $(uname -r 2>/dev/null || echo unknown)"
        echo "--- evsieve --version ---"
        "$EVSIEVE_BIN" --version 2>&1 || echo "(--version failed)"
        echo "--- evsieve --help ---"
        "$EVSIEVE_BIN" --help 2>&1 || echo "(--help failed)"
        echo "--- /dev/uinput ACL ---"
        if command -v getfacl >/dev/null 2>&1; then
            getfacl /dev/uinput 2>&1
        else
            stat -c '%A %U %G' /dev/uinput 2>&1
        fi
        echo "--- persist= CLI note ---"
        echo "persist=full is NOT present in this evsieve build" \
             "(persist=none|reopen|exit only); this probe uses" \
             "persist=reopen everywhere. Production wants persist=full" \
             "(start-before-connect, cache-primed) -- needs a" \
             "source-branch check; see A_NODE_STABILITY evidence."
        echo "==================================================="
    } >> "$RESULTS"
}

_print_banner() {
    echo "=============================================================="
    echo " evsieve reconnect probe (issue #38)"
    echo "=============================================================="
    echo " Connect ONE external DS4 (BT or USB). Steam should be running"
    echo " in Game Mode. This probe will:"
    echo "   - grab ONLY the DS4's own 054c evdev node, never the Deck's"
    echo "     built-in (28de:11ff) or any Steam virtual"
    echo "   - never restart or kill Steam/gamescope"
    echo "   - only kill evsieve processes it starts itself"
    echo " Ctrl+C is safe at any point; cleanup runs automatically and"
    echo " leaves no evsieve process behind."
    echo " Results are written to: ${RESULTS}"
    echo "=============================================================="
    echo
}

# --- P0: UINPUT_OPEN gate ---

_run_p0_gate() {
    echo "[probe] P0: uinput-open gate" >&2
    if ! find_ds4_event_node >/dev/null 2>&1; then
        prompt_operator "Connect your ONE external DS4 controller (USB" \
            " or Bluetooth) now, then press Enter." || true
    fi

    local ds4 ev_node rc
    ds4=$(find_ds4_event_node)
    rc=$?
    if (( rc == 2 )); then
        # 2026-07-18: an operator-skip on the multi-pad guard must abort
        # cleanly, never fall through and grab whatever pad remains.
        emit_verdict P0_UINPUT_OPEN OPERATOR_ABORT \
            "operator skipped the multi-pad guard; aborting probe"
        exit 1
    elif (( rc != 0 )); then
        emit_verdict P0_UINPUT_OPEN FAIL \
            "no 054c js-bearing pad detected; cannot proceed"
        exit 1
    fi
    ev_node="${ds4%% *}"

    local link="$LINK_DIR/p0-probe"
    start_evsieve grab "$link" "MCSS-probe-p0" "$ev_node"
    sleep 2

    local errfile
    errfile=$(_evsieve_logfile "MCSS-probe-p0")
    local node_created="none" uinput_err="none"
    if [[ -e "$link" ]]; then
        node_created=$(readlink -f "$link" 2>/dev/null || echo "$link")
    fi
    if [[ -f "$errfile" ]] && grep -iE \
        'uinput.*(permission|denied|eacces)' "$errfile" >/dev/null 2>&1
    then
        uinput_err=$(grep -iE 'uinput.*(permission|denied|eacces)' \
            "$errfile" | head -1)
    fi

    _stop_last_evsieve

    local acl
    if command -v getfacl >/dev/null 2>&1; then
        acl=$(getfacl /dev/uinput 2>&1 | tr '\n' ';')
    else
        acl=$(stat -c '%A %U %G' /dev/uinput 2>&1)
    fi

    local evidence
    evidence="getfacl=${acl}; node created=${node_created};"
    evidence+=" uinput-err=${uinput_err}"

    if [[ "$node_created" != "none" && "$uinput_err" == "none" ]]; then
        emit_verdict P0_UINPUT_OPEN PASS "$evidence"
    else
        emit_verdict P0_UINPUT_OPEN FAIL "$evidence"
        exit 1
    fi
}

# --- Bonus: does the grab starve Steam's own virtual? ---

_run_bonus_steam_grab() {
    local ds4_ev_node="$1"
    local ev js vnd prd steam_ev="" listed="no"
    # shellcheck disable=SC2034  # prd is a positional field of
    # _map_external_player_virtuals' fixed 4-column contract ("ev js vnd
    # prd"); only ev/vnd are used here but all must be read to keep
    # columns aligned.
    while IFS=' ' read -r ev js vnd prd; do
        [[ -z "$ev" ]] && continue
        [[ "$vnd" == "$DS4_VENDOR" ]] || continue
        steam_ev="$ev"
        listed="yes"
        break
    done < <(_map_external_player_virtuals 2>/dev/null)

    if [[ -z "$steam_ev" ]]; then
        emit_verdict BONUS_STEAM_GRAB NO_VIRTUAL \
            "grab held on ${ds4_ev_node}; no matching 28de:* virtual found"
        return 0
    fi

    announce_wiggle "Wiggle the DS4's stick — we watch whether Steam's" \
        "virtual (event${steam_ev}) still emits under evsieve's grab." \
        "NOTE: Steam also reads DS4s via hidraw, so screen response" \
        "during the grab is expected either way."

    # READ-only observation of the DS4's matched Steam virtual -- never a
    # grab/write target, per the hard constraint.
    local tally count
    tally=$(capture_stream "/dev/input/event${steam_ev}" \
        "$CAPTURE_SECONDS" steam-under-grab)
    count=$(_extract_field codes "$tally")

    local starved
    if [[ -z "$count" || "$count" == "0" ]]; then
        starved="STARVED"
    else
        starved="NOT_STARVED"
    fi

    local evidence
    evidence="grab held on ${ds4_ev_node}; steam virtual event${steam_ev}"
    evidence+=" tally[${tally}] over ${CAPTURE_SECONDS}s; parser lists"
    evidence+=" virtual=${listed}; production-meaning:"
    evidence+=" STARVED=>grab before Steam or run nested session,"
    evidence+=" NOT_STARVED=>coexistence is fine"
    emit_verdict BONUS_STEAM_GRAB "$starved" "$evidence"
}

# --- Probe A: NODE_STABILITY ---

_run_probe_a() {
    echo "[probe] Probe A: NODE_STABILITY (+ Bonus rides along)" >&2
    local ds4 ev_node rc
    ds4=$(find_ds4_event_node)
    rc=$?
    if (( rc == 2 )); then
        # 2026-07-18: operator-skip on the multi-pad guard means no
        # single pad was ever confirmed -- report OPERATOR_ABORT, not a
        # generic FAIL that would read like a detection problem.
        emit_verdict A_NODE_STABILITY OPERATOR_ABORT \
            "operator skipped the multi-pad guard before Probe A"
        emit_verdict BONUS_STEAM_GRAB OPERATOR_ABORT \
            "operator skipped the multi-pad guard before Probe A"
        return 1
    elif (( rc != 0 )); then
        emit_verdict A_NODE_STABILITY FAIL "DS4 not detected before Probe A"
        emit_verdict BONUS_STEAM_GRAB FAIL "DS4 not detected before Probe A"
        return 1
    fi
    ev_node="${ds4%% *}"

    # Watchers: an independent, evsieve-external timeline of the SAME
    # physical path (nodewatch) plus raw udev/kernel events, both for
    # correlating against evsieve's own disconnected/reconnected lines.
    _start_node_watcher "$ev_node"
    _start_udev_watcher

    local link_a="$LINK_DIR/slotA"
    start_evsieve grab "$link_a" "MCSS-probe-slotA" "$ev_node"
    sleep 2

    local pre
    pre=$(record_virtual_node "$link_a" "MCSS-probe-slotA")

    _run_bonus_steam_grab "$ev_node"

    if ! prompt_operator "Power the DS4 OFF now (hold PS ~10s until the" \
        " lightbar dies) to simulate battery death. Wait for it to" \
        " disappear, then press Enter."
    then
        emit_verdict A_NODE_STABILITY FAIL "operator skipped power-cycle"
        _stop_last_evsieve
        return 1
    fi

    local waited=0 gone=0
    while (( waited < RECONNECT_WAIT_S )); do
        if ! find_ds4_event_node >/dev/null 2>&1; then
            gone=1
            break
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    (( gone )) || echo "[probe] WARN: DS4 still enumerated" >&2

    local mid survived="no"
    mid=$(record_virtual_node "$link_a" "MCSS-probe-slotA")
    [[ "$mid" == *"realpath=/dev/"* ]] && survived="yes"

    if ! prompt_operator "Now power the DS4 back ON (press PS; reconnect" \
        " via the SAME transport you started with -- BT or USB)." \
        " Press Enter."
    then
        emit_verdict A_NODE_STABILITY FAIL "operator skipped reconnect"
        _stop_last_evsieve
        return 1
    fi

    if ! wait_for_ds4 "$RECONNECT_WAIT_S"; then
        emit_verdict A_NODE_STABILITY FAIL \
            "DS4 did not reappear within ${RECONNECT_WAIT_S}s"
        _stop_last_evsieve
        return 1
    fi
    sleep 2

    local post
    post=$(record_virtual_node "$link_a" "MCSS-probe-slotA")

    local pre_inode post_inode pre_path post_path pre_mm post_mm verdict
    pre_inode=$(_extract_field inode "$pre")
    post_inode=$(_extract_field inode "$post")
    pre_path=$(_extract_field realpath "$pre")
    post_path=$(_extract_field realpath "$post")
    pre_mm=$(_extract_field majmin "$pre")
    post_mm=$(_extract_field majmin "$post")

    if [[ "$pre_inode" == "$post_inode" && "$pre_inode" != "NONE" \
        && "$pre_path" == "$post_path" && "$pre_mm" == "$post_mm" ]]
    then
        verdict="STABLE"
    else
        verdict="CHANGED"
    fi

    local a_logfile disc_n recon_n
    a_logfile=$(_evsieve_logfile "MCSS-probe-slotA")
    disc_n=$(_count_matches disconnected "$a_logfile")
    recon_n=$(_count_matches reconnected "$a_logfile")

    local evidence
    evidence="mode=persist=reopen; pre[${pre}]; gap_survived=${survived};"
    evidence+=" post[${post}]; production-wants=persist=full"
    evidence+=" (start-before-connect, cache-primed) -- NOT in evsieve"
    evidence+=" 1.4.0 CLI (persist=none|reopen|exit only), needs a"
    evidence+=" source-branch check; evsieve_log=${a_logfile}"
    evidence+=" disconnected_count=${disc_n} reconnected_count=${recon_n}"
    emit_verdict A_NODE_STABILITY "$verdict" "$evidence"

    _stop_last_evsieve
    if [[ -e "$link_a" ]]; then
        echo "[probe] WARN: ${link_a} still present" >&2
    fi
    return 0
}

# --- Probe B: STREAM_FIDELITY ---

_run_probe_b() {
    echo "[probe] Probe B: STREAM_FIDELITY" >&2

    if ! prompt_operator "Confirm the DS4 is connected, then press Enter."
    then
        emit_verdict B_STREAM_FIDELITY CAPTURE_UNAVAILABLE \
            "operator skipped Probe B"
        return 1
    fi

    local ds4 ev_node rc
    ds4=$(find_ds4_event_node)
    rc=$?
    if (( rc == 2 )); then
        # 2026-07-18: operator-skip on the multi-pad guard -- report
        # OPERATOR_ABORT rather than CAPTURE_UNAVAILABLE, which would
        # read like a tooling problem instead of a deliberate abort.
        emit_verdict B_STREAM_FIDELITY OPERATOR_ABORT \
            "operator skipped the multi-pad guard before Probe B"
        return 1
    elif (( rc != 0 )); then
        emit_verdict B_STREAM_FIDELITY CAPTURE_UNAVAILABLE \
            "DS4 not detected before Probe B"
        return 1
    fi
    ev_node="${ds4%% *}"

    # Watcher: same nodewatch mechanism as Probe A (harmless if Probe A
    # already has one running on the same path -- see _start_node_watcher).
    _start_node_watcher "$ev_node"
    _start_udev_watcher

    local link_b="$LINK_DIR/slotB"
    start_evsieve "" "$link_b" "MCSS-probe-slotB" "$ev_node"
    sleep 2

    local virt_node
    virt_node=$(readlink -f "$link_b" 2>/dev/null) || virt_node=""
    if [[ -z "$virt_node" || ! -e "$virt_node" ]]; then
        emit_verdict B_STREAM_FIDELITY CAPTURE_UNAVAILABLE \
            "virtual node never appeared at ${link_b}"
        _stop_last_evsieve
        return 1
    fi

    local tool="python3"
    command -v python3 >/dev/null 2>&1 \
        || { command -v evtest >/dev/null 2>&1 && tool="evtest"; } \
        || tool="none"

    announce_wiggle "Hold and wiggle the LEFT stick through its FULL" \
        "range (pre-cycle capture)."
    local -a pre_lines=()
    mapfile -t pre_lines < <(_dual_capture "$ev_node" "$virt_node")
    local phys_pre="${pre_lines[0]:-}" virt_pre="${pre_lines[1]:-}"

    if ! prompt_operator "Power the DS4 OFF now (battery-death sim);" \
        " wait for it to disappear, then press Enter."
    then
        emit_verdict B_STREAM_FIDELITY CAPTURE_UNAVAILABLE \
            "operator skipped the power-cycle step"
        _stop_last_evsieve
        return 1
    fi

    if ! prompt_operator "Now power the DS4 back ON. Press Enter."; then
        emit_verdict B_STREAM_FIDELITY CAPTURE_UNAVAILABLE \
            "operator skipped reconnect"
        _stop_last_evsieve
        return 1
    fi

    if ! wait_for_ds4 "$RECONNECT_WAIT_S"; then
        emit_verdict B_STREAM_FIDELITY CAPTURE_UNAVAILABLE \
            "DS4 did not reappear within ${RECONNECT_WAIT_S}s"
        _stop_last_evsieve
        return 1
    fi
    sleep 2

    # Re-find the DS4 after the cycle: BT reconnects may re-enumerate to
    # a NEW eventN. evsieve persist=reopen watches the ORIGINAL path, so
    # old-vs-new is the decisive diagnostic when the virtual goes silent
    # (2026-07-18 run: node STABLE but zero post-cycle forwarding).
    local ds4_post ev_node_post path_verdict
    if ds4_post=$(find_ds4_event_node); then
        ev_node_post="${ds4_post%% *}"
    else
        ev_node_post="$ev_node"
    fi
    if [[ "$ev_node_post" == "$ev_node" ]]; then
        path_verdict="same"
    else
        path_verdict="changed(${ev_node}->${ev_node_post})"
    fi

    announce_wiggle "Wiggle the LEFT stick again (post-cycle capture)."
    local -a post_lines=()
    mapfile -t post_lines < <(_dual_capture "$ev_node_post" "$virt_node")
    local phys_post="${post_lines[0]:-}" virt_post="${post_lines[1]:-}"

    # 2026-07-18 false positive: phys_pre/virt_pre/phys_post/virt_post
    # were fed straight to _fidelity_matches even when one or more of
    # them was an empty capture (types= codes=0 abs=none), so an
    # empty-vs-empty pair "matched" and B_STREAM_FIDELITY=OK was emitted
    # despite recording nothing. ANY empty tally must short-circuit to
    # CAPTURE_EMPTY, never reach the OK/DEGRADED comparison, and the
    # evidence must name exactly which tally(ies) were empty.
    local ok empty_names=""
    _tally_is_empty "$phys_pre"  && empty_names+="phys_pre,"
    _tally_is_empty "$virt_pre"  && empty_names+="virt_pre,"
    _tally_is_empty "$phys_post" && empty_names+="phys_post,"
    _tally_is_empty "$virt_post" && empty_names+="virt_post,"
    empty_names="${empty_names%,}"

    if [[ -n "$empty_names" ]]; then
        ok="CAPTURE_EMPTY"
    elif _fidelity_matches "$phys_pre" "$virt_pre" \
        && _fidelity_matches "$phys_post" "$virt_post"
    then
        ok="OK"
    else
        ok="DEGRADED"
    fi

    local b_logfile disc_n recon_n nodewatch_log reappear_ts
    b_logfile=$(_evsieve_logfile "MCSS-probe-slotB")
    disc_n=$(_count_matches disconnected "$b_logfile")
    recon_n=$(_count_matches reconnected "$b_logfile")
    nodewatch_log=$(_nodewatch_logfile)
    reappear_ts=$(_last_reappear_ts "$nodewatch_log")

    local evidence
    evidence="pre phys[${phys_pre}] virt[${virt_pre}];"
    evidence+=" post phys[${phys_post}] virt[${virt_post}];"
    evidence+=" empty_tallies=${empty_names:-none};"
    evidence+=" phys_path=${path_verdict}; tool=${tool};"
    evidence+=" evsieve_log=${b_logfile} disconnected_count=${disc_n}"
    evidence+=" reconnected_count=${recon_n};"
    evidence+=" nodewatch_reappear_t=${reappear_ts} (correlate against"
    evidence+=" this log's disconnected/reconnected timestamps)"
    emit_verdict B_STREAM_FIDELITY "$ok" "$evidence"

    _stop_last_evsieve
}

# --- Main flow ---

if [[ ! -x "$EVSIEVE_BIN" ]]; then
    emit_verdict P0_UINPUT_OPEN FAIL \
        "evsieve binary not found or not executable at ${EVSIEVE_BIN}"
    exit 1
fi

_write_results_header
_confirm_cli_flags
_print_banner

_run_p0_gate
_run_probe_a
_run_probe_b

_stop_watchers

echo
echo "=============================================================="
echo " Results file: ${RESULTS}"
echo " evsieve logs (stdout+stderr, timestamped):"
echo "   P0:    $(_evsieve_logfile MCSS-probe-p0)"
echo "   A:     $(_evsieve_logfile MCSS-probe-slotA)"
echo "   B:     $(_evsieve_logfile MCSS-probe-slotB)"
echo " Physical-node watcher log: $(_nodewatch_logfile)"
if (( _UDEV_WATCHER_STARTED )); then
    echo " udevadm monitor log:       $(_udev_logfile)"
else
    echo " udevadm monitor log:       (udevadm not found, not started)"
fi
echo " Paste the VERDICT lines above into issue #38."
echo "=============================================================="
