#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: _home_bwrap_bind_args (#199)
# =============================================================================
# #199: bwrap aborts every spawn on Bazzite with "Can't mount on symlink
# destination /home", because Bazzite (Fedora Silverblue/Kinoite ostree
# convention) makes /home a symlink to /var/home, not a real mount point —
# unlike the Deck, where /home is its own real partition. _home_bwrap_bind_args
# binds the resolved real target and recreates the /home symlink inside the
# sandbox when the path is a symlink, and falls back to the original plain
# bind (unchanged Deck behavior) otherwise.
#
# _home_bwrap_bind_args is pure (stdout only, no side effects) and takes the
# path to check as an argument specifically so this suite can point it at a
# fake symlink/directory pair under a temp dir instead of touching the real
# /home — safe to run anywhere, including LXC 105 (no processes spawned).
#
# Run: bash tests/test_home_bwrap_bind.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

FAILURES=0
PASSES=0
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "[FAIL] $desc — expected to find: $needle" >&2
        echo "  --- actual ---" >&2
        echo "$haystack" | sed 's/^/  /' >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
        PASSES=$((PASSES + 1))
    fi
}
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "[FAIL] $desc — did not expect to find: $needle" >&2
        echo "  --- actual ---" >&2
        echo "$haystack" | sed 's/^/  /' >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
        PASSES=$((PASSES + 1))
    fi
}
assert_word_count() {
    local desc="$1" haystack="$2" expected="$3"
    local actual
    actual=$(wc -w <<<"$haystack" | tr -d ' ')
    if [[ "$actual" != "$expected" ]]; then
        echo "[FAIL] $desc — expected $expected words, got $actual" >&2
        echo "  --- actual ---" >&2
        echo "$haystack" | sed 's/^/  /' >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
        PASSES=$((PASSES + 1))
    fi
}

# shellcheck source=/dev/null
source "$REPO_ROOT/minecraftSplitscreen.sh"

if ! declare -f _home_bwrap_bind_args >/dev/null 2>&1; then
    echo "[FAIL] _home_bwrap_bind_args not defined after sourcing minecraftSplitscreen.sh" >&2
    exit 1
fi

_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR"' EXIT

# --- Case 1: real directory (Deck-style /home) — plain single bind ---------
_real_dir="$_TMPDIR/real_home"
mkdir -p "$_real_dir"
out="$(_home_bwrap_bind_args "$_real_dir")"
assert_contains   "real dir: plain dev-bind" "$out" "--dev-bind $_real_dir $_real_dir"
assert_not_contains "real dir: no --symlink"  "$out" "--symlink"
assert_word_count "real dir: exactly 3 words (flag src dst)" "$out" 3

# --- Case 2: symlink (Bazzite-style /home -> var/home) ----------------------
_target_dir="$_TMPDIR/var_home"
mkdir -p "$_target_dir"
_symlink_path="$_TMPDIR/home_link"
ln -s "$_target_dir" "$_symlink_path"
out="$(_home_bwrap_bind_args "$_symlink_path")"
assert_contains "symlink: dev-binds the RESOLVED real target, not the symlink path" \
    "$out" "--dev-bind $_target_dir $_target_dir"
assert_contains "symlink: recreates the symlink pointing at the real target" \
    "$out" "--symlink $_target_dir $_symlink_path"
assert_not_contains "symlink: does not dev-bind the symlink path itself" \
    "$out" "--dev-bind $_symlink_path"
assert_word_count "symlink: exactly 6 words (2 flags x 3)" "$out" 6

# --- Case 3: default argument is /home --------------------------------------
# Just confirm it doesn't error and falls into one of the two known shapes —
# the real system's /home may or may not be a symlink depending on the host.
out="$(_home_bwrap_bind_args)"
assert_contains "no-arg default targets /home" "$out" "/home"

echo
# Standard summary footer — the line .github/workflows/ci.yml parses for every
# suite (X/Y tests passed.); exit status is the gate.
echo "$PASSES/$((PASSES + FAILURES)) tests passed."
if (( FAILURES == 0 )); then
    exit 0
else
    exit 1
fi
