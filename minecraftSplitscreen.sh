#!/bin/bash
# minecraftSplitscreen.sh — production splitscreen launcher entry point
#
# Sources the runtime orchestrator modules (runtime_context.sh first, then the
# manifest in modules/runtime_modules.list) and dispatches on $1 to the
# correct entry: the production nested-Plasma launch
# (launchFromPlasma/prodFromPlasma), or the Phase B lifecycle test harness
# (test/testPlasma/testDirect/testNested). See the case statement near the
# bottom of this file.
#
# Overridable env vars:
#   N_SLOTS          — number of player slots (default 4)
#   INSTANCES_DIR    — override auto-detected launcher instances directory
#   LAUNCHER_EXEC    — override auto-detected launcher command
#
# This script IS the production launcher: the installer deploys it as-is
# (setup_splitscreen_launcher_script) and it auto-detects launcher config at
# runtime. (The old launcher_script_generator.sh template was retired — the
# launcher is deployed + version-stamped, not generated. Fix #90: the Phase-A
# static-test prototype path — runStaticTest/launchSlot/launchWindowTest/
# nestedPlasma and friends — is deleted; it duplicated what the orchestrator
# modules now own and exercised a different sandbox than production.)
#
# LEGACY NAMING: functions in this file use camelCase (launchFromPlasma,
# testPlasma, …) — frozen per the house style guide §6; do not rename.
#
# Env CONSUMED (legacy override inputs → runtime_context.sh resolvers, plus
# a few read directly by this file):
#   N_SLOTS, INSTANCES_DIR, LAUNCHER_EXEC, SPLITSCREEN_DEBUG_LOG,
#   SPLITSCREEN_STATE, SPLITSCREEN_FIFO, SPLITSCREEN_SCREEN_W,
#   SPLITSCREEN_TEST_OBSERVE_DELAY_S, MCSS_NESTED_SESSION, MCSS_DISPLAY,
#   MCSS_SCREEN_W/H, MCSS_GEOM_DIR, MCSS_HELPER_DIR, MCSS_KWIN_WRAPPER_PATH,
#   MCSS_SESSION_ENV_BAK, MCSS_AUTOSTART_*, MCSS_LAUNCHER_ROOT,
#   MCSS_INSTANCE_PREFIX
# Env PROVIDED: LOG / SPLITSCREEN_DEBUG_LOG (exported, shared across the
#   gamescope→KDE re-exec), MCSS_VERSION/COMMIT/BUILD_DATE (stamped by the
#   installer/deploy.sh)
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.5 2026-07-17  Fix #90: delete Phase-A prototype path + vestigial shims
#   v1.4 2026-07-10  #45 PR3: runtime_modules.list — one manifest, sourced
#   v1.3 2026-07-01  v1.1 batch: #43/#42 env guard, #40 fix, #15 teardown
#   v1.2 2026-06-23  A1: wire production launchFromPlasma to nested Plasma
#   v1.1 2026-06-19  Phase B test-mode entry point (testPlasma, lifecycle test)
#   v1.0 2025-06-11  Initial monolith launcher (145 commits — compressed hard)

# ── Build provenance ─────────────────────────────────────────────────────────
# Stamped by the installer at deploy time (setup_splitscreen_launcher_script does
# a sed substitution on the placeholders below).  Run un-stamped (e.g. straight
# from the repo during testing) the placeholders remain and we fall back to
# dev/unknown.  `--version`/`-v` prints and exits before any logging/side effects.
MCSS_VERSION="__MCSS_VERSION__"
MCSS_COMMIT="__MCSS_COMMIT__"
MCSS_BUILD_DATE="__MCSS_BUILD_DATE__"
[[ "$MCSS_VERSION"    == __MCSS_* ]] && MCSS_VERSION="dev"
[[ "$MCSS_COMMIT"     == __MCSS_* ]] && MCSS_COMMIT="unknown"
[[ "$MCSS_BUILD_DATE" == __MCSS_* ]] && MCSS_BUILD_DATE="unknown"
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "minecraftSplitscreen ${MCSS_VERSION} (commit ${MCSS_COMMIT}, built ${MCSS_BUILD_DATE})"
    exit 0
fi

# Per-run timestamped debug log. The script re-execs itself across the
# gamescope→KDE boundary (testPlasma/launchFromPlasma write an autostart that
# re-invokes us); those autostart Exec lines pass SPLITSCREEN_DEBUG_LOG so both
# halves of one run append to the SAME file. Only the first invocation (env var
# unset) mints a new timestamp. A stable -latest symlink makes tailing easy.
LOG="${SPLITSCREEN_DEBUG_LOG:-/tmp/splitscreen-debug-$(date +%Y%m%d-%H%M%S).log}"
export SPLITSCREEN_DEBUG_LOG="$LOG"
ln -sfn "$LOG" /tmp/splitscreen-debug-latest.log 2>/dev/null || true
exec 2>>"$LOG"
set -x

echo "=== $(date) XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-unset} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset} DISPLAY=${DISPLAY:-unset} ===" >> "$LOG"

# Source runtime orchestrator modules. runtime_context.sh sources FIRST and its
# resolvers run BEFORE the other modules source (#45 / PLAN Part 4 loading-order
# rule): module source-time defaults must read the canonical values, not race
# them. INSTANCES_DIR/LAUNCHER_EXEC/N_SLOTS survive as legacy override inputs
# consumed by mcss_resolve_paths — the old _detect_instances_dir /
# _detect_launcher_exec cascades live in the resolver now (superset: it also
# probes squashfs-root/AppRun, the FUSE workaround only the installer knew).
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [[ ! -f "$SCRIPT_DIR/modules/runtime_context.sh" ]]; then
    echo "FATAL: $SCRIPT_DIR/modules/runtime_context.sh missing — broken deploy (run deploy.sh or the installer)" | tee -a "$LOG" >&2
    exit 1
fi
source "$SCRIPT_DIR/modules/runtime_context.sh"
mcss_resolve_environment
mcss_resolve_paths
# #49: the module list is the ONE manifest deployed alongside the modules
# (installer and deploy.sh both ship it). runtime_context.sh is skipped in the
# loop — it was sourced explicitly above, before its resolvers ran.
_MOD_MANIFEST="$SCRIPT_DIR/modules/runtime_modules.list"
if [[ ! -f "$_MOD_MANIFEST" ]]; then
    echo "FATAL: $_MOD_MANIFEST missing — broken deploy (run deploy.sh or the installer)" | tee -a "$LOG" >&2
    exit 1
