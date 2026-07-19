#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: modules/evsieve_management.sh (dry-run / mock)
# =============================================================================
# Tests the evsieve build-at-install module's constants, installer wiring,
# fail-open control flow, and the SHA-verify / host-verify gates — all
# without network access, real distrobox/podman, or a real git clone (#38
# D4/PR1). See docs (scratchpad) PR1-DESIGN-DELTA.md §g for the test plan
# this file implements (T1-T11).
#
# Mock strategy: an isolated bin dir (real coreutils passed through via
# symlink, git/distrobox/podman/cargo deliberately excluded) is used as
# PATH so toolchain-presence tests are deterministic regardless of what is
# actually installed on the machine running this suite. Tests that need a
# tool "present" add a stub script (or a symlink to the real tool) into
# that same dir. Every stub appends its argv to a $CALLS log so tests can
# assert a tool WAS or WAS NOT invoked. A mktemp -d fake TARGET_DIR
# isolates the binary/stamp. print_* is stubbed locally (utilities.sh is
# never sourced) to capture warnings without printing them.
#
# Run: bash tests/test_evsieve_management.sh
# =============================================================================

readonly TEST_TOTAL=11

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
readonly REPO_ROOT
readonly MODULE="$REPO_ROOT/modules/evsieve_management.sh"

# Known-good constants (mirrors modules/evsieve_management.sh; #38 D4/PR1).
# Duplicated here deliberately: T1 asserts the MODULE's own constants match
# this exact shape/value, so this file cannot just read them back from it.
readonly _PINNED_COMMIT="ebd7efe1ee902e70c5943b65a2bf44b9a3c31eb8"
readonly _ARCHIVE_SHA=\
"118fb0e33d11a4de54621c7d5c562e98f9b00ac07d01a1d7aa9de4951a1bc86d"
readonly _PATCH_SHA=\
"9ec2cd9d50e0ed1eb387379d5baacadd565861c84fa1bbe8a4f800c8db261154"
readonly _WRONG_SHA=\
"0000000000000000000000000000000000000000000000000000000000000000"

# Resolved once, before any test mangles PATH.
_REAL_GIT="$(command -v git)"
readonly _REAL_GIT
_REAL_SHA256SUM="$(command -v sha256sum)"
readonly _REAL_SHA256SUM

TESTS_PASSED=0
TESTS_FAILED=0

# Clean up the shared isolated-bindir base (see _build_isolated_base)
# whenever this suite exits, however it exits.
trap '[[ -n "$_ISOLATED_BASE" ]] && rm -rf "$_ISOLATED_BASE"' EXIT

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# --- Mock helpers ------------------------------------------------------

# _ISOLATED_BASE: lazily-built once, cloned (cheaply) by every
# _isolated_bindir call below instead of re-walking /usr/bin et al. per
# test — walking those dirs 6x in this suite was the whole slow part.
_ISOLATED_BASE=""

