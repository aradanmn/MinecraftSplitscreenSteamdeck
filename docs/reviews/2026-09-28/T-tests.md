# Review T — tests/ (unit suites, tests/lib, hardware helpers, run_all)

Scope read in full: every `tests/test_*.sh` (28 files), `tests/lib/{fake_pad.sh,mc_osk_type.sh,uhid_rig.sh,workdir.sh,uhid_pad.py}`, `tests/hardware/lib/helpers.sh`, `tests/hardware/run_all.sh`, `.github/workflows/ci.yml`. Probe/gamescope/kwin scripts skimmed for PRINCIPLES #6/#7/#8 only. Real modules opened wherever a fixture contract mattered (`orchestrator.sh` `_handle_msg`/`_launch_slot`, `controller_monitor.sh` `start_controller_monitor`, `instance_lifecycle.sh` `teardown_instance`/`_build_bwrap_command`, `watchdog.sh`, `controller_proxy.sh` `proxy_stop_slot`/`_proxy_pidfile`, `window_manager.sh` `compute_grid_mode`/`apply_layout`, `preflight.sh` `mcss_notify_user`, `runtime_context.sh` path/flag defaults, `dock_detection.sh` `watch_display_mode`).

## Actual suite runs (repo root, `timeout 120 bash tests/test_<name>.sh`, jq present, no inotifywait, pid_max=32768)

CI-gated suites (BASELINE in ci.yml):

| suite | exit | secs | summary line (exact) | ci.yml baseline |
|---|---|---|---|---|
| test_controller_monitor.sh | 0 | 5 | `22/22 tests passed.` | 22 |
| test_instance_lifecycle.sh | 0 | 1 | `16/16 tests passed.` | 16 |
| test_watchdog.sh | 0 | 7 | `15/15 tests passed.` | 15 |
| test_window_manager.sh | **1** | 0 | `7/9 tests passed.` | 7 (see T4) |
| test_dock_detection.sh | 0 | 7 | `8/8 tests passed.` | 8 |
| test_runtime_context.sh | 0 | 0 | `30/30 tests passed.` | 30 |
| test_curseforge_token.sh | 0 | 0 | `7/7 tests passed.` | 7 |
| test_utilities.sh | 0 | 0 | `13/13 tests passed.` | 13 |
| test_orchestrator.sh | 0 | 2 | `9/9 tests passed.` | 9 |
| test_reconnect_dispatch.sh | 0 | 7 | `15/15 tests passed.` | 15 |
| test_controller_proxy.sh | 0 | 12 | `16/16 tests passed.` | 16 |
| test_slot_manager.sh | 0 | 1 | `17/17 tests passed.` | 17 |
| test_proxy_launch.sh | 0 | 0 | `7/7 tests passed.` | 7 |
| test_uhid_pad.sh | 0 | 1 | `23/23 tests passed.` | 18 (stale, see T23) |
| test_uhid_rig.sh | 0 | 13 | `93/93 tests passed.` | 93 |
| test_preflight.sh | 0 | 4 | `12/12 tests passed.` | 12 |
| test_version_stamp.sh | 0 | 0 | `18/18 tests passed.` | 18 |
| test_workdir.sh | 0 | 0 | `15/15 tests passed.` | 15 |
| test_uninstall_purge.sh | 0 | 1 | `22/22 tests passed.` | 22 |

Not gated by ci.yml but CI-safe (also run):

| suite | exit | secs | summary line |
|---|---|---|---|
| test_installer.sh (informational in CI) | 0 | 1 | `17/17 tests passed.` |
| test_evsieve_management.sh | 0 | **104** | `20/20 tests passed.` |
| test_controlify_seed.sh | 0 | 1 | `3/3 tests passed.` |
| test_module_resource.sh | 0 | 0 | `22/22 tests passed.` |
| test_probe_proxy_repoint.sh | 0 | 3 | `9/9 tests passed.` |
| test_home_bwrap_bind.sh | 0 | 0 | `[OK] all _home_bwrap_bind_args cases passed` |
| test_kwin_wrapper.sh | 0 | 0 | `[OK] all _kwin_wrapper_script cases passed` |
| test_notify_no_controller.sh | 0 | 0 | `[OK] all _notify_no_controller_docked cases passed` |

No suite hung. `test_phase_b_lifecycle.sh` is Deck-only (not run). Only regression vs baseline: none; the only failing suite (window_manager 7/9, exit 1) is at its documented baseline — but see T4 for why that baseline is hiding an inverted test.

---

