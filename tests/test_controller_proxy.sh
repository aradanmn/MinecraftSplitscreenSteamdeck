#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: modules/controller_proxy.sh (#38 M1/PR2, dark)
# =============================================================================
# Tests the evsieve symlink-farm proxy's public API in isolation — no real
# evsieve, no hardware, no root. Every test sources controller_monitor.sh
# (for parse_input_device_blocks, the ambient dependency — spike §A) then
# controller_proxy.sh inside its own subshell, mirroring
# tests/test_evsieve_management.sh's isolated-subshell/PATH-stub pattern:
# a fake `evsieve` script logs argv to $CALLS, creates the create-link
# target itself (a symlink to a fake node file), then re-execs itself
# (exec -a) into a `while` loop so its OWN /proc/<pid>/cmdline shows
# argv[0]=this-script's-own-path plus the original args verbatim — a bare
# `exec sleep <n>` here lets bash tail-call-optimize straight into sleep's
# image, silently discarding argv[0]/args (verified empirically), which
# would fail controller_proxy.sh's _proxy_pid_is_ours identity check
# (review fix, post-initial-review: never trust a bare pidfile pid — see
# that module's header). The `while` loop defeats the optimization so the
# stub's cmdline looks like a real evsieve's, and kill/kill-0/SIGTERM
# semantics match production exactly (single process, no child tree,
# mirrors the module's own plain `&`, no setsid — spike §A step 5).
#
# Every fake PID this suite tracks is a REAL backgrounded stub (or, in
# T10/T11, a plain `sleep`/an out-of-range literal) — never a
# tests/test_orchestrator.sh-style mock state-file fixture, since PR2
# writes zero state (§F). T11's stale-pidfile literal still follows that
# suite's fixture-PID-beyond-pid_max convention (must never resolve to a
# real process).
#
# Run: bash tests/test_controller_proxy.sh
# =============================================================================

readonly TEST_TOTAL=15

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
readonly REPO_ROOT
readonly CONTROLLER_MONITOR_MODULE="$REPO_ROOT/modules/controller_monitor.sh"
readonly MODULE="$REPO_ROOT/modules/controller_proxy.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# --- Fixture helpers -----------------------------------------------------

# _configure_env: Export the proxy-dir/helper/state overrides for one
# isolated tmp root. Call INSIDE each test's subshell, before sourcing.
# Inputs: $1 — tmp root (already created by the caller)
_configure_env() {
    local tmp="$1"
    export MCSS_HELPER_DIR="$tmp/helper"
    export MCSS_PROXY_PADS_DIR="$tmp/helper/proxy-pads"
    export MCSS_PROXY_VIRT_DIR="$tmp/helper/proxy-virt"
    export SPLITSCREEN_STATE="$tmp/state.json"
    mkdir -p "$MCSS_HELPER_DIR"
}

# _write_evsieve_stub: Write a fake evsieve to $1. Logs argv to $CALLS,
# creates the create-link=PATH target as a symlink to $FAKE_NODE, then
# stays alive with a cmdline that looks like a real evsieve's: argv[0]
# is this script's own path (== MCSS_EVSIEVE_BIN as invoked) followed by
# the original args verbatim — required so controller_proxy.sh's
# _proxy_pid_is_ours identity check (argv[0] + the exact --input slot
# path) recognizes this stub as "an evsieve for this slot", the same
# check it applies to a real binary. A bare `exec sleep N` here would
# let bash tail-call-optimize straight into sleep's own image, silently
# discarding argv[0] and every other arg (verified empirically — that
# was this suite's own first draft, and it broke every identity check);
# the `while` loop defeats that optimization by keeping bash itself,
# not sleep, as the long-lived process at this pid.
# Inputs: $1 — path to write the stub to
#   Globals (read by the STUB at run time, must be exported by the
#   caller): CALLS, FAKE_NODE
_write_evsieve_stub() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/bin/bash
echo "evsieve $*" >> "$CALLS"
link=""
for arg in "$@"; do
    case "$arg" in
        create-link=*) link="${arg#create-link=}" ;;
    esac
done
if [[ -n "$link" ]]; then
    mkdir -p "$(dirname "$link")"
    ln -sfn "$FAKE_NODE" "$link"
