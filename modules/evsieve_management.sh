#!/bin/bash
# =============================================================================
# EVSIEVE MANAGEMENT MODULE
# =============================================================================
# Build-at-install of a pinned, patched evsieve (#38 D4). Clones the pinned
# upstream commit, verifies it two ways (rev-parse + git-archive SHA-256),
# SHA-verifies and applies our GPL-2.0 bounded-retry patch, then
# `cargo build --release` inside a debian:12 distrobox and installs the
# binary under $TARGET_DIR/bin. Every failure path is FAIL-OPEN: the v1.1
# install is never harmed and the v1.2 controller-proxy feature simply
# stays unavailable (it is OFF by default anyway).
#
# Public API:
#   install_evsieve()   — exit 0 ALWAYS (fail-open, §D6); sets
#                         EVSIEVE_INSTALL_STATUS; installs
#                         $TARGET_DIR/bin/evsieve + stamp on success
#
# (Internal: _evsieve_bin, _evsieve_stamp, _evsieve_stamp_matches,
#  _evsieve_check_toolchain, _evsieve_acquire_source, _evsieve_resolve_patch,
#  _evsieve_apply_patch, _evsieve_ensure_box, _evsieve_build_in_box,
#  _evsieve_install_binary, _evsieve_host_verify, _evsieve_write_stamp,
#  _evsieve_degrade.)
#
# Globals CONSUMED (set elsewhere, read here):
#   TARGET_DIR         — install root; binary lands in $TARGET_DIR/bin
#   SCRIPT_DIR         — local-checkout root (for the in-repo patch)
#   MCSS_REPO_RAW_URL  — raw-content base for the curl|bash patch fetch
#
# Globals PROVIDED (set here, read elsewhere):
#   EVSIEVE_INSTALL_STATUS  — outcome token for tests/UX (values below)
#   EVSIEVE_* readonly constants (pin, SHAs, box name/image, timeouts)
#
# Inputs:  github.com/KarsMulder/evsieve.git (git clone at a pinned commit);
#          third_party/evsieve/evsieve-persist-reopen.patch (local or raw);
#          podman/distrobox (debian:12 container) for the toolchain.
# Outputs: print_* progress/status to stdout/stderr; $TARGET_DIR/bin/evsieve
#          + $TARGET_DIR/bin/.evsieve.stamp on success.
#
# Environment overrides (for testing):
#   EVSIEVE_DISTROBOX_NAME   — override the build-box name
#   EVSIEVE_SKIP_BUILD       — (tests) never invoked; stubs live on PATH
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-07-19  #38 D4/PR1: build-at-install evsieve, GPL-clean,
#                    fail-open
# =============================================================================

# --- Module-level constants ---
# Guarded (house pattern from runtime_context.sh's _MCSS_CONSTANTS_LOCKED):
# modules are re-sourceable within one process, so an unguarded readonly
# would abort on the second source.
if [[ -z "${_EVSIEVE_CONSTANTS_LOCKED:-}" ]]; then

    # Pinned upstream source (#38 D4). v1.4.0 + master fixes. Acquisition is
    # `git clone` + `git checkout <commit>` — NOT a codeload tarball: GitHub
    # archive tarballs are gzip-layer nondeterministic (2023 checksum-breakage
    # incident), so a hardcoded tarball SHA is fragile. Instead we verify
    # rev-parse AND the SHA-256 of the DETERMINISTIC `git archive` byte stream,
    # which reproduces identically on any machine.
    readonly EVSIEVE_REPO_URL="https://github.com/KarsMulder/evsieve.git"
    readonly EVSIEVE_PINNED_COMMIT="ebd7efe1ee902e70c5943b65a2bf44b9a3c31eb8"
    readonly EVSIEVE_SOURCE_ARCHIVE_SHA256=\