### T1. Hardware helper reaps sessions with name-matched `pkill -9` — kills a Desktop-Mode Plasma session
- **Severity:** Critical
- **Category:** principle-violation
- **File:** `tests/hardware/lib/helpers.sh:727-729`, `tests/hardware/lib/helpers.sh:742`, called from `helpers.sh:817` (`hw_launch_orchestrator`) and `helpers.sh:851` (`hw_stop_orchestrator`), i.e. every stage that launches or stops a session
- **Status:** CONFIRMED
- **What:** `hw_reap_stale_session` runs, unconditionally:
  ```bash
  pkill -9 -f 'SteamLaunch.*minecraftSplitscreen' 2>/dev/null || true
  pkill -9 -f 'latestUpdate' 2>/dev/null || true
  pkill -9 -f 'bwrap.*PolyMC' 2>/dev/null || true
  ...
  pkill -9 -f 'kwin_wayland' 2>/dev/null || true
  ```
  PRINCIPLES #7 bans exactly this ("`pkill`/`killall`/name-matched kills are banned"; the principle was earned by a test group-kill that disconnected a working session). The justification comment for the `kwin_wayland` line ("kwin_wayland only ever runs as this project's OWN nested session (Game Mode itself runs gamescope directly)") is false outside Game Mode: Desktop Mode on SteamOS and every Bazzite/Plasma-Wayland host (which the repo now explicitly supports — #198/#199, `test_kwin_wrapper.sh`, `test_home_bwrap_bind.sh`) runs the user's whole desktop under `kwin_wayland`. `-f 'latestUpdate'` matches any process whose *command line* contains that substring: an editor with `latestUpdate-1/options.txt` open, an SSH `tail -f .../latestUpdate-1/latest.log` the operator is watching, `tests/benchmark/sampler.sh` (whose own cmdline args are `latestUpdate-${slot}`), etc.
- **Failure scenario:** Operator runs `bash tests/hardware/run_all.sh stage3` from a Bazzite desktop or SteamOS Desktop Mode → `pkill -9 -f kwin_wayland` SIGKILLs the compositor → whole graphical session dies (including the terminal running the suite). Or: a second SSH window tailing an instance log is killed mid-run and the operator loses their diagnostics.
- **Fix:** Track and kill only what the harness started (helpers already have `HW_ORCH_PID`; hold the session PID/PGID from the Steam launch via the marked `pgrep`+environ loop that *already exists* at lines 721-724 and 743-748), and for kwin: match on our own nested kwin only — the one whose cmdline carries `--xwayland-display`/our `MCSS_KWIN_WRAPPER_PATH` parent — never by bare name. Delete the four `pkill` lines.

### T2. `test_instance_lifecycle.sh` does real process-GROUP kills on reachable fixture PIDs
- **Severity:** High
- **Category:** principle-violation
- **File:** `tests/test_instance_lifecycle.sh:146` (T4.5: `"pid":99999 ... "bwrap_pid":99998`), `tests/test_instance_lifecycle.sh:279` (T4.8: bwrap_pids `11110 22220 33330 44440`, pids `11111 22222 33333 44444`); sink `modules/instance_lifecycle.sh:1219,1242,1246`
- **Status:** CONFIRMED
- **What:** T4.5 and T4.8 call the *real* `teardown_instance`, which does `kill -TERM "-${bwrap_pid}"` then `kill -KILL "-${bwrap_pid}"` / `kill -9 "$java_pid"` on whatever the state file names. The fixture comment says "non-existent PID (kill will fail gracefully)" — but 11110/22220/33330/44440 are below `pid_max` on every Linux (32768 here; 4194304 on 64-bit systemd hosts, where 99998/99999 are reachable too). `test_orchestrator.sh:31-57` documents that this exact shape "has previously SIGKILLed the invoking shell's session" and guards its fixtures above pid_max; `test_controlify_seed.sh:23-28` and `test_controller_proxy.sh` T11 follow that convention; this suite does not.
- **Failure scenario:** Any process group whose PGID happens to be 11110/22220/33330/44440/99998 at the moment T4.8 runs (a Java instance on the Deck, the CI runner's own job tree, the developer's tmux server) gets SIGTERM then SIGKILL. Low probability per run, unbounded blast radius, and the suite is run on the Deck by the maintainer.
- **Fix:** Use the `test_orchestrator.sh` guard: fixture PIDs above `/proc/sys/kernel/pid_max` (e.g. `FIXTURE=$(( $(cat /proc/sys/kernel/pid_max) + 100000 ))`, refuse to run otherwise), or mock `teardown_instance`'s kill step. Also set `MCSS_GEOM_DIR="$tmpdir/geom"` in T4.5/T4.8 (see T12).