fi
exec -a "$0" /bin/bash -c 'while :; do sleep 100 & wait $!; done' "$@"
EOF
    chmod +x "$path"
}

# _proc_fixture: Write a /proc/bus/input/devices-style fixture at $1 with
# a single block: N: Name="MCSS-slot<slot>", H: Handlers=event90 js9.
# Inputs: $1 — dest path, $2 — slot number
_proc_fixture() {
    local dest="$1" slot="$2"
    cat > "$dest" <<EOF
I: Bus=0005 Vendor=054c Product=09cc Version=0111
N: Name="MCSS-slot${slot}"
P: Phys=
S: Sysfs=/devices/virtual/input/input99
H: Handlers=event90 js9

EOF
}

# =============================================================================
# T1 — _proxy_evsieve_bin resolves executable bin; 1 when absent/non-exec
# =============================================================================
test_t1() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local ok=1

    if ! (
        _configure_env "$tmp/a"
        export MCSS_EVSIEVE_BIN="$tmp/a/evsieve"
        mkdir -p "$tmp/a"
        printf '#!/bin/bash\n' > "$MCSS_EVSIEVE_BIN"
        chmod +x "$MCSS_EVSIEVE_BIN"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"
        out=$(_proxy_evsieve_bin) || exit 1
        [[ "$out" == "$MCSS_EVSIEVE_BIN" ]] || exit 1
    ); then
        ok=0
        echo "  T1 case A (executable resolves) failed" >&2
    fi

    if ! (
        _configure_env "$tmp/b"
        export MCSS_EVSIEVE_BIN="$tmp/b/does-not-exist"
        mkdir -p "$tmp/b"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"
        out=""
        rc=0
        out=$(_proxy_evsieve_bin) || rc=$?
        [[ "$rc" -eq 1 && -z "$out" ]] || exit 1
    ); then
        ok=0
        echo "  T1 case B (missing path -> 1, no stdout) failed" >&2
    fi

    if ! (
        _configure_env "$tmp/c"
        export MCSS_EVSIEVE_BIN="$tmp/c/evsieve-noexec"
        mkdir -p "$tmp/c"
        : > "$MCSS_EVSIEVE_BIN"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"
        out=""
        rc=0
        out=$(_proxy_evsieve_bin) || rc=$?
        [[ "$rc" -eq 1 && -z "$out" ]] || exit 1
    ); then
        ok=0
        echo "  T1 case C (non-executable -> 1, no stdout) failed" >&2
    fi

    if (( ok == 1 )); then
        _pass "T1 — _proxy_evsieve_bin resolves executable; 1 when \
absent/non-exec"
    else
        _fail "T1" "one or more sub-cases failed (see stderr above)"
    fi
}

# =============================================================================
# T2 — proxy_start_slot: creates the pads link, launches with exact argv,
#      echoes an integer pid, records _CONTROLLER_PROXY_PIDS[1]
# =============================================================================
test_t2() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        pid=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)
        rc=$?
        ok=1
        [[ "$rc" -eq 0 ]] || ok=0
        [[ "$pid" =~ ^[0-9]+$ ]] || ok=0
        linked="$(readlink "$MCSS_PROXY_PADS_DIR/slot1")"
        [[ "$linked" == "/dev/input/event7" ]] || ok=0
        # _CONTROLLER_PROXY_PIDS is populated INSIDE proxy_start_slot's own
        # frame; since this call is captured via `pid=$(...)` (the spec's
        # own stdout contract), that write happens in a forked subshell and
        # is invisible here (a bash fundamental — see the module header's
        # "Implementation note"). The pidfile is the module's actual,
        # subshell-safe tracking record, so assert against that instead —
        # this IS the "slot is tracked" assertion T2 calls for.
        [[ "$(cat "$(_proxy_pidfile 1)" 2>/dev/null)" == "$pid" ]] || ok=0

        expected="evsieve --input $MCSS_PROXY_PADS_DIR/slot1 grab"
        expected+=" persist=reopen --output"
        expected+=" create-link=$MCSS_PROXY_VIRT_DIR/slot1"
        expected+=" name=MCSS-slot1 device-id=054c:09cc"
        actual="$(cat "$CALLS")"
        [[ "$actual" == "$expected" ]] || {
            ok=0
            echo "  argv mismatch:" >&2
            echo "    expected: $expected" >&2
            echo "    actual:   $actual" >&2
        }

        proxy_stop_all >/dev/null 2>&1 || true
        (( ok == 1 ))
    ); then
        _pass "T2 — proxy_start_slot creates link, exact argv, pid, \
tracks slot"
    else
        _fail "T2" "see stderr above"
    fi
}

