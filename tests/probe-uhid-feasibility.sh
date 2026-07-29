#!/bin/bash
set -uo pipefail

# =============================================================================
# probe-uhid-feasibility.sh — can we build the virtual pad rig on /dev/uhid?
# =============================================================================
# PR-0 of build plan #157 (issue #136). Answers, in ONE bounded on-Deck run,
# every question docs/RESEARCH-136-VIRTUAL-PAD-RIG.md left open. Nothing in the
# rig gets built until this comes back green, because two of these answers can
# change the plan.
#
# The research doc's claims about uhid are code- and kernel-source-level
# inference. This probe is where they meet hardware (PRINCIPLES #3 — validate on
# hardware AND through the real path). It deliberately calls the REAL
# controller_monitor.sh enumerator rather than re-implementing /proc parsing, so
# a pass here means the PRODUCTION code sees our virtual pads, not that some
# parallel copy does.
#
# VERDICTS (each printed once, and collected at the end):
#   V1 UHID_ACCESS    — /dev/uhid present + openable (as user? sudo? not at all)
#   V2 UNIQ           — does our chosen fake MAC reach `U: Uniq=`?  (the whole
#                       reason uhid beat uinput; if NO, the rig cannot do #38)
#   V3 SYSFS_PARENT   — does step-6's parent-key strip yield a UNIQUE key?
#   V4 JS_NODE        — does joydev give it a jsN?
#   V5 GAMEPAD_CAPS   — does _has_gamepad_buttons accept its B: KEY= bitmap?
#   V6 ENUMERATED     — does _list_raw_external_pads emit it as an external pad?
#   V7 DEDUP          — do TWO pads BOTH enumerate, or collapse to one?
#                       COLLAPSED => the plan gains a PR-0b (dedup fix) first.
#   V8 RECONNECT      — destroy + recreate with the same uniq: new eventN, same
#                       identity? (the #38 RESUME precondition)
#   V9 STEAM_VIRTUAL  — does Steam mint a 28de virtual for it, as for a real pad?
#   V10 PURE_SUITE    — tests/test_uhid_pad.sh pass count ON THE DECK, to confirm
#                       CI and the Deck agree about the pure computation.
#
# HARD RULES (PRINCIPLES #6/#7/#8): every wait is bounded and shows busy-vs-
# waiting; only PIDs THIS script started are ever killed, from its own tracked
# list — no pkill/killall; backgrounded pad processes log to files, never to a
# capture pipe. Ctrl+C runs cleanup and EXITS (an earlier probe trapped INT
# without exiting and printed contaminated verdicts — see PR #146).
#
# USAGE (on the Deck, Desktop Mode or a Game Mode terminal):
#   bash tests/probe-uhid-feasibility.sh
#
# Run it with NO splitscreen session live: creating pads while the orchestrator
# is running would spawn real players. The probe checks and refuses.
#
# Environment overrides:
#   MCSS_MODULES        — module dir to source (default: this checkout's modules/)
#   MCSS_PROBE_RESULTS  — results file (default $HOME/uhid-probe-<stamp>.txt)
#   MCSS_PROBE_WAIT_S   — per-wait bound in seconds (default 10)
#
# Version history:
#   v1.0 2026-07-29  #136 PR-0: initial probe.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODULES="${MCSS_MODULES:-$REPO_ROOT/modules}"
PAD_PY="$REPO_ROOT/tests/lib/uhid_pad.py"
WAIT_S="${MCSS_PROBE_WAIT_S:-10}"
WORKDIR="$REPO_ROOT/.workdir/uhid-probe"
# Results live under .workdir/ too: Deck-side artifacts must stay inside the repo
# so a single wipe clears them (#122). An earlier default dropped them in $HOME.
RESULTS="${MCSS_PROBE_RESULTS:-$WORKDIR/results-$(date +%Y%m%d-%H%M%S).txt}"

PROC_DEVICES="/proc/bus/input/devices"
UNIQ_1="aa:bb:cc:00:00:01"
UNIQ_2="aa:bb:cc:00:00:02"

# Tracked pad processes: index -> pid, and index -> fifo. ONLY these get killed.
declare -A PAD_PIDS=()
declare -A PAD_FIFOS=()
declare -a VERDICTS=()

SUDO=""          # set to "sudo -n" if /dev/uhid needs it

# --- output helpers ----------------------------------------------------------

_log()  { echo "[probe] $*" | tee -a "$RESULTS"; }
_note() { echo "        $*" | tee -a "$RESULTS"; }

