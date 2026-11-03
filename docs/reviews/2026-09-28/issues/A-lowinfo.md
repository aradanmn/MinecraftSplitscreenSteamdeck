title: [A14-A28] Orchestrator/launcher low & info findings: subshell state loss, kill 0, dead code, hygiene
severity: low
security: no
type: Task
related: #135
---
- [ ] A14 — State-mutating calls run inside `| sed` pipelines (subshells)
- [ ] A15 — `main()` re-embeds the FIFO default literal
- [ ] A16 — Pipeline assignments under the leaked `set -e -o pipefail` in the launcher prologue paths
- [ ] A17 — `kill "${_PANEL_KILLER_PID:-0}"` defaults to `kill 0` (whole process group)
- [ ] A18 — Persistent FIFO fd inherited by every child (incl. the bwrap/JVM sandbox); re-opened without closing
- [ ] A19 — Advertised launcher overrides not carried across the autostart re-exec
- [ ] A20 — Hard-coded paths/names that bypass the resolvers or drift by Plasma version
- [ ] A21 — Debug log is a predictable world-readable `/tmp` xtrace file recording controller identities
- [ ] A22 — Three encodings of the "reset this slot" record
- [ ] A23 — Heartbeat restart of the controller monitor drops pads connected during the outage
- [ ] A24 — `docked_flow`'s return code 1 is overloaded (FIFO unset vs re-enter handheld)
- [ ] A25 — Installer `main()`: misleading "Run:" hint, duplicated repo URL, shared `/tmp` debug dir, non-local loop var
- [ ] A26 — Dead code: `restorePanels`, unreachable `--version` arm, prod-dead `_find_slot_by_uniq`
- [ ] A27 — Hygiene: leaked globals; `$0` vs `BASH_SOURCE`; `$DISPLAY` under `set -u`; magic `timeout 7200`; EXIT-only test trap
- [ ] A28 — `*)` nested-session entry into `main()` never resets the state file

## Summary
Fifteen Low/Info findings from review A (launcher entry, orchestrator, runtime context, installer main) that are each too small for their own issue but share files with the Medium+ fixes and are cheapest to land while those files are open. Twelve of them have one-line (or near) fixes shown below; the one-liner hunks were applied together on a scratch copy — `bash -n` passes on every touched file, the combined diff passes `git apply --check` against the pristine tree, and `tests/test_orchestrator.sh` is 9/9 on the patched copy. A15/A26(`_find_slot_by_uniq`)/A18(idempotent open) are also covered by the A13/A11/A3 diffs respectively; if those land first, tick them here. None of these needs a design decision except A22 and A23 (sentences, not diffs).

