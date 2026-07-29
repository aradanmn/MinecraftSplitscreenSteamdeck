#!/bin/bash
set -uo pipefail

# =============================================================================
# Test Suite: modules/version_stamp.sh (#89)
# =============================================================================
# The launcher's build-provenance stamp format used to be encoded three times —
# the forward sed in launcher_setup.sh AND deploy.sh, the inverse only in
# deploy.sh. A format change would have silently broken `deploy.sh --check`
# freshness detection while both writers still appeared to work. These tests
# pin the round trip that makes that impossible.
#
# No hardware, no install, no git repo required (the resolve tests deliberately
# run against a non-repo directory to exercise the degraded paths).
#
# Run: bash tests/test_version_stamp.sh
# =============================================================================

readonly TEST_TOTAL=15

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/modules/version_stamp.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TMPDIR_TEST=""

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

_expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then _pass "$name"
    else _fail "$name" "expected '$expected', got '$actual'"; fi
}

_setup() { TMPDIR_TEST="$(mktemp -d)"; }
_teardown() { [[ -n "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"; TMPDIR_TEST=""; }
trap _teardown EXIT

# _fixture_launcher: a minimal stand-in for minecraftSplitscreen.sh carrying the
# three placeholders in their real assignment form.
_fixture_launcher() {
    cat > "$TMPDIR_TEST/launcher.sh" <<'EOF'
#!/bin/bash
MCSS_VERSION="__MCSS_VERSION__"
MCSS_COMMIT="__MCSS_COMMIT__"
MCSS_BUILD_DATE="__MCSS_BUILD_DATE__"
echo body line that must never change
EOF
    echo "$TMPDIR_TEST/launcher.sh"
}

# --- T1: mcss_stamp_apply ----------------------------------------------------

test_apply_replaces_all_three() {
    _setup; local f; f="$(_fixture_launcher)"
    mcss_stamp_apply "$f" "1.2.3" "abc1234" "2026-07-29T12:00:00+00:00"
    local got; got="$(grep -cE '__MCSS_(VERSION|COMMIT|BUILD_DATE)__' "$f")"
    _expect "T1.1 no placeholders survive" "$got" "0"
    _teardown
}

test_apply_writes_values() {
    _setup; local f; f="$(_fixture_launcher)"
    mcss_stamp_apply "$f" "1.2.3" "abc1234" "2026-07-29T12:00:00+00:00"
    local v c d
    v="$(grep -m1 '^MCSS_VERSION=' "$f")"
    c="$(grep -m1 '^MCSS_COMMIT=' "$f")"
    d="$(grep -m1 '^MCSS_BUILD_DATE=' "$f")"
    if [[ "$v" == *1.2.3* && "$c" == *abc1234* && "$d" == *"2026-07-29T12:00:00+00:00"* ]]; then
        _pass "T1.2 all three values land in their own assignment"
    else
        _fail "T1.2 all three values land in their own assignment" "$v / $c / $d"
    fi
    _teardown
}

# T1.3: the date carries `+` and `:`, which is why its expression uses `|` as the
# sed delimiter. A date containing `/` would break a `/`-delimited expression.
test_apply_handles_slash_in_date() {
    _setup; local f; f="$(_fixture_launcher)"
    mcss_stamp_apply "$f" "1.0" "abc" "2026/07/29 12:00"
    local d; d="$(grep -m1 '^MCSS_BUILD_DATE=' "$f")"
    _expect "T1.3 a date containing slashes still stamps" \
        "$d" 'MCSS_BUILD_DATE="2026/07/29 12:00"'
    _teardown
}

test_apply_body_untouched() {
    _setup; local f; f="$(_fixture_launcher)"
    mcss_stamp_apply "$f" "1.0" "abc" "now"
    local got; got="$(grep -c 'body line that must never change' "$f")"
    _expect "T1.4 non-stamp lines are untouched" "$got" "1"
    _teardown
}

test_apply_missing_file_returns_1() {
    _setup
    local rc=0
    mcss_stamp_apply "$TMPDIR_TEST/nope.sh" "1" "2" "3" || rc=$?
    _expect "T1.5 missing file returns 1" "$rc" "1"
    _teardown
}

# T1.6: callers log their own wording, so this must stay silent on stdout —
# launcher_setup wraps it in print_info/print_warning.
test_apply_silent_on_stdout() {
    _setup; local f out; f="$(_fixture_launcher)"
    out="$(mcss_stamp_apply "$f" "1.0" "abc" "now" 2>/dev/null)"
    _expect "T1.6 writes nothing to stdout" "$out" ""
    _teardown
}

# --- T2: mcss_stamp_normalize ------------------------------------------------

test_normalize_restores_placeholders() {
    _setup; local f; f="$(_fixture_launcher)"
    mcss_stamp_apply "$f" "9.9.9" "cafe123" "2026-01-01T00:00:00+00:00"
    local got; got="$(mcss_stamp_normalize "$f" | grep -cE '__MCSS_(VERSION|COMMIT|BUILD_DATE)__')"
    _expect "T2.1 all three assignments normalize back" "$got" "3"
    _teardown
}

test_normalize_does_not_modify_file() {
    _setup; local f; f="$(_fixture_launcher)"
    mcss_stamp_apply "$f" "9.9.9" "cafe123" "now"
    local before; before="$(md5sum < "$f")"
    mcss_stamp_normalize "$f" >/dev/null
    local after; after="$(md5sum < "$f")"
    _expect "T2.2 normalize is read-only" "$after" "$before"
    _teardown
}

# T2.3 IS THE POINT OF THIS MODULE: a stamped tree and a placeholder checkout
# must compare equal once both sides are normalized. This is what deploy.sh
# --check relies on, and the property the old three-way duplication could break
# while both writers still looked fine.
test_round_trip_compares_equal() {
    _setup
    local pristine stamped
    pristine="$(_fixture_launcher)"; cp "$pristine" "$TMPDIR_TEST/pristine.sh"
    stamped="$TMPDIR_TEST/stamped.sh"; cp "$pristine" "$stamped"
    mcss_stamp_apply "$stamped" "1.2.3" "abc1234+dirty" "2026-07-29T12:00:00+00:00"
    if cmp -s <(mcss_stamp_normalize "$TMPDIR_TEST/pristine.sh") \
              <(mcss_stamp_normalize "$stamped"); then
        _pass "T2.3 stamped and pristine compare equal after normalization"
    else
        _fail "T2.3 stamped and pristine compare equal after normalization" \
            "normalized forms differ"
    fi
    _teardown
}

# T2.4: two DIFFERENT stamps of identical code must also compare equal — this is
# the "an older deploy is not drift" case from deploy.sh's header.
test_two_different_stamps_compare_equal() {
    _setup
    local a b
    a="$TMPDIR_TEST/a.sh"; b="$TMPDIR_TEST/b.sh"
    _fixture_launcher >/dev/null; cp "$TMPDIR_TEST/launcher.sh" "$a"
    cp "$TMPDIR_TEST/launcher.sh" "$b"
    mcss_stamp_apply "$a" "1.0" "aaaaaaa" "2020-01-01T00:00:00+00:00"
    mcss_stamp_apply "$b" "2.0" "bbbbbbb" "2026-07-29T23:00:00+00:00"
    if cmp -s <(mcss_stamp_normalize "$a") <(mcss_stamp_normalize "$b"); then
        _pass "T2.4 two different stamps of identical code compare equal"
    else
        _fail "T2.4 two different stamps of identical code compare equal" "differ"
    fi
    _teardown
}

# T2.5: but a real code change must NOT be hidden by normalization.
test_body_change_still_differs() {
    _setup
    local a b
    a="$TMPDIR_TEST/a.sh"; b="$TMPDIR_TEST/b.sh"
    _fixture_launcher >/dev/null; cp "$TMPDIR_TEST/launcher.sh" "$a"
    cp "$TMPDIR_TEST/launcher.sh" "$b"
    mcss_stamp_apply "$a" "1.0" "aaaaaaa" "now"
    mcss_stamp_apply "$b" "1.0" "aaaaaaa" "now"
    echo "# a real code change" >> "$b"
    if cmp -s <(mcss_stamp_normalize "$a") <(mcss_stamp_normalize "$b"); then
        _fail "T2.5 a real body change is still detected" "normalization hid it"
    else
        _pass "T2.5 a real body change is still detected"
    fi
    _teardown
}

# --- T3: mcss_stamp_resolve --------------------------------------------------

test_resolve_emits_three_tab_fields() {
    _setup
    local out n
    out="$(mcss_stamp_resolve "$TMPDIR_TEST")"
    n="$(awk -F'\t' '{print NF}' <<< "$out")"
    _expect "T3.1 resolve emits 3 tab-separated fields" "$n" "3"
    _teardown
}

# T3.2: no VERSION file and no git repo -> degrade to literals, never fail. An
# install must not abort because provenance is unavailable (PRINCIPLES #5).
test_resolve_degrades_without_version_or_git() {
    _setup
    local v c
    IFS=$'\t' read -r v c _ < <(mcss_stamp_resolve "$TMPDIR_TEST")
    if [[ "$v" == "dev" && "$c" == "unknown" ]]; then
        _pass "T3.2 degrades to dev/unknown with no VERSION and no git"
    else
        _fail "T3.2 degrades to dev/unknown with no VERSION and no git" "v=$v c=$c"
    fi
    _teardown
}

test_resolve_reads_version_file() {
    _setup
    echo "4.5.6" > "$TMPDIR_TEST/VERSION"
    local v
    IFS=$'\t' read -r v _ _ < <(mcss_stamp_resolve "$TMPDIR_TEST")
    _expect "T3.3 reads VERSION from the checkout" "$v" "4.5.6"
    _teardown
}

# T3.4: mark_dirty is the ONE divergence between the installer and deploy.sh,
# carried by parameter rather than by a second copy. Without the flag the commit
# must never gain the marker.
test_resolve_no_dirty_marker_without_flag() {
    _setup
    local c
    IFS=$'\t' read -r _ c _ < <(mcss_stamp_resolve "$REPO_ROOT")
    if [[ "$c" != *"+dirty"* ]]; then
        _pass "T3.4 omitting mark_dirty never adds the marker"
    else
        _fail "T3.4 omitting mark_dirty never adds the marker" "got '$c'"
    fi
    _teardown
}

run_all_tests() {
    echo "=== version_stamp.sh ==="
    test_apply_replaces_all_three
    test_apply_writes_values
    test_apply_handles_slash_in_date
    test_apply_body_untouched
    test_apply_missing_file_returns_1
    test_apply_silent_on_stdout
    test_normalize_restores_placeholders
    test_normalize_does_not_modify_file
    test_round_trip_compares_equal
    test_two_different_stamps_compare_equal
    test_body_change_still_differs
    test_resolve_emits_three_tab_fields
    test_resolve_degrades_without_version_or_git
    test_resolve_reads_version_file
    test_resolve_no_dirty_marker_without_flag
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