# _verdict: record and print one V-line. Collected for the closing summary so a
# long scrollback never hides a result.
_verdict() {
    local name="$1" value="$2" detail="${3:-}"
    VERDICTS+=("$name=$value${detail:+  ($detail)}")
    echo "[VERDICT] $name = $value${detail:+  ($detail)}" | tee -a "$RESULTS"
}

# _spin: busy indicator to STDERR (never stdout — callers capture stdout), only
# when attached to a TTY. PRINCIPLES #6: "I'm working" must look different from
# "I'm waiting for you".
_spin() {
    local pid="$1" msg="$2" i=0
    local -a frames=('|' '/' '-' '\')
    [[ -t 2 ]] || { wait "$pid" 2>/dev/null; return $?; }
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s %s ' "${frames[i++ % 4]}" "$msg" >&2
        sleep 0.2
    done
    printf '\r  ✓ %s\n' "$msg" >&2
    wait "$pid" 2>/dev/null
}

# _ask: a prompt with a visible caret, so waiting-for-input never reads as a hang.
_ask() {
    local prompt="$1" reply=""
    printf '\n%s\n> ' "$prompt" >&2
    read -r reply || true
    echo "$reply"
}

# _wait_for: poll `cmd` until it succeeds or WAIT_S elapses. Bounded, always.
# Returns 0 on success, 1 on timeout.
_wait_for() {
    local desc="$1"; shift
    local deadline=$(( SECONDS + WAIT_S )) i=0
    local -a frames=('|' '/' '-' '\')
    while (( SECONDS < deadline )); do
        if "$@"; then
            [[ -t 2 ]] && printf '\r  ✓ %s\n' "$desc" >&2
            return 0
        fi
        [[ -t 2 ]] && printf '\r  %s %s (%ds left) ' \
            "${frames[i++ % 4]}" "$desc" "$(( deadline - SECONDS ))" >&2
        sleep 0.3
    done
    [[ -t 2 ]] && printf '\r  ✗ %s — timed out after %ds\n' "$desc" "$WAIT_S" >&2
    return 1
}

# --- /proc helpers -----------------------------------------------------------
# Field reads use the module's own parser where one exists; these two only slice
# a block the parser already produced.

# _block_for_uniq: the whole /proc block whose U: line matches $1 (empty if none).
_block_for_uniq() {
    awk -v want="$1" 'BEGIN{RS="";FS="\n"} $0 ~ ("U: Uniq=" want "$") ||
        $0 ~ ("U: Uniq=" want "\n") {print; exit}' "$PROC_DEVICES" 2>/dev/null
}

_field_from_block() { grep -m1 "^$1" <<< "$2" | sed "s/^$1//"; }

_uniq_present() { [[ -n "$(_block_for_uniq "$1")" ]]; }
_uniq_absent()  { [[ -z "$(_block_for_uniq "$1")" ]]; }

# _event_of_uniq: eventN token from the H: handlers line, or empty.
_event_of_uniq() {
    local blk; blk="$(_block_for_uniq "$1")"
    [[ -z "$blk" ]] && return 1
    grep -m1 '^H: Handlers=' <<< "$blk" | grep -oE 'event[0-9]+' | head -1
}

_js_of_uniq() {
    local blk; blk="$(_block_for_uniq "$1")"
    [[ -z "$blk" ]] && return 1
    grep -m1 '^H: Handlers=' <<< "$blk" | grep -oE 'js[0-9]+' | head -1
}

# _parent_key_of: apply the EXACT strip _list_raw_external_pads step 6 uses.
# Kept identical on purpose — if the module's key changes, this probe's answer
# to V3 must change with it.
_parent_key_of() {
    sed -E 's#/input/input[0-9]+$##; s#/input[0-9]+$##' <<< "$1"
}

_count_steam_virtuals() {
    grep -c 'Vendor=28de' "$PROC_DEVICES" 2>/dev/null || echo 0
}

# --- pad lifecycle (the only device-touching part) ---------------------------

# _pad_start: launch a pad process, tracked. stdin is a FIFO we hold open so the
# device lives until we say otherwise; stdout/stderr go to a LOG FILE, never to
# a capture pipe (PRINCIPLES #8).
_pad_start() {
    local idx="$1" uniq="$2" product="$3"
    local fifo="$WORKDIR/pad${idx}.fifo" log="$WORKDIR/pad${idx}.log"
    rm -f "$fifo"; mkfifo "$fifo"
    : > "$log"
    # shellcheck disable=SC2086  # SUDO is deliberately word-split (may be empty)
    $SUDO python3 "$PAD_PY" create --uniq "$uniq" \
        --name "MCSS Test Pad $idx" --vendor 0x054c --product "$product" \
        < "$fifo" > "$log" 2>&1 &
    local pid=$!
    exec {fd}> "$fifo"          # hold the write end open: stdin stays open
    PAD_PIDS[$idx]=$pid
    PAD_FIFOS[$idx]=$fd
    _note "pad $idx started (pid $pid, uniq $uniq), log: $log"
}

# _pad_stop: end ONE pad we started. Ask it to exit via its own stdin first;
# fall back to killing exactly that PID. Never a name match (PRINCIPLES #7).
_pad_stop() {
    local idx="$1"
    local pid="${PAD_PIDS[$idx]:-}" fd="${PAD_FIFOS[$idx]:-}"
    [[ -z "$pid" ]] && return 0
    if [[ -n "$fd" ]]; then
        # Braced so the fd-dup and the stderr redirect don't compete (SC2261).
        { echo "destroy" >&"$fd"; } 2>/dev/null || true
        { exec {fd}>&-; } 2>/dev/null || true
    fi
    if kill -0 "$pid" 2>/dev/null; then
        ( sleep 2; kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null ) \
            >/dev/null 2>&1 &
        wait "$pid" 2>/dev/null || true
    fi
    unset "PAD_PIDS[$idx]" "PAD_FIFOS[$idx]"
}

cleanup() {
    local idx
    for idx in "${!PAD_PIDS[@]}"; do _pad_stop "$idx"; done
    rm -f "$WORKDIR"/*.fifo 2>/dev/null || true
}
# Ctrl+C must CLEAN UP *AND EXIT* — not fall through into the measurements.
trap 'cleanup; echo; echo "[probe] interrupted — cleaned up." >&2; exit 130' INT TERM
trap cleanup EXIT

# --- phases ------------------------------------------------------------------

phase0_environment() {
    _log "=== Phase 0 — environment (read-only, creates nothing) ==="

    command -v python3 >/dev/null 2>&1 \
        || { _verdict V1_UHID_ACCESS "NO_PYTHON"; return 1; }
    _note "python3: $(python3 --version 2>&1)"

    # V10 runs FIRST and unconditionally: it is pure computation, so it is
    # meaningful even on a box with no /dev/uhid at all — and comparing it
    # against CI is the whole reason it exists.
    local out passed=""
    if out=$(bash "$REPO_ROOT/tests/test_uhid_pad.sh" 2>&1); then
        passed=$(grep -oE '[0-9]+/[0-9]+ tests passed' <<< "$out" | head -1)
        _verdict V10_PURE_SUITE "PASS" "${passed:-?} here"
    else
        passed=$(grep -oE '[0-9]+/[0-9]+ tests passed' <<< "$out" | head -1)
        _verdict V10_PURE_SUITE "FAIL" "${passed:-?} here — CI and this host DISAGREE"
        _note "$(grep '^\[FAIL\]' <<< "$out" | head -5)"
    fi

    if [[ ! -e /dev/uhid ]]; then
        _verdict V1_UHID_ACCESS "ABSENT" "/dev/uhid not present; is the uhid module loaded?"
        return 1
    fi
    _note "/dev/uhid: $(ls -l /dev/uhid)"

    # Openability decides whether the rig needs sudo or a udev rule — the one
    # open question the research doc flagged as likely friction.
    if python3 -c 'open("/dev/uhid","rb+").close()' 2>/dev/null; then
        SUDO=""
        _verdict V1_UHID_ACCESS "USER" "openable as $USER, no sudo needed"
    elif sudo -n true 2>/dev/null && \
         sudo -n python3 -c 'open("/dev/uhid","rb+").close()' 2>/dev/null; then
        SUDO="sudo -n"
        _verdict V1_UHID_ACCESS "SUDO" "needs passwordless sudo — rig must elevate"
    else
        _verdict V1_UHID_ACCESS "DENIED" "not openable as user and sudo -n failed"
        # Actionable, not just a verdict: /dev/uinput already carries uaccess on
        # this hardware and uhid does not, so the fix is one udev rule granting
        # the seat's logged-in user the same ACL. No setuid helper, and no sudo
        # in the rig's own path (an unattended rig cannot answer a password
        # prompt). SteamOS's rootfs is immutable, hence the readonly dance.
        _note ""
        _note "To grant access (one-time, as root — then re-run this probe):"
        _note "  sudo steamos-readonly disable"
        _note "  printf 'KERNEL==\"uhid\", TAG+=\"uaccess\"\\n' \\"
        _note "    | sudo tee /etc/udev/rules.d/99-mcss-uhid.rules"
        _note "  sudo udevadm control --reload-rules && sudo udevadm trigger /dev/uhid"
        _note "  sudo steamos-readonly enable"
        _note ""
        _note "Treat it as re-installable: a SteamOS update may clear it."
        return 1
    fi
    return 0
}

phase1_single_pad() {
    _log "=== Phase 1 — one virtual pad ==="
    STEAM_BEFORE=$(_count_steam_virtuals)
    _note "28de devices before: $STEAM_BEFORE"

    _pad_start 1 "$UNIQ_1" 0x0001
    if ! _wait_for "pad 1 to appear in $PROC_DEVICES" _uniq_present "$UNIQ_1"; then
        _verdict V2_UNIQ "ABSENT" "no block with U: Uniq=$UNIQ_1 within ${WAIT_S}s"
        _note "pad log: $(cat "$WORKDIR/pad1.log" 2>/dev/null)"
        return 1
    fi

    local blk sysfs parent ev js keybits
    blk="$(_block_for_uniq "$UNIQ_1")"
    _note "--- /proc block ---"; echo "$blk" | tee -a "$RESULTS" >/dev/null
    echo "$blk" | sed 's/^/        /'

    # V2 — the field the whole approach rests on.
    _verdict V2_UNIQ "PRESENT" "U: Uniq=$UNIQ_1 reached the input device"

    # V3 — the dedup parent key.
    sysfs="$(_field_from_block 'S: Sysfs=' "$blk")"
    parent="$(_parent_key_of "$sysfs")"
    if [[ "$parent" == "/devices/virtual" || -z "$parent" ]]; then
        _verdict V3_SYSFS_PARENT "SHARED" "sysfs=$sysfs -> key '$parent' (collapse risk)"
    else
        _verdict V3_SYSFS_PARENT "UNIQUE" "sysfs=$sysfs -> key '$parent'"
    fi

    # V4 — joydev.
    js="$(_js_of_uniq "$UNIQ_1" || true)"
    ev="$(_event_of_uniq "$UNIQ_1" || true)"
    if [[ -n "$js" ]]; then
        _verdict V4_JS_NODE "PRESENT" "$js (event: ${ev:-none})"
    else
        _verdict V4_JS_NODE "ABSENT" "no jsN — step 1's JS-GATE will drop it"
    fi

    # V5 — the real capability gate, called directly.
    keybits="$(grep -m1 '^B: KEY=' <<< "$blk" | sed 's/^B: KEY=//')"
    if _has_gamepad_buttons "$keybits" 2>/dev/null; then
        _verdict V5_GAMEPAD_CAPS "ACCEPTED" "BTN_SOUTH/BTN_JOYSTICK gate passes"
    else
        _verdict V5_GAMEPAD_CAPS "REJECTED" "KEY bitmap lacks BTN_SOUTH and BTN_JOYSTICK"
    fi

    # V6 — the production enumerator's own verdict.
    local enumerated
    enumerated="$(_list_raw_external_pads 2>/dev/null | grep -c "${UNIQ_1}$")"
    if (( enumerated >= 1 )); then
        _verdict V6_ENUMERATED "YES" "_list_raw_external_pads emits it"
    else
        _verdict V6_ENUMERATED "NO" "production enumerator does not see it"
        _note "enumerator output: $(_list_raw_external_pads 2>&1 | head -5)"
    fi
    return 0
}

phase2_two_pads() {
    _log "=== Phase 2 — a second pad (the dedup question) ==="
    _pad_start 2 "$UNIQ_2" 0x0002
    if ! _wait_for "pad 2 to appear" _uniq_present "$UNIQ_2"; then
        _verdict V7_DEDUP "INCONCLUSIVE" "pad 2 never appeared in $PROC_DEVICES"
        return 1
    fi

    local out n1 n2 total
    out="$(_list_raw_external_pads 2>/dev/null)"
    n1="$(grep -c "${UNIQ_1}$" <<< "$out")"
    n2="$(grep -c "${UNIQ_2}$" <<< "$out")"
    total="$(grep -c . <<< "$out")"
    _note "enumerator emitted $total line(s); pad1=$n1 pad2=$n2"
    _note "$(sed 's/^/          /' <<< "$out")"

    if (( n1 >= 1 && n2 >= 1 )); then
        _verdict V7_DEDUP "BOTH" "each uhid pad keeps its own parent key — plan unchanged"
    else
        _verdict V7_DEDUP "COLLAPSED" \
            "only one survived step 6 — the plan needs PR-0b (dedup fix) first"
    fi
    return 0
}

phase3_reconnect() {
    _log "=== Phase 3 — destroy + recreate pad 1 with the SAME uniq ==="
    local before after
    before="$(_event_of_uniq "$UNIQ_1" || true)"
    _note "pad 1 event node before: ${before:-unknown}"

    _pad_stop 1
    if ! _wait_for "pad 1 to disappear" _uniq_absent "$UNIQ_1"; then
        _verdict V8_RECONNECT "INCONCLUSIVE" "pad 1 still present after destroy"
        return 1
    fi

    _pad_start 1 "$UNIQ_1" 0x0001
    if ! _wait_for "pad 1 to come back" _uniq_present "$UNIQ_1"; then
        _verdict V8_RECONNECT "GONE" "did not re-appear within ${WAIT_S}s"
        return 1
    fi
    after="$(_event_of_uniq "$UNIQ_1" || true)"
    _note "pad 1 event node after: ${after:-unknown}"

    if [[ -n "$after" && "$before" != "$after" ]]; then
        _verdict V8_RECONNECT "RENUMBERED" \
            "$before -> $after, same uniq — a real battery-death cycle, scriptable"
    elif [[ -n "$after" ]]; then
        _verdict V8_RECONNECT "SAME_NODE" \
            "came back on $after; identity held but no renumber to test against"
    else
        _verdict V8_RECONNECT "INCONCLUSIVE" "no event node after recreate"
    fi
    return 0
}

phase4_steam() {
    _log "=== Phase 4 — does Steam react to a virtual pad? ==="
    local after; after="$(_count_steam_virtuals)"
    _note "28de devices after: $after (before: ${STEAM_BEFORE:-?})"
    if (( after > ${STEAM_BEFORE:-0} )); then
        _verdict V9_STEAM_VIRTUAL "MINTED" \
            "Steam created $(( after - STEAM_BEFORE )) virtual(s) — same as a real pad"
    else
        _verdict V9_STEAM_VIRTUAL "NONE" "no new 28de device (Game Mode not running?)"
    fi
    return 0
}

# --- main --------------------------------------------------------------------

main() {
    mkdir -p "$WORKDIR"
    : > "$RESULTS"
    _log "uhid feasibility probe — $(date)"
    _log "results: $RESULTS"
    _log "modules: $MODULES"

    if [[ ! -r "$PROC_DEVICES" ]]; then
        _log "FATAL: $PROC_DEVICES unreadable"; exit 1
    fi

    # Source the REAL enumerator — this probe must agree with production, not
    # with a copy of it (PRINCIPLES #9).
    # shellcheck source=/dev/null
    if ! source "$MODULES/controller_monitor.sh" 2>/dev/null; then
        _log "FATAL: could not source $MODULES/controller_monitor.sh"; exit 1
    fi

    # Refuse to create pads under a live session: they would spawn real players.
    if pgrep -f 'latestUpdate-' >/dev/null 2>&1; then
        _log "REFUSING: a splitscreen session looks live (latestUpdate-* running)."
        _log "Creating virtual pads now would spawn real players. Quit the session first."
        exit 1
    fi

    phase0_environment || { _log "Phase 0 failed — not creating any devices."; _summary; exit 1; }

    local reply
    reply="$(_ask "Phase 0 done. Phases 1-4 CREATE virtual gamepads on this system.
Steam may react to them exactly as it would to a real pad.
Type 'go' to continue, anything else to stop here.")"
    if [[ "$reply" != "go" ]]; then
        _log "Stopped after Phase 0 at operator request."; _summary; exit 0
    fi

    phase1_single_pad || true
    phase2_two_pads   || true
    phase3_reconnect  || true
    phase4_steam      || true
    _summary
}

_summary() {
    echo "" | tee -a "$RESULTS"
    _log "=== SUMMARY ==="
    local v
    for v in "${VERDICTS[@]}"; do echo "  $v" | tee -a "$RESULTS"; done
    echo "" | tee -a "$RESULTS"
    _log "Full results: $RESULTS"
    _log "Paste the SUMMARY block into #157."
}

main "$@"