# =============================================================================
# T3 — Degrade: MCSS_EVSIEVE_BIN unresolved -> 2, no links, no process
# =============================================================================
test_t3() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        # Deterministic "unavailable" condition: an absolute path that is
        # guaranteed never to exist (rather than literally unsetting the
        # var, which would fall through to the real install-time default
        # and be nondeterministic across machines running this suite).
        export MCSS_EVSIEVE_BIN="$tmp/nonexistent-evsieve"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        rc=0
        out=$(proxy_start_slot 1 /dev/input/event7 054c 09cc) || rc=$?
        ok=1
        [[ "$rc" -eq 2 ]] || ok=0
        [[ -z "$out" ]] || ok=0
        [[ ! -e "$MCSS_PROXY_PADS_DIR/slot1" ]] || ok=0
        [[ ! -e "$MCSS_PROXY_VIRT_DIR/slot1" ]] || ok=0
        [[ ! -s "$CALLS" ]] || ok=0
        (( ok == 1 ))
    ); then
        _pass "T3 — MCSS_EVSIEVE_BIN unavailable -> 2, no links, no process"
    else
        _fail "T3" "expected clean 2 with zero side effects"
    fi
}

# =============================================================================
# T4 — Double-start idempotence: same pid echoed, one launch in $CALLS
# =============================================================================
test_t4() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        pid1=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)
        pid2=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)
        ok=1
        [[ "$pid1" == "$pid2" ]] || ok=0
        launches=$(grep -c '^evsieve ' "$CALLS")
        [[ "$launches" -eq 1 ]] || ok=0

        proxy_stop_all >/dev/null 2>&1 || true
        (( ok == 1 ))
    ); then
        _pass "T4 — double-start idempotence: same pid, one launch logged"
    else
        _fail "T4" "expected identical pid and exactly one evsieve launch"
    fi
}

# =============================================================================
# T5 — proxy_virtual_nodes: resolves "<realpath> /dev/input/js9"; 1 when
#      the virt link is absent
# =============================================================================
test_t5() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local ok=1

    if ! (
        _configure_env "$tmp/a"
        mkdir -p "$MCSS_PROXY_VIRT_DIR"
        fake_node="$tmp/a/fake-node"
        : > "$fake_node"
        ln -sfn "$fake_node" "$MCSS_PROXY_VIRT_DIR/slot1"
        export PROC_INPUT_DEVICES="$tmp/a/proc_input"
        _proc_fixture "$PROC_INPUT_DEVICES" 1
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        out=$(proxy_virtual_nodes 1) || exit 1
        expected="$(readlink -f "$fake_node") /dev/input/js9"
        [[ "$out" == "$expected" ]] || exit 1
    ); then
        ok=0
        echo "  T5 case A (resolves realpath + js9) failed" >&2
    fi

    if ! (
        _configure_env "$tmp/b"
        mkdir -p "$MCSS_PROXY_VIRT_DIR"
        export PROC_INPUT_DEVICES="$tmp/b/proc_input"
        _proc_fixture "$PROC_INPUT_DEVICES" 1
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        rc=0
        out=$(proxy_virtual_nodes 1) || rc=$?
        [[ "$rc" -eq 1 && -z "$out" ]] || exit 1
    ); then
        ok=0
        echo "  T5 case B (virt link absent -> 1) failed" >&2
    fi

    if (( ok == 1 )); then
        _pass "T5 — proxy_virtual_nodes resolves realpath+js9; 1 when absent"
    else
        _fail "T5" "see stderr above"
    fi
}