"118fb0e33d11a4de54621c7d5c562e98f9b00ac07d01a1d7aa9de4951a1bc86d"

    # Our ~35-line GPL-2.0 bounded-retry patch. Canonical home is the GPL
    # island; SHA-verified before use (local checkout OR curl|bash raw fetch).
    readonly EVSIEVE_PATCH_REPO_PATH=\
"third_party/evsieve/evsieve-persist-reopen.patch"
    readonly EVSIEVE_PATCH_SHA256=\
"9ec2cd9d50e0ed1eb387379d5baacadd565861c84fa1bbe8a4f800c8db261154"

    # Deterministic debian:12 build box; created by the module if missing.
    readonly EVSIEVE_DISTROBOX_NAME=\
"${EVSIEVE_DISTROBOX_NAME:-mcss-evsieve-build}"
    readonly EVSIEVE_DISTROBOX_IMAGE="debian:12"

    # Timeouts (units in name, STYLE-GUIDE §6). Box create pulls an image;
    # cargo build of evsieve is the long pole.
    readonly EVSIEVE_BOX_CREATE_TIMEOUT_S=300
    readonly EVSIEVE_BUILD_TIMEOUT_S=900

    # The house fail-open wording (#38 D6), shared by every degrade site so the
    # message is worded identically no matter which step failed.
    readonly EVSIEVE_FAIL_OPEN_NOTE="seamless controller reconnect \
unavailable (v1.2 proxy feature stays OFF); your v1.1 install is \
unaffected."
    _EVSIEVE_CONSTANTS_LOCKED=1   # process-local — NOT exported
fi

# EVSIEVE_INSTALL_STATUS: module-provided mutable global, set by
# install_evsieve(). Exactly one of these lowercase tokens after the call
# returns:
#   installed              — freshly built, verified, binary written
#   skipped                — good stamp + executable binary → no-op
#   degraded-no-toolchain  — git/podman/distrobox missing → fail-open
#   degraded-verify-failed — commit/archive/patch SHA mismatch → refuse
#   degraded-build-failed  — box-create/apt/cargo/copy-out failure
#   degraded-host-exec     — built binary won't run on the host
EVSIEVE_INSTALL_STATUS=""

# --- Internal functions ---

# _evsieve_bin: Return the installed evsieve binary path.
# TWO HOMES, DOCUMENTED PAIRING (PLAN Part 4): this INSTALL-TIME path pairs
# with the FUTURE runtime home runtime_context.sh:MCSS_EVSIEVE_BIN
# (default $MCSS_LAUNCHER_ROOT/bin/evsieve, lands in PR2). $TARGET_DIR
# defaults to $HOME/.local/share/PolyMC == the MCSS_LAUNCHER_ROOT default,
# so the two resolve to the SAME path. When you change one, grep
# MCSS_EVSIEVE_BIN in runtime_context.sh and change both. #38 D4.
# Outputs:
#   stdout(data) — the evsieve binary path
#   return — 0
_evsieve_bin() {
    echo "${TARGET_DIR:-$HOME/.local/share/PolyMC}/bin/evsieve"
}

# _evsieve_stamp: Return the install stamp path — records the pinned
# commit + patch SHA that produced the currently installed binary.
# Outputs:
#   stdout(data) — $(dirname "$(_evsieve_bin)")/.evsieve.stamp
#   return — 0
_evsieve_stamp() {
    echo "$(dirname "$(_evsieve_bin)")/.evsieve.stamp"
}

# _evsieve_stamp_matches: Is a good stamp present for the pinned commit?
# Inputs:
#   Globals: EVSIEVE_PINNED_COMMIT, EVSIEVE_PATCH_SHA256 (read); reads the
#            _evsieve_stamp file
# Outputs:
#   return — 0 iff the stamp's commit= and patch_sha256= lines equal the
#            pinned constants AND _evsieve_bin is executable; else 1
_evsieve_stamp_matches() {
    local stamp bin
    bin="$(_evsieve_bin)"
    stamp="$(_evsieve_stamp)"

    [[ -x "$bin" ]] || return 1
    [[ -f "$stamp" ]] || return 1

    local commit patch_sha
    commit=$(grep -m1 '^commit=' "$stamp" | cut -d= -f2)
    patch_sha=$(grep -m1 '^patch_sha256=' "$stamp" | cut -d= -f2)

    [[ "$commit" == "$EVSIEVE_PINNED_COMMIT" ]] || return 1
    [[ "$patch_sha" == "$EVSIEVE_PATCH_SHA256" ]] || return 1
    return 0
}

