#!/bin/bash
set -euo pipefail

# =============================================================================
# CONTROLLER PROXY MODULE
# =============================================================================
# #38 M1/PR2: a userspace evsieve symlink-farm proxy — the D2 stable-path
# primitive that lets a reconnecting pad resume forwarding into the SAME
# persistent virtual node instead of stranding a live sandbox bind (#61/#62).
# DARK ON ARRIVAL: this module has ZERO callers anywhere in the tree and
# writes ZERO orchestrator state — PR4 wires it into the orchestrator under
# MCSS_CONTROLLER_PROXY (default 0, OFF until PR7). Every proxy_* function
# is independently unit-testable and side-effect-free until called.
#
# Public API:
#   proxy_start_slot(slot, phys_event_node, phys_vendor, phys_product)
#     — stdout: the evsieve pid (success/no-op-resume only); exit 0 ok/no-op,
#       1 launch/poll failure, 2 proxy unavailable (no side effects)
#   proxy_repoint_slot(slot, phys_event_node)
#     — re-targets the slot's pad symlink, no process restart (D2); exit 0
#       alive, 1 dead (link still repointed — caller escalates), 2 proxy
#       unavailable
#   proxy_stop_slot(slot)
#     — kills+reaps the slot's evsieve, removes both symlinks; ALWAYS runs
#       regardless of MCSS_EVSIEVE_BIN; exit 0 always
#   proxy_virtual_nodes(slot)
#     — stdout: "<virt_ev_realpath> /dev/input/js<M>" (success only); exit 0
#       ok, 1 virt link unresolved or no jsN found
#   proxy_stop_all()
#     — proxy_stop_slot across 1..MCSS_MAX_PLAYERS + reaps stray slot*
#       links/pidfiles (crash residue); exit 0 always. Defined now, called
#       by nobody until PR4's cleanup() backstop + startup reap.
#
# Return-code convention (uniform across the API): 0 success, 1 operational
# failure, 2 = MCSS_EVSIEVE_BIN unresolved/non-executable ("proxy
# unavailable" — the fall-back-to-raw-binding signal every PR4 caller keys
# on). All human output -> stderr, "[controller_proxy] " prefix; stdout is
# data-only.
#
# Implementation note beyond the spike text (found while implementing, not
# a style choice): every public function's stdout contract is meant to be
# captured by a caller, i.e. `pid=$(proxy_start_slot ...)`. Command
# substitution always forks a subshell, so a write to the module-private
# _CONTROLLER_PROXY_PIDS array MADE DURING that call is invisible to the
# caller's shell once the subshell exits — a bash fundamental, not a bug in
# any one call site. An in-memory array alone therefore cannot be the
# idempotence/liveness record across separate top-level proxy_* invocations
# whenever a caller captures stdout this way (the normal, spec-mandated
# way). Each slot's pid is additionally persisted to a small file under
# $MCSS_HELPER_DIR (see _proxy_pidfile) — real filesystem state survives a
# subshell boundary — and THAT file is the authoritative liveness record;
# the array remains a same-process convenience cache, kept in sync wherever
# a function's own invocation happens to run in-process (e.g. this
# module's own test suite calling functions directly).
#
# A pidfile alone is NOT enough, though (second implementation
# correction, post-review): $MCSS_HELPER_DIR falls back to /tmp when
# $XDG_RUNTIME_DIR is unwritable, and /tmp SURVIVES REBOOTS — a crashed
# session's stale pidfile can outlive the pid it names, and the kernel
# recycles pids. Every site that treats a tracked pid as "alive" (start
# idempotence, repoint, stop) therefore goes through _proxy_live_pid,
# which requires BOTH `kill -0` AND _proxy_pid_is_ours (a /proc/<pid>/
# cmdline check for the evsieve binary + this exact slot's --input path)
# before trusting or signaling a pid; anything that fails either check is
# forgotten, never signaled, and treated as if no proxy existed. Teardown
# additionally cannot rely on `wait` to confirm the process actually
# exited (that pid is not this shell's child — see _proxy_kill_verified),
# so it polls `kill -0` after SIGTERM and falls back to SIGKILL.
#
# Globals CONSUMED (set elsewhere, read here):
#   MCSS_EVSIEVE_BIN, MCSS_PROXY_PADS_DIR, MCSS_PROXY_VIRT_DIR,
#   MCSS_HELPER_DIR, MCSS_MAX_PLAYERS — from runtime_context.sh (Group
#   B/C; resolved via mcss_resolve_paths, called defensively at the top of
#   every function below, same pattern as instance_lifecycle.sh/
#   kwin_positioner.sh)
#   parse_input_device_blocks — AMBIENT, from controller_monitor.sh, which
#   sources before this module per runtime_modules.list (same assumption
#   instance_lifecycle.sh's _vendor_of_js_node already relies on — see
#   controller_monitor.sh's own docstring note on that function).
#
# Inputs:  the evsieve binary (MCSS_EVSIEVE_BIN); /proc/bus/input/devices
#          (via parse_input_device_blocks, ambient).
# Outputs: symlinks under MCSS_PROXY_PADS_DIR/MCSS_PROXY_VIRT_DIR; a
#          backgrounded evsieve process per started slot, logged to
#          $MCSS_HELPER_DIR/evsieve-slot<N>.log; a pidfile per started slot
#          at $MCSS_HELPER_DIR/proxy-slot<N>.pid (this module's own
#          bookkeeping — NOT the orchestrator's SPLITSCREEN_STATE, which
#          this module never touches); stderr status lines.
#
# Environment overrides (for testing): none of this module's own — it reads
# MCSS_EVSIEVE_BIN/MCSS_PROXY_PADS_DIR/MCSS_PROXY_VIRT_DIR/MCSS_HELPER_DIR,
# all already env-overridable at their runtime_context.sh home (Group B).
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.1 2026-07-19  Review fix: never trust a bare pidfile pid — verify
#                    identity (/proc/<pid>/cmdline) before any kill -0
#                    liveness check or signal; SIGTERM+poll+SIGKILL
#                    replaces kill+wait (wait cannot reap a non-child)
#   v1.0 2026-07-19  #38 M1/PR2: dark module — evsieve symlink-farm proxy
#                    lifecycle, zero callers, zero state writes
# =============================================================================

