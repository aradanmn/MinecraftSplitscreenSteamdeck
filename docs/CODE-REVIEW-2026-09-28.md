# Deep Code Review — 2026-09-28

Reviewed at commit `7c04a59` (`main`). Scope: every shipped file — the launcher
(`minecraftSplitscreen.sh`), all 26 `modules/*.sh`, the installer / uninstaller /
`deploy.sh`, both Steam helpers (`add-to-steam.py`, `remove-from-steam.py`),
`system/deck-display-fixes/`, both GitHub workflows, `mods.conf`, `accounts.json`,
and the full `tests/` tree (unit suites, `tests/lib`, hardware harness).

**Method.** Seven parallel reviewers, one per module group, each reading its files
line-by-line and tracing cross-module contracts (FIFO message formats, function
signatures, return codes, env vars) into the callee. Every finding was verified
against the code; where a claim could be reproduced in the sandbox it was (marked
"reproduced"). Findings were then de-duplicated across reviewers and re-ranked. The
three most severe (A1, B1, E1) were independently re-verified by the consolidating
reviewer. All 19 CI-gated test suites plus the 8 ungated CI-safe suites were run;
results are in §6. Findings already recorded in an earlier audit doc are tagged
`[KNOWN]`.

The seven per-module reports are preserved verbatim under
`docs/reviews/2026-09-28/` (IDs `A`–`F`, `T` below refer to them). This document
is the consolidated, de-duplicated view.

## Totals (after de-duplication)

| Severity | Count | Of which security-tagged |
|---|---|---|
| Critical | 3 | 0 |
| High | 14 | 2 |
| Medium | 43 | 11 |
| Low | 83 | 9 |
| Info | 34 | 2 |
| **Total** | **177** | **24** |

(190 raw findings from the seven reviewers; 13 merged as duplicates across
reviewers, e.g. the `SLOT_DIED` ordering bug was found independently by A and B.)

## 1. Fix these first

Ordered by user impact × likelihood, not by module.

1. **A1 — the startup guard `pkill -9`s the launcher itself.** `minecraftSplitscreen.sh:447`
   runs `pkill -9 -f PolyMC` and the launcher's own command line is
   `…/.local/share/PolyMC/minecraftSplitscreen.sh`. Any launch that finds leftovers
   SIGKILLs the supervisor mid-sweep and bounces to the Steam library. Reproduced.
2. **B1 — `SLOT_DIED` frees the slot before tearing it down (default path).** With
   `MCSS_CONTROLLER_PROXY=1`, `slot_free` writes `active:false` and then
   `teardown_instance` returns early on its `slot_is_active` guard, so hung JVMs are
   never killed, survive session exit, and the stale `wid` gets the slot's next
   occupant killed ~4 s into its launch. The only test stubs `teardown_instance`.
3. **E1 — the X11 backend mis-declares `XWindowAttributes`.** `map_state` reads the
   colormap XID, so `dex_is_viewable` always says "unmapped" and the map-keeper
   re-maps/raises every window 45× per slot. Verified against `Xlib.h`.
4. **F1 — full uninstall `rm -rf`s `~/.local/share/PrismLauncher`**, a directory this
   project never creates and which commonly holds a user's own worlds. `--yes` skips
   the only confirmation.
5. **D1 — dock detection tears down a docked session on one un-corroborated sysfs
   read** (the HW-2 force-reboot path). PRINCIPLES #5 documents a confirm-across-reads
   design that is not in the code. `[KNOWN #133, reverted #138]`
6. **A3 + A4 — mode transitions are unsafe in both directions.** docked→handheld leaks
   the docked monitors (duplicate spawns/events, orphaned `udevadm`); a dock/undock
   cycle in handheld mode makes `_handle_msg` return 1 → `break` → `cleanup` → the
   single-player game is torn down.
7. **E2 + E3 — `apply_layout` is neither errexit-safe nor status-returning.** A
   positioning failure kills the backgrounded spawn group (no map-keeper, no reflow,
   slot never released, spawn log deleted unread); and because `apply_layout` never
   returns non-zero, the H10 reflow-retry can never fire.
8. **C1 — the installer's documented offline fallbacks are unreachable.**
   `FABRIC_VERSION=$(fetch_url … | jq …)` under `set -euo pipefail` aborts the process
   on a transport error before the fallback line runs. Reproduced.
9. **F2 / T4 / T5 / T6 — the CI gate cannot see regressions.** It compares only
   `passed >= baseline` and discards exit codes; `test_uhid_pad.sh` has 23 tests vs
   baseline 18; `test_window_manager.sh` encodes the *retired* grid rule so reverting
   the fix would turn it green; 7 CI-safe suites are not gated at all.
10. **T1 / T3 / T2 — tests that kill real processes.** The hardware helper runs
    `pkill -9 -f kwin_wayland` (kills a Desktop-Mode session); `test_orchestrator.sh`
    T6.3 runs the real `proxy_stop_slot` against `$XDG_RUNTIME_DIR/mcss`;
    `test_instance_lifecycle.sh` group-kills fixture PIDs below `pid_max`.

Security posture summary: no `curl|bash` inside modules, TLS never disabled, no
secret in the repo (`accounts.json` holds only offline placeholder accounts). Real
gaps: unpinned `main` for every module download including the tagged release asset
(F3); no hash check on mod jars although both APIs return one (B8/C5); prebuilt
evsieve pins nothing locally (D5); `/tmp` at the front of `PATH` on the helper-dir
fallback (A12); several predictable `/tmp` paths incl. the FIFO (A13); user-data
`rm -rf` on unvalidated env vars in the uninstaller (F1/F6); sourcing `~/.profile`
into the installer (C6); `sed` value injection in the build stamp (C7).

---

## 2. Critical

### A1. Startup guard's `pkill -9 -f "$_launcher_name"` SIGKILLs the launcher itself
- **File:** `minecraftSplitscreen.sh:445-447` (guard condition `:439`)
- **Category:** bug / PRINCIPLES #7 · **Status:** CONFIRMED (reproduced)
- **What:** `_launcher_name=$(basename "$MCSS_LAUNCHER_ROOT")` is `PolyMC`; the guard
  then runs `pkill -9 -f "$MCSS_INSTANCE_PREFIX"`, `pkill -9 -f "bwrap.*PolyMC"` and
  `pkill -9 -f "PolyMC"`. The launcher is deployed to
  `$HOME/.local/share/PolyMC/minecraftSplitscreen.sh` (`install-minecraft-splitscreen.sh:334`,
  `add-to-steam.py:42`) and Steam runs it from that path, so the third pattern matches
  this process and Steam's reaper. `pkill` excludes only its own PID. `|| true` cannot
  help against SIGKILL.
- **Failure:** Any launch where leftovers exist (stale nested session, leftover JVM) →
  instances killed → supervisor killed → the session-level reap, `rm -rf "$MCSS_GEOM_DIR"`,
  the systemd unit stop and the launch itself never run → Steam bounces to the library.
  This matches the "first launch after leftovers bounces, second works" symptom that
  the #58 comment attributes to errexit alone. Also kills any unrelated process with
  `PolyMC` in its cmdline.
- **Fix:** Delete the bare-name pattern. Kill only recorded PIDs (state file
  `bwrap_pid`/`pid` + the `_mcss_nested_pids` marker set), or exclude the ancestor
  chain: `for p in $(pgrep -f "$_launcher_name"); do [[ " $_chain " == *" $p "* ]] && continue; …`.

### B1 (= A2). `SLOT_DIED` frees the slot before `teardown_instance`, so the kill is skipped and stale pid/wid poison the next occupant
- **File:** `modules/orchestrator.sh:633-640`; `modules/slot_manager.sh:274-279`;
  `modules/instance_lifecycle.sh:1200-1203`, `:1250`, `:1058`; `modules/watchdog.sh:183-199`