# _evsieve_check_toolchain: Is the build toolchain present?
# We ASSUME nothing is present — a missing tool degrades, it never errors.
# Outputs:
#   return — 0 iff git, podman, distrobox are all on PATH; else 1
_evsieve_check_toolchain() {
    command -v git >/dev/null 2>&1 || return 1
    command -v podman >/dev/null 2>&1 || return 1
    command -v distrobox >/dev/null 2>&1 || return 1
    return 0
}

# _evsieve_acquire_source: Clone the pinned upstream commit and verify it
# two ways (rev-parse + the deterministic git-archive SHA-256).
# Inputs:
#   $1 — dest_dir: directory to clone into (must not already exist)
#   Globals: EVSIEVE_REPO_URL, EVSIEVE_PINNED_COMMIT,
#            EVSIEVE_SOURCE_ARCHIVE_SHA256 (read)
# Outputs:
#   return — 0 iff clone + checkout + both verifications pass; 1 on any
#            clone/checkout/mismatch failure
#   side effects — writes into dest_dir
_evsieve_acquire_source() {
    local dest_dir="$1"

    git clone --no-checkout "$EVSIEVE_REPO_URL" "$dest_dir" \
        >/dev/null 2>&1 || return 1
    git -C "$dest_dir" checkout "$EVSIEVE_PINNED_COMMIT" \
        >/dev/null 2>&1 || return 1

    local actual_commit
    actual_commit=$(git -C "$dest_dir" rev-parse HEAD 2>/dev/null)
    [[ "$actual_commit" == "$EVSIEVE_PINNED_COMMIT" ]] || return 1

    local actual_archive_sha
    actual_archive_sha=$(git -C "$dest_dir" archive --format=tar \
        "$EVSIEVE_PINNED_COMMIT" 2>/dev/null | sha256sum | cut -d' ' -f1)
    [[ "$actual_archive_sha" == "$EVSIEVE_SOURCE_ARCHIVE_SHA256" ]] \
        || return 1

    return 0
}

# _evsieve_resolve_patch: Obtain and SHA-verify the persist-reopen patch.
# Prefers the local checkout's copy (installer run from a git checkout);
# falls back to a curl|bash raw fetch (no-checkout installs) via
# fetch_url. Never trusts an unverified patch — a mismatch is a hard
# refusal, not a build with unverified source.
# Inputs:
#   $1 — dest_file: path to write the resolved patch to
#   Globals: SCRIPT_DIR, MCSS_REPO_RAW_URL, EVSIEVE_PATCH_REPO_PATH,
#            EVSIEVE_PATCH_SHA256 (read)
# Outputs:
#   return — 0 iff a patch was obtained AND its SHA-256 matches
#            EVSIEVE_PATCH_SHA256; 1 otherwise
#   side effects — writes dest_file
_evsieve_resolve_patch() {
    local dest_file="$1"
    local local_patch="$SCRIPT_DIR/$EVSIEVE_PATCH_REPO_PATH"

    if [[ -f "$local_patch" ]]; then
        cp "$local_patch" "$dest_file" 2>/dev/null || return 1
    else
        fetch_url "$MCSS_REPO_RAW_URL/$EVSIEVE_PATCH_REPO_PATH" \
            "$dest_file" >/dev/null 2>&1 || return 1
    fi

    [[ -f "$dest_file" ]] || return 1

    local actual_sha
    actual_sha=$(sha256sum "$dest_file" | cut -d' ' -f1)
    [[ "$actual_sha" == "$EVSIEVE_PATCH_SHA256" ]] || return 1
    return 0
}