fi
while IFS= read -r _mod; do
    [[ "$_mod" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$_mod" == "runtime_context.sh" ]] && continue
    _mod_path="$SCRIPT_DIR/modules/$_mod"
    if [[ -f "$_mod_path" ]]; then
        source "$_mod_path"
    fi
done < "$_MOD_MANIFEST"

# ─────────────────────────────────────────────────────────────────────────────
# Session-env leak guard.
# testPlasma/launchFromPlasma exec `dbus-run-session startplasma-wayland`. KDE startup
# pushes the NESTED compositor's WAYLAND_DISPLAY (e.g. wayland-1) into the shared
# systemd --user environment (dbus-update-activation-environment --systemd). But
# dbus-run-session only isolates the dbus *bus*, not the per-user systemd manager —
# so that value outlives our session. Afterward the next gamescope/Steam session
# inherits WAYLAND_DISPLAY pointing at a now-dead socket → gamescope can't start →
# sddm relaunches forever → both displays stay black.
# We snapshot the gamescope value BEFORE going nested and restore it on the way out.
# ─────────────────────────────────────────────────────────────────────────────
# #45/N7: env-snapshot moves out of world-writable /tmp (it is re-sourced into
# the session on restore). Path resolved by the prologue's mcss_resolve_paths.
_SESSION_ENV_BAK="$MCSS_SESSION_ENV_BAK"

# _snapshot_session_env: Record systemd --user's current WAYLAND_DISPLAY/
# DISPLAY (the gamescope values) before going nested, so they can be
# restored on the way out — see the "Session-env leak guard" block above.
# Inputs: Globals: _SESSION_ENV_BAK (write path), LOG (read)
# Outputs: side effects — writes $_SESSION_ENV_BAK, appends to $LOG
_snapshot_session_env() {
    : > "$_SESSION_ENV_BAK" 2>/dev/null || true
    local v cur
    for v in WAYLAND_DISPLAY DISPLAY; do
        # systemd --user still holds the gamescope value here (startplasma has not
        # clobbered it yet); fall back to our own inherited process env.
        cur=$(systemctl --user show-environment 2>/dev/null | sed -n "s/^${v}=//p" | head -1)
        [[ -z "$cur" ]] && cur="${!v:-}"
        if [[ -n "$cur" ]]; then
            echo "${v}=${cur}" >> "$_SESSION_ENV_BAK"
        else
            echo "#UNSET ${v}" >> "$_SESSION_ENV_BAK"
        fi
    done
    echo "[session-env] snapshot: $(tr '\n' ' ' < "$_SESSION_ENV_BAK" 2>/dev/null)" >> "$LOG"
}

# _restore_session_env: Push the snapshot from _snapshot_session_env back
# into systemd --user (or unset it), then remove the snapshot file.
# Inputs: Globals: _SESSION_ENV_BAK (read, then removed), LOG (read)
# Outputs: return — always 0; side effects — systemctl --user set/unset-
#          environment calls, appends to $LOG, removes $_SESSION_ENV_BAK
_restore_session_env() {
    [[ -f "$_SESSION_ENV_BAK" ]] || return 0
    local line
    while IFS= read -r line; do
        case "$line" in
            \#UNSET\ *) systemctl --user unset-environment "${line#\#UNSET }" 2>/dev/null || true ;;
            *=*)        systemctl --user set-environment "$line" 2>/dev/null || true ;;
        esac
    done < "$_SESSION_ENV_BAK"
    echo "[session-env] restored gamescope WAYLAND_DISPLAY/DISPLAY in systemd --user" >> "$LOG"
    rm -f "$_SESSION_ENV_BAK" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# _start_nested_plasma: Shared scaffolding for entering a nested Plasma
# session. Fix #51 (D9): was copy-pasted across testPlasma / launchFromPlasma
# ("DRY in a later cleanup" — this is that cleanup). Unsets the session-env
# leakage vars, writes the KWin wrapper shim at the resolved screen size,
# writes the autostart .desktop that re-invokes this script inside the
# session (documenting, per env var, which env each writes into that Exec
# line — see the Inputs list below), snapshots session env, then starts
# `dbus-run-session startplasma-wayland`.
# Inputs:
#   $1 — log tag (caller name, for $LOG lines)
#   $2 — autostart .desktop filename (under $MCSS_AUTOSTART_DIR)
#   $3 — .desktop Name= value
#   $4 — re-invoke argument appended after the script path ("" for none)
#   $5 — launch mode: "exec" (never returns) or "background" (supervised)
#   $6… — extra NAME=VALUE pairs for the Exec= env list (after the standard
#         MCSS_NESTED_SESSION=plasma)
#   Globals: MCSS_KWIN_WRAPPER_PATH, MCSS_HELPER_DIR, MCSS_AUTOSTART_DIR,
#            MCSS_SCREEN_W/H via mcss_resolve_screen, LOG (read)
# Outputs:
#   side effects — writes the wrapper shim + autostart .desktop, prepends
#   $MCSS_HELPER_DIR to PATH, snapshots session env.
#   "background" mode sets _NESTED_SESSION_PID; "exec" mode does not return.
_start_nested_plasma() {
    local tag="$1" desktop_file="$2" desktop_name="$3" reinvoke_arg="$4"
    local launch_mode="$5"
    shift 5

    unset LD_PRELOAD XDG_DESKTOP_PORTAL_DIR XDG_SEAT_PATH XDG_SESSION_PATH \
        || true

    local W H
    # #45/D7: canonical screen resolution (env-override-first cascade,
    # 1280x800 fallback).
    mcss_resolve_screen
    W="$MCSS_SCREEN_W"; H="$MCSS_SCREEN_H"
    echo "[$tag] W=$W H=$H" >> "$LOG"

    # #45/N6: wrapper shim lives in the 0700 per-user helper dir, not
    # world-writable /tmp — it is injected into PATH and EXECUTED by
    # startplasma.
    cat > "$MCSS_KWIN_WRAPPER_PATH" <<WEOF
#!/bin/bash
/usr/bin/kwin_wayland_wrapper --width ${W} --height ${H} --no-lockscreen "\$@"
WEOF
    chmod +x "$MCSS_KWIN_WRAPPER_PATH"
    export PATH="$MCSS_HELPER_DIR:$PATH"

    # Autostart re-invokes this script once the KDE session is running (a
    # fresh process — env does NOT carry over; mcss_exec_env_string is the
    # one Exec-line env writer, so per-caller extras ride through "$@").
    local SCRIPT_PATH _exec_env
    SCRIPT_PATH="$(readlink -f "$0")"
    _exec_env="$(mcss_exec_env_string MCSS_NESTED_SESSION=plasma "$@")"
    mkdir -p "$MCSS_AUTOSTART_DIR"
    cat > "$MCSS_AUTOSTART_DIR/$desktop_file" <<DEOF
[Desktop Entry]
Name=$desktop_name
Exec=env ${_exec_env} ${SCRIPT_PATH}${reinvoke_arg:+ $reinvoke_arg}
Type=Application
X-KDE-AutostartScript=true
DEOF
    _snapshot_session_env

    if [[ "$launch_mode" == "exec" ]]; then
        echo "[$tag] autostart written, exec-ing startplasma-wayland" \
            >> "$LOG"
        exec dbus-run-session startplasma-wayland
    fi
    echo "[$tag] autostart written (→ ${reinvoke_arg:-re-exec}), launching" \
        "nested session (supervised, non-exec)" >> "$LOG"
    dbus-run-session startplasma-wayland &
    _NESTED_SESSION_PID=$!
}

# ─────────────────────────────────────────────────────────────────────────────
# testPlasma: Outer entry — start a nested KDE session for the Phase B
# automated lifecycle test. Writes an autostart .desktop that re-invokes
# this script as testFromPlasma (→ launchTestFromPlasma) instead of main().
# Inputs: Globals: TEST_NUMBER, SPLITSCREEN_TEST_OBSERVE_DELAY_S (read; ridden
#         into the nested session's autostart Exec= env, since a fresh
#         re-invoked process does not inherit exported env)
# Outputs: side effects — see _start_nested_plasma ("exec" mode never returns)
# ─────────────────────────────────────────────────────────────────────────────
testPlasma() {
    echo "[testPlasma] start" >> "$LOG"
    # Fix #51 (D9): shared scaffolding. The chosen test number + observation
    # delay ride the Exec= env list into the nested session (the autostart
    # re-invocation is a fresh process — env does not carry over).
    _start_nested_plasma testPlasma "$MCSS_AUTOSTART_TEST_DESKTOP" \
        "Splitscreen Test" testFromPlasma exec \
        "TEST_NUMBER=${TEST_NUMBER:-all}" \
        "SPLITSCREEN_TEST_OBSERVE_DELAY_S=${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15}"
}

# _mcss_nested_pids: #58 — PIDs matching $1 (pgrep -f pattern) that belong to
# OUR nested-session tree, identified by SPLITSCREEN_DEBUG_LOG= in the
# process environ — every invocation of this script exports it (top of
# file), so a nested startplasma-wayland and all its descendants (kwin,
# plasma_session, baloo, ...) carry it. The REAL Desktop-Mode Plasma session
# does not, so a first launch right after Desktop → Game Mode (outgoing
# desktop still tearing down) must never see its processes here. Leftovers
# from builds predating the SPLITSCREEN_DEBUG_LOG export are invisible to
# this filter — accepted: they predate this branch and a manual reap/reboot
# covers the upgrade edge.
# Inputs: $1 — pgrep -f pattern
# Outputs: stdout — one matching PID per line; return — always 0
_mcss_nested_pids() {
    local _pat="$1" _pid
    for _pid in $(pgrep -f "$_pat" 2>/dev/null || true); do
        grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$_pid/environ" 2>/dev/null && echo "$_pid"
    done
    return 0
}

# _mcss_stale_tree_pids: #60 — PIDs of STALE RUN TREES: marked processes
# running this script (a prior run's orchestrator main loop, watchdog,
# controller monitor, supervisor, or Steam reaper), excluding this process
# and its ancestors. They survive their session's death — no session/
# instance name pattern matches a 'bash …/minecraftSplitscreen.sh …'
# cmdline — and keep acting on the SHARED state file and FIFO. Confirmed
# on-Deck 2026-07-05: a leftover run's teardown read the shared state and
# killed the instance a NEWER session had just spawned (~25s after boot).
# They must die before a new run starts. (The $(…) subshell evaluating this
# function can list itself; the subsequent kill is a no-op on an
# already-gone pid.)
# Inputs: none (uses $$/$PPID to build the ancestor-exclusion chain)
# Outputs: stdout — one stale PID per line; return — always 0
_mcss_stale_tree_pids() {
    local _chain=" $$ " _p="$PPID" _pid
    while [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 1 )); do
        _chain+=" $_p "
        _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
    done
    for _pid in $(_mcss_nested_pids 'minecraftSplitscreen'); do
        [[ "$_chain" == *" $_pid "* ]] && continue
        echo "$_pid"
    done
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# launchFromPlasma: PRODUCTION outer entry (this is the LaunchOptions the
# Steam shortcut runs). Starts the nested KDE/Plasma session exactly like
# testPlasma, but the autostart runs the PRODUCTION inner handler
# (prodFromPlasma → the real orchestrator) instead of the test harness. A1
# (2026-06-23): without this case the Steam shortcut fell through to a bare
# main() with NO nested compositor / no tiling, so a real user got no
# splitscreen — the working windowing lived only in `test`.
# Fix #51 (D9): the scaffolding tail is now the shared _start_nested_plasma
# (the "DRY in a later cleanup" this header used to promise). It writes the
# autostart .desktop's Exec= line via mcss_exec_env_string with
# MCSS_NESTED_SESSION=plasma (the re-invoked prodFromPlasma reads this to
# know it's inside our nested session — see the `*)` dispatch guard).
# Inputs: Globals: MCSS_LAUNCHER_ROOT, MCSS_INSTANCE_PREFIX, MCSS_GEOM_DIR
#         (read, startup-guard reap patterns/paths)
# Outputs: return — always falls through to completion (no early exit);
#          side effects — reaps leftover nested sessions/instances, starts
#          the nested session (background/supervised), blocks for the whole
#          session lifetime, then supervises the final reap; stderr log
launchFromPlasma() {
    echo "[launchFromPlasma] start (production)" >> "$LOG"

    # STARTUP GUARD (2026-06-27): reap any LEFTOVER nested session + MC instances BEFORE
    # starting a new one. A prior gamescope reset or failed launch can orphan a
    # startplasma-wayland nested session (plus its kwin/instances); without this, a relaunch
    # STACKS a second nested session on top — the two fight over the same state/FIFO,
    # re-trigger the Steam UI (the "gamescope restarting" chime), and pile up orphan JVMs.
    # We are in the OUTER gamescope/Steam context here (before exec), so this only kills the
    # leftover nested tree — never gamescope-session or steamwebhelper.
    #
    # #58 (2026-07-05, confirmed on Deck): two fixes to the original guard.
    #  1. The bare pkills ran under errexit (set -euo pipefail leaks in from the sourced
    #     modules): the first pattern with NO match returned 1 and killed THIS process
    #     mid-reap — Steam saw the game close, so every first launch after Desktop Mode
    #     bounced to the library and only the second (guard skipped) launch worked. The
    #     guard must reap and FALL THROUGH; every kill is now || true like the rest of
    #     this file.
    #  2. pkill -9 -f 'startplasma-wayland'/'kwin_wayland'/... matched the OUTGOING real
    #     Desktop-Mode session mid-teardown, not just our orphaned nested one. Session-level
    #     names are now scoped via _mcss_nested_pids (environ marker) so a dying desktop
    #     is left alone. MC-instance patterns (latestUpdate / bwrap→PolyMC) stay unscoped —
    #     they are unambiguous and a leftover instance must die wherever it came from.
    # #60: sweep stale run trees FIRST (see _mcss_stale_tree_pids) so no leftover
    # orchestrator/watchdog/supervisor can react — via the shared state file/FIFO —
    # while we reap its session and start ours.
    # #45: instance kill-patterns derive from the runtime_context constants.
    # MCSS_INSTANCE_PREFIX includes the trailing dash, so the pattern is
    # STRICTER than the old bare 'latestUpdate' literal (cannot match an
    # unrelated 'latestUpdater' style cmdline). The launcher pattern derives
    # from the resolved root's basename (PolyMC or PrismLauncher), so a Prism
    # install reaps its own launcher instead of a hardcoded 'PolyMC'.
    local _launcher_name
    _launcher_name=$(basename "$MCSS_LAUNCHER_ROOT")
    local _g _name _pid _stale_tree
    _stale_tree=$(_mcss_stale_tree_pids)
    if [[ -n "$_stale_tree" ]] || [[ -n "$(_mcss_nested_pids 'startplasma-wayland')" ]] || pgrep -f "$MCSS_INSTANCE_PREFIX" >/dev/null 2>&1; then
        echo "[launchFromPlasma] STARTUP GUARD: leftover nested session/instances found — reaping before launch (stale trees: ${_stale_tree:-none})" >> "$LOG"
        for _pid in $_stale_tree; do
            kill -9 "$_pid" 2>/dev/null || true
        done
        for _g in 1 2 3; do
            pkill -9 -f "$MCSS_INSTANCE_PREFIX" 2>/dev/null || true
            pkill -9 -f "bwrap.*$_launcher_name" 2>/dev/null || true
            pkill -9 -f "$_launcher_name" 2>/dev/null || true
            # #26/#60: 'udevadm monitor' / inotifywait are our monitors' children and
            # can orphan past a parent-only kill; marked-only match spares system udev.
            for _name in startplasma-wayland kwin_wayland plasma_session baloo_file 'udevadm monitor' inotifywait; do
                for _pid in $(_mcss_nested_pids "$_name"); do
                    kill -9 "$_pid" 2>/dev/null || true
                done
            done
            sleep 1
            [[ -n "$(_mcss_nested_pids 'startplasma-wayland')" ]] || break
        done
        rm -rf "$MCSS_GEOM_DIR" 2>/dev/null || true
        echo "[launchFromPlasma] STARTUP GUARD: reap done (nested=$(_mcss_nested_pids 'startplasma-wayland' | wc -l) jvm=$(pgrep -fc "$MCSS_INSTANCE_PREFIX" 2>/dev/null || true))" >> "$LOG"
    fi
    # #42: a Desktop-Mode double-click of the (now-guarded) desktop shortcut, or an
    # earlier install predating the #43 environment guard, can leave a transient
    # systemd --user unit (app-MinecraftSplitscreen@*.service) tracking a runaway
    # session. Raw pkill doesn't collapse that unit's cgroup and systemd may keep it
    # registered; explicitly stop any matching unit before a fresh launch. Best-effort
    # — systemctl may not be present/relevant on every target, hence `|| true` throughout.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop 'app-MinecraftSplitscreen@*' 2>/dev/null || true
    fi

    # #15/D6 (UNTESTED 2026-06-27 diagnosis → fix 2026-07-01, no Deck access this
    # session): do NOT `exec` into the nested session. `exec` replaces THIS process, so
    # once inside, only code running FROM WITHIN the dying session (launchProdFromPlasma's
    # own EXIT trap) can attempt teardown — and Plasma's systemd --user-managed helpers
    # (baloo_file, kglobalacceld, kactivitymanagerd, ...) get auto-restarted by systemd's
    # Restart=on-failure the instant a bare `pkill` kills them, since nothing told systemd
    # the unit/target is supposed to be going away. That's the confirmed root cause: the
    # reaper waits on the whole descendant tree, systemd keeps re-populating it, so Steam
    # never sees the game exit → Abort-Game overlay.
    #
    # Keeping THIS process alive as an OUTSIDE supervisor lets us run a SECOND, independent
    # reap pass (_supervise_reap_nested_session) after the inner session's own trap-driven
    # teardown has already tried once — a bounded retry loop that out-waits systemd's
    # restart-burst limit (systemd gives up restarting a unit after enough rapid failures
    # in a short window) rather than a single one-shot kill. Steam's reaper is watching
    # THIS pid (the one it launched); we don't return until the reap loop confirms the
    # tree is actually gone, instead of exiting the instant the nested session's own logout
    # completes.
    # Fix #51 (D9): shared scaffolding, background (supervised) mode.
    _start_nested_plasma launchFromPlasma "$MCSS_AUTOSTART_PROD_DESKTOP" \
        "Splitscreen" prodFromPlasma background
    local _session_pid="$_NESTED_SESSION_PID"

    # #60 follow-up (2026-07-05): the original wait here was a FLAT 60s budget from
    # session start — written for the post-game teardown but placed at launch, it
    # capped every session's LIFETIME at 60s. Invisible until tonight because the
    # errexit '((_waited++))' bug killed this supervisor at second one on every run;
    # fixing that resurrected the cap and it force-reaped LIVE sessions a minute in.
    # The wait is now three phases; only teardown is bounded (the #15 premise —
    # plasma_session respawn may keep the top-level session process alive forever —
    # still holds, hence the phase-3 budget before the forced reap):
    #   1. boot (bounded): wait for OUR inner handler (prodFromPlasma, marked with
    #      this run's log path) to appear in the nested session;
    #   2. lifetime (unbounded): wait while the inner handler lives — this is the
    #      whole time the user is playing;
    #   3. teardown grace (bounded): the inner trap gets a window to tear the
    #      session down itself before we fall through to the forced reap.
    local _boot=0 _boot_budget_s=90
    while (( _boot < _boot_budget_s )) && [[ -z "$(_mcss_own_run_pids 'prodFromPlasma')" ]] \
            && kill -0 "$_session_pid" 2>/dev/null; do
        sleep 1
        _boot=$(( _boot + 1 ))
    done
    echo "[launchFromPlasma] nested session boot phase ended after ${_boot}s (inner handler $( [[ -n "$(_mcss_own_run_pids 'prodFromPlasma')" ]] && echo up || echo ABSENT ))" >> "$LOG"

    while [[ -n "$(_mcss_own_run_pids 'prodFromPlasma')" ]] && kill -0 "$_session_pid" 2>/dev/null; do
        sleep 2
    done
    echo "[launchFromPlasma] inner handler gone — session over, granting teardown grace" >> "$LOG"

    local _waited=0 _wait_budget_s=30
    while (( _waited < _wait_budget_s )) && kill -0 "$_session_pid" 2>/dev/null; do
        sleep 1
        _waited=$(( _waited + 1 ))
    done
    if kill -0 "$_session_pid" 2>/dev/null; then
        echo "[launchFromPlasma] nested session still alive ${_wait_budget_s}s after game end — proceeding to forced supervised reap" >> "$LOG"
    else
        echo "[launchFromPlasma] nested session exited ${_waited}s into teardown grace — supervising final reap" >> "$LOG"
    fi

    _restore_session_env
    _supervise_reap_nested_session "$_session_pid"
    echo "[launchFromPlasma] complete (supervised reap done)" >> "$LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# launchProdFromPlasma: PRODUCTION inner handler (runs inside the nested
# Plasma session — this is what launchFromPlasma's autostart Exec= line
# re-invokes this script as, via MCSS_NESTED_SESSION=plasma + prodFromPlasma).
# Same nested-session scaffolding as launchTestFromPlasma (strip the panel
# for full real estate, clean full-session teardown on exit) but runs the
# REAL orchestrator main() — the FIFO event loop + controller monitor +
# spawn slot 1 + reflow — instead of the test harness.
# Inputs: Globals: SPLITSCREEN_FIFO, SPLITSCREEN_STATE (read/initialized)
# Outputs: return — 1 if orchestrator main() isn't available (modules not
#          sourced); otherwise blocks until the session ends, then returns
#          via _end_nested_session (which terminates the nested kwin/Plasma)
#          side effects — traps EXIT/INT/TERM/HUP for teardown (cleanup(),
#          _restore_session_env, panel-killer stop, _end_nested_session)
# ─────────────────────────────────────────────────────────────────────────────
launchProdFromPlasma() {
    echo "[launchProdFromPlasma] start" >> "$LOG"
    rm -f "$MCSS_AUTOSTART_DIR/$MCSS_AUTOSTART_PROD_DESKTOP" "$MCSS_AUTOSTART_DIR/$MCSS_AUTOSTART_TEST_DESKTOP" 2>/dev/null || true

    # Strip the Plasma panel (black backdrop, full tiling area); respawn-killer loop.
    pkill -x plasmashell 2>/dev/null || true
    ( while :; do pkill -x plasmashell 2>/dev/null; sleep 2; done ) &
    _PANEL_KILLER_PID=$!

    # On exit/signal: tear down instances, restore leaked session env, stop the panel killer,
    # reap the WHOLE nested session (so Steam/gamescope return to the library).
    # H4 (UNTESTED 2026-06-27): added `cleanup` (orchestrator instance teardown — it was NOT
    # in this trap, so a SIGTERM/compositor-reset orphaned every bwrap→PolyMC→java tree, the
    # "5 leftover" leak) and the INT/TERM/HUP signals (a bare EXIT trap does NOT fire on
    # TERM/INT). cleanup() is re-entrancy-guarded; teardown runs before _end_nested_session.
    trap 'declare -f cleanup >/dev/null 2>&1 && cleanup; _restore_session_env; kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null; _end_nested_session' EXIT INT TERM HUP

    if ! declare -f main >/dev/null 2>&1; then
        echo "[launchProdFromPlasma] ERROR: orchestrator main() not available — modules not sourced?" >> "$LOG"
        return 1
    fi

    # Initialise the FIFO + state file. main() ensures the FIFO but NOT the state file;
    # the test path does this in _run_phase_b_session. Without SPLITSCREEN_STATE the
    # watchdog/spawn fail ("SPLITSCREEN_STATE is not set") so nothing launches → gamescope
    # shows only the spinner. (2026-06-23)
    local fifo="$SPLITSCREEN_FIFO"
    export SPLITSCREEN_FIFO="$fifo"
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
    # #46/#50: single initializer (instance_lifecycle) + single path resolution
    # (runtime_context); mode auto-detected via get_display_mode instead of the
    # hardcoded "docked" that drifted against instance_lifecycle's "handheld".
    local state="$SPLITSCREEN_STATE"
    _ensure_state_file

    # Run the real orchestrator. It blocks until the session ends (P1/Deck instance
    # exits). Output to the log directly (NO pipe — a pipe's write-end would be inherited
    # by bwrap descendants and stall the orchestrator's FIFO reads).
    main >> "$LOG" 2>&1 || true

    # Final teardown.
    if declare -f teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>/dev/null || true
    fi
    kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null || true
    trap - EXIT
    _restore_session_env
    qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null \
        || qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null || true
    sleep 1
    _end_nested_session
    echo "[launchProdFromPlasma] complete" >> "$LOG"
}

# _mcss_own_run_pids: PIDs matching $1 (pgrep -f pattern) that belong to THIS RUN's
# tree — environ carries SPLITSCREEN_DEBUG_LOG=<our exact $LOG>, which is unique per
# run (timestamped) and inherited by every process the run spawns. Stricter than
# _mcss_nested_pids (any marker value): teardown must kill only ITS OWN session.
# (#60, confirmed on-Deck 2026-07-05: a stale supervisor's bounded reap loop was
# still running when the NEXT session launched, and the name-only pkills below
# murdered the new session's compositor ~25s after boot.)
# Inputs: $1 — pgrep -f pattern; Globals: LOG (read, this run's exact path)
# Outputs: stdout — one matching PID per line; return — always 0
_mcss_own_run_pids() {
    local _pat="$1" _pid
    for _pid in $(pgrep -f "$_pat" 2>/dev/null || true); do
        grep -qzF "SPLITSCREEN_DEBUG_LOG=${LOG}" "/proc/$_pid/environ" 2>/dev/null && echo "$_pid"
    done
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _end_nested_session: tear down the WHOLE nested Plasma session so Steam's reaper
# releases and gamescope returns to the library. Two gotchas (both confirmed 2026-06-23):
#   1. kwin_wayland_wrapper RESPAWNS kwin_wayland — kill the wrapper first or kwin comes back.
#   2. Plasma session services (baloo_file, kded, kglobalacceld, kactivitymanagerd, …)
#      survive a compositor-only teardown, get adopted by Steam's subreaper, and keep the
#      "game" alive forever (Abort-Game overlay) — the reaper waits on the whole descendant
#      tree. So reap them too. TERM pass, then KILL pass.
# #60: kills are scoped to THIS RUN's own tree via _mcss_own_run_pids — a raw name
# pkill here reaps ANY session, including a newer one launched while a stale
# supervisor is still inside its retry loop. Session helpers spawned outside our
# env-inheritance (e.g. re-spawned by the systemd user manager) are invisible to
# the scoping; those are handled by the plasma-workspace.target stop in
# _supervise_reap_nested_session, not by widening the kill back to all-names.
# Inputs: none. Outputs: side effects — TERM then KILL pass over this run's
# own tracked service PIDs; no return-value contract (always 0).
_end_nested_session() {
    local sig svc _pid
    for sig in TERM KILL; do
        for svc in kwin_wayland_wrapper kwin_wayland startplasma-wayland \
                   plasma_session baloo_file kded6 \
                   kglobalacceld kactivitymanagerd kscreen_backend_launcher \
                   xdg-desktop-portal-kde; do
            for _pid in $(_mcss_own_run_pids "$svc"); do
                kill -"$sig" "$_pid" 2>/dev/null || true
            done
        done
        [ "$sig" = TERM ] && sleep 1
    done
}

# _supervise_reap_nested_session: OUTSIDE-the-session supervisor for #15/D6.
# Called from launchFromPlasma AFTER the nested session's own process has exited (we no
# longer `exec` into it — see the comment there), so this runs from a process that was
# never part of the session being torn down. Tries the surgical systemd stop first (which
# cancels Restart=on-failure for units bound to the target, unlike a raw pkill that
# systemd just respawns against), then repeats the existing kill sweep in a BOUNDED RETRY
# loop — exploiting systemd's own restart-burst limit (it gives up respawning a unit after
# enough rapid failures in a short window) instead of a single one-shot pass.
# Inputs: $1 — the nested session's top-level PID (dbus-run-session), if known
# Outputs: return — 0 once no tracked process names remain, 1 if they survive
#          every pass (logged, not fatal — the caller still returns so
#          Steam's reaper isn't blocked forever on a bug in this reap)
_supervise_reap_nested_session() {
    # #60 residual: this function was invoked (xtrace shows the call) yet none of
    # its own log lines ever appeared and the supervisor process vanished — cause
    # unknown. First statement writes a breadcrumb so the next occurrence pins the
    # death to before/after function entry.
    echo "[supervise_reap] entered (session_pid=${1:-none}, pid=$$)" >> "$LOG"
    local _session_pid="${1:-}"
    local _tries=0 _max_tries=8
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop plasma-workspace.target 2>/dev/null || true
    fi
    while (( _tries < _max_tries )); do
        # If the dbus-run-session/startplasma-wayland top-level process itself is still
        # alive (it may never exit on its own — see the bounded-wait comment above),
        # collapse its WHOLE tree directly by PID, not just by name.
        if [[ -n "$_session_pid" ]] && kill -0 "$_session_pid" 2>/dev/null; then
            _kill_tree "$_session_pid" TERM
        fi
        _end_nested_session
        sleep 1
        if [[ -n "$_session_pid" ]] && kill -0 "$_session_pid" 2>/dev/null; then
            _kill_tree "$_session_pid" KILL
        fi
        # #60: completion check scoped to OUR OWN run's tree — a name-wide pgrep
        # here sees a CONCURRENT newer session's processes and keeps this loop
        # (and its kill sweeps) alive against them for all 8 passes.
        local _svc _left=""
        for _svc in kwin_wayland startplasma-wayland plasma_session baloo_file; do
            if [[ -n "$(_mcss_own_run_pids "$_svc")" ]]; then
                _left="$_svc"
                break
            fi
        done
        if [[ -z "$_left" ]]; then
            echo "[supervise_reap] own nested-session tree confirmed clean after $((_tries + 1)) pass(es)" >> "$LOG"
            return 0
        fi
        _tries=$(( _tries + 1 ))
        echo "[supervise_reap] own leftovers survived pass ${_tries}/${_max_tries} (${_left}) — retrying" >> "$LOG"
    done
    echo "[supervise_reap] WARNING: own nested-session processes survived ${_max_tries} reap passes" >> "$LOG"
    return 1
}

# (Decoration is handled by kwin_set_noborder <pid> in spawn_instance — set ONCE when the
# window appears. The earlier at-map "No titlebar and frame" window rule was removed
# 2026-06-23: it missed because Minecraft sets its caption/WM_CLASS only AFTER mapping, so
# the rule had nothing to match at evaluation time, and it clobbered ~/.config/kwinrulesrc.)

# launchTestFromPlasma: Called from KDE autostart inside the nested test
# session (re-invoked as testFromPlasma|testPlasma via testPlasma's Exec=
# line). Starts docked_flow in background, runs the Phase B lifecycle test
# script (or the TEST 8 position sweep) against the FIFO, then tears down.
# Inputs: Globals: TEST_NUMBER, SPLITSCREEN_TEST_OBSERVE_DELAY_S (read)
# Outputs: return — 1 if docked_flow isn't available (modules not sourced);
#          otherwise blocks for the whole test session, then returns after
#          full teardown (_end_nested_session terminates the nested KWin)
# ─────────────────────────────────────────────────────────────────────────────
launchTestFromPlasma() {
    echo "[launchTestFromPlasma] start" >> "$LOG"
    rm -f "$MCSS_AUTOSTART_DIR/$MCSS_AUTOSTART_TEST_DESKTOP" 2>/dev/null || true

    # Strip the Plasma panel for full-screen real estate.  plasma-session can
    # respawn plasmashell, so keep a background killer running for the whole
    # session (reaped on exit).  Killing plasmashell also clears the desktop
    # wallpaper → black backdrop behind the splitscreen tiles, which is what we
    # want (this is the "nested Plasma, no panel" path; bare nested KWin is a
    # future option — see TODO "Research — bare nested KWin on SteamOS 3.8").
    pkill -x plasmashell 2>/dev/null || true
    ( while :; do pkill -x plasmashell 2>/dev/null; sleep 2; done ) &
    _PANEL_KILLER_PID=$!

    # Tear down the nested KWin session, stop the panel killer, and restore the
    # leaked session env on exit — prevents a permanent black screen / sddm restart
    # loop if the test hangs, crashes, or is interrupted.
    trap '_restore_session_env; kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null; _end_nested_session' EXIT

    if ! declare -f docked_flow >/dev/null 2>&1; then
        echo "[launchTestFromPlasma] ERROR: docked_flow not available" >> "$LOG"
        return 1
    fi

    # Run the Phase B session via the shared runner (FIFO-safe orchestrator restart
    # loop, full process-tree teardown, observation delay).  Default a viewing delay
    # for this interactive Game-Mode path.  _run_phase_b_session initialises the
    # FIFO + state file itself.
    export SPLITSCREEN_TEST_OBSERVE_DELAY_S="${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15}"
    if [[ "${TEST_NUMBER:-}" == "8" ]]; then
        echo "[launchTestFromPlasma] TEST 8 — single-instance position sweep" >> "$LOG"
        _run_position_sweep_session
    else
        _run_phase_b_session
    fi

    # Final instance cleanup, then tear down KWin explicitly (cleaner log ordering).
    if declare -f teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>/dev/null || true
    fi
    kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null || true
    trap - EXIT
    _restore_session_env

    # Graceful Plasma logout first (lets session services stop cleanly), then FORCE-reap
    # the WHOLE nested session — compositor, wrapper, AND the Plasma helpers (baloo_file,
    # kded, …) that otherwise survive, get adopted by Steam's subreaper, and keep the
    # "game" alive (gamescope Abort-Game overlay). 2026-06-23: baloo_file adopted by the
    # reaper was confirmed to be why the game wouldn't exit on its own.
    qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null \
        || qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null || true
    sleep 1
    _end_nested_session
    echo "[launchTestFromPlasma] complete" >> "$LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kill_tree: Recursively signal a process and all of its descendants.
# pkill -P reaps only DIRECT children; docked_flow spawns grandchildren (subshells,
# spawn_instance, monitors) that otherwise orphan to init.
# Inputs: $1 — pid, $2 — signal (default TERM)
# Outputs: side effects — kill -SIG on the whole subtree, depth-first;
#          return — always 0 (per-kill failures are swallowed)
# ─────────────────────────────────────────────────────────────────────────────
_kill_tree() {
    local pid="$1" sig="${2:-TERM}" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _kill_tree "$child" "$sig"
    done
    kill "-${sig}" "$pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# _run_phase_b_session: Shared Phase B lifecycle-test runner.
# Assumes the display environment (DISPLAY / XAUTHORITY / WAYLAND_DISPLAY) is
# already set by the caller and that the orchestrator modules (docked_flow, …)
# are sourced.  Starts the orchestrator restart-loop in-process (so docked_flow
# stays in scope), runs the lifecycle harness against the FIFO, then tears down
# the whole orchestrator process tree.  Publishes the loop PID in the global
# _PHASE_B_ORCH_PID so an outer EXIT trap can also reap it.
# Inputs: Globals: SPLITSCREEN_FIFO, SPLITSCREEN_STATE, TEST_NUMBER (read)
# Outputs: return — 1 if docked_flow isn't available; otherwise 0 after the
#          harness completes (bounded by a 7200s timeout) and the
#          orchestrator loop + FIFO are torn down
#          side effects — sets _PHASE_B_ORCH_PID, initializes FIFO/state
# ─────────────────────────────────────────────────────────────────────────────
_run_phase_b_session() {
    if ! declare -f docked_flow >/dev/null 2>&1; then
        echo "[run_phase_b] docked_flow not available — modules not loaded?" >> "$LOG"
        return 1
    fi

    local fifo="$SPLITSCREEN_FIFO"
    export SPLITSCREEN_FIFO="$fifo"
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
    # #46/#50: single initializer; docked is the scenario under test here.
    local state="$SPLITSCREEN_STATE"
    _ensure_state_file docked

    _orch_loop() { while true; do docked_flow || true; sleep 0.5; done; }
    _orch_loop &
    _PHASE_B_ORCH_PID=$!
    echo "[run_phase_b] orchestrator loop PID=$_PHASE_B_ORCH_PID (DISPLAY=$DISPLAY)" >> "$LOG"
    sleep 2

    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    local test_script="$SCRIPT_DIR/tests/test_phase_b_lifecycle.sh"
    if [[ -f "$test_script" ]]; then
        timeout 7200 bash "$test_script" "${TEST_NUMBER:-all}" || true
    else
        echo "[run_phase_b] test script not found at $test_script" >> "$LOG"
    fi

    _kill_tree "$_PHASE_B_ORCH_PID" TERM
    sleep 1
    _kill_tree "$_PHASE_B_ORCH_PID" KILL
    rm -f "$fifo" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# _run_position_sweep_session: (TEST 8 — single-instance position sweep)
# Spawn ONE instance (slot 1) and move it through every layout position in turn —
# full, top half, bottom half, and all four quad cells — pausing at each so the
# user can SEE whether the window actually moves on screen. Logs the geometry
# immediately after each move AND again after the observation delay, so a revert
# (e.g. the Splitscreen mod re-asserting its own position every frame) shows up in
# the log even between captures.
#
# Purpose: isolate window POSITIONING from all the multi-instance confounders
# (reflows, slot-1-vs-others, focus/restack). If a single window won't move or
# won't STAY, the next step is to retry with the Splitscreen mod removed — it is
# the one constant across every failed attempt and may be pinning each window to
# its splitscreen.properties region.
# Inputs: Globals: SPLITSCREEN_FIFO, SPLITSCREEN_STATE,
#         SPLITSCREEN_TEST_OBSERVE_DELAY_S (read)
# Outputs: return — 1 if slot 1's window never appears (aborts the sweep);
#          otherwise 0 after the full 7-position sweep and teardown
#          side effects — spawns/tears down slot 1, appends geometry
#          snapshots to $LOG at each step
# ─────────────────────────────────────────────────────────────────────────────
_run_position_sweep_session() {
    local fifo="$SPLITSCREEN_FIFO"
    export SPLITSCREEN_FIFO="$fifo"
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
    # #46/#50: single initializer; docked is the scenario under test here.
    local state="$SPLITSCREEN_STATE"
    _ensure_state_file docked

    local W H
    # #45/D7: canonical resolver (this site was the old odd-720-out, #27).
    mcss_resolve_screen
    W="$MCSS_SCREEN_W"; H="$MCSS_SCREEN_H"
    local hw=$((W/2)) hh=$((H/2))
    # #55: default was 12 here while every other harness path used 15 — drifted.
    local delay="${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15}"
    echo "[sweep] single-instance position sweep on ${W}x${H}, observe ${delay}s/step" >> "$LOG"

    # Give the mod its single-instance config, then spawn slot 1 only.
    if declare -f _write_splitscreen_properties >/dev/null 2>&1; then
        _write_splitscreen_properties 1 "1" 2>/dev/null || true
    fi
    echo "[sweep] spawning slot 1 (single instance)…" >> "$LOG"
    spawn_instance 1 "" "" >> "$LOG" 2>&1 || true

    local wid="" i
    for i in $(seq 1 60); do
        wid=$(_get_wid_from_state 1 2>/dev/null || true)
        [[ -n "$wid" ]] && break
        sleep 1
    done
    if [[ -z "$wid" ]]; then
        echo "[sweep] ERROR: slot 1 window never appeared — aborting sweep" >> "$LOG"
        declare -f teardown_all_instances >/dev/null 2>&1 && teardown_all_instances 2>/dev/null || true
        return 1
    fi
    echo "[sweep] slot 1 wid=$wid — beginning sweep" >> "$LOG"

    _sweep_geo() { xwininfo -id "$1" 2>/dev/null | awk '/Absolute upper-left X/{x=$NF}/Absolute upper-left Y/{y=$NF}/Width:/{w=$NF}/Height:/{h=$NF}/Map State/{m=$NF}END{if(w=="")print "<none>";else printf "%sx%s+%s+%s %s",w,h,x,y,m}'; }

    local positions=(
        "FULL 0 0 $W $H"
        "TOP_HALF 0 0 $W $hh"
        "BOTTOM_HALF 0 $hh $W $hh"
        "QUAD_TL 0 0 $hw $hh"
        "QUAD_TR $hw 0 $hw $hh"
        "QUAD_BL 0 $hh $hw $hh"
        "QUAD_BR $hw $hh $hw $hh"
    )
    local p name x y w h
    for p in "${positions[@]}"; do
        read -r name x y w h <<< "$p"
        echo "[sweep] ===== $name → target ${w}x${h}+${x}+${y} =====" >> "$LOG"
        _position_slot 1 "$x" "$y" "$w" "$h" >> "$LOG" 2>&1 || true
        sleep 2
        echo "[sweep]   immediately: $(_sweep_geo "$wid")" >> "$LOG"
        sleep "$delay"
        echo "[sweep]   after ${delay}s:  $(_sweep_geo "$wid")" >> "$LOG"
    done

    echo "[sweep] sweep complete — tearing down" >> "$LOG"
    declare -f teardown_all_instances >/dev/null 2>&1 && teardown_all_instances 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# launchNested: Run the Phase B session inside a BARE nested KWin compositor.
# kwin_wayland nests as a Wayland client of the current session compositor
# (gamescope in Game Mode, host KWin in Desktop Mode) and owns the full screen
# with NO Plasma shell/panel — so instances tile across the entire display and
# nothing draws behind a menu bar.  Controller isolation is unaffected: only the
# DISPLAY target changes; bwrap --dev-bind device isolation is untouched.
# Inputs: $2 — optional TEST_NUMBER; Globals: WAYLAND_DISPLAY (read/detected)
# Outputs: does not return — execs kwin_wayland, whose session command
#          re-invokes this script as `_nestedSession` (env carried via
#          mcss_exec_env_string + explicit NAME=VALUE pairs on the exec line;
#          see the `_nestedSession)` case below for what it consumes)
# ─────────────────────────────────────────────────────────────────────────────
launchNested() {
    echo "[launchNested] start" >> "$LOG"
    if [[ -n "${2:-}" ]]; then
        export TEST_NUMBER="$2"
    fi

    # Parent compositor socket (kwin nests into it).  Auto-detect if unset.
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" cand
        for cand in gamescope-0 wayland-0 wayland-1; do
            [[ -S "$rt/$cand" ]] && { export WAYLAND_DISPLAY="$cand"; break; }
        done
    fi
    echo "[launchNested] parent WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<none>}" >> "$LOG"

    # Nested resolution.  CRITICAL: do NOT probe the compositor here (wlr-randr /
    # xdpyinfo).  When launched as a Steam game, gamescope watches the game's
    # Wayland clients — a throwaway probe that connects and immediately disconnects
    # makes gamescope think the game exited and it kills us before we ever exec
    # kwin (observed: trace died right after a wlr-randr connect/disconnect).  KWin
    # must be the FIRST and ONLY client.  mcss_resolve_screen --no-probe exists
    # for exactly this path: env override or 1280x800, never a probe.
    local W H
    mcss_resolve_screen --no-probe
    W="$MCSS_SCREEN_W"; H="$MCSS_SCREEN_H"
    echo "[launchNested] nested resolution ${W}x${H} (override SPLITSCREEN_SCREEN_W/H to change)" >> "$LOG"

    # Snapshot existing X sockets so the nested session can identify which XWayland
    # display kwin creates — it auto-picks the lowest free number and ignores
    # --xwayland-display (confirmed on-Deck: requesting :2 yields :1 when free).
    # Passed to the session child via env as a comma-wrapped list.
    local x_before
    x_before=",$(ls /tmp/.X11-unix/ 2>/dev/null | tr '\n' ',')"

    # Re-invoke THIS script as kwin's session leader.  kwin_wayland becomes the
    # FOREGROUND process so Steam/gamescope tracks and focuses it — a backgrounded
    # nested compositor never gets focus in Game Mode (confirmed on-Deck: gamescope
    # only displays apps launched through Steam).  kwin launches the session command
    # with WAYLAND_DISPLAY + DISPLAY pointing at the nested compositor; _nestedSession
    # runs the orchestrator + tests there and then exits, which makes kwin — and thus
    # the Steam "game" — exit too.
    local self; self="$(readlink -f "$0")"
    echo "[launchNested] exec nested kwin ${W}x${H} → _nestedSession (test=${TEST_NUMBER:-all})" >> "$LOG"
    exec kwin_wayland \
        --width "$W" --height "$H" \
        --no-lockscreen --no-global-shortcuts \
        --xwayland \
        -- env \
            $(mcss_exec_env_string MCSS_NESTED_SESSION=kwin TEST_NUMBER=${TEST_NUMBER:-all} SPLITSCREEN_TEST_OBSERVE_DELAY_S=${SPLITSCREEN_TEST_OBSERVE_DELAY_S:-15}) \
            SPLITSCREEN_STATE="$SPLITSCREEN_STATE" \
            SPLITSCREEN_FIFO="$SPLITSCREEN_FIFO" \
            SPLITSCREEN_DEBUG_LOG="$LOG" \
            _NESTED_X_BEFORE="$x_before" \
            bash "$self" _nestedSession
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point — Phase B: event-loop orchestrator
# ─────────────────────────────────────────────────────────────────────────────
# dispatch_mode is set by the test/testPlasma wrappers to override the
# default behavior when running automated tests inside nested KDE.

# Fail-fast HARD STOP if the KDE/Plasma/KWin stack (or other critical deps) is missing —
# a clear, distro-aware message beats a cryptic mid-launch crash (preflight, item G).
# Skip only the version flag (needs no deps).
if declare -f _preflight_deps >/dev/null 2>&1; then
    case "${1:-}" in
        --version|-v) : ;;
        *) _preflight_deps launch || exit 1 ;;
    esac
fi

case "${1:-}" in
    launchFromPlasma)
        # PRODUCTION entry — this is the LaunchOptions the Steam shortcut runs
        # (set by add-to-steam.py). Start the nested Plasma session; its autostart
        # re-invokes this script as `prodFromPlasma` INSIDE the session. (A1: previously
        # this fell through to `*) → main()` with no nested compositor = no splitscreen.)
        echo "[main] Production launch — launchFromPlasma (starting nested Plasma)" >> "$LOG"
        launchFromPlasma
        ;;
    prodFromPlasma)
        # PRODUCTION inner handler — runs INSIDE the nested Plasma session (from the
        # launchFromPlasma autostart). Strips the panel + runs the real orchestrator.
        echo "[main] Production launch — prodFromPlasma (inside nested Plasma)" >> "$LOG"
        if declare -f launchProdFromPlasma >/dev/null 2>&1; then
            launchProdFromPlasma
        else
            echo "[main] ERROR: launchProdFromPlasma not available — modules not sourced?" >> "$LOG"
        fi
        ;;
    test)
        # Phase B lifecycle test: first call from outside nested session.
        # Optional second arg is a test number for the harness.
        # Steam launch option: "test" (run all) or "test 6" (run specific)
        echo "[main] Phase B test mode — starting (outer)" >> "$LOG"
        if [[ -n "${2:-}" ]]; then
            export TEST_NUMBER="$2"
            echo "[main] Test number: $TEST_NUMBER" >> "$LOG"
        fi
        testPlasma
        ;;
    testFromPlasma|testPlasma)
        # Called from KDE autostart inside the nested test session
        echo "[main] Phase B test mode — inside KDE session" >> "$LOG"
        if declare -f launchTestFromPlasma >/dev/null 2>&1; then
            launchTestFromPlasma
        elif declare -f main >/dev/null 2>&1; then
            echo "[main] No launchTestFromPlasma — starting orchestrator main()" >> "$LOG"
            main
        else
            # Fix #90: launchWindowTest/runStaticTest (the Phase-A prototype
            # fallback that used to run here) are deleted — this IS the
            # correct behavior when neither handler is available.
            echo "[main] ERROR: runtime modules missing (no" \
                "launchTestFromPlasma/main) — reinstall/redeploy" >> "$LOG"
            exit 1
        fi
        ;;
    testDirect)
        # Run Phase B tests directly against an EXISTING display session (the bare
        # host :0).  Does NOT start a nested compositor — windows render on the host
        # desktop (subject to its panel/WM).  Kept for SSH/headless debugging; for a
        # clean full-screen run use "testNested".
        # Usage: DISPLAY=:0 XAUTHORITY=… bash minecraftSplitscreen.sh testDirect [N]
        echo "[main] testDirect — using existing display ${DISPLAY:-<unset>}" >> "$LOG"
        if [[ -n "${2:-}" ]]; then
            export TEST_NUMBER="$2"
        fi
        _td_cleanup() {
            [[ -n "${_PHASE_B_ORCH_PID:-}" ]] && { _kill_tree "$_PHASE_B_ORCH_PID" TERM; sleep 1; _kill_tree "$_PHASE_B_ORCH_PID" KILL; }
            rm -f "$SPLITSCREEN_FIFO" 2>/dev/null || true
        }
        trap '_td_cleanup' EXIT
        _run_phase_b_session
        trap - EXIT
        ;;
    testNested)
        # Run Phase B tests inside a BARE nested KWin compositor (full screen, no
        # panel).  Works from Game Mode (nests into gamescope) or Desktop Mode
        # (nests into host KWin).  This is the intended path — instances tile across
        # the whole display with no menu bar, and we fully control window placement.
        # Usage: bash minecraftSplitscreen.sh testNested [N]
        echo "[main] testNested — bare nested KWin compositor" >> "$LOG"
        launchNested "$@"
        ;;
    _nestedSession)
        # INTERNAL: runs INSIDE the bare nested kwin (launched by launchNested's
        # `exec kwin_wayland … -- … bash "$0" _nestedSession`).  kwin sets
        # WAYLAND_DISPLAY + DISPLAY for this session; resolve/confirm the nested X
        # display, run the Phase B session against it, then terminate kwin so the
        # Steam "game" exits cleanly.
        echo "[_nestedSession] start (DISPLAY=${DISPLAY:-<unset>})" >> "$LOG"
        _ns_display="${DISPLAY:-}"
        _ns_ready=0
        for _i in $(seq 1 60); do
            if [[ -n "$_ns_display" ]] && DISPLAY="$_ns_display" xdpyinfo >/dev/null 2>&1; then
                _ns_ready=1; break
            fi
            # Fallback: kwin didn't export DISPLAY — find the new X socket vs the
            # snapshot launchNested passed in _NESTED_X_BEFORE.
            _newx=""
            for _x in /tmp/.X11-unix/X*; do
                [[ -e "$_x" ]] || continue
                _b="$(basename "$_x")"
                case "${_NESTED_X_BEFORE:-,}" in
                    *",$_b,"*) ;;
                    *) _newx="$_b" ;;
                esac
            done
            if [[ -n "$_newx" ]]; then
                _ns_display=":${_newx#X}"
                DISPLAY="$_ns_display" xdpyinfo >/dev/null 2>&1 && { _ns_ready=1; break; }
            fi
            sleep 0.5
        done
        if [[ "$_ns_ready" -ne 1 ]]; then
            echo "[_nestedSession] ERROR: nested X display never became ready" >> "$LOG"
            exit 1
        fi
        # nested XWayland accepts local same-user connections without auth; drop any
        # inherited (stale) cookie so it can't cause a spurious rejection.
        unset XAUTHORITY
        export DISPLAY="$_ns_display" GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb
        # #45: single-writer for the nested X display — consumers (dex, etc.)
        # read MCSS_DISPLAY at call time instead of capturing DISPLAY at source time.
        mcss_set_display "$_ns_display"
        echo "[_nestedSession] nested display ready: $DISPLAY" >> "$LOG"

        # Give the nested compositor an IMMEDIATE full-screen background window.
        # gamescope shows a loading spinner for a nested compositor that presents no
        # window (the old nested-Plasma path always had plasmashell's surfaces, so
        # gamescope always had content).  A persistent black full-screen window makes
        # KWin present a surface right away → gamescope displays it — and it doubles
        # as the black backdrop behind the splitscreen tiles.  Sized from the nested
        # root window (querying our OWN XWayland is safe; the earlier problem was
        # probing the gamescope parent before kwin existed).
        _ns_geo=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2; exit}')
        [[ -z "$_ns_geo" ]] && _ns_geo="1280x800"
        _ns_bw="${_ns_geo%x*}"; _ns_bh="${_ns_geo#*x}"
        echo "[_nestedSession] spawning ${_ns_bw}x${_ns_bh} background window" >> "$LOG"
        python3 -c "