# Sourcing runtime_context.sh here (idempotent, process-local sentinels)
# makes standalone sourcing (unit tests) behave like the launcher prologue,
# which sources it first — same rationale as controller_monitor.sh/
# instance_lifecycle.sh/kwin_positioner.sh.
source "$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh"

# --- Module-level constants ---

# Bounded poll for a freshly-launched evsieve to produce a live virtual node
# (§A: "~2s, iters x 0.1s"). Units in name (STYLE-GUIDE §6).
readonly CONTROLLER_PROXY_START_TIMEOUT_S=2
readonly CONTROLLER_PROXY_POLL_INTERVAL_S="0.1"
readonly CONTROLLER_PROXY_START_POLL_ITERS=20

# Bounded poll for a SIGTERM'd evsieve to actually exit before the
# SIGKILL fallback (review fix: `wait` cannot reap a non-child — the pid
# was launched in an EARLIER, separate proxy_start_slot invocation, so a
# later proxy_stop_slot call has no child relationship to it; polling
# kill -0 is the only reliable "did it actually die" signal across that
# boundary). Same cadence as the start poll.
readonly CONTROLLER_PROXY_STOP_TIMEOUT_S=2
readonly CONTROLLER_PROXY_STOP_POLL_ITERS=20

# --- Internal data structures ---

# Module-private kill-list cache: slot -> evsieve pid, for same-process
# callers. See the "Implementation note" above the header for why this is
# a CACHE, not the authoritative record — that is _proxy_pidfile.
# proxy_stop_slot/proxy_stop_all kill ONLY tracked pids (probe discipline:
# never pkill).
declare -A _CONTROLLER_PROXY_PIDS

# --- Internal functions ---

# _proxy_evsieve_bin: Resolve the evsieve binary — the gate every proxy_*
# call (except proxy_stop_slot/proxy_stop_all, which must clean up even
# with no binary) runs first.
# Name deviation (judgment, spike §A): design calls this _evsieve_bin, but
# evsieve_management.sh (the INSTALL-time module) already defines
# _evsieve_bin with a different contract (TARGET_DIR/bin/evsieve). The two
# are never co-sourced (installer vs runtime), but the module-prefixed name
# removes reader confusion (STYLE-GUIDE §6).
# Inputs:
#   Globals: MCSS_EVSIEVE_BIN (read, via mcss_resolve_paths)
# Outputs:
#   stdout(data) — the evsieve binary path, success only
#   return — 0 if resolved and executable; 1 otherwise (no stdout)
_proxy_evsieve_bin() {
    mcss_resolve_paths
    [[ -x "$MCSS_EVSIEVE_BIN" ]] || return 1
    echo "$MCSS_EVSIEVE_BIN"
    return 0
}