# _evsieve_apply_patch: Apply the SHA-verified patch to the cloned source.
# Inputs:
#   $1 — src_dir: the cloned+checked-out evsieve source tree
#   $2 — patch_file: the SHA-verified patch (from _evsieve_resolve_patch)
# Outputs:
#   return — 0 iff `git apply --check` then `git apply` both succeed;
#            1 otherwise
#   side effects — modifies files under src_dir
_evsieve_apply_patch() {
    local src_dir="$1" patch_file="$2"

    git -C "$src_dir" apply --check "$patch_file" >/dev/null 2>&1 \
        || return 1
    git -C "$src_dir" apply "$patch_file" >/dev/null 2>&1 || return 1
    return 0
}

# _evsieve_ensure_box: Create the build box if missing; heal a broken one.
# A box that `distrobox list`s but fails a cheap `-- true` probe is
# treated as broken (e.g. left behind by an interrupted earlier create) —
# removed and recreated ONCE; a second failure is bounded to
# degraded-build-failed by the caller.
# Inputs:
#   Globals: EVSIEVE_DISTROBOX_NAME, EVSIEVE_DISTROBOX_IMAGE,
#            EVSIEVE_BOX_CREATE_TIMEOUT_S (read)
# Outputs:
#   return — 0 iff the box exists and is usable after this call; 1
#            otherwise
#   side effects — may create/remove/recreate the distrobox
_evsieve_ensure_box() {
    if ! distrobox list 2>/dev/null \
        | grep -q "[[:space:]]${EVSIEVE_DISTROBOX_NAME}[[:space:]]"; then
        timeout "$EVSIEVE_BOX_CREATE_TIMEOUT_S" distrobox create --yes \
            --name "$EVSIEVE_DISTROBOX_NAME" \
            --image "$EVSIEVE_DISTROBOX_IMAGE" >/dev/null 2>&1 || return 1
        return 0
    fi

    if distrobox enter --name "$EVSIEVE_DISTROBOX_NAME" -- true \
        >/dev/null 2>&1; then
        return 0
    fi

    # Broken box (e.g. an interrupted earlier create): heal ONCE.
    distrobox rm -f "$EVSIEVE_DISTROBOX_NAME" >/dev/null 2>&1 || true
    timeout "$EVSIEVE_BOX_CREATE_TIMEOUT_S" distrobox create --yes \
        --name "$EVSIEVE_DISTROBOX_NAME" \
        --image "$EVSIEVE_DISTROBOX_IMAGE" >/dev/null 2>&1 || return 1
    return 0
}

# _evsieve_build_in_box: Build evsieve inside the debian:12 box.
# libevdev-dev is mandatory (empirically proven, PR1 design delta §e):
# evsieve's build.rs unconditionally links dylib=evdev with no
# pkg-config probe and no feature-gate, so the link dies without it.
# Inputs:
#   $1 — src_dir: the patched source tree (must be under $TARGET_DIR /
#        $HOME so distrobox's default HOME share makes it visible inside
#        the box at the SAME absolute path, no extra --volume needed)
#   Globals: EVSIEVE_DISTROBOX_NAME, EVSIEVE_BUILD_TIMEOUT_S (read)
# Outputs:
#   return — 0 on a successful `cargo build --release`; 1 otherwise
#   side effects — writes src_dir/target/release/evsieve inside the box
#                  (visible on the host via the HOME share)
_evsieve_build_in_box() {
    local src_dir="$1"

    timeout "$EVSIEVE_BUILD_TIMEOUT_S" distrobox enter \
        --name "$EVSIEVE_DISTROBOX_NAME" -- sh -c '
            set -e
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update
            sudo apt-get install -y --no-install-recommends \
                git cargo libevdev-dev
            cd "'"$src_dir"'"
            cargo build --release
        ' >/dev/null 2>&1
}