# =============================================================================
# T6 — proxy_repoint_slot rewrites the pads link; 0 alive, 1 dead
# =============================================================================
test_t6() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        ok=1
        pid=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)

        rc=0
        proxy_repoint_slot 1 /dev/input/event8 || rc=$?
        [[ "$rc" -eq 0 ]] || { ok=0; echo "  alive repoint rc=$rc" >&2; }
        [[ "$(readlink "$MCSS_PROXY_PADS_DIR/slot1")" \
            == "/dev/input/event8" ]] || { ok=0; echo "  alive link" >&2; }

        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        # Give the kill a moment to land before the dead-case probe.
        for _i in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done

        rc=0
        proxy_repoint_slot 1 /dev/input/event9 || rc=$?
        [[ "$rc" -eq 1 ]] || { ok=0; echo "  dead repoint rc=$rc" >&2; }
        [[ "$(readlink "$MCSS_PROXY_PADS_DIR/slot1")" \
            == "/dev/input/event9" ]] || { ok=0; echo "  dead link" >&2; }

        unset '_CONTROLLER_PROXY_PIDS[1]'
        proxy_stop_all >/dev/null 2>&1 || true
        (( ok == 1 ))
    ); then
        _pass "T6 — proxy_repoint_slot: 0 alive (repointed), 1 dead \
(still repointed)"
    else
        _fail "T6" "see stderr above"
    fi
}

# =============================================================================
# T7 — proxy_stop_slot kills stub, unsets entry, removes both links;
#      stop-when-stopped -> 0
# =============================================================================
test_t7() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        ok=1
        pid=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)

        rc=0
        proxy_stop_slot 1 || rc=$?
        [[ "$rc" -eq 0 ]] || { ok=0; echo "  stop rc=$rc" >&2; }
        # Entry cleared: check the pidfile (the authoritative record —
        # see the module header's "Implementation note"), not the
        # in-process cache, which a $(...)-captured start never populated
        # in THIS frame to begin with.
        [[ ! -f "$(_proxy_pidfile 1)" ]] || { ok=0; echo "  entry" >&2; }
        [[ ! -e "$MCSS_PROXY_PADS_DIR/slot1" ]] || { ok=0; echo "  pads" >&2; }
        [[ ! -e "$MCSS_PROXY_VIRT_DIR/slot1" ]] || { ok=0; echo "  virt" >&2; }
        for _i in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$pid" 2>/dev/null && { ok=0; echo "  stub still alive" >&2; }

        rc=0
        proxy_stop_slot 1 || rc=$?
        [[ "$rc" -eq 0 ]] || { ok=0; echo "  stop-when-stopped rc=$rc" >&2; }

        (( ok == 1 ))
    ); then
        _pass "T7 — proxy_stop_slot kills+unsets+removes; \
stop-when-stopped -> 0"
    else
        _fail "T7" "see stderr above"
    fi
}

# =============================================================================
# T8 — Dark assertion: full start->virtual_nodes->stop cycle leaves
#      SPLITSCREEN_STATE untouched
# =============================================================================
test_t8() {
    local tmp state_file
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    state_file="$tmp/state.json"
    echo '{"slots":{},"mode":"handheld"}' > "$state_file"
    local before after
    before=$(sha256sum "$state_file")

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        export PROC_INPUT_DEVICES="$tmp/proc_input"
        _proc_fixture "$PROC_INPUT_DEVICES" 1
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        proxy_start_slot 1 /dev/input/event7 054c 09cc >/dev/null
        proxy_virtual_nodes 1 >/dev/null
        proxy_stop_slot 1
        exit 0
    ); then
        after=$(sha256sum "$state_file")
        if [[ "$before" == "$after" ]]; then
            _pass "T8 — dark: full lifecycle leaves SPLITSCREEN_STATE \
untouched"
        else
            _fail "T8" "SPLITSCREEN_STATE changed (before=$before after=$after)"
        fi
    else
        _fail "T8" "the start->virtual_nodes->stop cycle itself failed"
    fi
}