### T3. `test_orchestrator.sh` T6.3 runs the real `proxy_stop_slot` against the real `$XDG_RUNTIME_DIR/mcss` — can kill a live session's slot-2 evsieve
- **Severity:** High
- **Category:** principle-violation
- **File:** `tests/test_orchestrator.sh:167-172` (T6.3), sink `modules/orchestrator.sh:632-634` → `modules/controller_proxy.sh` `proxy_stop_slot` (`mcss_resolve_paths` → `_proxy_pidfile` → `${MCSS_HELPER_DIR}/proxy-slot2.pid`)
- **Status:** CONFIRMED (reproduced: sourcing the launcher the way the suite does yields `MCSS_CONTROLLER_PROXY=1`, `MCSS_HELPER_DIR=/run/user/<uid>/mcss`, `pidfile2=/run/user/<uid>/mcss/proxy-slot2.pid`)
- **What:** T6.3 mocks `teardown_instance` but not `proxy_stop_slot`/`slot_free`. Since #150 flipped `MCSS_CONTROLLER_PROXY` to default `1` (`runtime_context.sh:210`), `_handle_msg "SLOT_DIED 2"` now takes the flag-on branch:
  ```bash
  proxy_stop_slot "$slot" 2>/dev/null || true
  slot_free "$slot" 2>/dev/null || true
  ```
  `proxy_stop_slot` resolves the production helper dir (the suite overrides `LAUNCHER_DIR`/`SPLITSCREEN_STATE` only, never `MCSS_HELPER_DIR`/`MCSS_PROXY_*_DIR`), reads the real `proxy-slot2.pid`, identity-verifies it, kills it, and unconditionally `rm -f "$MCSS_PROXY_PADS_DIR/slot2" "$MCSS_PROXY_VIRT_DIR/slot2"`. The header's kill-safety analysis (lines 19-24) predates the flag flip and only covers `teardown_instance`. T6.8's real `start_watchdog` likewise consults the real pidfiles via `_watchdog_proxy_dead` (harmless, but state-dependent).
- **Failure scenario:** Maintainer runs `bash tests/test_orchestrator.sh` on the Deck while a 4-up session is up (the README says the suite is "safe to run un-namespaced") → player 2's evsieve proxy is SIGTERM/SIGKILLed and its pads/virt symlinks deleted → P2 loses input for the rest of the session (unrecoverable per the watchdog docstring). With no session up, it still deletes any leftover symlinks under the real runtime dir.
- **Fix:** Point the proxy dirs at the suite tmpdir before sourcing (`export MCSS_HELPER_DIR="$_TMPDIR/helper" MCSS_PROXY_PADS_DIR=... MCSS_PROXY_VIRT_DIR=...`), and/or stub `proxy_stop_slot(){ :; }` in T6.3 like `test_reconnect_dispatch.sh` does. Update the header's kill-safety note to cover the proxy path.