# _evsieve_install_binary: Atomically copy the built binary into place.
# Copy-out only — the host-exec gate and stamp are separate steps (see
# _evsieve_host_verify, _evsieve_write_stamp), so a binary that copies but
# won't run on the host is diagnosed distinctly from a build failure.
# Inputs:
#   $1 — src_dir: the built source tree (src_dir/target/release/evsieve
#        must exist)
# Outputs:
#   return — 0 on a successful atomic install; 1 otherwise
#   side effects — tmp file + mv into $(dirname "$(_evsieve_bin)")
_evsieve_install_binary() {
    local src_dir="$1"
    local built_bin="$src_dir/target/release/evsieve"
    local bin_dir bin_path tmp_path

    [[ -x "$built_bin" ]] || return 1

    bin_path="$(_evsieve_bin)"
    bin_dir="$(dirname "$bin_path")"
    mkdir -p "$bin_dir" || return 1

    tmp_path="${bin_path}.tmp.$$"
    cp "$built_bin" "$tmp_path" || return 1
    chmod +x "$tmp_path" || { rm -f "$tmp_path"; return 1; }
    mv -f "$tmp_path" "$bin_path" || { rm -f "$tmp_path"; return 1; }
    return 0
}

# _evsieve_host_verify: Run the installed binary FROM THE HOST as the
# final success gate. The binary links libevdev dynamically and is built
# inside the debian:12 box but must run on the SteamOS host, not the box
# — this is the stated host-side dependency check (libevdev.so.2).
# Outputs:
#   return — 0 iff `"$(_evsieve_bin)" --version` exits 0; else 1
_evsieve_host_verify() {
    "$(_evsieve_bin)" --version >/dev/null 2>&1
}

# _evsieve_write_stamp: Write the commit + patch-sha stamp. Called ONLY
# after _evsieve_host_verify passes, so a stamp never certifies a binary
# the host cannot run.
# Inputs:
#   Globals: EVSIEVE_PINNED_COMMIT, EVSIEVE_PATCH_SHA256 (read)
# Outputs:
#   return — 0 on write, 1 if the stamp could not be written (e.g. ENOSPC)
#   side effects — writes $(_evsieve_stamp)
_evsieve_write_stamp() {
    local stamp
    stamp="$(_evsieve_stamp)"
    {
        echo "commit=${EVSIEVE_PINNED_COMMIT}"
        echo "patch_sha256=${EVSIEVE_PATCH_SHA256}"
    } > "$stamp" 2>/dev/null || return 1
}

# _evsieve_degrade: The single fail-open funnel. Sets the outcome token,
# warns the user, and always returns 0 — install_evsieve's every failure
# path routes through here so v1.1 is never harmed.
# Inputs:
#   $1 — status_token: one of the degraded-* EVSIEVE_INSTALL_STATUS values
#   $2 — message: a step-specific reason, house-worded (#38 D6)
# Outputs:
#   return — 0
#   side effects — sets EVSIEVE_INSTALL_STATUS; print_warning "$message"
_evsieve_degrade() {
    local status_token="$1" message="$2"
    EVSIEVE_INSTALL_STATUS="$status_token"
    print_warning "$message"
    return 0
}

# --- Public API ---

