#!/bin/bash

# =============================================================================
# UHID RIG LIBRARY
# =============================================================================
# Owns the LIFECYCLE of one or more virtual gamepads created by
# tests/lib/uhid_pad.py create (#136 / build plan #157, PR-2). Generalizes the
# one-off inline pad plumbing that used to live only in
# tests/probe-uhid-feasibility.sh (_pad_start/_pad_stop/cleanup) into reusable
# functions for PR-3 (stage3_hotplug automation), PR-4 (#71 burst-spawn
# repro), and PR-5 (#151 destroy/recreate identity-swap repro).
#
# NOT an executable entry point — sourced, like tests/lib/workdir.sh. No
# `main`, no "$@" dispatch. NOT a re-implementation of controller enumeration
# (that is controller_monitor.sh, ARCHITECTURE.md §2) or of the uhid wire
# format (that is uhid_pad.py, already merged and CI-covered). NOT a
# production module — nothing under modules/ may ever source this.
#
# NAMING DEVIATION (deliberate): tests/lib/workdir.sh uses an `mcss_` public
# prefix; this file uses `rig_` per the accepted plan in #157, which names the
# surface rig_create_pad / rig_destroy_pad / rig_inject / rig_cleanup. Private
# helpers are `_rig_*`; mutable globals are `_MCSS_RIG_*` (the `_MCSS_` prefix
# because this library can be sourced into shells that also source
# modules/*.sh, and ARCHITECTURE.md §2 requires repo-wide unique names).
#
# NO SUDO, EVER. The Deck grants the seat user `uaccess` on /dev/uhid via
# /etc/udev/rules.d/60-mcss-uhid.rules (see probe-uhid-feasibility.sh
# phase0_environment for the remedy if that rule is missing — deliberately
# NOT duplicated here, PRINCIPLES #9). If /dev/uhid is not openable as the
# current user, rig_init fails loudly (rc 3) rather than trying to elevate.
#
# NO LIVE-SESSION REFUSAL. Unlike the probe, this library does not check for
# a live splitscreen session — PR-3's entire purpose is driving one.
#
# Public API (COMMANDS — never call inside `$( )`; print nothing to stdout):
#   rig_init([rig_id])              — prepare the rig; idempotent.
#     return: 0 ready, 1 pad command missing/unrunnable,
#             2 /dev/uhid absent, 3 /dev/uhid not openable as this user.
#   rig_create_pad(N, [uniq], [name], [product])
#     return: 0 created+ready, 1 died/timed out, 2 bad args.
#   rig_destroy_pad(N)              — idempotent; escalation ladder (§5.2).
#     return: 0 gone (any rung, or was untracked), 1 still alive, 2 bad index.
#   rig_inject(N, "<cmd>")          — synchronous; waits for the ack.
#     return: 0 acked, 1 no ack / pad not live, 2 bad args.
#   rig_inject_nowait(N, "<cmd>")   — fire-and-forget (for `hold`).
#     return: 0 written, 1 pad not live / write failed, 2 bad args.
#   rig_cleanup()                   — destroy every pad THIS instance started.
#     return: 0 always.
#   rig_install_traps()             — opt-in; refuses to clobber existing traps.
#     return: 0 installed, 1 refused (a signal already has a non-empty trap).
#
# Public API (QUERIES — safe inside `$( )`; pure/side-effect-free):
#   rig_default_uniq(N)   — stdout: "aa:bb:cc:00:00:0N". return: 0 / 2 bad N.
#   rig_workdir()         — stdout: absolute rig dir. return: 0 / 1 not inited.
#   rig_pad_field(N, KEY) — stdout: the value, or empty.
#     return: 0 found, 1 not found, 2 bad args. KEYS: pid uniq name product
#     started starttime fifo log. THE ONE reader of pad<N>.pid (PRINCIPLES #1).
#   rig_list_pads()       — stdout: tracked indices, ascending, one per line.
#   rig_pad_is_live(N)    — predicate, no stdout. return: 0 live, 1 not, 2 bad.
#   rig_wait_for_pad(N, [timeout_s]) / rig_wait_for_pad_gone(N, [timeout_s])
#     — poll the PRODUCTION enumerator (controller_monitor.sh's
#     _list_raw_external_pads, reached via a soft guard — this library never
#     sources a runtime module, ARCHITECTURE.md §4). return: 0 condition met,
#     1 timeout, 2 enumerator not sourced ("can't tell" — the one deliberate
#     rc 2; see the fail-loud note below).
#
# Globals PROVIDED:
#   UHID_RIG_VENDOR_ID       — readonly, 0x054c (matches the probe)
#   _MCSS_RIG_DIR            — this rig instance's workdir (after rig_init)
#   _MCSS_RIG_PIDS/_FDS/_UNIQS — module-level assoc arrays, index -> value;
#     the in-memory authority during a run (§4.2). The pidfile is the durable
#     mirror, read ONLY through rig_pad_field.
#
# Globals CONSUMED: MCSS_WORKDIR (via workdir.sh), MCSS_RIG_* (below).
#
# Inputs:  /dev/uhid, indirectly, via uhid_pad.py (or a CI double, see the
#          MCSS_RIG_PAD_CMD override below).
# Outputs: .workdir/uhid-rig/<rig_id>/{pad<N>.fifo,pad<N>.pid,pad<N>.log},
#          the pad processes it spawns, `[uhid_rig] ` stderr diagnostics.
#          stdout is never used for diagnostics (STYLE-GUIDE golden rule) —
#          command functions print nothing at all; query functions print
#          data only.
#
# Environment overrides (test-only unless noted):
#   MCSS_RIG_ID               — rig instance id (default: $$)
#   MCSS_RIG_READY_TIMEOUT_S  — default 5  (wait for the `created` line)
#   MCSS_RIG_ACK_TIMEOUT_S    — default 5  (wait for an `ok` ack)
#   MCSS_RIG_EXIT_TIMEOUT_S   — default 5  (wait for exit after `destroy`)
#   MCSS_RIG_KILL_GRACE_S     — default 2  (grace after SIGTERM / SIGKILL)
#   MCSS_RIG_ENUM_TIMEOUT_S   — default 10 (wait for the enumerator)
#   MCSS_RIG_MAX_PADS         — default 8  (index upper bound; deliberately
#                                NOT MCSS_MAX_PLAYERS — a test rig constant
#                                must not couple to a product constant)
#   MCSS_RIG_PAD_CMD          — THE CI SEAM. Default: "python3 <this dir>/
#                                uhid_pad.py". tests/test_uhid_rig.sh points
#                                this at tests/lib/fake_pad.sh, a protocol
#                                double that touches no device, so this
#                                library's lifecycle logic gets real CI
#                                coverage even though /dev/uhid does not exist
#                                on a runner. When overridden, rig_init skips
#                                its /dev/uhid preflight (a stub pad needs no
#                                device) — gated on the override being SET,
#                                not on parsing the command string.
#
# FAIL LOUD, NOT FAIL OPEN — not a PRINCIPLES #5 violation. #5 governs
# runtime detectors, where a false positive tears down a live player's
# session, so "don't know" must degrade to keep-last-good. This is a TEST
# RIG: quietly continuing past a failed pad creation produces confidently
# wrong verdicts in whatever suite is driving it — the #146 failure mode
# (Ctrl+C tore down the subject, then execution fell through into the
# measurements and reported the corpse as a real result). Every timeout here
# returns non-zero and says why. The one deliberate "don't know" is
# rig_wait_for_pad's rc 2 when controller_monitor.sh is not sourced — the rig
# genuinely cannot answer, so it says so instead of asserting.
#
# TRAP OWNERSHIP: sourcing this file installs NOTHING. rig_install_traps is
# explicit opt-in and refuses to clobber an existing trap. A caller that
# already owns EXIT/INT/TERM must chain manually — see the two patterns at
# the top of tests/test_uhid_rig.sh.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-08-01  #136 PR-2: initial rig control surface.
# =============================================================================