import tkinter as tk
r=tk.Tk(); r.overrideredirect(True); r.geometry('${_ns_bw}x${_ns_bh}+0+0'); r.configure(bg='black')
r.lower(); r.mainloop()
" >> "$LOG" 2>&1 &
        _NS_BG_PID=$!
        sleep 1

        _run_phase_b_session
        kill "$_NS_BG_PID" 2>/dev/null || true
        echo "[_nestedSession] session complete — terminating nested kwin (PPID=$PPID)" >> "$LOG"
        kill -TERM "$PPID" 2>/dev/null || true
        ;;
    *)
        # #43/#42 GUARD: a bare invocation with no argument used to fall straight into
        # main() -> docked_flow on WHATEVER display is currently active — that's exactly
        # how #42 happened (a Desktop-Mode .desktop shortcut with no LaunchOptions spawned
        # a live 4-player splitscreen outside gamescope). Only proceed if we're already
        # confirmed inside our own nested session (MCSS_NESTED_SESSION=plasma|kwin, set by
        # launchFromPlasma/testPlasma/launchNested before they re-invoke this
        # script) OR the OUTER context is gamescope itself (mcss_require_gamescope checks
        # XDG_CURRENT_DESKTOP/XDG_SESSION_DESKTOP, which is only meaningful pre-nesting).
        if [[ "${MCSS_NESTED_SESSION:-0}" != "0" ]] || { declare -f mcss_require_gamescope >/dev/null 2>&1 && mcss_require_gamescope; }; then
            if declare -f main >/dev/null 2>&1; then
                echo "[main] Phase B orchestrator available — starting main()" >> "$LOG"
                main
            else
                # Fix #90: launchWindowTest/nestedPlasma (the Phase-A
                # prototype fallback that used to run here) are deleted —
                # this IS the correct behavior when main() is absent.
                echo "[main] ERROR: runtime modules missing (main() not" \
                    "available) — reinstall/redeploy" >> "$LOG"
                exit 1
            fi
        else
            echo "[main] REFUSED bare invocation outside gamescope/nested session — see runtime_context guard above. Launch via the Steam shortcut instead." >> "$LOG"
            # #40/#42: a bare double-click (e.g. the desktop shortcut) used to either
            # crash silently (#40, _set_mode) or spawn a runaway (#42). Now it's refused
            # safely, but give visible feedback instead of "nothing happens" — Game Mode
            # has no terminal to see the log in.
            if command -v kdialog >/dev/null 2>&1; then
                kdialog --error "Minecraft Splitscreen only runs from the Steam library (Game Mode)." >/dev/null 2>&1 &
            elif command -v zenity >/dev/null 2>&1; then
                zenity --error --text="Minecraft Splitscreen only runs from the Steam library (Game Mode)." >/dev/null 2>&1 &
            fi
            exit 1
        fi
        ;;
esac