# =============================================================================
# T9 — proxy_stop_all reaps stray slot* links across both dirs
# =============================================================================
test_t9() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        mkdir -p "$MCSS_PROXY_PADS_DIR" "$MCSS_PROXY_VIRT_DIR"
        # A stray link OUTSIDE 1..MCSS_MAX_PLAYERS — proves the wildcard
        # reap, not just the per-slot loop.
        ln -sfn /dev/input/eventXX "$MCSS_PROXY_PADS_DIR/slot99"
        ln -sfn /dev/input/eventXX "$MCSS_PROXY_VIRT_DIR/slot99"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        rc=0
        proxy_stop_all || rc=$?
        ok=1
        [[ "$rc" -eq 0 ]] || ok=0
        pads_stray="$MCSS_PROXY_PADS_DIR/slot99"
        virt_stray="$MCSS_PROXY_VIRT_DIR/slot99"
        [[ ! -e "$pads_stray" && ! -L "$pads_stray" ]] \
            || { ok=0; echo "  pads stray" >&2; }
        [[ ! -e "$virt_stray" && ! -L "$virt_stray" ]] \
            || { ok=0; echo "  virt stray" >&2; }
        (( ok == 1 ))
    ); then
        _pass "T9 — proxy_stop_all reaps stray slot* links in both proxy dirs"
    else
        _fail "T9" "see stderr above"
    fi
}

# =============================================================================
# T10 — stale-pidfile ALIEN pid safety: proxy_stop_slot must never signal
#       a pid that isn't verified as an evsieve for this slot
# =============================================================================
test_t10() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        mkdir -p "$MCSS_PROXY_PADS_DIR" "$MCSS_PROXY_VIRT_DIR"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        # An unrelated, real, long-lived process THIS TEST owns (its own
        # child, so we can clean it up) — simulates a crashed session's
        # stale pidfile whose number was recycled by an unrelated process.
        # /proc/<pid>/cmdline for a plain `sleep` never matches
        # MCSS_EVSIEVE_BIN/"*/evsieve", so _proxy_pid_is_ours must refuse
        # it.
        sleep 300 &
        alien_pid=$!

        pidfile="$(_proxy_pidfile 1)"
        echo "$alien_pid" > "$pidfile"

        rc=0
        proxy_stop_slot 1 || rc=$?
        ok=1
        [[ "$rc" -eq 0 ]] || { ok=0; echo "  stop rc=$rc" >&2; }
        kill -0 "$alien_pid" 2>/dev/null \
            || { ok=0; echo "  ALIEN PID WAS KILLED" >&2; }
        [[ ! -f "$pidfile" ]] \
            || { ok=0; echo "  pidfile not cleared" >&2; }

        kill "$alien_pid" 2>/dev/null || true
        wait "$alien_pid" 2>/dev/null || true
        (( ok == 1 ))
    ); then
        _pass "T10 — stale pidfile naming an alien pid is never signaled"
    else
        _fail "T10" "module signaled a non-evsieve pid (see stderr above)"
    fi
}

# =============================================================================
# T11 — stale-pidfile IMPOSSIBLE pid recovery: proxy_start_slot must
#       treat an out-of-range pidfile as dead and start fresh
# =============================================================================
test_t11() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        mkdir -p "$MCSS_HELPER_DIR"
        pidfile="$(_proxy_pidfile 1)"
        # Beyond kernel.pid_max (tests/test_orchestrator.sh convention) —
        # can never resolve to a real process on this or any host.
        echo "4999910" > "$pidfile"

        pid=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)
        rc=$?
        ok=1
        [[ "$rc" -eq 0 ]] || { ok=0; echo "  rc=$rc" >&2; }
        [[ "$pid" =~ ^[0-9]+$ ]] || { ok=0; echo "  pid=$pid" >&2; }
        [[ "$pid" != "4999910" ]] \
            || { ok=0; echo "  echoed the impossible stale pid" >&2; }
        launches=$(grep -c '^evsieve ' "$CALLS")
        [[ "$launches" -eq 1 ]] \
            || { ok=0; echo "  launches=$launches" >&2; }

        proxy_stop_all >/dev/null 2>&1 || true
        (( ok == 1 ))
    ); then
        _pass "T11 — impossible pidfile pid treated as dead; fresh start"
    else
        _fail "T11" "see stderr above"
    fi
}