### T4. `test_window_manager.sh` T3.1/T3.9 assert the retired highest-slot grid semantics — the suite goes GREEN if the count-based fix is reverted
- **Severity:** High
- **Category:** test-quality
- **File:** `tests/test_window_manager.sh:38-48` (cases `"2:half"`, `"1 3:quad"`, `"3:quad"`, `"4:quad"`, `"2 4:quad"`), `tests/test_window_manager.sh:216-231` (T3.9 `compute_grid_mode "3"` expects `quad`); product `modules/window_manager.sh:208-236`
- **Status:** CONFIRMED (run output: `[FAIL] T3.1.3 — slots='2': expected 'half', got 'full'`, `T3.1.4 '1 3' expected quad got half`, `T3.1.6/7`, `T3.1.9 '2 4' expected quad got half`, `T3.9 slot 3 only: expected grid 'quad', got 'full'` → `7/9 tests passed.`) — partially [KNOWN: ci.yml comment "a few sub-tests are pre-existing known-fails tied to gated/unimplemented features"; docs/TODO.md:321 records the COUNT-based change as deployed 2026-06-23]
- **What:** `compute_grid_mode` was deliberately changed to count-based ("Was highest-slot-based, which left {2,4} as 'quad' and a lone slot-4 in a corner"). The test still encodes the OLD contract, so 6 of its 9 sub-cases fail *because the code is correct*. CI's baseline of 7 was set to tolerate this. The consequence is inverted: if someone reintroduces the highest-slot bug, T3.1 and T3.9 start passing (`9/9`), CI prints `OK: 9 >= 7`, and nothing notices. Meanwhile the intended behaviors ({2}→full, {2,4}→half, {1,3}→half, {3}→full) have zero unit coverage. This is precisely the PRINCIPLES #4 anti-pattern (a green-on-broken-code test) with the extra twist that it is red-on-correct-code.
- **Failure scenario:** PR reverts/mangles `compute_grid_mode` to slot-number-based → suite result improves from 7/9 to 9/9 → CI passes → lone P4 sits in a quarter of the TV again.
- **Fix:** Rewrite the T3.1 table to the documented count contract (`"2:full" "1 3:half" "3:full" "4:full" "2 4:half"`), rewrite T3.9 to assert `full` + `compute_slot_geometry 1 full` (or test `apply_layout`'s order-mapping through a stubbed `_position_slot`), bump ci.yml baseline to 9. Mutation-check by re-inverting `count`→highest-slot.

### T5. CI gates only on the parsed pass COUNT — a suite can print a full pass count while also recording failures
- **Severity:** Medium
- **Category:** test-quality
- **File:** `.github/workflows/ci.yml:90-101`; example `tests/test_watchdog.sh:330-361` (T5.7)
- **Status:** CONFIRMED (bash simulation of T5.7's flow: `_fail` then `_pass` → `passed=1 failed=1`; suite would print `15/15 tests passed.` and exit 1)
- **What:** ci.yml discards the exit status (`out=$(bash "$suite" 2>&1) || true`) and compares only `X` from `X/Y tests passed`. Its design comment ("none of these scripts exit non-zero on a failed sub-test") is stale: every suite now ends with `[[ TESTS_FAILED -eq 0 ]]` / `exit 1` (verified: window_manager exits 1). Several tests can emit `[FAIL]` and still `_pass` in the same test body, so `TESTS_PASSED == TEST_TOTAL` while `TESTS_FAILED > 0`: T5.7 (`_fail` at 334/337/345 without return, then `_pass` at 358); `test_dock_detection.sh` T1.7/T1.8 are fine, but the pattern is unguarded elsewhere too. The gate also cannot see a suite whose `TEST_TOTAL` drifted below the real test count.
- **Failure scenario:** Watchdog regresses so the first `read` times out ("timed out waiting for first SLOT_DIED" → `_fail`) but the process stays alive → `_pass` → `15/15 tests passed.` → CI `OK: 15 >= 15`.
- **Fix:** Gate on BOTH: `rc=0; out=$(bash "$suite" 2>&1) || rc=$?` and fail when `rc != 0 && passed >= baseline` for suites whose baseline == total; or simply require `grep -c '^\[FAIL\]'` to be `<= (total - baseline)`. Fix T5.7 to `return` after each `_fail`. Update the stale ci.yml comment.

### T6. Eight CI-safe suites are not in the ci.yml BASELINE map (three can't be, they print no summary line)
- **Severity:** Medium
- **Category:** test-quality
- **File:** `.github/workflows/ci.yml:68-89`; ungated: `tests/test_controlify_seed.sh`, `tests/test_evsieve_management.sh`, `tests/test_module_resource.sh`, `tests/test_probe_proxy_repoint.sh`, `tests/test_home_bwrap_bind.sh`, `tests/test_kwin_wrapper.sh`, `tests/test_notify_no_controller.sh` (+ `test_installer.sh` informational by design)
- **Status:** CONFIRMED (grep of `[tests/test_X.sh]` keys vs `ls tests/test_*.sh`; all 7 ran green here without network: 20/20, 3/3, 22/22, 9/9, `[OK]`×3)
- **What:** These suites run in seconds with no network/hardware (evsieve_management stubs git/distrobox/podman/fetch_url; installer T7.7 now stubs every module, so its "network quirk" rationale is stale too). None of them regress CI if broken. `test_home_bwrap_bind.sh`, `test_kwin_wrapper.sh`, `test_notify_no_controller.sh` print `[OK] all ... cases passed` / `[FAIL] N case(s) failed` instead of `X/Y tests passed`, so the current parser would report "no summary line" for them. `test_module_resource.sh` is the only guard for the HW-1 double-source abort; `test_evsieve_management.sh` guards the SHA-verify/host-verify gates (security-relevant).
- **Failure scenario:** A change breaks evsieve archive-SHA verification or re-introduces an unguarded `readonly` block → every CI run stays green.
- **Fix:** Add the seven to BASELINE (evsieve_management=20, controlify_seed=3, module_resource=22, probe_proxy_repoint=9, installer=17); give the three `[OK]`-style suites the standard `X/Y tests passed.` footer (or gate them on exit status). Consider a `tests/run_ci.sh` that enumerates `tests/test_*.sh` so new suites can't be forgotten.

### T7. `test_preflight.sh` cleanup reaps `*.pid` files that nothing ever writes — mock dialogs leak for 30 s per case
- **Severity:** Medium
- **Category:** test-quality
- **File:** `tests/test_preflight.sh:63-74` (`_mock_cleanup`), mock body `tests/test_preflight.sh:45-53`, `tests/test_preflight.sh:198,218` (`pgrep -f`)
- **Status:** CONFIRMED (grep: the only `.pid` reference in the suite or in `modules/preflight.sh` is the reader loop at line 67; the mock writes `.args`, `.env`, `.started` only)
- **What:** `_mock_cleanup` says "Reap only what the mocks started, by PID (PRINCIPLES #7)" and loops over `"$MOCKBIN"/*.pid` — but no `.pid` file is ever created, so the loop is dead code and every `kdialog`/`zenity` mock (`sleep 30`) started by T1.3, T2.1-T2.4, T3.1, T3.3, T3.4 outlives its test and the `rm -rf "$MOCKBIN"` that follows (8-10 orphan `sleep 30` processes per run). CI does not hang only because `mcss_notify_user` redirects the notifier's stdout itself (`preflight.sh`). T3.2/T3.3 then find the leaked process with `pgrep -f "$MOCKBIN/kdialog"` — a name-matched lookup (path is unique, so safe, but it exists only because the PID was never captured).
- **Failure scenario:** Mutation: make `mcss_notify_user` synchronous (drop the `&`) → T3.1 still passes only by elapsed-time; leaked mocks from earlier cases can make T2.3's `zenity.started`/`kdialog.started` assertions read a previous case's file if `mktemp -d` ever reuses a name; and the suite's own "PRINCIPLES #7 by PID" claim is false.
- **Fix:** Have the mock write `echo $$ > "$MOCKBIN/$tool.pid"` before `sleep 30` (then `_mock_cleanup` works as written and T3.2/T3.3 can read the pid from the file instead of `pgrep -f`).

### T8. `uhid_pad.py`: an out-of-range `axis` value poisons the pad — every later command fails
- **Severity:** Medium
- **Category:** bug
- **File:** `tests/lib/uhid_pad.py:379-381` (`UhidPad.axis`), `tests/lib/uhid_pad.py:264-266` (validation in `encode_report`), `tests/lib/uhid_pad.py:445-447` (loop swallows the error and continues)
- **Status:** CONFIRMED (reproduced in-process with a pipe fd: `axis("LX", 300)` raises `axis LX out of range: 300`; `_axes` is then `{'LX': 300}`; a following `press("BTN_SOUTH")` raises the same error)
- **What:**
  ```python
  def axis(self, name, value):
      self._axes[normalize_axis(name)] = int(value)   # stored BEFORE range check
      self.send()                                      # encode_report raises here
  ```
  The range check lives in `encode_report`, so the bad value is already committed to `self._axes` when the exception propagates. `_run_command_loop` catches it, prints `bad command`, and continues — but every subsequent `send()` re-encodes the poisoned axis and raises again, so the pad is dead for the rest of its life (`press`/`hat`/`neutral` all fail; `neutral()` would clear it but never gets to `send()` successfully... actually `neutral()` clears first then sends, so it is the only recovery). `press`/`hat` validate before mutating; `axis` is the odd one out. `fake_pad.sh` (the CI double) rejects out-of-range axes *without* state change, so `test_uhid_rig.sh` cannot see this — the drift guard only checks `--help` text.
- **Failure scenario:** A rig script sends `axis LX 300` by typo → all later `press BTN_SOUTH` acks turn into `bad command 'press BTN_SOUTH': axis LX out of range: 300`; the operator reads it as a button-name problem.
- **Fix:** Validate before storing: `v = int(value); if not 0 <= v <= 255: raise ValueError(...)`, then assign. Add a `--self-test` line covering it.

### T9. `hw_expected_slot_geometry` re-encodes grid/cell policy with different semantics from `compute_grid_mode`/`apply_layout` (latent)
- **Severity:** Medium
- **Category:** principle-violation
- **File:** `tests/hardware/lib/helpers.sh:402-439`; product `modules/window_manager.sh:218-236` (count-based) and `modules/window_manager.sh:323-343` (quad: cell = slot number; half/full: cell = ORDER among active)
- **Status:** CONFIRMED (divergence by reading; latent because every current caller — `stage3_hotplug.sh:198-463`, `probe-burst-spawn.sh:122` — passes a contiguous set `"1"`, `"1 2"`, `"1 2 3"`, `"1 2 3 4"`)
- **What:** The helper's comment says "mirrors compute_grid_mode" but it does: `count>=2 → half; any slot>=3 → quad; count>=3 → quad`, and in `half` it maps cells by *slot number* (`3|4 → full-screen`). The product: `count<=1 full, ==2 half, else quad`, and in half/full the cell is the slot's *order* among active slots. For active `"1 3"` (P2 quit): helper says `quad` / slot 3 at bottom-left quarter; product says `half` / slot 3 in the bottom half. PRINCIPLES #9 ("one encoding") — this is a second copy of the layout policy that has already drifted.
- **Failure scenario:** The first stage that asserts geometry after a *non-last* slot leaves (e.g. a stage5-style "P2 dies, P1+P3 reflow" check) will fail against correct product behavior, or pass against a regression.
- **Fix:** Source `modules/window_manager.sh` (pure functions, no side effects) in helpers and compute expected geometry with `compute_grid_mode` + the same order/slot cell rule (or expose a pure `compute_slot_cell active_slots slot` in window_manager and call it from both). Delete the local copy.

### T10. `test_module_resource.sh` omits `version_stamp.sh` from its static installer list — the drift it warns about has already happened
- **Severity:** Medium
- **Category:** test-quality
- **File:** `tests/test_module_resource.sh:33-48` (list has 10 entries; comment says "11 of them"); source of truth `install-minecraft-splitscreen.sh:129-139` (11 entries incl. `version_stamp.sh`)
- **Status:** CONFIRMED (run prints `22/22` = 12 runtime + 10 installer; `INSTALLER_MODULE_FILES` has 11)
- **What:** The suite exists to catch a module that aborts on double-source (the HW-1 on-Deck abort). Its installer list is "static on purpose — mirrors INSTALLER_MODULE_FILES", but `version_stamp.sh` (#89) was never added, so its re-source safety is unverified. `deploy.sh` sources `version_stamp.sh` from the checkout and the installer sources it too, so a `readonly` added there would reproduce the HW-1 class of abort.
- **Failure scenario:** A future `readonly VERSION_STAMP_X=` at top level of `version_stamp.sh` → run_all.sh/deploy path aborts with "readonly variable"; this suite stays 22/22.
- **Fix:** Parse the list from the installer (`grep -A 15 'readonly INSTALLER_MODULE_FILES=' ... | grep -o '"[a-z_]*\.sh"'`) the way `test_installer.sh` T7.2 already does, or add `version_stamp.sh` and assert the count equals T7.2's installer count.

### T11. `test_controller_monitor.sh` T2.8 contains a dead first monitor launch (start → sleep 0.3 → kill) left over from an abandoned approach
- **Severity:** Low
- **Category:** dead-code
- **File:** `tests/test_controller_monitor.sh:509-534`
- **Status:** CONFIRMED
- **What:** Lines 512-517 start a real `start_controller_monitor docked &` against `proc_input_initial`, lines 520-529 are a comment thread concluding "Can't … Let's use the polling approach differently", line 530 kills it, and the test then does the real symlink-based run. The first launch adds ~0.3 s, one extra background process whose stdout is the suite's (CI-captured) stdout, and a spurious `[controller_monitor] Starting …` log line; it asserts nothing.
- **Failure scenario:** None functional; it doubles the FIFO create/remove and makes the test read as if two monitors were under test.
- **Fix:** Delete lines 509-533 (keep `mkfifo` + the symlink run).

### T12. `test_instance_lifecycle.sh` T4.5/T4.8 delete the production geom-cache files under `/tmp/mcss-geom`
- **Severity:** Low
- **Category:** test-quality
- **File:** `tests/test_instance_lifecycle.sh:150,283`; sink `modules/instance_lifecycle.sh:1196` (`rm -f "${MCSS_GEOM_DIR:-/tmp/mcss-geom}/slot${slot}"`), default `modules/runtime_context.sh:327`
- **Status:** CONFIRMED (sourcing the three modules as the suite does leaves `MCSS_GEOM_DIR` unset → fallback `/tmp/mcss-geom`, the same default a live session resolves)
- **What:** T4.14-T4.17 correctly set `MCSS_GEOM_DIR="$tmpdir/geom"`; T4.5 and T4.8 do not, so a run removes `/tmp/mcss-geom/slot2` (T4.5) and `slot1..4` (T4.8) of whatever session is running on that machine — the exact "stale/missing geom entry mispositions the next reflow" class fixed in #172.
- **Failure scenario:** Suite run on the Deck during a session → next `apply_layout` loses its skip-unchanged cache for all four slots (harmless-ish: forces a re-position) — but it is real state touched by a unit test.
- **Fix:** `export MCSS_GEOM_DIR="$tmpdir/geom"` at suite top (or in T4.5/T4.8).

### T13. `run_all.sh` exports a FIFO path that no production code uses; stage6 is not in the "all" run
- **Severity:** Low
- **Category:** hardcoded
- **File:** `tests/hardware/run_all.sh:57` (`SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"`), `tests/hardware/run_all.sh:8,22,185-199`; production default `modules/runtime_context.sh:326` (`/tmp/minecraft-splitscreen.fifo`), override in `tests/hardware/lib/helpers.sh:814`
- **Status:** CONFIRMED
- **What:** run_all's exported FIFO path is a stale duplicate (PRINCIPLES #9) that `hw_launch_orchestrator` immediately overwrites with the real default; any stage reading `$SPLITSCREEN_FIFO` before a launch (stage0/stage1 smoke checks) looks at a path that never exists. Usage text says "stages 0–5" and the all-run stops at stage5 although `stage6_teardown.sh` exists — so a full run leaves the session up unless the operator remembers `run_all.sh stage6`.
- **Fix:** Drop the export (let helpers/runtime_context own the default) or import it from `runtime_context.sh`; add stage6 to the sequence (or document why it is manual).

### T14. `test_phase_b_lifecycle.sh` duplicates state/FIFO defaults and state readers, never exits non-zero, and sends a 4-field CONTROLLER_ADD
- **Severity:** Low
- **Category:** principle-violation
- **File:** `tests/test_phase_b_lifecycle.sh:37,41-50,69,84,100,106,116,133` (private `jq` readers + `$HOME/.local/share/PolyMC/splitscreen_state.json` spelled 7×), `tests/test_phase_b_lifecycle.sh:251-263` ("REAL 4-field CONTROLLER_ADD"), `tests/test_phase_b_lifecycle.sh:658-663` (no exit code)
- **Status:** CONFIRMED (real format is 5 fields — `controller_monitor.sh:845`; orchestrator tolerates 4 so it works, but the comment is stale since #38 PR3)
- **What:** PRINCIPLES #1/#9: raw `jq` on the state file and hand-copied defaults instead of the accessors (`_get_slot_field`, `slot_is_active`, `get_active_slots` from `instance_lifecycle.sh`, which the file even says it "matches exactly"). `_main` ends with `grep -c "PASS" ... && _info` (a zero count suppresses the line) and always exits 0, so a `testDirect` wrapper cannot tell pass from fail. Deck-only, so severity Low.
- **Fix:** Source `runtime_context.sh` + `instance_lifecycle.sh` for the accessors/defaults; end with `exit $(( fails > 0 ))`; emit `CONTROLLER_ADD … 0000 0000 <uniq>` (5 fields) and fix the comment.

### T15. `hw_shortcut_gameid` hard-codes `/home/deck`
- **Severity:** Low
- **Category:** hardcoded
- **File:** `tests/hardware/lib/helpers.sh:772`
- **Status:** CONFIRMED
- **What:** `glob.glob("/home/deck/.steam/steam/userdata/*/config/shortcuts.vdf")` — every other path in the harness is `$HOME`-relative; on Bazzite (`/var/home/<user>`, #199) or any non-`deck` user the Steam launch path returns nothing and `hw_launch_orchestrator` fails with "no Steam shortcut found".
- **Fix:** `os.path.expanduser("~/.steam/steam/userdata/*/config/shortcuts.vdf")` (matches `remove-from-steam.py`'s resolution).

### T16. Diagnostic gamescope scripts clean up with `pkill -f` on window-title substrings
- **Severity:** Low
- **Category:** principle-violation
- **File:** `tests/gamescope-override-redirect-test.sh:414`, `tests/gamescope-xdotool-test.sh:153`, `tests/gamescope-dex-test.sh:328`
- **Status:** CONFIRMED
- **What:** e.g. `pkill -f "OVER_REDIRECT_L\|OVER_REDIRECT_R"` right after `kill $W1_PID $W2_PID` — the tracked-PID kill already exists; the `pkill` is a belt that PRINCIPLES #7 forbids (it also matches the operator's own `grep OVER_REDIRECT_L` in another terminal). Legacy diag scripts, no CI exposure.
- **Fix:** Delete the `pkill` lines; the PIDs are tracked one line above.

### T17. `test_dock_detection.sh` minor hygiene: unquoted trap expansion, dead constants
- **Severity:** Low
- **Category:** robustness
- **File:** `tests/test_dock_detection.sh:78,98,118,134,201` (`trap "rm -rf $tmpdir" RETURN`), `tests/test_dock_detection.sh:11-12` (`readonly TEST_PASSED=0 / TEST_FAILED=1` unused), `tests/test_dock_detection.sh:281` (`local total=` unused)
- **Status:** CONFIRMED
- **What:** The trap string expands `$tmpdir` at definition time inside double quotes; a `TMPDIR` containing a space (or glob chars) would `rm -rf` the wrong words. Every other suite uses `trap 'rm -rf "$tmpdir"' RETURN`. The two readonly constants and `total` are never referenced.
- **Fix:** Single-quote the trap; delete the dead names.

### T18. Background monitors/watchdogs in several suites inherit the suite's stdout (the CI capture pipe)
- **Severity:** Low
- **Category:** principle-violation
- **File:** `tests/test_controller_monitor.sh:543,639,947` (`start_controller_monitor docked &`), `tests/test_watchdog.sh:63,103,146,184,226,273,327,386,420,452,514` (`start_watchdog &`), `tests/test_dock_detection.sh:215` (`watch_display_mode &`)
- **Status:** CONFIRMED (bounded today: each is killed by tracked PID and the only orphan is a `sleep ≤2s`/`sleep 3` child; no hang observed)
- **What:** PRINCIPLES #8: "Any process backgrounded inside a command substitution's reach must redirect its stdout/stderr off the captured pipe." ci.yml wraps each suite in `out=$(bash "$suite" 2>&1)`. `kill "$monitor_pid"` terminates the bash subshell but not its running child (`sleep 2` in the polling loop, or `inotifywait` if inotify-tools is ever installed on the runner — `dock_detection.sh:27` runs it with stdout inherited). Today the orphan exits within seconds; the discipline `test_orchestrator.sh` T6.8 applies (`>/dev/null 2>&1` on every backgrounded flow) is not applied here.
- **Fix:** Append `>/dev/null 2>&1` (or `2>>"$tmpdir/log"`) to each backgrounded `start_*`/`watch_*` call; the FIFO is the only channel the assertions read.

### T19. `test_kwin_wrapper.sh` `command` shim is one-arg-unsafe under the modules' `set -u`
- **Severity:** Info
- **Category:** robustness
- **File:** `tests/test_kwin_wrapper.sh:526-530`; `modules/*.sh:2` (`set -euo pipefail` at source time)
- **Status:** CONFIRMED (no current one-arg `command X` in the sourcing chain, so it passes)
- **What:** `command() { [[ "$1" == "-v" && "$2" == "setpriv" ]] && return 1; builtin command "$@"; }` is exported into a child that sources modules which turn on `set -u`; any `command foo` (single arg) in that chain would abort with "`$2`: unbound variable" instead of running. Use `"${2:-}"`.

### T20. `test_uninstall_purge.sh` T4.x/T5.1 depend on no real `steam`/`steamwebhelper` running on the host
- **Severity:** Low
- **Category:** test-quality
- **File:** `tests/test_uninstall_purge.sh:468-497` (T5.1), sink `remove-from-steam.py:166-180` (scans `/proc/*/comm` for `steam`/`steamwebhelper`)
- **Status:** CONFIRMED by reading
- **What:** `remove-from-steam.py` refuses (exit 2) whenever *any* process named `steam` exists. On a developer desktop with Steam open, T4.2-T4.6 fail (remover never rewrites) and T5.1 passes vacuously without its own `sleep`-renamed fixture. The suite has no override (e.g. `MCSS_PROC_ROOT`) to point the guard at a fake `/proc`.
- **Fix:** Give `remove-from-steam.py` a `--proc-root`/env seam and use it in the suite; or skip T4.x with an explicit `[SKIP] Steam is running` instead of a misleading `[FAIL]`.

### T21. `test_installer.sh` T7.17 tests bash, not the repo; T7.2 pins a magic total
- **Severity:** Info
- **Category:** test-quality
- **File:** `tests/test_installer.sh:514-533` (T7.17), `tests/test_installer.sh:83-101` (T7.2 `== 23`)
- **Status:** CONFIRMED
- **What:** T7.17 asserts a property of bash's readonly/prefix-assignment semantics with no repo code involved — it can never fail on a repo change (T7.18 is the real structural guard). T7.2's `23` is a hand-maintained count that has "gone stale" before per its own comment; asserting `installer_count == 11 && runtime_count == $(wc -l manifest)` would carry the same intent without the drift.

### T22. `mc_osk_type.sh` defines global helper functions from inside `mc_osk_type`
- **Severity:** Info
- **Category:** robustness
- **File:** `tests/lib/mc_osk_type.sh:70-83`
- **Status:** CONFIRMED
- **What:** Bash function definitions inside a function body are global once executed: `_p`, `_h`, `_goto`, `_shift` are created in the caller's shell on first call and shadow any same-named helper in a sourced lib (uhid_rig/helpers use `_rig_*`/`hw_*`, so no collision today; `_p`/`_h` are generic enough to collide later).
- **Fix:** Name them `_osk_press`/`_osk_hat`/`_osk_goto`/`_osk_shift`.

### T23. Stale CI baseline and a slow suite
- **Severity:** Info
- **Category:** test-quality
- **File:** `.github/workflows/ci.yml:82` (`test_uhid_pad.sh]=18`; suite has `TEST_TOTAL=23`), `tests/test_evsieve_management.sh:83-100` (104 s here — symlinks every file in `/usr/bin /bin /usr/sbin /sbin`)
- **Status:** CONFIRMED
- **What:** The uhid_pad baseline lets 5 of 23 tests fail silently (the #70 additions: BTN_MODE/THUMB*, hat, triggers). The evsieve suite's `_build_isolated_base` walk is the whole runtime; a `PATH` of `coreutils`-only symlinks (a fixed short list) would cut it to seconds if it is added to CI (T6).
- **Fix:** Bump to 23; build the isolated bindir from an explicit list of the ~25 tools the module uses.

### T24. `helpers.sh` `eval`s xdotool output
- **Severity:** Info
- **Category:** security
- **File:** `tests/hardware/lib/helpers.sh:473,522` (`eval "$geom"` from `xdotool getwindowgeometry --shell`)
- **Status:** CONFIRMED
- **What:** Trusted local tool, fixed `KEY=value` output; noted only because the repo's own rules flag `eval`. A `read -r` loop over the `--shell` lines would remove the eval.

### T25. Hardware harness operator prompts are unbounded reads without a caret
- **Severity:** Info
- **Category:** principle-violation
- **File:** `tests/hardware/lib/helpers.sh:190,210,592` (`read -r response`)
- **Status:** CONFIRMED
- **What:** PRINCIPLES #6 asks operator scripts to make "waiting for YOU" visible with a caret; the probes do this (`probe-evsieve-reconnect.sh:811 printf '> '`, `probe-uhid-feasibility.sh:112`), the hardware helpers print the instruction block but no caret. Intentionally unbounded (operator step), so Info only.

---

## Summary

Counts: Critical 1, High 3, Medium 6, Low 8, Info 7.

Suite results: all 19 CI-gated suites at or above baseline (window_manager 7/9 = baseline 7; uhid_pad 23/23 vs baseline 18); the 8 ungated CI-safe suites all pass; no hangs; slowest is `test_evsieve_management.sh` at 104 s.

Top three:
1. **T1** — `tests/hardware/lib/helpers.sh` `hw_reap_stale_session` uses `pkill -9 -f` on `kwin_wayland`, `latestUpdate`, `bwrap.*PolyMC`, `SteamLaunch.*` — PRINCIPLES #7; on Desktop Mode/Bazzite it kills the operator's whole desktop session, and it runs on every stage launch/stop.
2. **T3 / T2** — two CI-safe unit suites touch real state: `test_orchestrator.sh` T6.3 runs the real `proxy_stop_slot` against `$XDG_RUNTIME_DIR/mcss` (since the `MCSS_CONTROLLER_PROXY` default flipped) and `test_instance_lifecycle.sh` T4.5/T4.8 process-group-kill reachable fixture PIDs — both are the exact hazard class the repo already paid for (#103).
3. **T4** — `test_window_manager.sh` still asserts the retired highest-slot grid rule; the CI baseline of 7 hides that the test is inverted: reverting the count-based fix would make it go 9/9 green, and the intended behavior has no unit coverage. Closely related: **T5** (CI gates on pass count only, so a suite can report 15/15 with `[FAIL]` lines) and **T6** (8 CI-safe suites, including the evsieve SHA-verify guards and the double-source guard, are not gated at all).