# Re-sourceable: safe to source twice (module-level assoc arrays and the
# readonly vendor-id constant live INSIDE this guard so a re-source neither
# wipes live rig state nor re-triggers a `readonly` reassignment error — the
# same pattern tests/lib/workdir.sh uses).
if [[ -z "${_MCSS_UHID_RIG_LOADED:-}" ]]; then
    _MCSS_UHID_RIG_LOADED=1   # process-local — NOT exported

    _MCSS_RIG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=tests/lib/workdir.sh
    source "$_MCSS_RIG_SELF_DIR/workdir.sh"

    : "${MCSS_RIG_ID:=$$}"
    : "${MCSS_RIG_READY_TIMEOUT_S:=5}"
    : "${MCSS_RIG_ACK_TIMEOUT_S:=5}"
    : "${MCSS_RIG_EXIT_TIMEOUT_S:=5}"
    : "${MCSS_RIG_KILL_GRACE_S:=2}"
    : "${MCSS_RIG_ENUM_TIMEOUT_S:=10}"
    : "${MCSS_RIG_MAX_PADS:=8}"

    # The CI seam (§7.1 of the PR-2 work order). Record whether the CALLER
    # overrode MCSS_RIG_PAD_CMD BEFORE defaulting it, so rig_init can gate its
    # /dev/uhid preflight on "was this overridden", not on parsing the
    # resulting command string.
    _MCSS_RIG_PAD_CMD_OVERRIDDEN="${MCSS_RIG_PAD_CMD:+1}"
    _MCSS_RIG_PAD_CMD_OVERRIDDEN="${_MCSS_RIG_PAD_CMD_OVERRIDDEN:-0}"
    : "${MCSS_RIG_PAD_CMD:=python3 $_MCSS_RIG_SELF_DIR/uhid_pad.py}"
    # shellcheck disable=SC2206  # deliberate word-split of a test-only
    # command string into argv; MCSS_RIG_PAD_CMD is never user-tainted here.
    read -r -a _MCSS_RIG_PAD_CMD <<< "$MCSS_RIG_PAD_CMD"

    readonly UHID_RIG_VENDOR_ID="0x054c"

    # In-memory maps: THE authority during a run (§4.2 of the work order).
    # index -> pid / write-fd / uniq. The pidfile is the durable mirror.
    declare -A _MCSS_RIG_PIDS=()
    declare -A _MCSS_RIG_FDS=()
    declare -A _MCSS_RIG_UNIQS=()
    _MCSS_RIG_DIR=""
    _MCSS_RIG_RUNNING_ID=""