- **Category:** bug · **Status:** CONFIRMED (code trace, re-verified)
- **What:** With the proxy flag on (default since #150), the handler runs
  `proxy_stop_slot` then `slot_free` (writes `active:false`) and only then
  `teardown_instance`, which hits `if ! slot_is_active "$slot"; then … return 0` and
  never sends SIGTERM/SIGKILL nor executes the line-1250 write that nulls
  `pid/bwrap_pid/wid/js_node`. `slot_free` nulls identity fields only. The #174 commit
  comment even records the "not active, nothing to tear down" symptom on a normal quit.
- **Failure:** (1) Hung JVM on player quit (the #37 Bug B case the window-gone watchdog
  exists for) is never killed and survives `cleanup()` (`teardown_all_instances` walks
  active slots only) → adopted by Steam's reaper → Abort-Game overlay class of hang.
  (2) Spawn's reserve write (`:1058`) does not null `wid`, so the dead window's WID
  stays; the watchdog's stale-wid check fires `SLOT_DIED` for the new occupant ~4 s
  into launch → a second orphan. (3) `tests/test_reconnect_dispatch.sh:43` and
  `test_orchestrator.sh` T6.3 stub `teardown_instance`, so no test can see it.
- **Fix:** Reorder: `teardown_instance` first, then `proxy_stop_slot`/`slot_free`
  (both idempotent). Independently make the guard process-based (skip only when
  `bwrap_pid`, `pid`, `wid` are all empty), always run the line-1250 write, add
  `"wid": null` to spawn's reserve write, and consolidate the three "reset this slot"
  encodings (A22) into one `slot_reset`. Add a real-process dispatch test
  (mutation-tested per PRINCIPLES #4).

### E1. dex `XWindowAttributes` ctypes struct omits `colormap` — `map_state` reads the colormap XID
- **File:** `modules/dex.sh:102-117` (struct), `:448-458` (`action_is_viewable`);
  consumer `modules/instance_lifecycle.sh:1148-1160` (map-keeper #57)
- **Category:** bug · **Status:** CONFIRMED (checked against `/usr/include/X11/Xlib.h:325-328`)
- **What:** Xlib orders the fields `save_under, colormap, map_installed, map_state, …,
  override_redirect, screen`. The Python struct declares `save_under, map_installed,
  map_state, …, screen, colormap`. Total size matches (136 B), so nothing overflows,
  but `map_state` is read at offset 80 (low half of `colormap`) instead of 92.
  `print("viewable" if a.map_state == 2 …)` is therefore "viewable" only when the
  window's colormap XID happens to be 2. Geometry fields (`x,y,width,height`) precede
  the error and are correct.
- **Failure:** Every spawn: the map-keeper polls every 2 s for 45 iterations, always
  gets "unmapped", and calls `dex_map_raise` 45× per slot; four keepers raise their
  windows against each other for 90 s. Any future consumer of `dex_is_viewable` is
  misled the same way.
- **Fix:** Reorder to match `Xlib.h` exactly (`save_under, colormap(c_ulong),
  map_installed, map_state, all_event_masks, your_event_mask, do_not_propagate_mask,
  override_redirect, screen`). Add a test asserting
  `XWindowAttributes.map_state.offset == 92` and `sizeof == 136` on x86_64.

---

## 3. High

### A3. docked→handheld re-entry leaks the docked flow's monitors and the persistent FIFO fd
- **File:** `modules/orchestrator.sh:918-919`, `:1011-1016`, `:732-746`, `:120-124`
- **Status:** CONFIRMED
- On `DISPLAY_MODE_CHANGE handheld`, `docked_flow` returns 1 without teardown;
  `handheld_flow` blanks `_CONTROLLER_MONITOR_PID` (monitor still running), starts a
  second dock monitor and watchdog, and `_open_fifo_reader` allocates a new fd. Result:
  the orphaned docked monitor keeps emitting `CONTROLLER_ADD` → a second instance in
  handheld mode; every event is delivered twice; the docked monitor and its `udevadm`
  child survive `cleanup()` (the #26/#60 "game still Running" symptom).
- **Fix:** Kill `_CONTROLLER_MONITOR_PID`/`_DOCK_MONITOR_PID`/`_WATCHDOG_PID` via
  `_kill_tree` before `return 1`; make `_open_fifo_reader` a no-op when the fd is set.

### A4. In `handheld_flow`, `DISPLAY_MODE_CHANGE handheld` ends the session
- **File:** `modules/orchestrator.sh:774`, `:649-686` · **Status:** CONFIRMED · PRINCIPLES #5
- The loop is `_handle_msg "$msg" || break`; `_handle_msg` returns 1 for
  `DISPLAY_MODE_CHANGE handheld` ("so the caller can re-enter handheld_flow") — but
  when the caller *is* handheld_flow, `break` → `cleanup` → slot 1 killed. The
  `docked` arm only sets mode and keeps looping, so dock-then-undock while playing
  handheld tears down the game.
- **Fix:** Distinct return code (e.g. 3) treated as a no-op in handheld_flow, or check
  `_get_mode` before returning 1.

### A5. Stranded autostart `.desktop` + unguarded `prodFromPlasma` dispatch can run the launcher on the real desktop
- **File:** `minecraftSplitscreen.sh:286-292`, `:508-535`, `:554`, `:1043-1052`, `:557-558`
- **Status:** CONFIRMED (path); trigger PLAUSIBLE
- The only `rm -f` of `~/.config/autostart/splitscreen-prod.desktop` is inside
  `launchProdFromPlasma`; if the nested Plasma never runs the autostart (crash, 90 s
  budget), the file is stranded. The `prodFromPlasma)` arm has no
  `MCSS_NESTED_SESSION`/gamescope guard. Next real Desktop login runs the launcher on
  the real desktop: `pkill -x plasmashell` every 2 s (A7), instances on the desktop,
  and `qdbus … logout` on exit.
- **Fix:** Remove the autostart file unconditionally at the end of `launchFromPlasma`;
  require nested+gamescope in the `prodFromPlasma)` arm.

### C1. Installer offline fallbacks are unreachable — transport failure aborts under `set -e`
- **File:** `modules/version_management.sh:404-411`; `modules/java_management.sh:114-120`, `:135-141`;
  weaker siblings `launcher_setup.sh:73-84`, `version_management.sh:84-92`
- **Status:** CONFIRMED (reproduced: exit 56, "FALLBACK REACHED" never prints)
- `FABRIC_VERSION=$(fetch_url … - | jq -r '.[0].version')` and
  `manifest_json=$(fetch_url … -)` are plain assignments; DNS/connect/`--max-time`
  failures propagate through `pipefail` and errexit kills the process before the
  documented `FABRIC_VERSION="0.16.9"` / `_mc_version_to_java_major` fallbacks run.
  `get_required_java_version` runs inside `$(…)` so the outer assignment dies too.
- **Fix:** `… ) || FABRIC_VERSION=""` at each site, or a shared
  `fetch_url_body_or_empty` helper (PRINCIPLES #9).

### C2. `download_and_install_jdk` picks the wrong extracted JDK and skips version validation
- **File:** `modules/java_management.sh:245`, `:255-256`, `:411-421` · **Status:** CONFIRMED (reproduced)
- `jdk_dir=$(find "$install_dir" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)`
  over the shared `$TARGET_DIR/java` returns the highest version present, not the one
  just extracted; `JAVA_17_HOME` can point at jdk-25. The post-install branch skips
  `_java_output_matches_major` and reports success.
- **Fix:** Take the dir name from `tar -tzf | head -1`, or extract to a temp dir and
  move; validate on the post-install path too.

### D1. dock_detection emits a destructive `DISPLAY_MODE_CHANGE` from ONE un-corroborated sysfs read
- **File:** `modules/dock_detection.sh:242-252`, `:255-264`, `:85-101`; consumer `orchestrator.sh:660-685`
- **Status:** CONFIRMED · `[KNOWN: HW2-VALIDATION-2026-07-22; #133 closed not_planned after #138 reverted]` · PRINCIPLES #5
- `_detect_via_drm` keys only on `status` (a failed read counts as "not connected");
  both watch paths emit on a single differing read; the orchestrator then tears down
  every non-P1 slot. PRINCIPLES #5 claims a "confirms a mode across reads" design that
  does not exist in code.
- **Fix:** Treat `status != connected` with `enabled == enabled` (or `dpms == On`) as
  inconclusive → keep last-good; confirm the destructive direction across N reads;
  correct PRINCIPLES #5.

### E2. `apply_layout` is not errexit-safe — a positioning failure kills the backgrounded spawn group
- **File:** `modules/window_manager.sh:360`, `:383`, `:317-319`, `:198`, `:361`;
  callers `instance_lifecycle.sh:1138`, `orchestrator.sh:448-470` · **Status:** CONFIRMED (reproduced)
- `_position_slot`, `kwin_place_windows`, `dex_list_windows | while`, and the
  geom-cache `printf >` are bare under `set -euo pipefail`; `spawn_instance` calls
  `sync_apply_layout` bare inside the orchestrator's `{ … } &`. First failing
  `_position_slot` (empty wid + KWin unreachable) terminates the group before the
  map-keeper, the post-spawn reflow and the slot-release branch; the EXIT trap deletes
  the spawn log before it is echoed.
- **Fix:** Status-test each call (`|| _failed+=("$slot")`, `|| true` on the cache
  write); `spawn_instance … || _si_rc=$?` in the orchestrator.

### E3. `apply_layout`/`sync_apply_layout` never return non-zero, so the H10 reflow-retry is dead
- **File:** `modules/window_manager.sh:285-397`; consumer `orchestrator.sh:334-341` · **Status:** CONFIRMED (reproduced)
- The function's exit status is that of its trailing `if` block (always 0);
  `_position_slot`'s `return 1` is discarded, `_REFLOW_NEEDED` never set; after a
  dock/undock with KWin unreachable the windows stay tiled for the old output.
- **Fix:** Track failures, `return (( ${#_failed[@]} == 0 ))`; document the contract;
  mutation-tested unit test.

### F1. Full uninstall `rm -rf`s the user's PrismLauncher root, which this project never creates
- **File:** `uninstall-minecraft-splitscreen.sh:63`, `:66-74`, `:295-297` · **Status:** CONFIRMED · security / data loss
- `PRISM_DIR="${PRISM_DIR:-$HOME/.local/share/PrismLauncher}"` is in `FULL_TARGETS`.
  The installer writes only under `TARGET_DIR` (PolyMC); Prism is merely a probe
  fallback. A Deck user with their own Prism worlds loses them; `--yes` skips the
  prompt. Weaker analogue: `$HOME/.local/jdk` at `:73`.
- **Fix:** Remove `$PRISM_DIR` from `FULL_TARGETS`; if a Prism-hosted install must be
  supported, remove only our artefacts under it, and only when a marker exists.

### F2 (+ T5, T6, T23). CI baseline gate lets regressions through
- **File:** `.github/workflows/ci.yml:12-18`, `:68-102` · **Status:** CONFIRMED
- Gate is `passed >= BASELINE` with `|| true` on the suite; totals and exit codes are
  never checked. `test_uhid_pad.sh` prints 23/23 vs baseline 18 → five regressions pass.
  The comment "none of these scripts exit non-zero" is stale (17/19 do). A test can
  `_fail` then `_pass` in one body (`test_watchdog.sh` T5.7) and still print 15/15.
  Seven CI-safe suites (evsieve_management — the SHA-verify guard —, controlify_seed,
  module_resource, probe_proxy_repoint, home_bwrap_bind, kwin_wrapper,
  notify_no_controller) are not gated; the last three print `[OK]`, not `X/Y`.
- **Fix:** Gate on exit status with an explicit known-fail allowlist (only
  `test_window_manager.sh`, until T4 is fixed); add the seven suites; bump uhid_pad to
  23; `timeout-minutes`, `permissions:`, pinned actions (F17).

### T4. `test_window_manager.sh` T3.1/T3.9 assert the retired highest-slot grid rule — the suite goes green if the fix is reverted
- **File:** `tests/test_window_manager.sh:38-48`, `:216-231`; product `window_manager.sh:208-236` · **Status:** CONFIRMED (7/9, exit 1)
- `compute_grid_mode` was deliberately made count-based (TODO.md:321). Six sub-cases
  fail *because the code is correct*; the CI baseline of 7 tolerates it. Reverting to
  slot-number-based makes it 9/9 and CI prints `OK: 9 >= 7`. The intended {2}→full,
  {2,4}→half, {1,3}→half behaviours have zero coverage.
- **Fix:** Rewrite the table to the count contract; bump baseline to 9;
  mutation-check by re-inverting.

### T1. Hardware helper reaps sessions with name-matched `pkill -9`
- **File:** `tests/hardware/lib/helpers.sh:727-729`, `:742` (from `:817`, `:851`) · **Status:** CONFIRMED · PRINCIPLES #7
- `pkill -9 -f 'kwin_wayland'`, `'latestUpdate'`, `'bwrap.*PolyMC'`,
  `'SteamLaunch.*minecraftSplitscreen'` run on every stage launch/stop. On Desktop
  Mode or Bazzite (now supported, #198/#199) the first kills the operator's whole
  compositor; `-f latestUpdate` matches an editor or `tail -f` on an instance log.
- **Fix:** Track and kill only what the harness started (`HW_ORCH_PID`, the marked
  environ loop that already exists at `:721-724`); delete the four `pkill` lines.

### T3. `test_orchestrator.sh` T6.3 runs the real `proxy_stop_slot` against the real `$XDG_RUNTIME_DIR/mcss`
- **File:** `tests/test_orchestrator.sh:167-172`; sink `orchestrator.sh:632-634` → `controller_proxy.sh` · **Status:** CONFIRMED (reproduced path)
- Since the `MCSS_CONTROLLER_PROXY` default flipped, `_handle_msg "SLOT_DIED 2"` takes
  the proxy branch; the suite overrides `SPLITSCREEN_STATE` but not `MCSS_HELPER_DIR`,
  so it reads the real `proxy-slot2.pid`, kills the identity-verified PID and removes
  the real pad/virt symlinks. Running the suite on the Deck during a session drops P2's
  input.
- **Fix:** Export `MCSS_HELPER_DIR`/`MCSS_PROXY_*_DIR` under the suite tmpdir before
  sourcing; stub `proxy_stop_slot` in T6.3.

### T2. `test_instance_lifecycle.sh` process-group-kills fixture PIDs below `pid_max`
- **File:** `tests/test_instance_lifecycle.sh:146`, `:279`; sink `instance_lifecycle.sh:1219,1242,1246` · **Status:** CONFIRMED
- T4.5/T4.8 call the real `teardown_instance` (`kill -TERM "-$pgid"`, then `-KILL`) on
  11110/22220/33330/44440/99998 — all below `pid_max` (32768 here; 4194304 on 64-bit
  systemd hosts). `test_orchestrator.sh:31-57` documents that this exact shape
  SIGKILLed a working session before and guards above `pid_max`; this suite does not.
- **Fix:** Fixture PIDs above `/proc/sys/kernel/pid_max` (refuse otherwise) or mock the
  kill step; also set `MCSS_GEOM_DIR` (T12).

---

## 4. Medium

### Runtime: orchestrator / launcher

- **A6. handheld→docked switch is not implemented** despite the header contract
  (`orchestrator.sh:700-701`, `:657-660`, `:1005-1023`). Docking mid-session flips
  `.mode` but never starts a controller monitor; pads never spawn. Implement or delete
  the claim and log "unsupported".
- **A7. `pkill -x plasmashell` + 2 s respawn-killer loop** (`minecraftSplitscreen.sh:557-558`,
  `:743-744`) are name-matched kills of every plasmashell of the user; safe only
  because Game Mode has none, destructive combined with A5. Kill the nested one by
  marker/tree.
- **A8. `_mcss_stale_tree_pids` cannot see what its comment says it reaps**
  (`minecraftSplitscreen.sh:326-370`, `:87`, `:683-685`). `/proc/PID/environ` is the
  execve-time block; a later `export` does not change it (reproduced), so the outer
  supervisor, Steam's reaper and all `$(…)` subshells are invisible to the marker.
  `systemctl --user stop plasma-workspace.target` is unscoped and can stop a newer
  session's target. Re-exec once with the marker set; scope the target stop.
- **A9. Marker vars and PATH likely leak into the systemd `--user` manager** via
  startplasma's env import (`:146-198`, `:277`, `:302`) — PLAUSIBLE; confirm with
  `systemctl --user show-environment` on the Deck. Would make the real desktop match
  `_mcss_nested_pids`. Unset them in `_restore_session_env`.
- **A10. Missing manifest modules are silently skipped** (`minecraftSplitscreen.sh:137-143`).
  A partial deploy degrades with no diagnostic. Make a missing entry fatal-loud.
- **A11 (= B2). Orchestrator keeps raw-jq state readers and duplicate slot finders**
  (`orchestrator.sh:166-169`, `:226-234`, `:246-253`, `:266-275` [dead], `:287-296`)
  that `slot_manager.sh:43-48` says PR-c retired. PRINCIPLES #1/#9; ARCHITECTURE §2.
  Route through `slot_find_*`, delete `_find_slot_by_uniq`, add a `get_mode` accessor.
- **A12 (+ D16, E14). `/tmp` fallback for `MCSS_HELPER_DIR` prepends `/tmp` to `PATH`**
  and writes executed helpers (KWin shim, dex backend, evsieve logs/pidfiles/symlink
  farms) to predictable world-writable paths (`runtime_context.sh:343-350`,
  `minecraftSplitscreen.sh:274-277`, `controller_proxy.sh:379-392`, `dex.sh:66,516`).
  Full local-user PATH hijack when `/run/user/$UID` is unusable. Fall back to
  `mktemp -d` (0700); never prepend a world-writable dir to PATH. Security.
- **A13 (+ D11). FIFO at fixed `/tmp/minecraft-splitscreen.fifo`; a pre-existing
  non-FIFO makes the session silently deaf** (`runtime_context.sh:326`,
  `orchestrator.sh:973-980`, `controller_monitor.sh:847,856,926`). `mkfifo || true`,
  reader refuses non-`-p`, writers `>>` into a regular file with no error. Local user
  can inject `SLOT_DIED 1`. Default under `$MCSS_HELPER_DIR`; make a non-FIFO fatal-loud;
  guard writers with `-p`. Security.

### Runtime: lifecycle / slots / watchdog

- **B3. Watchdog dedup keyed on slot only** (`watchdog.sh:212-226`) — a slot freed and
  re-claimed within one 2 s poll never re-arms; second occupant's death is never
  reported. Key on `bwrap_pid` incarnation. PLAUSIBLE (timing).
- **B4. Startup reset orphans a crashed session's JVMs; `_poll_for_java`'s
  `pgrep | head -1` then binds the new slot to the OLD JVM** (`instance_lifecycle.sh:151-165`,
  `:628`, `:652`). Reap recorded PIDs (identity-verified via `/proc/<pid>/cmdline`)
  before the reset; restrict the java search to descendants of `$bwrap_pid`.
- **B5. `slot_claim` REJECTs a known pad whose event node silently changed**
  (`slot_manager.sh:209-221`) — no udev REMOVE processed → stale `event_node` forever;
  a later REMOVE of the new node finds no slot. Compare `$ev` to the stored node; if
  different, `slot_touch` + `RESUME`.
- **B6. Update path runs the full Fabric+mod install twice per instance and clobbers
  `instance.cfg` customisations** (`instance_creation.sh:207-209`, `:225-243`, `:251`,
  `:280`, `:817-836`) — contradicts "settings will be preserved"; `MISSING_MODS` from
  the first run is lost in the `$(…)` subshell.
- **B7 (+ C10). `install_fabric_and_mods` carries its own 5-tier Modrinth ladder ending
  in an "any Fabric release" fallback that ignores the target MC version**
  (`instance_creation.sh:401-443`); `fetch_and_add_external_mod` adds Modrinth deps with
  an empty URL that lands in that tier (`mod_management.sh:1096-1109`). Installs
  wrong-MC jars. Use `match_modrinth_version` (#88) and drop the tier.
- **B8 (= C5). Mod jars downloaded with no integrity check although Modrinth
  (`hashes.sha512`) and CurseForge (`hashes[]`) return one in the same response**
  (`mod_management.sh:190-199`, `:329-331`; `instance_creation.sh:501`). A truncated
  CDN body is loaded into the JVM. The JDK path already verifies SHA-256. Security.
- **B9 (= E27). Title-keeper and map-keeper subshells hold the capture pipe**
  (`instance_lifecycle.sh:1114-1121`, `:1149-1161`; `orchestrator.sh:754`, `:460`).
  In `handheld_flow` `spawn_instance … 2>&1 | sed` cannot complete until the 90 s
  map-keeper exits — the event loop is blocked for ~90 s after launch. PRINCIPLES #8.
  Redirect both keepers to the log.

### Runtime: controllers / dock / evsieve

- **D2. The 500 ms add-debounce is dead code** — `_CONTROLLER_MONITOR_DEBOUNCE_MAP` is
  only written inside `prev_nodes=$(_check_devices_changed …)` (subshell), so the parent
  map is always empty (reproduced). Worse, the in-process logic would `continue` yet
  still return the node in the baseline, permanently hiding a flapping pad. Delete the
  debounce or return the baseline via nameref and omit debounced nodes.
- **D3. The `MCSS-slot*` identity gate exists only in `_list_raw_external_pads`**
  (`controller_monitor.sh:551`); `_map_external_player_virtuals`
  (`CONTROLLER_MONITOR_RAW_BINDING=0`) and the handheld branch enumerate our own
  evsieve virtuals as pads (reproduced: "4 external pad(s)" incl. `MCSS-slot1`). Gate
  once at the shared reader; share the literal (D14).
- **D4. Prebuilt evsieve is installed over the working binary BEFORE the host-exec
  check, no rollback** (`evsieve_management.sh:241`, `:555-561`, `:487-492`). A
  non-running binary stays `-x`; runtime pays a 2 s poll+kill per slot per launch and
  silently drops to raw binding. Verify the candidate before `mv`.
- **D5. Prebuilt evsieve integrity pins nothing locally** — `.stamp`, `.sha256` and the
  binary all come from the same mutable `releases/latest` URL, hard-coded to `aradanmn`
  (`evsieve_management.sh:98-102`, `:213-239`) while everything else derives from
  `MCSS_REPO_RAW_URL`. Pin `EVSIEVE_PREBUILT_SHA256` in-tree; derive the owner. Security.

### Runtime: window / X11 / KWin

- **E4. `kwin_place_windows`/`kwin_set_noborder` qdbus failures under `set -e` leak the
  `.js` and leave scripts loaded in KWin** (`kwin_positioner.sh:237`, `:246-251`, `:298`,
  `:306-309`). `|| id=""`, `|| true`, `trap … RETURN`; merge the two near-identical bodies.
- **E5. `kwin_set_noborder` interpolates `${pid}` into KWin JS without the H7 integer
  check, and has zero callers** (`kwin_positioner.sh:270-291`; stale comment
  `minecraftSplitscreen.sh:719`). Delete or validate. Security (JS injection hardening).
- **E6. `_dex_run` has no timeout** (`dex.sh:531-535`; `signal` imported, unused). Every
  dex call is an unbounded synchronous Xlib round-trip in the FIFO hot path — the
  same hang mode `window_manager.sh:312-314` cites for rejecting xdotool. PRINCIPLES #6.
  `timeout --foreground "$DEX_TIMEOUT_S"` + `signal.alarm` + `XSetIOErrorHandler`.

### Steam / desktop integration

- **E7. `add-to-steam.py` derives the next shortcut index with a raw-bytes regex**
  (`add-to-steam.py:100-111`, `rb'\x00(\d+)\x00'`, takes the *last* match). A
  digit-only string value or an int with a digit byte pattern yields a wrong or
  duplicate index; Steam then drops/merges an entry. Use the remover's `parse_map`
  (share as `mcss_vdf.py`) and `max(int(k)) + 1`.
- **E8. `shortcuts.vdf` rewritten in place (truncate-then-write) in both scripts;
  adder has no backup** (`add-to-steam.py:143-146`, `remove-from-steam.py:275-279`).
  ENOSPC after truncation empties the user's whole non-Steam library. tmp + fsync +
  `os.replace`; one backup naming.
- **E9. `system_integration.sh:149,155` runs `steam -shutdown` + `pkill -x steam`**
  while `remove-from-steam.py:20-23` in the same repo refuses to do exactly that
  because it "wedged Game Mode before". PRINCIPLES #7. Detect and refuse/ask; never
  signal by name.
- **E10. `remove-from-steam.py` `is_ours` rule 3 deletes any shortcut whose exe is
  under `~/.local/share/PolyMC`** — including a user's own `PolyMC.AppImage` shortcut
  (`remove-from-steam.py:140-157`; called with `--target-dir` from the uninstaller).
  Narrow to the launcher basename; add a fixture entry that must survive.

### Installer / uninstaller / deploy / ops

- **C3. Re-install is not atomic** — `runtime_deploy.sh:72-82`, `:171-185` fetch onto
  the live launcher/module paths and `rm -f` the launcher on a bad fetch; a 404 (bad
  `REPO_REF`) or mid-transfer drop leaves a working install with no launcher.
  Fetch to `mktemp` in-dir, validate, `mv`; stage all modules before swapping.
- **C4. Eleven raw `curl`/`wget` CurseForge sites bypass `fetch_url`, most with no
  timeout** (`mod_management.sh:476,828,976,993,1014,1135,1232,1455,1547,1676`;
  `version_management.sh:254`; `launcher_setup.sh:94`). One stalled TCP connection
  hangs the 20-version scan forever with no spinner. PRINCIPLES #6/#9; ARCHITECTURE §2.
  Add a header-file arg to `fetch_url`; one `MCSS_API_TIMEOUT_S`.
- **C6. `source ~/.profile` inside the installer** (`java_management.sh:366`, `:408`)
  — under `set -u` an unbound variable in the user's profile kills the run despite
  `|| true` (reproduced); vestigial since #41; runs arbitrary user shell code. Delete.
- **C7. `mcss_stamp_apply` uses unescaped values in `sed s///`** (`version_stamp.sh:71-75`).
  The installer's own documented `REPO_REF=feat/…` form contains `/` → sed fails →
  launcher reports `dev/unknown`, the outcome #170 set out to fix (reproduced). `&`/`\`
  inject. Escape, or use `${content//__MCSS_COMMIT__/$commit}`.
- **C8. PolyMC AppImage: raw `wget -O`, no checksum; a failed download permanently
  satisfies the `-f` "already present" check** (`launcher_setup.sh:62`, `:94-95`).
  Fetch to tmp, `mv`, gate on `-s` + ELF magic.
- **C9. Version scan re-fetches each required mod's full version list per candidate
  (20 × 7 = 140 calls) and treats any non-200 as "incompatible"** (fail-closed)
  (`version_management.sh:98-207`; `mod_management.sh:380-389`, `:1872/:1888` runs it
  twice). Cache per mod id; surface "could not verify" instead of dropping versions.
  PRINCIPLES #5.
- **C11. Version filter and mod scan use different ladders** (`version_management.sh:223-224`,
  `:274-278` vs `mod_management.sh:401`, `:500-515`) — a version can be offered then
  fail for the same required mod. `[KNOWN: TODO.md:33-35]`
- **F3. The tagged release asset (and every curl|bash run) fetches modules from
  unpinned `main` with no integrity check** (`install-minecraft-splitscreen.sh:109,115,199`;
  `release.yml:138-146`). A release is neither reproducible nor isolated from later
  pushes; a compromised `main` is executed by every install. Bake the tag into the
  uploaded asset; ship `modules.sha256`. Security.
- **F4. Installer `trap cleanup EXIT INT TERM` swallows Ctrl-C** (`install-minecraft-splitscreen.sh:82-90`;
  `utilities.sh:329-332`) — never re-raises; a Ctrl-C at a prompt is an EOF default and
  the run continues after `MODULES_DIR` was deleted, so `install_runtime_modules` falls
  to the network tier and deploys `main`, not the checkout (reproduced).
  `trap 'cleanup; trap - EXIT; exit 130' INT`.
- **F5. Uninstaller is "curl|bash-able" but `read -r -p` reads the script stream** —
  a piped run prints "No changes made", exit 0 (reproduced)
  (`uninstall-minecraft-splitscreen.sh:5`, `:183`, `:235`). Read from `/dev/tty` or
  refuse when `! -t 0` without a mode flag.
- **F6. `rm -rf` on env-supplied `TARGET_DIR`/`PRISM_DIR` with no validation; `--yes`
  removes the only guard** (`uninstall-minecraft-splitscreen.sh:62-63`, `:280`).
  `TARGET_DIR=$HOME … --yes` removes the home directory. Require absolute, not `/` or
  `$HOME`, plus an install marker. Security.
- **F7. `dock-display-hotplug.sh` has no udev rule, needs root (`su … deck`), and its
  README row contradicts the code** (`system/deck-display-fixes/`). After `install.sh`
  nothing ever runs it. Ship the rule or delete the script.
- **F8. `resume-display-restore.sh` restarts `gamescope-session.target` on every docked
  resume with no failure detection** (`resume-display-restore.sh:52-60`) — kills any
  running game, splitscreen included. PRINCIPLES #5. Restart only when the DP output is
  observed broken.

### Tests

- **T7. `test_preflight.sh` `_mock_cleanup` reaps `*.pid` files nothing writes** —
  every `sleep 30` mock dialog leaks; the file's PRINCIPLES #7 claim is false; T3.2/T3.3
  fall back to `pgrep -f`. Have the mock write its pid.
- **T8. `uhid_pad.py` `axis` stores the value before range validation** (`:379-381`) —
  one `axis LX 300` poisons the pad; every later command fails (reproduced).
  `fake_pad.sh` does not mirror this.
- **T9. `hw_expected_slot_geometry` re-encodes grid policy with semantics that diverge
  from `compute_grid_mode`/`apply_layout`** (`helpers.sh:402-439`) — latent (callers
  pass contiguous sets). Source the pure functions instead.
- **T10. `test_module_resource.sh` omits `version_stamp.sh`** from its "11" installer
  list (has 10) — its double-source safety is untested. Parse the list from the installer.

---

## 5. Low and Info

Compact form; each row is a verified finding with full detail in the per-module report
named by its ID prefix.

### 5.1 Runtime: orchestrator / launcher / runtime_context (A)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| A14 | Low | `orchestrator.sh:412,673,754,1109,1114` | State-mutating calls run inside `\| sed` subshells; in-process globals (`_CONTROLLER_PROXY_PIDS`) discarded; `\|\| true` applies to `sed` | Use the temp-file pattern the SLOT_DIED arm already uses |
| A15 | Low | `orchestrator.sh:973-977` | FIFO default literal duplicated from `runtime_context.sh:326` | `mcss_resolve_paths` + `$SPLITSCREEN_FIFO` |
| A16 | Low | `minecraftSplitscreen.sh:171,363` | Pipeline assignments under leaked `set -e -o pipefail` can kill the launcher before Plasma starts (PLAUSIBLE) | `\|\| true` inside the substitution |
| A17 | Low | `minecraftSplitscreen.sh:567,596,750,773` | `kill "${_PANEL_KILLER_PID:-0}"` defaults to `kill 0` = whole process group (latent) | `[[ -n … ]] && kill` |
| A18 | Low | `orchestrator.sh:120-124,722,833` | FIFO fd inherited by every child incl. the bwrap/JVM sandbox; re-opened without close on re-entry | Close in children; idempotent `_open_fifo_reader` |
| A19 | Low | `minecraftSplitscreen.sh:11-14`; `runtime_context.sh:739-764` | Advertised overrides (`N_SLOTS`, `MCSS_RAW_BINDING`, screen W/H, …) not carried across the autostart re-exec (PLAUSIBLE) | Add to `_canonical` |
| A20 | Low | `runtime_context.sh:76,269-280`; `minecraftSplitscreen.sh:238,642-645` | State file hard-wired under PolyMC regardless of `MCSS_LAUNCHER_ROOT`; `/usr/bin/kwin_wayland_wrapper` literal vs PATH probe; `kded6` only | Derive; `command -v`; list `kded5 kded6` |
| A21 | Low | `minecraftSplitscreen.sh:70,87-90` | Predictable world-readable `/tmp` xtrace log records controller MACs and env strings (security) | `$MCSS_HELPER_DIR` + `umask 077` |
| A22 | Low | `orchestrator.sh:465`; `instance_lifecycle.sh:1246`; `slot_manager.sh:276-278` | Three encodings of "reset this slot"; none nulls everything (enables B1) | One `slot_reset` |
| A23 | Low | `orchestrator.sh:362-364` | Heartbeat restart uses `SKIP_INITIAL_EMIT=1` → pads connected during the outage never spawn | Run the acquisition pass once on restart |
| A24 | Low | `orchestrator.sh:821-824,918-919,1011-1016` | `docked_flow` return 1 overloaded (FIFO unset vs re-enter handheld) | Distinct codes |
| A25 | Low | `main_workflow.sh:230,243,61,216` | "Run:" hint tells users to invoke the launcher bare (refused outside gamescope); duplicated repo URL; shared `/tmp/mcss-debug-api`; non-local loop var | Fix text; derive URL; `mktemp -d`; `local` |
| A26 | Info | `orchestrator.sh:1113-1115,266-275`; `minecraftSplitscreen.sh:1027-1032` | `restorePanels` never defined (tests stub it); unreachable `--version` arm; dead `_find_slot_by_uniq` | Delete |
| A27 | Info | `orchestrator.sh:144,158,227`; `minecraftSplitscreen.sh:835,838,841,750` | Leaked globals; `$0` vs `BASH_SOURCE`; `$DISPLAY` unguarded under `set -u`; magic `timeout 7200`; test trap is EXIT-only | Hygiene |
| A28 | Info | `minecraftSplitscreen.sh:1185-1188`; `orchestrator.sh:209-214` | `*)` nested entry never resets the state file (unlike `prodFromPlasma`) | `_ensure_state_file` at top of `main()` |

### 5.2 Runtime: lifecycle / creation / slots / watchdog (B)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| B10 | Low | `instance_lifecycle.sh:765-768,157-165` | `_ensure_state_file` called outside the lock from `update_slot_state`; initializer hard-codes 4 slots and omits slot_manager fields | Init inside `flock`; generate from `MCSS_MAX_PLAYERS` |
| B11 | Low | `instance_lifecycle.sh:1058`; `slot_manager.sh:191-195` | Spawn's late reserve write can revert a RESUME'd `event_node` (PLAUSIBLE, 0.2–2 s window) | Write only what spawn owns |
| B12 | Low | `watchdog.sh:112`; `controller_proxy.sh:270-283` | Watchdog's proxy *check* deletes the pidfile (query with a destructive side effect; CQS) | Pure predicate for the watchdog |
| B13 | Low | `instance_lifecycle.sh:1071` | `rm -f /tmp/qtsingleapp-*` deletes every QtSingleApplication socket on the host; ineffective for the `--tmpfs /tmp` sandbox | Direct-path only, PolyMC-scoped glob |
| B14 | Low | `instance_lifecycle.sh:509` | `${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}` re-embeds the vendor literal via a legacy alias | Bare `$MCSS_STEAM_VENDOR_ID` |
| B15 | Low | `runtime_context.sh:80`; `instance_lifecycle.sh:778`; `orchestrator.sh:199` | `MCSS_STATE_LOCK` exported, never used; both writers derive `.lock` themselves | Remove or one helper |
| B16 | Low | `slot_manager.sh:66-71` | `MCSS_RECONNECT_GRACE_S` defined outside `runtime_context.sh` (ARCHITECTURE §3) | Move or rename |
| B17 | Low | `instance_lifecycle.sh:173,1198,781,707,1087,960,1077,472,351`; `instance_creation.sh:379,390,560-563,588,616-621`; `slot_manager.sh:126`; `watchdog.sh:60` | Consumer-side `:-` fallbacks (`/tmp/mcss-geom`, lock timeout, max players) and unnamed tunables (warm-up iters, `sleep 0.3`, `sleep 86400`, `/tmp/splitscreen-bwrap-N.log`, volumes, `maxFps:120`, `version:3465`, Collective id) | Bare reads; name constants |
| B18 | Low | `instance_creation.sh:267-270`; `instance_lifecycle.sh:974,881-891` | Unreachable "different location" branch; Controllable `rm` (mod replaced); LWJGL-2 title property serving a strategy that "rarely hits" | Delete / comment |
| B19 | Low | `instance_lifecycle.sh:941-947`; `orchestrator.sh:463-465` | `spawn_instance` rc 2 ("already running") treated as failure → live slot's pids wiped `[KNOWN: AUDIT-2026-07-21:59]` | `case $_si_rc` |
| B20 | Low | `instance_lifecycle.sh:934-938` | bwrap required even for the handheld direct launch that never uses it | Move the check |
| B21 | Low | `instance_lifecycle.sh:322-323,372,566,280` | `_detect_xauthority` / `read < <(_vp_of_js_node)` return non-zero under standalone `set -e` → empty bwrap command or controller-less sandbox (runtime flows run `set +e`, so only probes/harnesses bite) | `\|\| true` |
| B22 | Info | `instance_lifecycle.sh:1222-1236` | `teardown_instance` blocks the FIFO loop up to 10 s per hung slot `[KNOWN: TODO.md:307]` | — |
| B23 | Info | `slot_manager.sh:211,104-108` | Comment says "newest" but `head -n 1` returns the lowest slot | Fix comment or sort |
| B24 | Info | `instance_lifecycle.sh:1114-1161`; `orchestrator.sh:1094-1105` | Keeper subshells are untracked PIDs that outlive `cleanup()` | Record PIDs |
| B25 (+C12) | Info/Low | `instance_creation.sh:333,557,470`; `mod_management.sh:1984,2102` | Two derivations of the instance number; required-mod check is a *prefix* match ("Sodium Extra" → CRITICAL "Sodium") | `==` by (platform,id) |
| B26 | Info | `instance_creation.sh:824` | `sed` edit unescaped for `&`/`\|` in `JAVA_PATH` (moot while B6 rewrites the file) | Reuse `setInstanceCfgValue` |
| B27 | Info | `instance_lifecycle.sh:994,996,1043`; `instance_creation.sh:743,745` | Redundant `command -v jq` guards; duplicated Controlify jq write; proxy gate evaluated twice | Hygiene |
| B28 | Info | `instance_creation.sh:199,284` | `create_instances` unconditionally re-enables errexit `[KNOWN: CODE-REVIEW-2026-07-21-CLOSED:18]` | — |

### 5.3 Installer: mods / versions / java / deploy / utilities (C)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| C13 | Low | `version_management.sh:446` | Predictable `/tmp/fabric_versions_$$.json` (symlink pre-plant; security) | `mktemp` |
| C14 | Low | `mod_management.sh` (11 sites); `utilities.sh:198-200` | CurseForge key in argv (`-H "x-api-key: …"`) at every call; key file written under default umask then `chmod 600`; `-L` forwards the header on cross-host redirect (security) | `-H @file`, `umask 077`, drop `-L` |
| C15 | Low | `mod_management.sh:916-931` | jq program built by string interpolation of `MC_VERSION`; unreachable jq-less fallback | `--arg`; delete branch |
| C16 | Low | `mod_management.sh:680-864,1090-1094,1159-1162` | Dead `resolve_mod_dependencies` + two resolvers (a 4th/5th ladder copy); jq-less fallbacks; Modrinth id in the CF table | Delete |
| C17 | Low | `mod_management.sh:970-1031` | Three CF calls where one suffices; first response never read; hard-coded JEI→Fabric-API dep | One `/files` call |
| C18 | Low | `mod_management.sh:1156-1188` | CF branch of `fetch_and_add_external_mod` always "succeeds", even with no key/name/URL | Return 1 |
| C19 | Low | `mod_management.sh:190-193,1612` | Ladder picks newest regardless of `version_type`; requires `primary==true` (Modrinth says fall back to first file); cartesian `select` duplicates ids | `release` first; `// .files[0]`; `any()` |
| C20 | Low | `version_management.sh:404-410` | `.[0].version` may be an unstable loader; stale `0.16.9` magic fallback (PLAUSIBLE) | `select(.stable)` |
| C21 | Low | `version_management.sh:445-455,482-505` | `.lwjgl` field Fabric meta does not publish → static table always runs; wasted round-trip (PLAUSIBLE) | Derive from Mojang `libraries[]` |
| C22 | Low | `java_management.sh:85-86` | Offline Java table maps 1.20.5/1.20.6 → 17 (needs 21) | Split bucket |
| C23 | Low | `version_management.sh:347-380` | Menu lists 10, accepts 1–20 (unlisted versions selectable); hard-coded stale "Controlify" line | Cap; `_required_mods_summary` |
| C24 | Low | `mod_management.sh` (×17); `java_management.sh:111,176,177,287,399`; `version_management.sh:85,98,189`; `launcher_setup.sh:127` | API base URLs re-embedded ×17; `$HOME/.local/share/PolyMC` ×3; Mojang manifest URL twice; `x64`, 20, 30, 15, 12 magic | Bare constants |
| C25 (=F18) | Low | `install-minecraft-splitscreen.sh:384-396` vs `mods.conf` | Built-in mod defaults duplicate `mods.conf` without `# PAIRED`; README install path guarantees the duplicate is what users get; `MOD_DEPS_BY_NAME` dropped | Fetch `mods.conf` like `accounts.json` |
| C26 | Low | `mod_management.sh:973,990,1011,1069,1132,1229` | `local x=$(mktemp)` masks failure (SC2155); no traps → leaks on Ctrl-C | One temp dir + EXIT trap |
| C27 | Low | `mod_management.sh:123,609-627,2164-2170,2202` | `MOD_NAME/MOD_TYPE/MOD_ID` set as globals; loop vars not `local`; `read -a` without `-r` | `local` |
| C28 | Low | `mod_management.sh:1082` | Any body containing the string `"error"` treated as API error | `jq -e '.error?'` |
| C29 | Low | `mod_management.sh:1372-1403,631-632` | Modrinth slug vs id treated as different mods → duplicate downloads (PLAUSIBLE) | Normalise to `.id` |
| C30 | Low | `launcher_setup.sh:124-135` | `polymc.cfg` rewritten unconditionally on every run (user settings lost) | Update keys in place |
| C31 | Low | `mod_management.sh:1866-1916` | Custom-mod version switch discards the custom mod; re-runs `detect_java`/`configure_polymc_defaults` from inside a prompt (ARCHITECTURE §4) | Return to `main_workflow` |
| C32 | Low | `mod_management.sh:280-283,343-348,525-546` | CF `downloadUrl: null` reported as "no compatible file"; `/files` page size unhandled (PLAUSIBLE) | `select(.downloadUrl != null)`; `gameVersion=` |
| C33 | Low | `runtime_deploy.sh:181,149` | Runtime modules downloaded with the 15 s default timeout (PLAUSIBLE on slow links; pairs with C3) | Pass `0` |
| C34 | Info | `accounts.json` | Offline placeholder accounts only; no secret; all installs share four UUIDs | — |
| C35 | Info | `utilities.sh:95-98,128` | wget branch not equivalent to curl (`--timeout` per phase; `-S` then `2>/dev/null`) | — |
| C36 | Info | `mod_management.sh:1333` | `xargs` used as a trimmer re-tokenises quotes | Pure-bash trim |
| C37 | Info | `runtime_deploy.sh:107-116` | Stale comment references `launcher_setup.sh` | — |
| C38 | Info | `utilities.sh:322-323` | `mcss_prompt` nameref could shadow its own locals | Guard |
| C39 | Info | `tests/` | No tests for the #88 ladders, `_version_fallback_allowed`, the offline tables, `parse_custom_mod_input`; `test_version_stamp.sh` did not catch C7 | Fixture-JSON table tests |

### 5.4 Runtime: controllers / dock / evsieve (D)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| D6 | Low | `controller_proxy.sh:383,407-412,591-604` | `proxy_start_slot` failure leaves the pad symlink; `proxy_stop_all` (crash-residue reaper) has no production caller | `rm -f` on failure; wire or delete |
| D7 | Low | `controller_monitor.sh:91` | `readonly CONTROLLER_MONITOR_DEBOUNCE_MS=500` clobbers the documented env override (reproduced) | `${X:-500}` |
| D8 | Low | `controller_proxy.sh:122-133,299,312,398,408` | `*_TIMEOUT_S` constants only printed; real bound is `ITERS × INTERVAL` → can drift | Derive |
| D9 | Low | `dock_detection.sh:228-253` | `watch_display_mode` returns silently if `inotifywait` fails; heartbeat restarts it forever; poll fallback never used | Fall through to polling |
| D10 | Low | `controller_monitor.sh:965`; `dock_detection.sh:242` | Neither monitor traps TERM to reap its child `[KNOWN: N15]` | `trap` |
| D12 | Low | `controller_monitor.sh:841,919,729-736`; `orchestrator.sh:866,530` | `uniq` tokenised via `awk $5` on hotplug vs `read` slurp at startup (PLAUSIBLE, whitespace uniq only) | One `read -r` tokeniser |
| D13 | Low | `controller_monitor.sh:289-302,750-766`; `controller_proxy.sh:591-604` | Dead `_eventN_to_virtual_idx`, `get_controller_by_index` (listed as public API), `proxy_stop_all` | Delete |
| D14 | Low | `controller_proxy.sh:389,546`; `controller_monitor.sh:551,701,730-733,959,970`; `dock_detection.sh:244` | `MCSS-slot` prefix (the cross-module identity contract) in three sites with no shared constant; unnamed sleeps; node prefixes | `MCSS_PROXY_DEVNAME_PREFIX` in runtime_context |
| D15 | Low | `evsieve_management.sh:431` | `$src_dir` spliced into a single-quoted `sh -c` script (a `'` in `TARGET_DIR` breaks/injects) | Positional `$1` |
| D17 | Info | `evsieve_management.sh:498-500`; `preflight.sh` | No check that `/dev/uinput` is writable; host-verify is `--version` only | Soft warning |
| D18 | Info | `controller_monitor.sh:445,813,99,389,396` | shellcheck SC2206/SC2034 without the required suppressions (STYLE §7.8) | Annotate |
| D19 | Info | `controller_monitor.sh:807-810,837-841,914-919` | 4–5 `echo\|awk` forks per device per scan in the hot path | As D12 |
| D20 | Info | `controller_proxy.sh:199,224-226` | Pidfile contents not validated before `kill -0` (identity check saves it, by order) | Regex guard |
| D21 | Info | `controller_proxy.sh:409-410` | Unbounded `wait` after a plain `kill` on the failure path (PLAUSIBLE) | `_proxy_kill_verified` |

### 5.5 Runtime: window / KWin / dex / Steam helpers (E)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| E11 | Low | `system_integration.sh:114,125`; `add-to-steam.py:83-84` | Duplicate-shortcut check greps a hard-coded path fragment; adder picks an *unordered* first Steam user; no duplicate check in the adder itself | Move check into the adder with the real parser |
| E12 | Low | `window_manager.sh:149` | `dex_search` fallback can return several WIDs (no `head -1`) → `int()` fails → "dex remap FAILED" (PLAUSIBLE) | `head -1` |
| E13 | Low | `dex.sh:282,380,412,453,465` | Backend rejects hex WIDs although both callers' docs say hex is accepted | `int(x, 0)` |
| E15 | Low | `window_manager.sh:352-361`; `runtime_context.sh:327`; `instance_lifecycle.sh:173,1198` | Geom cache at predictable `/tmp/mcss-geom` decides "skip repositioning"; writer is a bare redirection under `set -e`; literal duplicated | `$MCSS_HELPER_DIR/geom` |
| E16 | Low | `window_manager.sh:251-252`; `orchestrator.sh:321` | `1280`/`800` re-embedded on the consumer side (the exact drift ARCHITECTURE §3 cites) | Require args |
| E17 | Low | `kwin_positioner.sh:250,308` | Unnamed `sleep 0.2` settle delays ×2 | `KWIN_POSITIONER_RUN_SETTLE_S` |
| E18 | Low | `system_integration.sh:213,222-227` | Shortcuts backup lands in `$PWD` (arbitrary under curl\|bash); silently skipped on failure | Next to the file; abort on failure |
| E19 | Low | `system_integration.sh:488`; `add-to-steam.py:131` | `.desktop` `Exec=` and Steam `exe` unquoted | Quote |
| E20 | Low | `add-to-steam.py:84,92-94,158,164-166` | Uncaught `FileNotFoundError` when Steam never ran; no `config/` mkdir; `urlopen` without timeout (#6); `.jpg` saved as `.png` | Harden |
| E21 | Low | `remove-from-steam.py:58,84,313` | Truncated input raises `ValueError`/`struct.error` past the `VdfError` handler (fail-safe, presentation only) | Wrap |
| E22 | Info | `dex.sh:194-201,244-248` | format-32 property read uses 4-byte stride (only correct for n=1); `XFree` skipped on early return; `'<I'` assumes LE | 8-byte stride; `finally` |
| E23 | Info | `dex.sh:454-457` | "gone" branch unreachable (default Xlib handler `exit(1)`s on BadWindow); the shell `\|\| echo gone` implements the contract | `XSetErrorHandler` or document |
| E24 | Info | `window_manager.sh:7-13,362` | Stale header (xdotool / placeholders); `[orchestrator] … [kwin frameGeometry]` tag on the dex path | Rewrite |
| E25 | Info | `system_integration.sh:264-268,291` | `add-to-steam.py` stderr discarded; helper fetched from `main` and executed unpinned (same trust model as the bootstrap) | Log stderr |
| E26 | Info | `add-to-steam.py:114-139`; `tests/test_uninstall_purge.sh:84-94` | crc order comment inaccurate; VDF entry writer exists in three copies | Share `mcss_vdf.py` |

### 5.6 Install / uninstall / deploy / system / CI (F)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| F9 | Low | `install-minecraft-splitscreen.sh:109,115` | `REPO_REF` unvalidated; curl squashes `..` so `../../other/repo/main` fetches from another repo (reproduced) | Regex-validate |
| F10 | Low | `install-minecraft-splitscreen.sh:199,214,275-277` | Bootstrap curl/wget with no timeouts (#6) | `--connect-timeout 10 --max-time 60` |
| F11 | Low | `system/deck-display-fixes/*` | Hard-coded `deck`, UID 1000, `/home/deck` in three files; `.service` copied verbatim into any `$HOME` | `%h`; derive user once |
| F12 | Low | `dock-display-hotplug.sh:17-23,50`; `resume-display-restore.sh:19` | Root-run hook writes a predictable `/tmp` stamp (symlink target overwrite); unvalidated arithmetic on its contents; unbounded `/tmp` log | `/run`; validate; `logger` |
| F13 | Low | `minecraftsplitscreen-test.sh:7,10` | Hard-coded checkout path; unbounded `git pull` on every Steam launch; `\|\| true` hides a failed `cd` | Drop auto-pull; `cd \|\| exit 1` |
| F14 | Low | `uninstall-minecraft-splitscreen.sh:417-444` | Fetched helper executed unverified; cleanup only if under `/tmp` (leaks with `TMPDIR`) | Compare to `$tmp` |
| F15 | Low | `uninstall-minecraft-splitscreen.sh:83-93` | `--keep-data` leaves `modules/`, `bin/evsieve`, `java/` (~300 MB); two targets (`live.check`, `PolyMC-*.log`) nothing writes | Add ours; drop phantoms |
| F16 | Low | `deploy.sh:44,52,186-187,205-212` | Non-atomic `cp` into a live tree; `sed -n '2,31p'` help range; third env-var name for the root; stamp failure reported as success | tmp+mv; heredoc; accept both names |
| F17 | Low | `ci.yml:33-56`; `release.yml:47,140,150` | shellcheck gate omits uninstaller/deploy/system/tests; no `timeout-minutes`; no `permissions:`; unpinned actions; every PR runs twice | Harden |
| F19 | Info | `install-minecraft-splitscreen.sh:101,199-215,263-268` | Under curl\|bash `SCRIPT_DIR` = CWD picks up a stray `modules/`; download loop leaks globals | Require manifest + launcher to treat as checkout |
| F20 | Info | `README.md:68`; `system/…/README.md:12-13` | "builds evsieve in a container" (now prebuilt-first); `predock-probe.sh` listed but absent; hotplug row contradicts code | Reword |
| F21 | Info | `system/deck-display-fixes/install.sh:12-21` | Aborts on `systemctl --user` without a session bus, after a half install; no uninstall for the root hook | Export runtime vars; add `--remove` |
| F22 | Info | `.gitignore` | Clean; `*.log` is broad | — |

### 5.7 Tests (T)

| ID | Sev | File | Finding | Fix |
|---|---|---|---|---|
| T11 | Low | `test_controller_monitor.sh:509-534` | Dead first monitor launch (start → sleep → kill) from an abandoned approach | Delete |
| T12 | Low | `test_instance_lifecycle.sh:150,283` | T4.5/T4.8 delete the production `/tmp/mcss-geom/slotN` files | `MCSS_GEOM_DIR` |
| T13 | Low | `tests/hardware/run_all.sh:57,185-199` | Exports a FIFO path no production code uses; stage6 not in the "all" run | Drop export; add stage6 |
| T14 | Low | `test_phase_b_lifecycle.sh` | Raw jq + defaults spelled 7×; never exits non-zero; sends a 4-field `CONTROLLER_ADD` (real is 5) | Accessors; exit code |
| T15 | Low | `helpers.sh:772` | `/home/deck` hard-coded (`hw_shortcut_gameid`) | `expanduser` |
| T16 | Low | `gamescope-*.sh:414,153,328` | `pkill -f` on window-title substrings after the tracked-PID kill (#7) | Delete |
| T17 | Low | `test_dock_detection.sh:78-201,11-12,281` | `trap "rm -rf $tmpdir"` expands at definition; dead constants | Single-quote |
| T18 | Low | `test_controller_monitor.sh`, `test_watchdog.sh`, `test_dock_detection.sh` | Backgrounded monitors inherit the CI capture pipe (#8; bounded today) | `>/dev/null 2>&1` |
| T19 | Info | `test_kwin_wrapper.sh:526-530` | `command` shim reads `$2` unguarded under `set -u` | `${2:-}` |
| T20 | Low | `test_uninstall_purge.sh:468-497` | T4.x/T5.1 depend on no real `steam` process on the host (no `/proc` seam) | `--proc-root` |
| T21 | Info | `test_installer.sh:514-533,83-101` | T7.17 tests bash, not the repo; T7.2 pins a magic total (23) | Derive |
| T22 | Info | `tests/lib/mc_osk_type.sh:70-83` | Global helper names (`_p`, `_h`) defined inside a function | Prefix |
| T24 | Info | `helpers.sh:473,522` | `eval` of xdotool `--shell` output | `read -r` loop |
| T25 | Info | `helpers.sh:190,210,592` | Operator prompts without a caret (#6) | `printf '> '` |

---

## 6. Test suite results (this environment, `timeout 120`, jq present, no inotifywait)

All 19 CI-gated suites at or above baseline; no hangs. The one red suite is red for the
wrong reason (T4).

| Suite | Result | Baseline | Note |
|---|---|---|---|
| test_controller_monitor | 22/22 | 22 | |
| test_instance_lifecycle | 16/16 | 16 | T2 hazard |
| test_watchdog | 15/15 | 15 | T5.7 can `_fail` then `_pass` |
| test_window_manager | **7/9, exit 1** | 7 | T4: inverted test |
| test_dock_detection | 8/8 | 8 | |
| test_runtime_context | 30/30 | 30 | |
| test_curseforge_token | 7/7 | 7 | |
| test_utilities | 13/13 | 13 | |
| test_orchestrator | 9/9 | 9 | T3 hazard |
| test_reconnect_dispatch | 15/15 | 15 | stubs `teardown_instance` (B1 invisible) |
| test_controller_proxy | 16/16 | 16 | |
| test_slot_manager | 17/17 | 17 | |
| test_proxy_launch | 7/7 | 7 | |
| test_uhid_pad | 23/23 | **18** | stale baseline |
| test_uhid_rig | 93/93 | 93 | |
| test_preflight | 12/12 | 12 | leaks `sleep 30` mocks (T7) |
| test_version_stamp | 18/18 | 18 | did not catch C7 |
| test_workdir | 15/15 | 15 | |
| test_uninstall_purge | 22/22 | 22 | |

Ungated but CI-safe, all green: installer 17/17, evsieve_management 20/20 (104 s),
controlify_seed 3/3, module_resource 22/22, probe_proxy_repoint 9/9, home_bwrap_bind /
kwin_wrapper / notify_no_controller `[OK]`.

## 7. Cross-cutting patterns

These recur across modules and are cheaper to fix as a class than one site at a time.

1. **Plain assignment from a failing pipeline under `set -euo pipefail`** (C1, E2, E4,
   A16, B21, D9). The installer and every module opt in to errexit; the documented
   fallback lines after such assignments are unreachable. A repo-wide grep for
   `=\$\(.*\| ` in installer modules is the fast way to find the rest.
2. **Name-matched kills** despite PRINCIPLES #7 (A1, A7, E9, T1, T16, B13's `rm -f`
   analogue). The launcher's own startup guard is the worst instance.
3. **Predictable paths in `/tmp`** (A12, A13, A21, B17, C13, D16, E14, E15, F12).
   `MCSS_HELPER_DIR` (0700) already exists for this; the FIFO, geom cache, dex
   backend, debug log and the helper-dir fallback itself do not use it.
4. **Consumer-side `:-` re-embeds of canonical constants** (B14, B17, C24, E15, E16,
   A15) — the drift pattern ARCHITECTURE §3 names.
5. **Copies of the version-match ladder** (B7, C10, C16, C19) — three live copies
   plus a dead one, after #88 declared one.
6. **Stale contracts in headers and docs**: slot_manager's "PR-c retired …" (A11),
   PRINCIPLES #5's "confirms across reads" (D1), ci.yml's "none exit non-zero" (F2),
   `orchestrator.sh`'s handheld→docked (A6), `kwin_set_noborder … in spawn_instance`
   (E5), README's container build (F20). Where the doc and the code disagree, the
   doc currently wins in reviewers' heads.
7. **Tests that cannot fail on the bug they nominally guard**: `teardown_instance`
   stubbed (B1), inverted grid table (T4), baseline gate (F2), `.pid` files nothing
   writes (T7), highest-slot semantics duplicated in the harness (T9).

## 8. Suggested fix order

Small, self-contained PRs, each mutation-tested where a test exists:

1. A1 (delete one `pkill` line), B1 (reorder + `wid:null`), E1 (reorder struct) — three
   one-screen diffs with outsized impact.
2. F1 + F6 (uninstaller blast radius), T1 + T3 + T2 (tests that kill real processes).
3. F2 + T4 + T6 (make CI able to see regressions) — do this *before* the larger fixes so
   they are actually guarded.
4. A3 + A4 + A6 (mode transitions), E2 + E3 (errexit-safe layout with a real return
   contract), D1 (fail-open dock detection, and fix PRINCIPLES #5 to match).
5. C1 + C2 + C3 + C7 + C8 (installer: reachable fallbacks, right JDK, atomic deploy).
6. Security batch: F3 (pin the release), B8/C5 (jar hashes), D5 (pin evsieve), A12/A13
   (helper-dir fallback + FIFO location), C6 (drop `~/.profile`), C14 (key in argv).
7. The Low/Info tables as opportunistic cleanups when touching each file.

---

_Per-module reports with full reasoning, reproduction notes and code quotes:_
`docs/reviews/2026-09-28/{A-orchestrator,B-lifecycle,C-installer-mods,D-controllers,E-window-system,F-install-ops,T-tests}.md`.
