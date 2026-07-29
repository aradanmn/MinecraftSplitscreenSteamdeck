#!/bin/bash
set -uo pipefail

# =============================================================================
# Test Suite: preflight.sh — mcss_notify_user (#125)
# =============================================================================
# kdialog/zenity are MOCKED onto PATH, so nothing here opens a real dialog and no
# display is needed. What is actually under test is the contract every caller
# depends on: it never blocks, it never writes to stdout, it always logs to
# stderr, it prefers kdialog, it self-dismisses only when asked, and it fails
# open when no notifier exists.
#
# Run: bash tests/test_preflight.sh
# =============================================================================

readonly TEST_TOTAL=12

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/modules/preflight.sh"

TESTS_PASSED=0
TESTS_FAILED=0
MOCKBIN=""

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

_expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then _pass "$name"
    else _fail "$name" "expected '$expected', got '$actual'"; fi
}

# _mock_env: a PATH containing ONLY the notifiers named in $@, each recording its
# argv to $MOCKBIN/<name>.args and then sleeping so "is it still running?" is a
# meaningful question. PATH is replaced (not prepended) so a real kdialog on the
# host can never leak into a test that is meant to have none.
_mock_env() {
    MOCKBIN="$(mktemp -d)"
    local tool
    for tool in "$@"; do
        cat > "$MOCKBIN/$tool" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$MOCKBIN/$tool.args"
{ echo "QT_QPA_PLATFORM=\${QT_QPA_PLATFORM:-}"
  echo "GDK_BACKEND=\${GDK_BACKEND:-}"
  echo "DISPLAY=\${DISPLAY:-}"; } > "$MOCKBIN/$tool.env"
echo running > "$MOCKBIN/$tool.started"
sleep 30
EOF
        chmod +x "$MOCKBIN/$tool"
    done
    # coreutils the function itself needs; everything else is deliberately absent.
    local need
    for need in sleep kill command env; do
        [[ -x "/usr/bin/$need" ]] && ln -sf "/usr/bin/$need" "$MOCKBIN/$need" 2>/dev/null
    done
}