fi

# --- Internal helpers ---------------------------------------------------

# _rig_valid_index: Is $1 an in-range pad index? DRY home for the bound check
# every public function repeats (PRINCIPLES #9).
# Inputs:  $1 — candidate index
# Outputs: return — 0 valid (1..MCSS_RIG_MAX_PADS), 1 invalid
_rig_valid_index() {
    local n="${1:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 && n <= MCSS_RIG_MAX_PADS )) || return 1
    return 0
}

# _rig_pad_cmd_runnable: Is _MCSS_RIG_PAD_CMD's argv[0] on PATH, and does any
# trailing .py/.sh argument (the script path) actually exist?
# Outputs: return — 0 runnable, 1 not
_rig_pad_cmd_runnable() {
    local -a cmd=("${_MCSS_RIG_PAD_CMD[@]}")
    (( ${#cmd[@]} > 0 )) || return 1
    command -v "${cmd[0]}" >/dev/null 2>&1 || return 1
    local i
    for (( i = 1; i < ${#cmd[@]}; i++ )); do
        case "${cmd[$i]}" in
            *.py|*.sh) [[ -e "${cmd[$i]}" ]] || return 1 ;;
        esac
    done
    return 0
}

# _rig_pidfile_write: THE ONLY WRITER of pad<N>.pid (PRINCIPLES #1). Atomic
# via tmp+mv (STYLE-GUIDE §7.9) so a crash mid-write never leaves a
# half-written file for rig_pad_field to misread.
# Inputs:
#   $1..$8 — n pid uniq name product started starttime fifo, $9 — log
# Outputs: side effects — writes _MCSS_RIG_DIR/pad<N>.pid. return: 0/1.
_rig_pidfile_write() {
    local n="$1" pid="$2" uniq="$3" name="$4" product="$5" started="$6"
    local starttime="$7" fifo="$8" log="$9"
    local pidfile="$_MCSS_RIG_DIR/pad${n}.pid" tmp
    tmp="$(mktemp "${pidfile}.tmp.XXXXXX")" || return 1
    {
        printf 'pid=%s\n' "$pid"
        printf 'uniq=%s\n' "$uniq"
        printf 'name=%s\n' "$name"
        printf 'product=%s\n' "$product"
        printf 'started=%s\n' "$started"
        printf 'starttime=%s\n' "$starttime"
        printf 'fifo=%s\n' "$fifo"
        printf 'log=%s\n' "$log"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$pidfile"
}

# _rig_proc_starttime: Field 22 (starttime) of /proc/<pid>/stat. Parsed from
# the LAST ')' forward, because field 2 (comm) can itself contain spaces and
# parens — a naive whitespace split would misalign every field after it.
# Inputs:  $1 — pid
# Outputs: stdout — the starttime value. return: 0 found, 1 no such pid/stat.
_rig_proc_starttime() {
    local pid="$1" stat rest
    [[ -r "/proc/$pid/stat" ]] || return 1
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    rest="${stat##*) }"
    local -a f
    read -r -a f <<< "$rest"
    (( ${#f[@]} >= 20 )) || return 1
    printf '%s\n' "${f[19]}"
}

# _rig_pid_is_ours: Verify the pid recorded for pad N is still the SAME
# process, via /proc/<pid>/stat's starttime — the kernel's own stamp, which
# is what makes PID recycling survivable. This is NOT name matching
# (PRINCIPLES #7 bans that); it is confirming a PID WE RECORDED is still the
# process we recorded, immediately before every signal. Reads pid/starttime
# through rig_pad_field ONLY (PRINCIPLES #1 — the pidfile has one reader);
# falls back to the in-memory pid if the pidfile has none yet.
# Inputs:  $1 — pad index
# Outputs: return — 0 same process, 1 gone/mismatched/unknown
_rig_pid_is_ours() {
    local n="$1" pid starttime actual
    pid="$(rig_pad_field "$n" pid)"
    starttime="$(rig_pad_field "$n" starttime)"
    [[ -z "$pid" ]] && pid="${_MCSS_RIG_PIDS[$n]:-}"
    [[ -n "$pid" && -n "$starttime" ]] || return 1
    actual="$(_rig_proc_starttime "$pid")" || return 1
    [[ "$actual" == "$starttime" ]]
}

# _rig_close_tracked_fds: Close every currently-tracked pad's FIFO write fd.
# MUST run only inside a freshly-forked CHILD, before exec (Rule 2, §4.5 of
# the work order) — never in the live rig shell, or it would sever pads out
# from under a running rig. At spawn time the new pad's own fd is not yet
# tracked, so this closes exactly the OTHER pads' fds, which is the point:
# without it, pad 2 inherits pad 1's write end and pad 1 can never see EOF.
# Outputs: side effects — closes fds in THIS (sub)shell only.
_rig_close_tracked_fds() {
    local idx f
    for idx in "${!_MCSS_RIG_FDS[@]}"; do
        f="${_MCSS_RIG_FDS[$idx]}"
        # shellcheck disable=SC2091,SC2086  # eval is unavoidable to close a
        # dynamically-numbered fd variable; kept to this one line.
        eval "exec ${f}>&-" 2>/dev/null || true
    done
}

# _rig_tail_log: Echo the last 5 lines of a pad log to stderr, prefixed.
# Inputs:  $1 — log path
# Outputs: stderr only.
_rig_tail_log() {
    local file="$1"
    tail -n 5 "$file" 2>/dev/null | sed 's/^/[uhid_rig]   /' >&2
}

# _rig_kill_stray: End a pad process THIS call just forked, when it never
# reported ready. Signaling this pid is not a PRINCIPLES #7 violation — it is
# exactly the pid captured via $! a moment earlier in the same function, not
# a name match. Bounded by MCSS_RIG_KILL_GRACE_S.
# Inputs:  $1 — pid
# Outputs: side effects — TERM then KILL if it survives. Never hangs.
_rig_kill_stray() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$(( SECONDS + MCSS_RIG_KILL_GRACE_S ))
    while (( SECONDS < deadline )) && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    return 0
}

# _rig_wait_for_ready: Bounded poll for "^created uniq=" in a pad's log,
# bailing early if the pid dies first. TTY-gated spinner (PRINCIPLES #6).
# Inputs:  $1 — log path, $2 — pid, $3 — timeout_s
# Outputs: return — 0 ready, 1 timed out or the process died first.
_rig_wait_for_ready() {
    local file="$1" pid="$2" timeout_s="$3"
    local deadline=$(( SECONDS + timeout_s )) i=0
    local -a frames=('|' '/' '-' "\\")
    while (( SECONDS < deadline )); do
        if grep -Eq '^created uniq=' "$file" 2>/dev/null; then
            [[ -t 2 ]] && printf '\r' >&2
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || return 1
        if [[ -t 2 ]]; then
            printf '\r  %s waiting for pad ready (%ds left) ' \
                "${frames[i++ % 4]}" "$(( deadline - SECONDS ))" >&2
        fi
        sleep 0.1
    done
    [[ -t 2 ]] && printf '\r' >&2
    return 1
}

# _rig_wait_for_count: Bounded poll until the count of lines in a file
# matching REGEX exceeds BASELINE. Used for the ack wait — the "created" line
# proved liveness already, so no early pid-death bailout is needed here.
# Inputs:  $1 — file, $2 — regex, $3 — baseline count, $4 — timeout_s
# Outputs: return — 0 count increased, 1 timed out.
_rig_wait_for_count() {
    local file="$1" regex="$2" baseline="$3" timeout_s="$4"
    local deadline=$(( SECONDS + timeout_s )) i=0 count
    local -a frames=('|' '/' '-' "\\")
    while (( SECONDS < deadline )); do
        count=$(grep -Ec "$regex" "$file" 2>/dev/null || true)
        (( count > baseline )) && { [[ -t 2 ]] && printf '\r' >&2; return 0; }
        if [[ -t 2 ]]; then
            printf '\r  %s waiting for ack (%ds left) ' \
                "${frames[i++ % 4]}" "$(( deadline - SECONDS ))" >&2
        fi
        sleep 0.1
    done
    [[ -t 2 ]] && printf '\r' >&2
    return 1
}

# _rig_wait_for_gone: Bounded poll until pad N no longer verifies as a live
# process of ours (_rig_pid_is_ours + kill -0). Re-checked every iteration —
# this is the "re-verify immediately before each signal" rule (§5.2): the
# CALLER signals only after this returns 1 (timed out) and re-confirms
# identity right before doing so.
# Inputs:  $1 — pad index, $2 — timeout_s
# Outputs: return — 0 gone already, 1 still alive after timeout_s.
_rig_wait_for_gone() {
    local n="$1" timeout_s="$2"
    local pid="${_MCSS_RIG_PIDS[$n]:-}"
    [[ -z "$pid" ]] && return 0
    local deadline=$(( SECONDS + timeout_s )) i=0
    local -a frames=('|' '/' '-' "\\")
    while (( SECONDS < deadline )); do
        if ! _rig_pid_is_ours "$n" || ! kill -0 "$pid" 2>/dev/null; then
            [[ -t 2 ]] && printf '\r' >&2
            return 0
        fi
        if [[ -t 2 ]]; then
            printf '\r  %s waiting for pad %s to exit (%ds left) ' \
                "${frames[i++ % 4]}" "$n" "$(( deadline - SECONDS ))" >&2
        fi
        sleep 0.1
    done
    [[ -t 2 ]] && printf '\r' >&2
    return 1
}

# _rig_wait_for_enum: Bounded poll of _list_raw_external_pads for a uniq's
# presence/absence. Caller has already soft-guarded that the function exists.
# Inputs:  $1 — uniq, $2 — "present"|"absent", $3 — timeout_s
# Outputs: return — 0 condition met, 1 timed out.
_rig_wait_for_enum() {
    local uniq="$1" mode="$2" timeout_s="$3"
    local deadline=$(( SECONDS + timeout_s )) i=0 n
    local -a frames=('|' '/' '-' "\\")
    while (( SECONDS < deadline )); do
        n="$(_list_raw_external_pads 2>/dev/null | grep -c "${uniq}\$")"
        if { [[ "$mode" == "present" ]] && (( n >= 1 )); } || \
           { [[ "$mode" == "absent" ]] && (( n == 0 )); }; then
            [[ -t 2 ]] && printf '\r' >&2
            return 0
        fi
        if [[ -t 2 ]]; then
            printf '\r  %s waiting for enumerator (%ds left) ' \
                "${frames[i++ % 4]}" "$(( deadline - SECONDS ))" >&2
        fi
        sleep 0.3
    done
    if [[ -t 2 ]]; then
        printf '\r  timed out waiting for enumerator after %ds\n' \
            "$timeout_s" >&2
    fi
    return 1
}

# --- Public API: commands -------------------------------------------------

# rig_init: Prepare the rig. Idempotent; safe to call repeatedly. COMMAND —
# never call inside `$( )`.
# Inputs:  $1 — optional rig id (default MCSS_RIG_ID, the sourcing shell's
#   PID). Globals read: MCSS_RIG_PAD_CMD / _MCSS_RIG_PAD_CMD_OVERRIDDEN.
# Outputs:
#   stdout — nothing. stderr — "[uhid_rig] " diagnostics only.
#   return — 0 ready, 1 pad command missing/unrunnable or workdir uncreatable,
#     2 /dev/uhid absent, 3 /dev/uhid not openable as this user.
#   side effects — mcss_workdir_init; resets the in-memory maps.
rig_init() {
    local rig_id="${1:-$MCSS_RIG_ID}"

    if ! _rig_pad_cmd_runnable; then
        echo "[uhid_rig] pad command not found or not runnable:" \
            "${_MCSS_RIG_PAD_CMD[*]}" >&2
        return 1
    fi

    # Preflight steps 2/3 (needs a real /dev/uhid) are skipped when the pad
    # command has been overridden away from uhid_pad.py — the CI seam.
    if [[ "$_MCSS_RIG_PAD_CMD_OVERRIDDEN" != "1" ]]; then
        if [[ ! -e /dev/uhid ]]; then
            echo "[uhid_rig] /dev/uhid not present — is the uhid module" \
                "loaded?" >&2
            return 2
        fi
        if ! python3 -c \
            'import os; os.close(os.open("/dev/uhid", os.O_RDWR|os.O_NONBLOCK))' \
            2>/dev/null
        then
            local msg="[uhid_rig] /dev/uhid not openable as $USER — see the"
            msg+=" udev-rule remedy printed by"
            msg+=" tests/probe-uhid-feasibility.sh"
            echo "$msg" >&2
            return 3
        fi
    fi

    mcss_workdir_init "uhid-rig/$rig_id" || {
        echo "[uhid_rig] could not create workdir for rig $rig_id" >&2
        return 1
    }
    _MCSS_RIG_RUNNING_ID="$rig_id"
    _MCSS_RIG_DIR="$(mcss_workdir "uhid-rig/$rig_id")"
    _MCSS_RIG_PIDS=()
    _MCSS_RIG_FDS=()
    _MCSS_RIG_UNIQS=()
    return 0
}

# rig_create_pad: Create and start pad N. COMMAND — never call inside `$( )`:
# (a) the FIFO write fd is opened in THIS shell via `exec {fd}>` and would be
# lost the instant a `$( )` subshell exits, orphaning the pad; (b) PRINCIPLES
# #8 — the backgrounded child must never inherit a capture pipe. Returns as
# soon as ITS OWN process reports ready (a few ms) — it does NOT wait for
# kernel enumeration, so back-to-back calls land a burst (PR-4's shape); use
# rig_wait_for_pad for enumeration.
# Inputs:
#   $1 — pad index, 1..MCSS_RIG_MAX_PADS.
#   $2 — optional uniq (default: rig_default_uniq N).
#   $3 — optional device name (default: "MCSS Test Pad <N>").
#   $4 — optional product id (default: 0x000<N>; vendor is always
#        UHID_RIG_VENDOR_ID).
# Outputs:
#   stdout — nothing. stderr — one line on success naming pid/uniq/log.
#   return — 0 created+ready, 1 died or never reported ready within
#     MCSS_RIG_READY_TIMEOUT_S (log tail echoed; half-created pad torn down),
#     2 bad index or index already live (re-creating a live index is never an
#     implicit replace — callers write destroy-then-create explicitly).
_rig_create_pad_impl() {
    local n="$1" uniq="$2" name="$3" product="$4"

    local fifo="$_MCSS_RIG_DIR/pad${n}.fifo"
    local log="$_MCSS_RIG_DIR/pad${n}.log"
    rm -f "$fifo"
    mkfifo "$fifo" || {
        echo "[uhid_rig] mkfifo failed: $fifo" >&2
        return 1
    }
    : > "$log"

    # Rule 1 (§4.5, load-bearing): background BEFORE opening the write end.
    # The child's `< "$fifo"` blocks it in open(fifo, O_RDONLY) until we
    # rendezvous below. Opening the write end FIRST would make the forked
    # child inherit that fd too, so the pad would hold its own stdin open and
    # could NEVER see EOF — the shell-death safety property (§4.4) would
    # silently disappear.
    # Rule 2 (§4.5): _rig_close_tracked_fds runs INSIDE the child, before
    # exec, closing every OTHER already-tracked pad's write fd — otherwise
    # this pad would inherit them and those pads could never EOF either.
    local fd
    ( _rig_close_tracked_fds
      exec "${_MCSS_RIG_PAD_CMD[@]}" create --uniq "$uniq" --name "$name" \
          --vendor "$UHID_RIG_VENDOR_ID" --product "$product"
    ) < "$fifo" > "$log" 2>&1 &
    local pid=$!
    exec {fd}> "$fifo"

    if ! _rig_wait_for_ready "$log" "$pid" "$MCSS_RIG_READY_TIMEOUT_S"; then
        echo "[uhid_rig] pad $n did not become ready within" \
            "${MCSS_RIG_READY_TIMEOUT_S}s" >&2
        _rig_tail_log "$log"
        { exec {fd}>&-; } 2>/dev/null || true   # SC2261: brace vs redirect
        _rig_kill_stray "$pid"
        rm -f "$fifo"
        return 1
    fi

    local starttime
    starttime="$(_rig_proc_starttime "$pid")" || starttime=""
    _MCSS_RIG_PIDS[$n]="$pid"
    _MCSS_RIG_FDS[$n]="$fd"
    _MCSS_RIG_UNIQS[$n]="$uniq"
    _rig_pidfile_write "$n" "$pid" "$uniq" "$name" "$product" \
        "$(date +%s)" "$starttime" "$fifo" "$log"
    echo "[uhid_rig] pad $n started (pid $pid, uniq $uniq), log: $log" >&2
    return 0
}

rig_create_pad() {
    local n="${1:-}" uniq="${2:-}" name="${3:-}" product="${4:-}"
    _rig_valid_index "$n" || {
        echo "[uhid_rig] bad pad index: '${1:-}'" >&2
        return 2
    }
    [[ -n "${_MCSS_RIG_DIR:-}" ]] || {
        echo "[uhid_rig] rig_init has not run" >&2
        return 2
    }
    if [[ -n "${_MCSS_RIG_PIDS[$n]:-}" ]]; then
        echo "[uhid_rig] pad $n is already live — destroy it first" >&2
        return 2
    fi
    [[ -n "$uniq" ]] || uniq="$(rig_default_uniq "$n")"
    [[ -n "$name" ]] || name="MCSS Test Pad $n"
    if [[ -z "$product" ]]; then
        printf -v product '0x%04x' "$n"
    fi
    _rig_create_pad_impl "$n" "$uniq" "$name" "$product"
}

# rig_destroy_pad: End exactly pad N. COMMAND — never call inside `$( )`
# (see rig_create_pad's rationale; this function also manipulates a held fd
# in the live shell). Idempotent. Escalation ladder (§5.2): write `destroy`
# to the FIFO, close the write fd (guarantees EOF even if unread), poll for
# exit, escalate SIGTERM then SIGKILL against the VERIFIED pid only,
# re-checking identity immediately before each signal (PID recycling safe).
# Inputs:  $1 — pad index.
# Outputs:
#   stdout — nothing. stderr — one line naming which rung ended it.
#   return — 0 gone (any rung, including "was not tracked" — idempotency),
#     1 still alive after SIGKILL + grace, 2 bad index.
#   side effects — removes pad<N>.fifo/.pid; KEEPS pad<N>.log (evidence).
rig_destroy_pad() {
    local n="${1:-}"
    _rig_valid_index "$n" || {
        echo "[uhid_rig] bad pad index: '${1:-}'" >&2
        return 2
    }

    local fifo="${_MCSS_RIG_DIR:-}/pad${n}.fifo"
    local pidfile="${_MCSS_RIG_DIR:-}/pad${n}.pid"

    if [[ -z "${_MCSS_RIG_PIDS[$n]:-}" ]]; then
        echo "[uhid_rig] pad $n not tracked — nothing to destroy" >&2
        rm -f "$fifo" "$pidfile" 2>/dev/null || true
        return 0
    fi

    local pid="${_MCSS_RIG_PIDS[$n]}" fd="${_MCSS_RIG_FDS[$n]:-}"
    local rung="destroy"

    # Rung 1: ask nicely, only if the pad still looks alive and we hold the fd.
    if [[ -n "$fd" ]] && _rig_pid_is_ours "$n" && kill -0 "$pid" 2>/dev/null
    then
        { echo "destroy" >&"$fd"; } 2>/dev/null || true
    fi
    # Rung 2: close the write fd regardless — guarantees EOF even if step 1
    # was never read (e.g. the pad was mid-`hold`).
    if [[ -n "$fd" ]]; then
        { exec {fd}>&-; } 2>/dev/null || true   # SC2261: brace vs redirect
    fi

    if ! _rig_wait_for_gone "$n" "$MCSS_RIG_EXIT_TIMEOUT_S"; then
        rung="TERM"
        if _rig_pid_is_ours "$n"; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
        if ! _rig_wait_for_gone "$n" "$MCSS_RIG_KILL_GRACE_S"; then
            rung="KILL"
            if _rig_pid_is_ours "$n"; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
            if ! _rig_wait_for_gone "$n" "$MCSS_RIG_KILL_GRACE_S"; then
                echo "[uhid_rig] pad $n still alive after SIGKILL + grace" >&2
                return 1
            fi
        fi
    fi

    echo "[uhid_rig] pad $n destroyed (rung: $rung)" >&2
    rm -f "$fifo" "$pidfile"
    unset "_MCSS_RIG_PIDS[$n]" "_MCSS_RIG_FDS[$n]" "_MCSS_RIG_UNIQS[$n]"
    return 0
}

# _rig_inject_impl: Shared body for rig_inject/rig_inject_nowait.
# Inputs:  $1 — index, $2 — cmd, $3 — "wait"|"nowait"
# Outputs: return — 0 written(+acked if waiting), 1 not live/write/ack
#   failed, 2 bad args.
_rig_inject_impl() {
    # NOTE: parameter named cmdline, not cmd — a same-named local `cmd` in
    # another function (_rig_pad_cmd_runnable) is an array there, and the
    # linter's cross-function name tracking flags a scalar/array clash on
    # the shared name even though bash scoping keeps them unrelated. The
    # rename is the cleaner fix over a suppression.
    local n="$1" cmdline="$2" mode="$3"
    _rig_valid_index "$n" || {
        echo "[uhid_rig] bad pad index: '$n'" >&2
        return 2
    }
    [[ -n "${_MCSS_RIG_PIDS[$n]:-}" ]] || {
        echo "[uhid_rig] pad $n not tracked" >&2
        return 2
    }
    if ! rig_pad_is_live "$n"; then
        echo "[uhid_rig] pad $n is not live" >&2
        return 1
    fi
    if [[ "$cmdline" == *$'\n'* ]]; then
        echo "[uhid_rig] rig_inject: one call is one command (no newlines)" >&2
        return 2
    fi

    local fd="${_MCSS_RIG_FDS[$n]}" log="$_MCSS_RIG_DIR/pad${n}.log"
    local baseline=0
    if [[ "$mode" == "wait" ]]; then
        baseline=$(grep -Ec '^ok ' "$log" 2>/dev/null || true)
    fi

    if ! { echo "$cmdline" >&"$fd"; } 2>/dev/null; then
        echo "[uhid_rig] pad $n: write to fifo failed" >&2
        return 1
    fi

    [[ "$mode" == "wait" ]] || return 0

    if ! _rig_wait_for_count "$log" '^ok ' "$baseline" \
        "$MCSS_RIG_ACK_TIMEOUT_S"
    then
        local msg="[uhid_rig] pad $n: no ack within"
        msg+=" ${MCSS_RIG_ACK_TIMEOUT_S}s for '$cmdline'"
        echo "$msg" >&2
        _rig_tail_log "$log"
        return 1
    fi
    return 0
}

# rig_inject: Send one command line to pad N's stdin and wait for its ack.
# COMMAND — never call inside `$( )` (see rig_create_pad). Passed through
# verbatim; this library does NOT validate button/axis names — uhid_pad.py
# already validates at its own boundary (PRINCIPLES #9: one encoding).
# `hold <BTN> <ms>` blocks the pad's loop for ms — its ack arrives AFTER the
# sleep, so raise MCSS_RIG_ACK_TIMEOUT_S for that call, or use
# rig_inject_nowait instead.
# Inputs:  $1 — index, $2 — command line (must contain no newline).
# Outputs:
#   stdout — nothing. stderr — on failure only (log tail on no-ack).
#   return — 0 acked, 1 no ack within MCSS_RIG_ACK_TIMEOUT_S, 2 bad args.
rig_inject() { _rig_inject_impl "${1:-}" "${2:-}" wait; }

# rig_inject_nowait: Same guards and write as rig_inject, no ack wait. Exists
# for `hold` and for timing-sensitive sequences where the ack round-trip
# would perturb what is being measured. COMMAND — never call inside `$( )`.
# Inputs:  $1 — index, $2 — command line.
# Outputs: return — 0 written, 1 pad not live / write failed, 2 bad args.
rig_inject_nowait() { _rig_inject_impl "${1:-}" "${2:-}" nowait; }

# rig_cleanup: Destroy every pad THIS rig instance started, descending index
# order (mirrors creation order in reverse — deterministic log diffs).
# COMMAND — never call inside `$( )`. Re-entrancy guarded so a trap firing
# DURING cleanup (e.g. the #146 shape: INT runs cleanup+exit, exit re-fires
# the EXIT trap which also calls cleanup) is a harmless no-op. NEVER globs
# beyond _MCSS_RIG_DIR — another rig instance's pidfiles are not this
# instance's to reap (PIDs get recycled).
# Outputs:
#   stdout — nothing. stderr — per-pad diagnostics only on trouble.
#   return — 0, always (cleanup that can fail its caller is worse than
#     cleanup that reports and moves on).
#   side effects — destroys tracked pads; removes leftover *.fifo in
#     _MCSS_RIG_DIR; empties the in-memory maps.
rig_cleanup() {
    [[ -n "${_MCSS_RIG_IN_CLEANUP:-}" ]] && return 0
    _MCSS_RIG_IN_CLEANUP=1

    local -a indices=()
    local k
    for k in "${!_MCSS_RIG_PIDS[@]}"; do indices+=("$k"); done
    if (( ${#indices[@]} > 0 )); then
        mapfile -t indices < <(printf '%s\n' "${indices[@]}" | sort -rn)
    fi
    local idx
    for idx in "${indices[@]}"; do
        rig_destroy_pad "$idx" || \
            echo "[uhid_rig] cleanup: pad $idx did not fully stop" >&2
    done

    if [[ -n "${_MCSS_RIG_DIR:-}" ]]; then
        rm -f "$_MCSS_RIG_DIR"/*.fifo 2>/dev/null || true
    fi
    return 0
}

# rig_install_traps: Opt-in EXIT/INT/TERM trap installer. Refuses (does not
# clobber) if any of the three already has a non-empty trap — bash has one
# handler per signal, and a sourced library silently overwriting a suite's
# teardown is the #146 bug's shape. INT/TERM MUST exit (130/143) rather than
# fall through — that fall-through, with a cleanup that didn't exit, is
# exactly what #146 was.
# Outputs: return — 0 installed, 1 refused (a signal already had a trap).
rig_install_traps() {
    local sig
    for sig in INT TERM EXIT; do
        if [[ -n "$(trap -p "$sig")" ]]; then
            echo "[uhid_rig] rig_install_traps: refusing — $sig already has" \
                "a trap" >&2
            return 1
        fi
    done
    trap 'rig_cleanup; exit 130' INT
    trap 'rig_cleanup; exit 143' TERM
    trap rig_cleanup EXIT
    return 0
}

# --- Public API: queries (safe inside `$( )`) -----------------------------

# rig_default_uniq: Pure. "aa:bb:cc:00:00:0N", matching the probe's
# UNIQ_1/UNIQ_2. No state, no files.
# Inputs:  $1 — pad index (1..MCSS_RIG_MAX_PADS)
# Outputs: stdout — the uniq string. return: 0 / 2 bad index.
rig_default_uniq() {
    local n="${1:-}"
    _rig_valid_index "$n" || return 2
    printf 'aa:bb:cc:00:00:%02x\n' "$n"
    return 0
}

# rig_workdir: Where this rig instance's artifacts live. Delegates to
# mcss_workdir; creates nothing.
# Outputs: stdout — absolute path. return: 0 / 1 if rig_init has not run.
rig_workdir() {
    [[ -n "${_MCSS_RIG_DIR:-}" ]] || return 1
    printf '%s\n' "$_MCSS_RIG_DIR"
    return 0
}

# rig_pad_field: THE ONE reader of pad<N>.pid (PRINCIPLES #1) — no other
# function in this file parses that file's contents.
# Inputs:  $1 — pad index, $2 — key (pid uniq name product started starttime
#   fifo log)
# Outputs: stdout — the value, or nothing. return: 0 found, 1 not found,
#   2 bad args.
rig_pad_field() {
    local n="${1:-}" key="${2:-}"
    _rig_valid_index "$n" || return 2
    [[ -n "$key" ]] || return 2
    local pidfile="${_MCSS_RIG_DIR:-}/pad${n}.pid"
    [[ -n "${_MCSS_RIG_DIR:-}" && -f "$pidfile" ]] || return 1
    local line
    line="$(grep -m1 "^${key}=" "$pidfile" 2>/dev/null)" || return 1
    printf '%s\n' "${line#*=}"
    return 0
}

# rig_list_pads: Tracked indices, ascending, one per line.
# Outputs: stdout — indices, or nothing if none tracked. return: 0.
rig_list_pads() {
    local -a indices=()
    local k
    for k in "${!_MCSS_RIG_PIDS[@]}"; do indices+=("$k"); done
    (( ${#indices[@]} > 0 )) && printf '%s\n' "${indices[@]}" | sort -n
    return 0
}

# rig_pad_is_live: Predicate — no stdout, so `if rig_pad_is_live 1; then`
# reads naturally.
# Inputs:  $1 — pad index
# Outputs: return — 0 live, 1 not live, 2 bad index.
rig_pad_is_live() {
    local n="${1:-}"
    _rig_valid_index "$n" || return 2
    _rig_pid_is_ours "$n" || return 1
    local pid="${_MCSS_RIG_PIDS[$n]:-}"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    return 0
}

# rig_wait_for_pad / rig_wait_for_pad_gone: Poll the PRODUCTION enumerator
# (_list_raw_external_pads from controller_monitor.sh) until pad N's uniq
# does/does not appear, matched as the LAST field of an emitted line — this
# library never re-implements enumeration (ARCHITECTURE.md §2). Reached
# through a soft guard (STYLE-GUIDE §7.6): this library never sources a
# runtime module itself (ARCHITECTURE.md §4); the caller must have sourced
# controller_monitor.sh already.
# Inputs:  $1 — pad index, $2 — optional timeout_s (default
#   MCSS_RIG_ENUM_TIMEOUT_S)
# Outputs: return — 0 condition met, 1 timeout, 2 enumerator not sourced or
#   pad N has no recorded uniq ("can't tell" — see the fail-loud note above).
rig_wait_for_pad() {
    local n="${1:-}" timeout_s="${2:-$MCSS_RIG_ENUM_TIMEOUT_S}"
    declare -f _list_raw_external_pads >/dev/null || return 2
    local uniq
    uniq="$(rig_pad_field "$n" uniq)" || return 2
    [[ -n "$uniq" ]] || return 2
    _rig_wait_for_enum "$uniq" present "$timeout_s"
}

rig_wait_for_pad_gone() {
    local n="${1:-}" timeout_s="${2:-$MCSS_RIG_ENUM_TIMEOUT_S}"
    declare -f _list_raw_external_pads >/dev/null || return 2
    local uniq
    uniq="$(rig_pad_field "$n" uniq)" || return 2
    [[ -n "$uniq" ]] || return 2
    _rig_wait_for_enum "$uniq" absent "$timeout_s"
}