# _build_isolated_base: Populate $_ISOLATED_BASE with a passthrough
# symlink farm of every real coreutil (cp/mv/grep/cut/dirname/mktemp/
# timeout/... all keep working) EXCLUDING git/distrobox/podman/cargo/
# sha256sum. sha256sum is excluded (not just git/distrobox/podman/cargo)
# even though it is a plain coreutil: every test that needs it stubs it
# explicitly via _stub_sha256sum, and _write_stub's rm-before-write is
# the real safety net — but excluding it here too means a passthrough
# SYMLINK to the real /usr/bin/sha256sum never exists at this path in the
# first place, belt-and-suspenders against ever writing through a symlink
# into the real system binary again.
_build_isolated_base() {
    [[ -n "$_ISOLATED_BASE" ]] && return 0
    local dir real_dir f name
    dir=$(mktemp -d)
    for real_dir in /usr/bin /bin /usr/sbin /sbin; do
        [[ -d "$real_dir" ]] || continue
        for f in "$real_dir"/*; do
            [[ -e "$f" ]] || continue
            name="$(basename "$f")"
            case "$name" in
                git|distrobox|podman|cargo|sha256sum) continue ;;
            esac
            [[ -e "$dir/$name" ]] && continue
            ln -s "$f" "$dir/$name" 2>/dev/null || true
        done
    done
    _ISOLATED_BASE="$dir"
}

# _isolated_bindir: A fresh bin dir with git/distrobox/podman/cargo/
# sha256sum deliberately ABSENT (see _build_isolated_base). Tests add
# stubs/symlinks for whichever of those they need present.
# Outputs:
#   stdout(data) — path to the new bin dir
_isolated_bindir() {
    _build_isolated_base
    local dir
    dir=$(mktemp -d)
    cp -al "$_ISOLATED_BASE"/. "$dir"/ 2>/dev/null \
        || cp -a "$_ISOLATED_BASE"/. "$dir"/
    echo "$dir"
}

# _write_stub: Write $3 to $1/$2 as an executable file, REMOVING any
# existing entry at that path first. The rm-first step is load-bearing:
# $1/$2 may be a symlink (e.g. from _isolated_bindir's passthrough), and
# `cat > path` on a symlink writes THROUGH it into the symlink's target —
# which, for a tool name pointing at a real system binary, would corrupt
# that real binary in place. `rm -f` first guarantees a plain new file.
# Inputs:
#   $1 — dir, $2 — name, $3 — full script body (already newline-joined)
_write_stub() {
    local dir="$1" name="$2" body="$3"
    rm -f "$dir/$name"
    printf '%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# _placeholder_tool: Write a no-op executable so `command -v $2` succeeds.
_placeholder_tool() {
    _write_stub "$1" "$2" "#!/bin/bash
exit 0"
}

# _write_logging_stub: Write a stub that only logs its invocation to
# $CALLS and exits 0 — used where a tool must be present but the test
# asserts it is NEVER actually called.
_write_logging_stub() {
    local dir="$1" name="$2"
    _write_stub "$dir" "$name" "#!/bin/bash
echo \"$name \$*\" >> \"\$CALLS\"
exit 0"
}

# _stub_git_good: git clone/checkout/apply always succeed; rev-parse
# reports $commit; archive prints dummy bytes (the paired sha256sum stub
# decides whether those bytes "verify").
_stub_git_good() {
    local dir="$1" commit="$2"
    rm -f "$dir/git"
    cat > "$dir/git" <<EOF
#!/bin/bash
echo "git \$*" >> "\$CALLS"
case "\$1" in
    clone)
        dest="\${@: -1}"
        mkdir -p "\$dest"
        exit 0
        ;;
    -C)
        case "\$3" in
            checkout) exit 0 ;;
            rev-parse) echo "$commit"; exit 0 ;;
            archive) echo "stub-archive-bytes"; exit 0 ;;
            apply) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$dir/git"
}

# _stub_sha256sum: file-arg calls (patch verification) pass through to
# the REAL sha256sum (so a real patch file gets a real, correct hash);
# no-arg/stdin calls (the git-archive pipe) return $archive_sha instead —
# lets a test control the archive-verification outcome independent of the
# fake `git archive` bytes.
_stub_sha256sum() {
    local dir="$1" archive_sha="$2"
    rm -f "$dir/sha256sum"
    cat > "$dir/sha256sum" <<EOF
#!/bin/bash
echo "sha256sum \$*" >> "\$CALLS"
if [[ \$# -eq 0 ]]; then
    cat >/dev/null
    echo "$archive_sha  -"
    exit 0
fi
exec "$_REAL_SHA256SUM" "\$@"
EOF
    chmod +x "$dir/sha256sum"
}

# _stub_distrobox_build: list/create/rm are no-ops; enter locates the
# freshly mktemp'd build src dir under $TARGET_DIR (exported) and drops a
# copy of $EVSIEVE_TEST_FAKE_BIN (exported) at target/release/evsieve —
# simulating a successful in-box `cargo build --release` + copy-out
# target without a real toolchain.
_stub_distrobox_build() {
    local dir="$1"
    rm -f "$dir/distrobox"
    cat > "$dir/distrobox" <<'EOF'
#!/bin/bash
echo "distrobox $*" >> "$CALLS"
case "$1" in
    list|create|rm)
        exit 0
        ;;
    enter)
        src_dir=$(ls -d "$TARGET_DIR"/.evsieve-build.*/src \
            2>/dev/null | head -1)
        if [[ -n "$src_dir" ]]; then
            mkdir -p "$src_dir/target/release"
            cp "$EVSIEVE_TEST_FAKE_BIN" "$src_dir/target/release/evsieve"
            chmod +x "$src_dir/target/release/evsieve"
        fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$dir/distrobox"
}