# =============================================================================
# T12 — stop actually reaps: the bounded SIGTERM-poll path (not `wait` on
#       a non-child) must leave the stub process gone
# =============================================================================
test_t12() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _configure_env "$tmp"
        export MCSS_EVSIEVE_BIN="$tmp/evsieve"
        _write_evsieve_stub "$MCSS_EVSIEVE_BIN"
        export CALLS="$tmp/calls.log"; : > "$CALLS"
        export FAKE_NODE="$tmp/fake-node"; : > "$FAKE_NODE"
        # shellcheck disable=SC1090
        source "$CONTROLLER_MONITOR_MODULE"
        # shellcheck disable=SC1090
        source "$MODULE"

        pid=$(proxy_start_slot 1 /dev/input/event7 054c 09cc)
        proxy_stop_slot 1

        ok=1
        for _i in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$pid" 2>/dev/null \
            && { ok=0; echo "  stub still alive after stop" >&2; }
        (( ok == 1 ))
    ); then
        _pass "T12 — proxy_stop_slot's SIGTERM-poll path actually reaps"
    else
        _fail "T12" "stub process survived proxy_stop_slot"
    fi
}

# =============================================================================
# T13 — HW-1 regression: proxy_start_slot in a truly clean process (env -i,
#       `set -u`, NO MCSS_* pre-set at all — unlike every test above, which
#       calls _configure_env and so always pre-sets MCSS_HELPER_DIR/
#       MCSS_PROXY_PADS_DIR/MCSS_PROXY_VIRT_DIR before sourcing, masking
#       any ordering bug in path resolution) with MCSS_EVSIEVE_BIN left
#       UNSET — must return 2 cleanly, no unbound-variable errors.
# =============================================================================
test_t13() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local out="$tmp/stdout.log" err="$tmp/stderr.log" rc=0
    env -i \
        PATH="$PATH" \
        HOME="$tmp/home" \
        XDG_RUNTIME_DIR="$tmp/xdg-runtime" \
        CM_MODULE="$CONTROLLER_MONITOR_MODULE" \
        PROXY_MODULE="$MODULE" \
        bash -c '
            set -u
            # shellcheck disable=SC1090
            source "$CM_MODULE"
            # shellcheck disable=SC1090
            source "$PROXY_MODULE"
            proxy_start_slot 1 /dev/input/event7 054c 09cc
        ' >"$out" 2>"$err" || rc=$?

    ok=1
    [[ "$rc" -eq 2 ]] || { ok=0; echo "  rc=$rc (want 2)" >&2; }
    [[ ! -s "$out" ]] || { ok=0; echo "  stdout: $(cat "$out")" >&2; }
    if grep -qi 'unbound variable' "$err"; then
        ok=0
        echo "  unbound-variable error present:" >&2
        cat "$err" >&2
    fi

    if (( ok == 1 )); then
        _pass "T13 — clean process, MCSS_EVSIEVE_BIN unset: -> 2 cleanly, \
no unbound-variable errors"
    else
        _fail "T13" "see stderr above"
    fi
}

# =============================================================================
# T14 — HW-1 regression, THE ACTUAL DECK REPRO: T13 alone does NOT catch
#       the on-Deck bug — MCSS_EVSIEVE_BIN unset makes proxy_start_slot
#       return early (via _proxy_evsieve_bin's own `|| return 2`) before
#       ever reaching a SECOND path-var access in proxy_start_slot's own
#       (non-subshell) scope. The real bug needed a RESOLVABLE evsieve
#       binary: proxy_start_slot's old first line, `bin=$(_proxy_evsieve_
#       bin) || return 2`, resolved paths only inside that command-
#       substitution subshell, so a subsequent bare access in this
#       function's own scope (_proxy_live_pid -> ... -> _proxy_pidfile,
#       then this function's own mkdir -p) saw MCSS_HELPER_DIR/
#       MCSS_PROXY_PADS_DIR unbound. Confirmed empirically against the
#       pre-fix module: this exact test (env -i, set -u, no MCSS_* preset,
#       a resolvable evsieve stub) reproduced the identical two-line-166 +
#       one-line-347 unbound-variable sequence from the Deck evidence.
# =============================================================================
test_t14() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local evsieve_bin="$tmp/evsieve"
    _write_evsieve_stub "$evsieve_bin"
    local fake_node="$tmp/fake-node"
    : > "$fake_node"
    local calls="$tmp/calls.log"
    : > "$calls"

    local out="$tmp/stdout.log" err="$tmp/stderr.log" rc=0
    env -i \
        PATH="$PATH" \
        HOME="$tmp/home" \
        XDG_RUNTIME_DIR="$tmp/xdg-runtime" \
        MCSS_EVSIEVE_BIN="$evsieve_bin" \
        CALLS="$calls" \
        FAKE_NODE="$fake_node" \
        CM_MODULE="$CONTROLLER_MONITOR_MODULE" \
        PROXY_MODULE="$MODULE" \
        bash -c '
            set -u
            # shellcheck disable=SC1090
            source "$CM_MODULE"
            # shellcheck disable=SC1090
            source "$PROXY_MODULE"
            proxy_start_slot 1 /dev/input/event7 054c 09cc
            proxy_stop_slot 1
        ' >"$out" 2>"$err" || rc=$?

    ok=1
    [[ "$rc" -eq 0 ]] || { ok=0; echo "  rc=$rc (want 0)" >&2; }
    local pid
    pid="$(head -n1 "$out" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || { ok=0; echo "  pid=$pid" >&2; }
    if grep -qi 'unbound variable' "$err"; then
        ok=0
        echo "  unbound-variable error present (the on-Deck bug):" >&2
        cat "$err" >&2
    fi

    if (( ok == 1 )); then
        _pass "T14 — clean process, resolvable evsieve, NO pre-set path \
vars: proxy_start_slot succeeds, no unbound-variable errors (Deck repro)"
    else
        _fail "T14" "see stderr above"
    fi
}