# install_evsieve: Build-at-install a pinned, patched evsieve (#38 D4).
# FAIL-OPEN: exits 0 on every path, sets EVSIEVE_INSTALL_STATUS to record
# the outcome; the v1.1 install is never harmed and the v1.2 controller-
# proxy feature simply stays unavailable if this degrades (it is OFF by
# default anyway until PR7).
# Inputs:
#   Globals: TARGET_DIR, SCRIPT_DIR, MCSS_REPO_RAW_URL (read)
# Outputs:
#   return — 0 ALWAYS
#   side effects — sets EVSIEVE_INSTALL_STATUS; on success installs
#                  $TARGET_DIR/bin/evsieve + $TARGET_DIR/bin/.evsieve.stamp
install_evsieve() {
    print_header "🎮 EVSIEVE (SEAMLESS RECONNECT) — OPTIONAL v1.2 STEP"

    if _evsieve_stamp_matches; then
        EVSIEVE_INSTALL_STATUS="skipped"
        print_success "evsieve already installed and up to date."
        return 0
    fi

    local msg
    if ! _evsieve_check_toolchain; then
        msg="evsieve build toolchain not found (need git, podman,"
        msg+=" distrobox, all on PATH); ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-no-toolchain" "$msg"
        return 0
    fi

    # Guarded assignment: a bare failing $(mktemp) under the entry script's
    # set -e would abort the whole installer — violating fail-open (#38 D4).
    local build_root
    if ! build_root=$(mktemp -d \
        "${TARGET_DIR:-$HOME/.local/share/PolyMC}/.evsieve-build.XXXXXX" \
        2>/dev/null); then
        msg="evsieve build workspace could not be created;"
        msg+=" ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-build-failed" "$msg"
        return 0
    fi
    # STYLE-GUIDE §7 rule 9: trap the temp build tree, every exit path.
    # shellcheck disable=SC2064  # build_root is fixed now, intentional.
    trap "rm -rf '$build_root'" RETURN

    print_progress "Fetching pinned evsieve source (git clone)..."
    if ! _evsieve_acquire_source "$build_root/src"; then
        msg="evsieve source clone/verification failed (commit or"
        msg+=" archive SHA mismatch — refusing to build unverified"
        msg+=" source); ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-verify-failed" "$msg"
        return 0
    fi

    if ! _evsieve_resolve_patch "$build_root/patch"; then
        msg="evsieve patch fetch/verification failed (SHA mismatch —"
        msg+=" refusing to build unverified source);"
        msg+=" ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-verify-failed" "$msg"
        return 0
    fi

    if ! _evsieve_apply_patch "$build_root/src" "$build_root/patch"; then
        msg="evsieve patch failed to apply; ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-build-failed" "$msg"
        return 0
    fi

    print_progress "Building evsieve in the ${EVSIEVE_DISTROBOX_NAME}\
 distrobox (this can take several minutes)..."
    if ! run_with_spinner \
        "Preparing ${EVSIEVE_DISTROBOX_NAME} box (first run pulls a debian image)" \
        _evsieve_ensure_box; then
        msg="evsieve build box could not be created;"
        msg+=" ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-build-failed" "$msg"
        return 0
    fi

    if ! run_with_spinner "Compiling evsieve (cargo build --release)" \
        _evsieve_build_in_box "$build_root/src"; then
        msg="evsieve build (cargo build --release) failed;"
        msg+=" ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-build-failed" "$msg"
        return 0
    fi

    if ! _evsieve_install_binary "$build_root/src"; then
        msg="evsieve binary copy-out failed; ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-build-failed" "$msg"
        return 0
    fi

    if ! _evsieve_host_verify; then
        msg="built evsieve binary will not run on this host (likely"
        msg+=" missing libevdev.so.2); ${EVSIEVE_FAIL_OPEN_NOTE}"
        _evsieve_degrade "degraded-host-exec" "$msg"
        return 0
    fi

    # Stamp-write failure is tolerated (|| true): the binary is installed
    # and host-verified; a missing stamp only costs a rebuild next run —
    # and a bare nonzero here under the entry's set -e would kill the
    # installer, violating fail-open (#38 D4).
    _evsieve_write_stamp || true

    # shellcheck disable=SC2034  # PROVIDED global: read by callers/tests,
    # never read inside this file (documented in the module header).
    EVSIEVE_INSTALL_STATUS="installed"
    print_success "evsieve built and installed: $(_evsieve_bin)"
    return 0
}