# _proxy_pidfile: Return SLOT's on-disk pid-record path — the
# subshell-safe authoritative liveness record (see the module header's
# "Implementation note").
# Inputs:
#   $1 — slot number
#   Globals: MCSS_HELPER_DIR (read; caller must have resolved paths first)
# Outputs:
#   stdout(data) — $MCSS_HELPER_DIR/proxy-slot<N>.pid
_proxy_pidfile() {
    echo "$MCSS_HELPER_DIR/proxy-slot$1.pid"
}

# _proxy_tracked_pid: Read SLOT's currently-recorded pid, preferring the
# on-disk pidfile (authoritative) and falling back to the in-process cache
# (covers a direct, non-subshell same-process call that raced ahead of a
# pidfile write — defense in depth, not the normal path).
# Inputs:
#   $1 — slot number
#   Globals: _CONTROLLER_PROXY_PIDS (read)
# Outputs:
#   stdout(data) — the pid, or empty if none recorded
_proxy_tracked_pid() {
    local slot="$1" pidfile pid=""
    pidfile=$(_proxy_pidfile "$slot")
    [[ -f "$pidfile" ]] && pid=$(<"$pidfile")
    [[ -z "$pid" ]] && pid="${_CONTROLLER_PROXY_PIDS[$slot]:-}"
    echo "$pid"
}

# _proxy_forget_slot: Clear SLOT's pid record — both the pidfile and the
# in-process cache.
# Inputs:
#   $1 — slot number
#   Globals: _CONTROLLER_PROXY_PIDS (write)
# Outputs:
#   side effects — rm -f the pidfile; unsets the cache entry
_proxy_forget_slot() {
    local slot="$1" pidfile
    pidfile=$(_proxy_pidfile "$slot")
    rm -f "$pidfile"
    unset '_CONTROLLER_PROXY_PIDS[$slot]'
}

# _proxy_pid_is_ours: Verify PID is actually an evsieve process THIS
# module could have launched for SLOT — a pidfile number is NEVER trusted
# blindly. Review fix: $MCSS_HELPER_DIR falls back to /tmp when
# $XDG_RUNTIME_DIR is unwritable, and /tmp SURVIVES REBOOTS — a crashed
# session's stale proxy-slot<N>.pid can therefore outlive the pid it
# named by a long margin, and the kernel recycles pids. Without this
# check, an unrelated process that happened to reuse the number would
# either get SIGTERM/SIGKILL'd (proxy_stop_slot/proxy_stop_all) or be
# mistaken for "alive" by the start idempotence check (which would then
# never actually launch evsieve again for that slot). This repo already
# paid for exactly this hazard class once (see tests/test_orchestrator.sh
# fixture-PID-beyond-pid_max convention/comments).
# Inputs:
#   $1 — pid
#   $2 — slot number
#   Globals: MCSS_EVSIEVE_BIN, MCSS_PROXY_PADS_DIR (read, via
#            mcss_resolve_paths)
# Outputs:
#   return — 0 iff /proc/<pid>/cmdline exists and its NUL-separated argv
#            has BOTH: argv[0] equal to MCSS_EVSIEVE_BIN (or ending in
#            "/evsieve") AND a token exactly equal to
#            "$MCSS_PROXY_PADS_DIR/slot<slot>" (the --input value, unique
#            per slot — this is what makes the check slot-precise, not
#            just binary-precise); 1 otherwise, including a vanished pid
_proxy_pid_is_ours() {
    local pid="$1" slot="$2"
    mcss_resolve_paths

    local cmdline
    cmdline=$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null) || return 1
    [[ -n "$cmdline" ]] || return 1

    local argv0
    argv0=$(head -n1 <<< "$cmdline")
    [[ "$argv0" == "$MCSS_EVSIEVE_BIN" || "$argv0" == */evsieve ]] \
        || return 1

    local want="$MCSS_PROXY_PADS_DIR/slot${slot}"
    grep -qxF "$want" <<< "$cmdline"
}