_mock_cleanup() {
    [[ -n "$MOCKBIN" && -d "$MOCKBIN" ]] || return 0
    # Reap only what the mocks started, by PID (PRINCIPLES #7) — never a name match.
    local f pid
    for f in "$MOCKBIN"/*.pid; do
        [[ -f "$f" ]] || continue
        pid="$(cat "$f")"
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$MOCKBIN"
    MOCKBIN=""
}
trap _mock_cleanup EXIT

# --- T1: fail open when nothing is installed ---------------------------------

test_no_notifier_returns_1() {
    _mock_env                                  # no tools at all
    local rc=0
    ( PATH="$MOCKBIN" mcss_notify_user "T" "body" ) 2>/dev/null || rc=$?
    _expect "T1.1 returns 1 when no notifier exists" "$rc" "1"
    _mock_cleanup
}

test_no_notifier_still_logs() {
    _mock_env
    local err
    err=$( { PATH="$MOCKBIN" mcss_notify_user "Title" "the body"; } 2>&1 >/dev/null )
    if [[ "$err" == *"Title"* && "$err" == *"the body"* ]]; then
        _pass "T1.2 message still reaches stderr with no notifier"
    else
        _fail "T1.2 message still reaches stderr with no notifier" "got '$err'"
    fi
    _mock_cleanup
}

# T1.3 is the one that protects every caller: orchestrator/preflight capture
# stdout elsewhere, so a stray echo here would corrupt a command substitution.
test_never_writes_stdout() {
    _mock_env kdialog
    local out
    out=$( PATH="$MOCKBIN" mcss_notify_user "T" "body" 2>/dev/null )
    _expect "T1.3 writes nothing to stdout" "$out" ""
    _mock_cleanup
}

test_no_notifier_no_stdout() {
    _mock_env
    local out
    out=$( PATH="$MOCKBIN" mcss_notify_user "T" "body" 2>/dev/null )
    _expect "T1.4 writes nothing to stdout when failing open" "$out" ""
    _mock_cleanup
}

# --- T2: notifier selection --------------------------------------------------

test_kdialog_returns_0() {
    _mock_env kdialog
    local rc=0
    ( PATH="$MOCKBIN" mcss_notify_user "T" "body" ) 2>/dev/null || rc=$?
    _expect "T2.1 returns 0 when kdialog exists" "$rc" "0"
    _mock_cleanup
}

test_kdialog_invoked_with_body() {
    _mock_env kdialog
    PATH="$MOCKBIN" mcss_notify_user "MyTitle" "MyBody" 2>/dev/null
    local waited=0
    while (( waited < 20 )) && [[ ! -f "$MOCKBIN/kdialog.args" ]]; do
        sleep 0.1; waited=$((waited + 1))
    done
    local args; args="$(cat "$MOCKBIN/kdialog.args" 2>/dev/null)"
    if [[ "$args" == *"MyTitle"* && "$args" == *"MyBody"* && "$args" == *"--error"* ]]; then
        _pass "T2.2 kdialog invoked with --error, title and body"
    else
        _fail "T2.2 kdialog invoked with --error, title and body" "got '$args'"
    fi
    _mock_cleanup
}

test_prefers_kdialog_over_zenity() {
    _mock_env kdialog zenity
    PATH="$MOCKBIN" mcss_notify_user "T" "body" 2>/dev/null
    local waited=0
    while (( waited < 20 )) && [[ ! -f "$MOCKBIN/kdialog.started" ]]; do
        sleep 0.1; waited=$((waited + 1))
    done
    if [[ -f "$MOCKBIN/kdialog.started" && ! -f "$MOCKBIN/zenity.started" ]]; then
        _pass "T2.3 prefers kdialog when both exist"
    else
        _fail "T2.3 prefers kdialog when both exist" \
            "kdialog=$([[ -f "$MOCKBIN/kdialog.started" ]] && echo y || echo n) zenity=$([[ -f "$MOCKBIN/zenity.started" ]] && echo y || echo n)"
    fi
    _mock_cleanup
}

test_falls_back_to_zenity() {
    _mock_env zenity
    local rc=0
    ( PATH="$MOCKBIN" mcss_notify_user "T" "body" ) 2>/dev/null || rc=$?
    local waited=0
    while (( waited < 20 )) && [[ ! -f "$MOCKBIN/zenity.started" ]]; do
        sleep 0.1; waited=$((waited + 1))
    done
    if (( rc == 0 )) && [[ -f "$MOCKBIN/zenity.started" ]]; then
        _pass "T2.4 falls back to zenity when kdialog is absent"
    else
        _fail "T2.4 falls back to zenity when kdialog is absent" "rc=$rc"
    fi
    _mock_cleanup
}

# --- T3: the non-blocking / self-dismiss contract ----------------------------

# T3.1: the mock sleeps 30s. If mcss_notify_user waited on it, this test would
# take 30s — the whole point is that it does not.
test_does_not_block() {
    _mock_env kdialog
    local start=$SECONDS
    PATH="$MOCKBIN" mcss_notify_user "T" "body" 5 2>/dev/null
    local elapsed=$(( SECONDS - start ))
    if (( elapsed <= 2 )); then
        _pass "T3.1 returns immediately (does not wait on the dialog)"
    else
        _fail "T3.1 returns immediately (does not wait on the dialog)" "took ${elapsed}s"
    fi
    _mock_cleanup
}

# T3.2/T3.3: self-dismiss fires only when secs > 0. A user with no controller
# connected may have no way to dismiss a modal dialog (#125), so the reaper is
# the thing that keeps an undismissable dialog from becoming an unbounded wait.
test_self_dismiss_kills_dialog() {
    _mock_env kdialog
    PATH="$MOCKBIN" mcss_notify_user "T" "body" 1 2>/dev/null
    local pid; pid="$(pgrep -f "$MOCKBIN/kdialog" | head -1)"
    if [[ -z "$pid" ]]; then
        _fail "T3.2 self-dismiss kills the dialog after N seconds" "mock never started"
        _mock_cleanup; return
    fi
    local waited=0
    while (( waited < 40 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1; waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        _fail "T3.2 self-dismiss kills the dialog after N seconds" "still alive after 4s"
    else
        _pass "T3.2 self-dismiss kills the dialog after N seconds"
    fi
    _mock_cleanup
}

test_no_self_dismiss_without_secs() {
    _mock_env kdialog
    PATH="$MOCKBIN" mcss_notify_user "T" "body" 2>/dev/null
    local pid; pid="$(pgrep -f "$MOCKBIN/kdialog" | head -1)"
    if [[ -z "$pid" ]]; then
        _fail "T3.3 no self-dismiss when secs is omitted" "mock never started"
        _mock_cleanup; return
    fi
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        _pass "T3.3 no self-dismiss when secs is omitted"
    else
        _fail "T3.3 no self-dismiss when secs is omitted" "dialog was killed anyway"
    fi
    _mock_cleanup
}

# T3.4: the stderr line must stay ONE line — a multi-line body would otherwise
# break log greps that assume one record per line.
test_stderr_line_is_flattened() {
    _mock_env kdialog
    local err lines
    err=$( { PATH="$MOCKBIN" mcss_notify_user "T" $'line one\nline two\nline three'; } 2>&1 >/dev/null )
    lines="$(grep -c . <<< "$err")"
    _expect "T3.4 multi-line body logs as a single stderr line" "$lines" "1"
    _mock_cleanup
}

run_all_tests() {
    echo "=== preflight.sh / mcss_notify_user ==="
    test_no_notifier_returns_1
    test_no_notifier_still_logs
    test_never_writes_stdout
    test_no_notifier_no_stdout
    test_kdialog_returns_0
    test_kdialog_invoked_with_body
    test_prefers_kdialog_over_zenity
    test_falls_back_to_zenity
    test_does_not_block
    test_self_dismiss_kills_dialog
    test_no_self_dismiss_without_secs
    test_stderr_line_is_flattened
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