### A14. State-mutating calls run inside `| sed` pipelines (subshells)
`modules/orchestrator.sh:412`, `:673`, `:754`, `:1109`, `:1114`. `teardown_instance "$slot" 2>&1 | sed … >&2 || true`, `spawn_instance 1 "" "" 2>&1 | sed …`, `teardown_all_instances 2>&1 | sed …`: the left side of a pipeline is a subshell, so in-process globals the callee updates (`_CONTROLLER_PROXY_PIDS` via `proxy_stop_slot`/`proxy_start_slot`) are discarded and `|| true` applies to `sed`, not the function; the SLOT_DIED arm (`:637-645`) already uses a temp file precisely to avoid this. Fix: use the same temp-file pattern at the four remaining sites (or `{ teardown_instance "$slot"; } 2> >(sed 's/^/[orchestrator] /' >&2)` — PRINCIPLES #8 caveat: a process substitution must not outlive the caller on a capture pipe). Impact today is a stale pid cache (the pidfile is authoritative, `controller_proxy.sh:48-58`); the pattern is a trap for any future in-memory state.

### A15. `main()` re-embeds the FIFO default literal
`modules/orchestrator.sh:973-977` vs `modules/runtime_context.sh:326`. Two encodings of a cross-process contract value (PRINCIPLES #9, ARCHITECTURE §3). Fix (also part of the A13 diff):
```diff
@@ -970,11 +974,8 @@
     # ── Ensure FIFO exists
-    local fifo="${SPLITSCREEN_FIFO:-}"
-    if [[ -z "$fifo" ]]; then
-        fifo="/tmp/minecraft-splitscreen.fifo"
-        export SPLITSCREEN_FIFO="$fifo"
-    fi
+    mcss_resolve_paths                      # A15: idempotent; owns the default
+    local fifo="$SPLITSCREEN_FIFO"
     if [[ ! -p "$fifo" ]]; then
```

### A16. Pipeline assignments under the leaked `set -e -o pipefail`
`minecraftSplitscreen.sh:171` (`_snapshot_session_env`), `:363` (`_mcss_stale_tree_pids`). Sourced modules turn on `set -euo pipefail` for the launcher shell (`:414-420`); `cur=$(systemctl --user show-environment | sed … | head -1)` and `_p=$(ps -o ppid= -p "$_p" | tr -d ' ')` are assignments from pipelines, so a non-zero `systemctl` (no user bus) or `ps` (an ancestor exiting mid-walk) kills the launcher before Plasma starts, with only an xtrace line. PLAUSIBLE. Fix:
```diff
-        cur=$(systemctl --user show-environment 2>/dev/null | sed -n "s/^${v}=//p" | head -1)
+        cur=$(systemctl --user show-environment 2>/dev/null | sed -n "s/^${v}=//p" | head -1 || true)
…
-        _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
+        _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || true)
```

### A17. `kill "${_PANEL_KILLER_PID:-0}"` defaults to `kill 0`
`minecraftSplitscreen.sh:567`, `:596`, `:750`, `:773`. With the variable unset/empty this signals the launcher's whole process group (in the nested session: the orchestrator, monitors, in-flight spawns). Latent — the var is always set at `:559`/`:745` before the trap can fire — but the intent is "no-op if unset". Fix (all four sites):
```diff
-    trap 'declare -f cleanup >/dev/null 2>&1 && cleanup; _restore_session_env; kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null; _end_nested_session' EXIT INT TERM HUP
+    trap 'declare -f cleanup >/dev/null 2>&1 && cleanup; _restore_session_env; [[ -n "${_PANEL_KILLER_PID:-}" ]] && kill "$_PANEL_KILLER_PID" 2>/dev/null; _end_nested_session' EXIT INT TERM HUP
…
-    kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null || true
+    [[ -n "${_PANEL_KILLER_PID:-}" ]] && kill "$_PANEL_KILLER_PID" 2>/dev/null || true
```

### A18. Persistent FIFO fd inherited by every child; re-opened without closing
`modules/orchestrator.sh:120-124`, `:722`, `:833`, `:1130-1133`. `exec {_SPLITSCREEN_FIFO_FD}<> "$fifo"` opens without `FD_CLOEXEC`, so the fd rides into `start_controller_monitor`, `udevadm`, `inotifywait`, `evsieve`, `bwrap` and the game JVM (the sandbox gets a read-write handle to the orchestrator's control channel); a second `_open_fifo_reader` call orphans the first fd. Fix: the idempotent open is in the A3 diff; additionally close the fd in children — `start_controller_monitor docked {_SPLITSCREEN_FIFO_FD}<&- &`, `watch_display_mode {_SPLITSCREEN_FIFO_FD}<&- &`, `start_watchdog {_SPLITSCREEN_FIFO_FD}<&- &` and `spawn_instance … {_SPLITSCREEN_FIFO_FD}<&-` inside `_launch_slot`'s brace group (bash ≥ 4.1 `{var}<&-` syntax; guard with `[[ -n "$_SPLITSCREEN_FIFO_FD" ]]`). Verify with `ls -l /proc/<java pid>/fd | grep -c fifo` → 0 on the Deck.

### A19. Advertised overrides not carried across the autostart re-exec
`minecraftSplitscreen.sh:11-14` (header advertises `N_SLOTS`, `INSTANCES_DIR`, `LAUNCHER_EXEC`), `modules/runtime_context.sh:739-764` (`_canonical` list). `mcss_exec_env_string` carries `MCSS_CONTROLLER_PROXY` "so the child does not re-derive its own default" but omits `MCSS_MAX_PLAYERS`, `MCSS_RAW_BINDING` (`:745-750` admits the risk), `MCSS_INSTANCES_DIR`, `MCSS_LAUNCHER_EXEC`, `MCSS_SCREEN_W/H` (`:754-757` calls it a carried contract) and `MCSS_NESTED_KWIN_NNP`; the nested `prodFromPlasma` process re-resolves them from ITS environment. PLAUSIBLE (Steam LaunchOptions `N_SLOTS=2 launchFromPlasma` → nested orchestrator runs 4 slots). Fix: append `MCSS_MAX_PLAYERS MCSS_RAW_BINDING MCSS_INSTANCES_DIR MCSS_LAUNCHER_EXEC MCSS_SCREEN_W MCSS_SCREEN_H MCSS_NESTED_KWIN_NNP` to `_canonical` (all are exported resolved values; `MCSS_LAUNCHER_EXEC` may contain a space for the flatpak form — `_mcss_emit_env` refuses it loudly, so pass that one as a quoted extra at the call site). Add a `test_runtime_context.sh` case: `N_SLOTS=2 … mcss_exec_env_string` contains `MCSS_MAX_PLAYERS=2`.

### A20. Hard-coded paths/names that bypass the resolvers or drift by Plasma version
(a) `modules/runtime_context.sh:76`: `SPLITSCREEN_STATE` defaults under `$HOME/.local/share/PolyMC/` regardless of the `MCSS_LAUNCHER_ROOT` cascade (`:269-280`, no `# PAIRED` with `install-minecraft-splitscreen.sh:334`) — a PrismLauncher install writes its state under a PolyMC dir. Fix: derive it inside `mcss_resolve_paths` after the root is known (`${SPLITSCREEN_STATE:-$MCSS_LAUNCHER_ROOT/splitscreen_state.json}`; the hardware harness already exports its own). (b) `minecraftSplitscreen.sh:238` hardcodes `/usr/bin/kwin_wayland_wrapper` while `modules/preflight.sh:146-147` only checks that SOME wrapper is on PATH — resolve with `command -v kwin_wayland_wrapper` at shim-write time, excluding `$MCSS_HELPER_DIR`. (c) `minecraftSplitscreen.sh:642-645` lists `kded6` only; SteamOS ≤3.6 (Plasma 5.27) has `kded5`, which survives and keeps the "game" alive:
```diff
-                   plasma_session baloo_file kded6 \
+                   plasma_session baloo_file kded5 kded6 \
```

### A21. Debug log is a predictable world-readable `/tmp` xtrace file (security)
`minecraftSplitscreen.sh:70`, `:87-90`. `LOG=/tmp/splitscreen-debug-$(date +%Y%m%d-%H%M%S).log`, then `exec 2>>"$LOG"; set -x`: predictable to the second (symlink pre-planting → append as the Deck user to an attacker-chosen file), default umask (world-readable), and the xtrace records every `CONTROLLER_ADD … <phys_uniq>` (Bluetooth MACs) and the full Exec env strings. Fix: `umask 077` before the `exec`, `LOG` under `$MCSS_HELPER_DIR` (needs `mcss_resolve_paths` before `:70` — or `mktemp /tmp/splitscreen-debug-XXXXXX.log`), keep only the `-latest` symlink in `/tmp`. Update the RUNBOOK/README `tail` instructions with the new location.

### A22. Three encodings of the "reset this slot" record
`modules/orchestrator.sh:465`; `modules/instance_lifecycle.sh:1246`; `modules/slot_manager.sh:276-278`. `_launch_slot`'s failure path and `teardown_instance` each inline `{"active": false, "pid": null, "bwrap_pid": null, "event_node": null, "js_node": null, "wid": null}`; `slot_free` writes a third subset (nulls `phys_*`/`disconnected*`, NOT `pid`/`bwrap_pid`/`wid`). None resets everything — the gap that lets B1/A2 leave live PIDs behind an `active:false` record. Fix: one `slot_reset <n>` in instance_lifecycle (next to `update_slot_state`) that nulls every schema field (`active pid bwrap_pid wid event_node js_node phys_uniq phys_vendor phys_product disconnected disconnected_at`), called from all three sites; `slot_free` becomes a thin alias. Test: `test_slot_manager.sh` asserts every field is null after `slot_free`; mutation = drop one field.

### A23. Heartbeat restart of the controller monitor drops pads connected during the outage
`modules/orchestrator.sh:362-364`. The restarted monitor runs with `CONTROLLER_MONITOR_SKIP_INITIAL_EMIT=1`, re-baselining `prev_nodes` from the current device list without emitting, so a pad that appeared while the monitor was dead is in the baseline and never produces a `CONTROLLER_ADD`. Fix: on restart run the docked acquisition pass once — dispatch `list_eligible_controllers docked` lines through `_handle_msg "CONTROLLER_ADD …"` (`slot_claim` de-duplicates known pads as REJECT/RESUME) — then start the monitor hotplug-only; factor the acquisition loop out of `docked_flow` (`:856-869`) into `_acquire_present_controllers` so both callers share it (PRINCIPLES #9).

### A24. `docked_flow`'s return code 1 is overloaded
`modules/orchestrator.sh:821-824`, `:918-919`, `:1011-1016`. Header (`:791-792`) documents both "FIFO unset" and "re-enter handheld" as `1`; `main()` treats any 1 as re-entry and runs `handheld_flow`, which fails the same FIFO check. Harmless today (main always sets the FIFO) but makes the A3/A4/A6 hand-over fragile. Fix: `return 2`… is taken by A6 for "go docked"; use `return 3` for the FIFO error in both flows and document the codes as named constants (`ORCHESTRATOR_RC_GO_HANDHELD=1`, `ORCHESTRATOR_RC_GO_DOCKED=2`, `ORCHESTRATOR_RC_FATAL=3`) in the constants block; `main()`'s loop (A6) breaks on anything but 1/2.

### A25. Installer `main()`: misleading "Run:" hint, duplicated URL, shared `/tmp` debug dir, non-local loop var
`modules/main_workflow.sh:230`, `:243`, `:61`, `:216`; paired writer `modules/instance_creation.sh:379`. (a) The completion banner tells the user to run the launcher directly — the `*)` dispatch refuses a bare invocation outside gamescope (`minecraftSplitscreen.sh:1176-1211`), so following it yields "nothing happens" + a kdialog. (b) The support URL is a second literal of the repo base (the only constant today is `MCSS_REPO_RAW_URL`, the raw-content URL — add `MCSS_REPO_URL` next to it in `install-minecraft-splitscreen.sh:115` and print that). (c) `/tmp/mcss-debug-api` is a fixed shared-namespace path that `instance_creation.sh` then writes into. (d) `mod` leaks as a global (STYLE §7.4). Fix for (a)(c)(d):
```diff
--- a/modules/main_workflow.sh
-        rm -rf "/tmp/mcss-debug-api" 2>/dev/null || true
+        rm -rf "${TMPDIR:-/tmp}/mcss-debug-api-$(id -u)" 2>/dev/null || true
…
+        local mod
         for mod in "${MISSING_MODS[@]}"; do
…
-    echo "Run: $TARGET_DIR/minecraftSplitscreen.sh"
+    echo "Launch: from the Steam library entry \"Minecraft Splitscreen\" (Game Mode). Running $TARGET_DIR/minecraftSplitscreen.sh directly is refused outside gamescope."
--- a/modules/instance_creation.sh
-                local debug_dir="/tmp/mcss-debug-api"
+                local debug_dir="${TMPDIR:-/tmp}/mcss-debug-api-$(id -u)"   # PAIRED: main_workflow.sh --debug cleanup
```

### A26. Dead code: `restorePanels`, unreachable `--version` arm, prod-dead `_find_slot_by_uniq`
`modules/orchestrator.sh:1113-1115` (`restorePanels` — `grep -rn restorePanels` finds only the guarded call and two test stubs at `tests/test_orchestrator.sh:225,380`, which make tests pass against a function the product never defines); `minecraftSplitscreen.sh:1027-1032` (`--version|-v) : ;;` can never run — `:58-61` already exited); `modules/orchestrator.sh:266-275` (`_find_slot_by_uniq`, deleted by the A11 diff). Fix for the first two (drop the two test stubs as well):
```diff
--- a/modules/orchestrator.sh
-    # ── Restore panels
-    if type restorePanels >/dev/null 2>&1; then
-        restorePanels 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
-    fi
-
--- a/minecraftSplitscreen.sh
+# (--version/-v already exited at the top of the file — no arm needed here.)
 if declare -f _preflight_deps >/dev/null 2>&1; then
-    case "${1:-}" in
-        --version|-v) : ;;
-        *) _preflight_deps launch || exit 1 ;;
-    esac
+    _preflight_deps launch || exit 1
 fi
```

### A27. Hygiene: leaked globals; `$0` vs `BASH_SOURCE`; `$DISPLAY` under `set -u`; magic timeout; EXIT-only test trap
`modules/orchestrator.sh:144,158` (`msg` global in `_read_fifo_msg`), `:227` (`slot` global in `_find_free_slot`); `minecraftSplitscreen.sh:838` (`SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"` overwrites the prologue's BASH_SOURCE-derived global — the Fix #80 regression), `:835` (`(DISPLAY=$DISPLAY)` unguarded under the leaked `set -u` — `testDirect` from SSH without DISPLAY dies with "unbound variable"), `:841` (`timeout 7200` magic), `:750` (test-path trap is `EXIT` only, unlike the H4-fixed prod trap). Fix:
```diff
--- a/modules/orchestrator.sh
-    local timeout_s="${1:-5}"
+    local timeout_s="${1:-5}" msg
…
 _find_free_slot() {
+    local slot
--- a/minecraftSplitscreen.sh
-    echo "[run_phase_b] orchestrator loop PID=$_PHASE_B_ORCH_PID (DISPLAY=$DISPLAY)" >> "$LOG"
+    echo "[run_phase_b] orchestrator loop PID=$_PHASE_B_ORCH_PID (DISPLAY=${DISPLAY:-unset})" >> "$LOG"
…
-    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
+    # SCRIPT_DIR: the prologue's BASH_SOURCE-derived value (Fix #80) — not $0.
     local test_script="$SCRIPT_DIR/tests/test_phase_b_lifecycle.sh"
+    local _PHASE_B_TIMEOUT_S=7200
     if [[ -f "$test_script" ]]; then
-        timeout 7200 bash "$test_script" "${TEST_NUMBER:-all}" || true
+        timeout "$_PHASE_B_TIMEOUT_S" bash "$test_script" "${TEST_NUMBER:-all}" || true
…
-    trap '_restore_session_env; …; _end_nested_session' EXIT
+    trap '_restore_session_env; …; _end_nested_session' EXIT INT TERM HUP
```
(`_find_free_slot` itself is deleted by A11; the `local slot` line then has no target.)

### A28. `*)` nested-session entry into `main()` never resets the state file
`minecraftSplitscreen.sh:1185-1188`; `modules/orchestrator.sh:209-214`. `launchProdFromPlasma` calls `_ensure_state_file` (`:585`) to wipe a crashed run's `active:true` slots; the `*)` arm (`MCSS_NESTED_SESSION=kwin` / gamescope bare) goes straight to `main()`, whose `_set_mode` only initializes a MISSING/invalid file. Stale `active:true` records are then handed to `_reap_dead_slots` (fine) but also to `slot_claim`'s `slot_find_by_uniq` (RESUME onto a slot with no instance until the reap runs). Fix (idempotent, `_atomic_write`-safe):
```diff
--- a/modules/orchestrator.sh
 main() {
     echo "[orchestrator] main() starting — PID=$$" >&2
+    # A28: every entry into main() starts from a clean state file (the `*)`
+    # nested-session dispatch skipped this; prodFromPlasma did it itself).
+    _ensure_state_file
```
Note `tests/test_orchestrator.sh` T6.8/T6.9 pass with this (they drive the flows, not `main()`); a test that calls `main()` with a pre-populated state file would need to expect the reset.

## Hardware verification
One docked stage3 + stage6 pass on the Deck after the batch lands is enough for the group: A16/A17/A26/A27/A28 are exercised by any real launch + quit (`tests/hardware/run_all.sh stage2` then `stage6` — no survivors, `[supervise_reap] entered` present, `grep -c 'unbound variable' /tmp/splitscreen-debug-latest.log` → 0); A20(c) needs a SteamOS ≤3.6 (Plasma 5.27) Deck for `kded5`; A18 is proven by `ls -l /proc/<java pid>/fd | grep -c fifo` → 0; A19 by `N_SLOTS=2 launchFromPlasma` in the Steam launch options → the nested log shows `MCSS_MAX_PLAYERS=2` on the Exec line and a third pad is REJECTed; A21 by `stat -c %a /run/user/1000/mcss/splitscreen-debug-*.log` → 600; A23 by `kill $(pgrep -f start_controller_monitor)` from SSH, plugging a pad DURING the ~5 s outage, and seeing it spawn after `Controller monitor restarted`; A14/A15/A22/A24/A25 are CI + unit test only (no behavioral change on hardware).

## References
Review: A14–A28 (docs/reviews/2026-09-28/A-orchestrator.md; consolidated §5 table and §7 patterns 3/4/6). PRINCIPLES #8 (A14), #9 (A15, A22, A23), #7 (A17), #6 (A27 timeout), #1 (A22). Related: #135 (A18/A26 — orphaned handles and dead teardown steps in the same cleanup path), the A3/A4/A6 mode-transition issues (A24), A11 (A26's `_find_slot_by_uniq`), A12/A13 (A21's `/tmp` class), B1 (A22). STYLE-GUIDE §7.4 (A25/A27 locals), Fix #80 (A27 `$0`).