# _proxy_live_pid: Return SLOT's tracked pid IFF it is BOTH alive
# (kill -0) AND verified (_proxy_pid_is_ours) — the combined check every
# liveness/signal site in this module must use. A pid that fails either
# half is NEVER signaled and NEVER treated as alive: this clears the
# stale record (_proxy_forget_slot) and returns empty, so the caller
# proceeds exactly as if no proxy existed for the slot.
# Inputs:
#   $1 — slot number
# Outputs:
#   stdout(data) — the verified-live pid, or empty
#   return — 0 always
_proxy_live_pid() {
    local slot="$1" pid
    pid=$(_proxy_tracked_pid "$slot")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
        && _proxy_pid_is_ours "$pid" "$slot"
    then
        echo "$pid"
        return 0
    fi
    _proxy_forget_slot "$slot"
    return 0
}

# _proxy_kill_verified: Terminate PID — already identity-verified once by
# the caller via _proxy_live_pid — with SIGTERM, poll for exit, SIGKILL
# fallback. Re-verifies identity immediately before EACH signal sent:
# review fix — pid reuse mid-poll (rare, but the entire reason this
# module never trusts a bare pid number) must never let a later signal
# land on a different, unrelated process that took over the same pid
# during the wait. Single-pid signals only — never a process group,
# never pkill (probe discipline, same as tests/probe-evsieve-reconnect.sh
# and tests/probe-proxy-repoint.sh).
# Inputs:
#   $1 — pid (caller has already confirmed liveness+identity once)
#   $2 — slot number (the re-verification key)
# Outputs:
#   side effects — sends SIGTERM, and SIGKILL if still alive+ours after
#                  the poll window, to $1 ONLY
_proxy_kill_verified() {
    local pid="$1" slot="$2"

    _proxy_pid_is_ours "$pid" "$slot" && kill -TERM "$pid" 2>/dev/null

    local i
    for (( i = 0; i < CONTROLLER_PROXY_STOP_POLL_ITERS; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep "$CONTROLLER_PROXY_POLL_INTERVAL_S"
    done

    if kill -0 "$pid" 2>/dev/null && _proxy_pid_is_ours "$pid" "$slot"; then
        echo "[controller_proxy] evsieve pid ${pid} (slot ${slot}) did" \
            "not exit after SIGTERM within" \
            "${CONTROLLER_PROXY_STOP_TIMEOUT_S}s — sending SIGKILL" >&2
        kill -KILL "$pid" 2>/dev/null || true
    fi
    # Opportunistic, non-blocking reap: harmless (immediate no-op error)
    # unless $pid happens to be an actual child of THIS shell that has
    # already exited (a zombie) — in which case this clears it. Never
    # blocks on a still-running non-child (bash reports "not a child"
    # immediately rather than waiting).
    wait "$pid" 2>/dev/null || true
}

# --- Public API ---

# proxy_start_slot: Start (or idempotently resume) SLOT's evsieve proxy,
# forwarding PHYS_EVENT_NODE into a persistent virtual output.
# Inputs:
#   $1 — slot number
#   $2 — phys_event_node (e.g. /dev/input/event7)
#   $3 — phys_vendor (4-hex, e.g. 054c)
#   $4 — phys_product (4-hex, e.g. 09cc) — device-id carries vendor:product,
#        NOT uniq (uniq is the orchestrator's matching key, never the
#        proxy's launch identity — spike §A signature-deviation note)
#   Globals: MCSS_PROXY_PADS_DIR, MCSS_PROXY_VIRT_DIR, MCSS_HELPER_DIR
#            (read, via mcss_resolve_paths); _CONTROLLER_PROXY_PIDS
#            (read/write)
# Outputs:
#   stdout(data) — the evsieve pid, on success or no-op double-start only
#   return — 0 success/no-op-resume; 1 the virtual node never came up
#            within the poll window (pid killed, no side effects survive);
#            2 MCSS_EVSIEVE_BIN unavailable (no side effects at all)
#   side effects — mkdir -p both proxy dirs; ln -sfn the pads symlink;
#                  spawns a backgrounded evsieve, logging to
#                  $MCSS_HELPER_DIR/evsieve-slot<N>.log; writes/clears the
#                  slot's pidfile (see _proxy_pidfile)
proxy_start_slot() {
    local slot="$1" phys_event_node="$2" phys_vendor="$3" phys_product="$4"
    local bin
    bin=$(_proxy_evsieve_bin) || return 2

    # Idempotence: a tracked, still-alive, IDENTITY-VERIFIED pid is a
    # no-op double-start. _proxy_live_pid already clears the record (and
    # returns empty) for anything dead OR failing the identity check —
    # including a stale pidfile whose number was recycled by an unrelated
    # process — so falling through here always means a genuinely fresh
    # start is needed.
    local existing
    existing=$(_proxy_live_pid "$slot")
    if [[ -n "$existing" ]]; then
        _CONTROLLER_PROXY_PIDS[$slot]="$existing"
        echo "$existing"
        return 0
    fi

    mkdir -p "$MCSS_PROXY_PADS_DIR" "$MCSS_PROXY_VIRT_DIR"

    local pad_link="$MCSS_PROXY_PADS_DIR/slot${slot}"
    local virt_link="$MCSS_PROXY_VIRT_DIR/slot${slot}"
    ln -sfn "$phys_event_node" "$pad_link"

    local logfile="$MCSS_HELPER_DIR/evsieve-slot${slot}.log"
    # Plain `&` (no setsid): evsieve is a single process with no child tree,
    # unlike bwrap — mirrors the probe's start_evsieve (spike §A step 5).
    "$bin" --input "$pad_link" grab persist=reopen \
        --output create-link="$virt_link" name="MCSS-slot${slot}" \
                 device-id="${phys_vendor}:${phys_product}" \
        >>"$logfile" 2>&1 &
    local pid=$!
    echo "$pid" > "$(_proxy_pidfile "$slot")"
    _CONTROLLER_PROXY_PIDS[$slot]="$pid"

    local i real
    for (( i = 0; i < CONTROLLER_PROXY_START_POLL_ITERS; i++ )); do
        real=$(readlink -f "$virt_link" 2>/dev/null) || real=""
        if [[ -n "$real" && -e "$real" ]]; then
            echo "$pid"
            return 0
        fi
        sleep "$CONTROLLER_PROXY_POLL_INTERVAL_S"
    done

    echo "[controller_proxy] evsieve pid ${pid} (slot ${slot}) never" \
        "produced a live virtual node at ${virt_link} within" \
        "${CONTROLLER_PROXY_START_TIMEOUT_S}s — killing" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    _proxy_forget_slot "$slot"
    return 1
}

# proxy_repoint_slot: Re-point SLOT's pad symlink to a new physical event
# node (D2's seamless-reconnect primitive) — NEVER restarts the evsieve
# process; evsieve's own persist=reopen loop re-resolves the moved symlink.
# Inputs:
#   $1 — slot number
#   $2 — phys_event_node (the pad's NEW /dev/input/eventN)
#   Globals: MCSS_PROXY_PADS_DIR (read, via mcss_resolve_paths);
#            _CONTROLLER_PROXY_PIDS (read)
# Outputs:
#   return — 2 MCSS_EVSIEVE_BIN unavailable (no side effects); 0 the
#            slot's evsieve is alive (repointed AND live); 1 the slot's
#            evsieve is unset/dead — the link IS still repointed (cheap,
#            idempotent) but there is no live evsieve to re-resolve it;
#            caller must escalate (e.g. SLOT_DIED)
#   side effects — mkdir -p the pads dir (defensive — normally already
#                  exists from proxy_start_slot); ln -sfn the pads symlink
proxy_repoint_slot() {
    local slot="$1" phys_event_node="$2"
    _proxy_evsieve_bin >/dev/null || return 2

    mkdir -p "$MCSS_PROXY_PADS_DIR"
    ln -sfn "$phys_event_node" "$MCSS_PROXY_PADS_DIR/slot${slot}"

    local pid
    pid=$(_proxy_live_pid "$slot")
    if [[ -n "$pid" ]]; then
        _CONTROLLER_PROXY_PIDS[$slot]="$pid"
        return 0
    fi
    echo "[controller_proxy] slot ${slot} repointed to" \
        "${phys_event_node} but no live evsieve — caller must escalate" >&2
    return 1
}

# proxy_stop_slot: Tear down SLOT's proxy. ALWAYS cleans up regardless of
# MCSS_EVSIEVE_BIN (teardown must never be blocked by a missing binary).
# Idempotent: stop-when-stopped is a clean no-op. NEVER signals a pid that
# fails _proxy_pid_is_ours (review fix — see that function and
# _proxy_kill_verified for the stale-pidfile/pid-reuse hazard this guards
# against).
# Inputs:
#   $1 — slot number
#   Globals: MCSS_PROXY_PADS_DIR, MCSS_PROXY_VIRT_DIR (read, via
#            mcss_resolve_paths); _CONTROLLER_PROXY_PIDS (read/write)
# Outputs:
#   return — 0 always
#   side effects — SIGTERM (then SIGKILL if needed) the slot's tracked
#                  evsieve pid, ONLY if it is still alive AND verified as
#                  ours; rm -f both slot<N> symlinks + the slot's pidfile
proxy_stop_slot() {
    local slot="$1"
    mcss_resolve_paths

    local pid
    pid=$(_proxy_live_pid "$slot")
    [[ -n "$pid" ]] && _proxy_kill_verified "$pid" "$slot"
    _proxy_forget_slot "$slot"

    rm -f "$MCSS_PROXY_PADS_DIR/slot${slot}" "$MCSS_PROXY_VIRT_DIR/slot${slot}"
    return 0
}

# proxy_virtual_nodes: Resolve SLOT's virtual evdev node + its jsN handler.
# Inputs:
#   $1 — slot number
#   Globals: MCSS_PROXY_VIRT_DIR (read, via mcss_resolve_paths); reads
#            parse_input_device_blocks (ambient)
# Outputs:
#   stdout(data) — "<virt_ev_realpath> /dev/input/js<M>", success only
#   return — 0 success; 1 the virt link doesn't resolve to a live node, or
#            no block named MCSS-slot<N> has a jsN handler
proxy_virtual_nodes() {
    local slot="$1"
    mcss_resolve_paths

    local virt_ev
    virt_ev=$(readlink -f "$MCSS_PROXY_VIRT_DIR/slot${slot}" 2>/dev/null) \
        || virt_ev=""
    [[ -n "$virt_ev" && -e "$virt_ev" ]] || return 1

    local devname="MCSS-slot${slot}"
    local vendor product name handlers sysfs phys keybits uniq _h jsn=""
    # Read-arity — critical (spike §A): an 8-variable read against today's
    # 7-field parse_input_device_blocks emit does NOT slurp (a read with
    # MORE vars than fields leaves the extra var, "uniq" here, clean) — so
    # this loop is already PR3-correct and needs no read-arity change when
    # the parser gains its 8th field there.
    # shellcheck disable=SC2034  # vendor/product/sysfs/phys/keybits/uniq
    # are positional fields of parse_input_device_blocks' fixed contract;
    # only name/handlers are used here but all must be read to keep the
    # later columns aligned. uniq field reserved (populated by PR3's
    # parse_input_device_blocks 8th field).
    while IFS=$'\x1f' read -r vendor product name handlers sysfs phys \
        keybits uniq; do
        local stripped="${name#\"}"
        stripped="${stripped%\"}"
        [[ "$stripped" == "$devname" ]] || continue
        for _h in $handlers; do
            case "$_h" in
                js*) jsn="${_h#js}" ;;
            esac
        done
        break
    done < <(parse_input_device_blocks 2>/dev/null)

    [[ -n "$jsn" ]] || return 1
    echo "${virt_ev} /dev/input/js${jsn}"
    return 0
}

# proxy_stop_all: Stop every slot's proxy (1..MCSS_MAX_PLAYERS) and reap
# any dangling slot* symlink or stray pidfile left in/under the proxy
# dirs/helper dir — crash residue: $MCSS_HELPER_DIR falls back to /tmp
# when $XDG_RUNTIME_DIR/mcss isn't writable, and /tmp survives a crash
# (spike §B). Defined now; called by nobody until PR4's cleanup()
# backstop + startup reap.
# Inputs:
#   Globals: MCSS_MAX_PLAYERS (read); MCSS_PROXY_PADS_DIR,
#            MCSS_PROXY_VIRT_DIR, MCSS_HELPER_DIR (read, via
#            mcss_resolve_paths)
# Outputs:
#   return — 0 always
#   side effects — same as proxy_stop_slot, per slot 1..MCSS_MAX_PLAYERS;
#                  rm -f any remaining slot* symlink (tracked or not) in
#                  either proxy dir, and any stray proxy-slot*.pid file
proxy_stop_all() {
    mcss_resolve_paths
    local slot
    for (( slot = 1; slot <= MCSS_MAX_PLAYERS; slot++ )); do
        proxy_stop_slot "$slot"
    done

    local f
    for f in "$MCSS_PROXY_PADS_DIR"/slot* "$MCSS_PROXY_VIRT_DIR"/slot* \
        "$MCSS_HELPER_DIR"/proxy-slot*.pid; do
        [[ -e "$f" || -L "$f" ]] && rm -f "$f"
    done
    return 0
}