# =============================================================================
# T1 — constant well-formedness
# =============================================================================
test_t1() {
    if (
        TARGET_DIR="$(mktemp -d)"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"

        ok=1
        [[ "$EVSIEVE_PINNED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || ok=0
        [[ "$EVSIEVE_SOURCE_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || ok=0
        [[ "$EVSIEVE_PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]] || ok=0
        [[ "$EVSIEVE_REPO_URL" == *.git ]] || ok=0
        (( ok == 1 ))
    ); then
        _pass "T1 — evsieve constants are well-formed"
    else
        _fail "T1" "one or more EVSIEVE_* constants failed shape checks"
    fi
}

# =============================================================================
# T2 — patch file present + hashes to EVSIEVE_PATCH_SHA256
# =============================================================================
test_t2() {
    local patch="$REPO_ROOT/third_party/evsieve/evsieve-persist-reopen.patch"
    if [[ ! -f "$patch" ]]; then
        _fail "T2" "patch file not found at $patch"
        return
    fi
    local actual
    actual=$(sha256sum "$patch" | cut -d' ' -f1)
    if [[ "$actual" == "$_PATCH_SHA" ]]; then
        _pass "T2 — patch file present and hashes to EVSIEVE_PATCH_SHA256"
    else
        _fail "T2" "SHA mismatch: expected $_PATCH_SHA got $actual"
    fi
}

# =============================================================================
# T3 — module wired into the installer (module list + source line)
# =============================================================================
test_t3() {
    local installer="$REPO_ROOT/install-minecraft-splitscreen.sh"
    local has_entry=0 has_source=0
    grep -A 20 'readonly INSTALLER_MODULE_FILES=' "$installer" \
        | grep -q '"evsieve_management.sh"' && has_entry=1 || true
    grep -q 'source "\$MODULES_DIR/evsieve_management.sh"' "$installer" \
        && has_source=1 || true

    if (( has_entry == 1 && has_source == 1 )); then
        _pass "T3 — evsieve_management.sh wired into module list + sourced"
    else
        _fail "T3" "entry=${has_entry} source_line=${has_source}"
    fi
}

# =============================================================================
# T4 — idempotence skip: matching stamp -> skipped, no tool calls
# =============================================================================
test_t4() {
    local tmp bindir target calls
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir="$tmp/bin"; mkdir -p "$bindir"
    target="$tmp/target"; mkdir -p "$target/bin"
    calls="$tmp/calls.log"; : > "$calls"

    _write_logging_stub "$bindir" git
    _write_logging_stub "$bindir" distrobox

    : > "$target/bin/evsieve"
    chmod +x "$target/bin/evsieve"
    {
        echo "commit=${_PINNED_COMMIT}"
        echo "patch_sha256=${_PATCH_SHA}"
    } > "$target/bin/.evsieve.stamp"

    if (
        export CALLS="$calls"
        export PATH="$bindir:$PATH"
        TARGET_DIR="$target"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"
        install_evsieve
        [[ "$EVSIEVE_INSTALL_STATUS" == "skipped" ]] || exit 1
        [[ ! -s "$calls" ]] || exit 1
    ); then
        _pass "T4 — idempotence: matching stamp -> skipped, no tool calls"
    else
        _fail "T4" "did not skip cleanly, or a tool was invoked (see $calls)"
    fi
}

# =============================================================================
# T5 — fail-open, no distrobox: git present, distrobox/podman absent
# =============================================================================
test_t5() {
    local tmp bindir target warn
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir=$(_isolated_bindir)
    ln -sf "$_REAL_GIT" "$bindir/git"
    target="$tmp/target"; mkdir -p "$target"
    warn="$tmp/warn.log"; : > "$warn"

    if (
        export PATH="$bindir"
        TARGET_DIR="$target"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { echo "$*" >> "$warn"; }
        # shellcheck disable=SC1090
        source "$MODULE"
        rc=0
        install_evsieve || rc=$?
        [[ "$EVSIEVE_INSTALL_STATUS" == "degraded-no-toolchain" ]] \
            || exit 1
        [[ "$rc" -eq 0 ]] || exit 1
        [[ -s "$warn" ]] || exit 1
        [[ ! -e "$target/bin/evsieve" ]] || exit 1
    ); then
        _pass "T5 — fail-open: no distrobox/podman -> degraded-no-toolchain"
    else
        _fail "T5" "unexpected status/behavior (see $tmp)"
    fi
}

# =============================================================================
# T6 — fail-open, no git: distrobox+podman present, git absent
# =============================================================================
test_t6() {
    local tmp bindir target
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir=$(_isolated_bindir)
    _placeholder_tool "$bindir" podman
    _placeholder_tool "$bindir" distrobox
    target="$tmp/target"; mkdir -p "$target"

    if (
        export PATH="$bindir"
        TARGET_DIR="$target"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"
        install_evsieve
        [[ "$EVSIEVE_INSTALL_STATUS" == "degraded-no-toolchain" ]]
    ); then
        _pass "T6 — fail-open: no git -> degraded-no-toolchain"
    else
        _fail "T6" "expected degraded-no-toolchain with git missing"
    fi
}

# =============================================================================
# T7 — SHA-mismatch refusal: never builds unverified source
# =============================================================================
test_t7() {
    local tmp bindir target calls
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir=$(_isolated_bindir)
    target="$tmp/target"; mkdir -p "$target"
    calls="$tmp/calls.log"; : > "$calls"

    _stub_git_good "$bindir" "$_PINNED_COMMIT"
    _stub_sha256sum "$bindir" "$_WRONG_SHA"
    _write_logging_stub "$bindir" distrobox
    _placeholder_tool "$bindir" podman

    if (
        export CALLS="$calls"
        export PATH="$bindir"
        TARGET_DIR="$target"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"
        install_evsieve
        [[ "$EVSIEVE_INSTALL_STATUS" == "degraded-verify-failed" ]] \
            || exit 1
        grep -q '^distrobox ' "$calls" && exit 1
        [[ ! -e "$target/bin/evsieve" ]] || exit 1
        exit 0
    ); then
        _pass "T7 — archive SHA mismatch -> degraded-verify-failed, no build"
    else
        _fail "T7" "unexpected status, or distrobox was invoked (see $calls)"
    fi
}

# =============================================================================
# T8 — stale stamp bypasses skip and re-enters the build path
# =============================================================================
test_t8() {
    local tmp bindir target
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir=$(_isolated_bindir)
    target="$tmp/target"; mkdir -p "$target/bin"
    : > "$target/bin/evsieve"
    chmod +x "$target/bin/evsieve"
    {
        echo "commit=0000000000000000000000000000000000000000"
        echo "patch_sha256=${_PATCH_SHA}"
    } > "$target/bin/.evsieve.stamp"

    if (
        export PATH="$bindir"
        TARGET_DIR="$target"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"
        install_evsieve
        [[ "$EVSIEVE_INSTALL_STATUS" == "degraded-no-toolchain" ]]
    ); then
        _pass "T8 — stale-commit stamp is NOT skipped, re-enters build path"
    else
        _fail "T8" "stale stamp did not trigger a rebuild attempt"
    fi
}

# =============================================================================
# T9 — main_workflow.sh calls install_evsieve after install_runtime_modules
# =============================================================================
test_t9() {
    local workflow="$REPO_ROOT/modules/main_workflow.sh"
    local runtime_line evsieve_line
    runtime_line=$(grep -n 'install_runtime_modules' "$workflow" \
        | head -1 | cut -d: -f1)
    evsieve_line=$(grep -n 'install_evsieve' "$workflow" \
        | head -1 | cut -d: -f1)

    if [[ -z "$runtime_line" ]]; then
        _fail "T9" "install_runtime_modules not found in main_workflow.sh"
        return
    fi
    if [[ -z "$evsieve_line" ]]; then
        _fail "T9" "install_evsieve not called in main_workflow.sh"
        return
    fi

    if (( evsieve_line > runtime_line )); then
        _pass "T9 — install_evsieve called after install_runtime_modules"
    else
        local msg="install_evsieve (L${evsieve_line}) appears before"
        msg+=" install_runtime_modules (L${runtime_line})"
        _fail "T9" "$msg"
    fi
}

# =============================================================================
# T10 — fail-open return contract: install_evsieve always returns 0
# =============================================================================
test_t10() {
    local tmp bindir target rc
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir=$(_isolated_bindir)
    target="$tmp/target"; mkdir -p "$target"

    rc=$(
        PATH="$bindir"
        TARGET_DIR="$target"
        SCRIPT_DIR="$REPO_ROOT"
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"
        install_evsieve
        echo $?
    )
    if [[ "$rc" == "0" ]]; then
        _pass "T10 — install_evsieve returns 0 with no toolchain at all"
    else
        _fail "T10" "install_evsieve returned $rc, expected 0"
    fi
}

# =============================================================================
# T11 — host-exec gate precedes stamping: no premature stamp
# =============================================================================
test_t11() {
    local tmp bindir target calls fake_bin
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    bindir=$(_isolated_bindir)
    target="$tmp/target"; mkdir -p "$target"
    calls="$tmp/calls.log"; : > "$calls"
    fake_bin="$tmp/fake-evsieve"
    printf '#!/bin/bash\nexit 1\n' > "$fake_bin"
    chmod +x "$fake_bin"

    _stub_git_good "$bindir" "$_PINNED_COMMIT"
    _stub_sha256sum "$bindir" "$_ARCHIVE_SHA"
    _stub_distrobox_build "$bindir"
    _placeholder_tool "$bindir" podman

    if (
        export CALLS="$calls"
        export PATH="$bindir"
        export TARGET_DIR="$target"
        export EVSIEVE_TEST_FAKE_BIN="$fake_bin"
        # shellcheck disable=SC2034  # read by the sourced module, below.
        SCRIPT_DIR="$REPO_ROOT"
        # shellcheck disable=SC2034  # read by the sourced module, below.
        MCSS_REPO_RAW_URL="https://example.invalid/repo"
        print_header() { :; }
        print_progress() { :; }
        print_success() { :; }
        print_warning() { :; }
        # shellcheck disable=SC1090
        source "$MODULE"
        install_evsieve
        [[ "$EVSIEVE_INSTALL_STATUS" == "degraded-host-exec" ]] || exit 1
        [[ ! -e "$target/bin/.evsieve.stamp" ]] || exit 1
        exit 0
    ); then
        _pass "T11 — host-exec fails -> degraded-host-exec, no stamp"
    else
        _fail "T11" "expected degraded-host-exec with no stamp file (see $tmp)"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== evsieve_management test suite ==="
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
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