# =============================================================================
# T15 — HW-1 lead 2, investigated and REFUTED as a distinct bug (see the
#       commit message for the empirical trace): a pre-exported
#       MCSS_ENV_CONTEXT (Game Mode session env leaking into a probe's
#       shell) does NOT make mcss_resolve_paths or controller_proxy.sh's
#       own sourcing a no-op — mcss_resolve_paths is gated by its OWN
#       process-local, NEVER-exported sentinel (_MCSS_PATHS_DONE; see
#       runtime_context.sh's "Load-guard rule"), not by MCSS_ENV_CONTEXT.
#       Pinned here as a regression guard: T14's exact scenario, plus
#       MCSS_ENV_CONTEXT pre-exported, must still succeed cleanly.
# =============================================================================
test_t15() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local evsieve_bin="$tmp/evsieve"
    _write_evsieve_stub "$evsieve_bin"
    local fake_node="$tmp/fake-node"
    : > "$fake_node"
    local calls="$tmp/calls.log"
    : > "$calls"

    local out="$tmp/stdout.log" err="$tmp/stderr.log" rc=0
    env -i \
        PATH="$PATH" \
        HOME="$tmp/home" \
        XDG_RUNTIME_DIR="$tmp/xdg-runtime" \
        MCSS_ENV_CONTEXT="gamescope" \
        MCSS_EVSIEVE_BIN="$evsieve_bin" \
        CALLS="$calls" \
        FAKE_NODE="$fake_node" \
        CM_MODULE="$CONTROLLER_MONITOR_MODULE" \
        PROXY_MODULE="$MODULE" \
        bash -c '
            set -u
            # shellcheck disable=SC1090
            source "$CM_MODULE"
            # shellcheck disable=SC1090
            source "$PROXY_MODULE"
            proxy_start_slot 1 /dev/input/event7 054c 09cc
            proxy_stop_slot 1
        ' >"$out" 2>"$err" || rc=$?

    ok=1
    [[ "$rc" -eq 0 ]] || { ok=0; echo "  rc=$rc (want 0)" >&2; }
    local pid
    pid="$(head -n1 "$out" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || { ok=0; echo "  pid=$pid" >&2; }
    if grep -qi 'unbound variable' "$err"; then
        ok=0
        echo "  unbound-variable error present:" >&2
        cat "$err" >&2
    fi

    if (( ok == 1 )); then
        _pass "T15 — MCSS_ENV_CONTEXT pre-exported does not block path \
resolution: proxy_start_slot still succeeds cleanly"
    else
        _fail "T15" "see stderr above"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== controller_proxy test suite ==="
echo ""
test_t1
test_t2
test_t3
test_t4
test_t5
test_t6
test_t7
test_t8
test_t9
test_t10
test_t11
test_t12
test_t13
test_t14
test_t15
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
