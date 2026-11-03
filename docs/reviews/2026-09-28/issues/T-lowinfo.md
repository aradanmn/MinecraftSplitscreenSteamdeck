title: [T11-T25] tests/ Low/Info hygiene: dead code, hardcoded paths, unquoted traps, capture-pipe leaks, missing carets
severity: low
security: no
type: Task
related: #199, #125
---
- [ ] T11 — `test_controller_monitor.sh` T2.8: dead first monitor launch from an abandoned approach
- [ ] T12 — `test_instance_lifecycle.sh` T4.5/T4.8 delete the production `/tmp/mcss-geom/slotN` cache
- [ ] T13 — `run_all.sh` exports a FIFO path no production code uses; stage6 is not in the "all" run
- [ ] T14 — `test_phase_b_lifecycle.sh` duplicates state/FIFO defaults + readers, never exits non-zero, sends 4-field CONTROLLER_ADD
- [ ] T15 — `hw_shortcut_gameid` hard-codes `/home/deck`
- [ ] T16 — diagnostic gamescope scripts clean up with `pkill -f` on window-title substrings
- [ ] T17 — `test_dock_detection.sh`: unquoted trap expansion, dead constants
- [ ] T18 — backgrounded monitors/watchdogs in three suites inherit the CI capture pipe
- [ ] T19 — `test_kwin_wrapper.sh` `command` shim reads `$2` unguarded under `set -u`
- [ ] T20 — `test_uninstall_purge.sh` T4.x/T5.1 depend on no real `steam` process on the host
- [ ] T21 — `test_installer.sh` T7.17 tests bash, not the repo; T7.2 pins a magic total
- [ ] T22 — `mc_osk_type.sh` defines global helper functions (`_p`, `_h`, …) from inside a function
- [ ] T24 — `helpers.sh` `eval`s xdotool `--shell` output
- [ ] T25 — hardware harness operator prompts are unbounded reads without a caret

## Summary

Fourteen Low/Info findings from the tests/ review (docs/reviews/2026-09-28/T-tests.md), none of which changes a suite's verdict today: leftover code from abandoned approaches, second copies of defaults the runtime owns, name-matched `pkill` in legacy diagnostic scripts, shell-hygiene nits (`trap "… $var"`, `$2` under `set -u`), backgrounded flows that hold the CI capture pipe (bounded today), and operator-prompt ergonomics. Each subsection has the file:line, the one-or-two-sentence what/why, and either a short diff or the sentence-sized fix. T23 (stale uhid_pad baseline, slow evsieve suite) is folded into the F2 CI-gate issue and is not listed here.

### T11. `test_controller_monitor.sh` T2.8 dead first monitor launch
`tests/test_controller_monitor.sh:509-534`. Lines 512-517 start a real `start_controller_monitor docked &` against `proc_input_initial`, 520-529 is a comment thread concluding "Let's use the polling approach differently", 530-531 kill it, and the test then does the real symlink-based run. It asserts nothing, costs 0.3 s, one extra background process on the suite's stdout, and a spurious `[controller_monitor] Starting …` log line. Fix: delete lines 509-533 (everything from the first `INPUTPLUMBER_DBUS_AVAILABLE=0 \` block through `rm -f "$fifo"`), keep the `mkfifo` + `ln -sf … proc_input_link` run that follows.

### T12. `test_instance_lifecycle.sh` T4.5/T4.8 delete the production geom cache
`tests/test_instance_lifecycle.sh:150,283`; sink `modules/instance_lifecycle.sh:1196` (`rm -f "${MCSS_GEOM_DIR:-/tmp/mcss-geom}/slot${slot}"`). T4.14-T4.17 set `MCSS_GEOM_DIR="$tmpdir/geom"`; T4.5 and T4.8 do not, so a run removes `/tmp/mcss-geom/slot2` and `slot1..4` of whatever session is live on that machine (the #172 mispositioning class). Fix: the `MCSS_GEOM_DIR="$tmpdir/geom"` lines are included in the **T2 issue's diff** (same two fixtures); a suite-wide `export MCSS_GEOM_DIR="$tmpdir/geom"` at the top is the fuller form.

### T13. `run_all.sh` stale FIFO export; stage6 missing from the all-run
`tests/hardware/run_all.sh:57` exports `SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"`, a path no production code uses (`runtime_context.sh:326` defaults to `/tmp/minecraft-splitscreen.fifo`; `helpers.sh:814` overwrites it at launch) — PRINCIPLES #9. Usage text (`:8,22`) says "stages 0-5" and the all-run (`:185-199`) stops at stage5 although `stage6_teardown.sh` exists, so a full run leaves the session up.
```diff
--- a/tests/hardware/run_all.sh
+++ b/tests/hardware/run_all.sh
@@ -54,7 +54,6 @@
 # --- Exported variables ---
 export REPO_ROOT
 export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
-export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
 export HW_PASSED=0
 export HW_FAILED=0
 export HW_SKIPPED=0
@@ -197,6 +196,7 @@
     run_stage "stage3_hotplug"
     run_stage "stage4_isolation"
     run_stage "stage5_crash"
+    run_stage "stage6_teardown"
 fi
 
 # ---------------------------------------------------------------------------
```
(Let `helpers.sh`/`runtime_context.sh` own the FIFO default; also update the usage text at `:8,22` to "0-6".)

### T14. `test_phase_b_lifecycle.sh` duplicated defaults/readers, no exit code, 4-field CONTROLLER_ADD
`tests/test_phase_b_lifecycle.sh:37,41-50,69,84,100,106,116,133` (private `jq` readers and `$HOME/.local/share/PolyMC/splitscreen_state.json` spelled 7×), `:251-263` (comment says "REAL 4-field CONTROLLER_ADD"; the real format is 5 fields since #38 PR3 — `controller_monitor.sh:845`), `:658-663` (`grep -c PASS … && _info` — a zero count suppresses the line, and `_main` always exits 0, so a wrapper cannot tell pass from fail). PRINCIPLES #1/#9. Fix: source `runtime_context.sh` + `instance_lifecycle.sh` for `slot_is_active`/`get_active_slots`/`_get_slot_field` and the defaults; inject `CONTROLLER_ADD /dev/null /dev/zero 0000 0000 <uniq>` and fix the comment; end `_main` with `exit $(( $(grep -c '\[FAIL\]' "$LOG") > 0 ))`. Deck-only suite, so Low.

### T15. `hw_shortcut_gameid` hard-codes `/home/deck`
`tests/hardware/lib/helpers.sh:772`. Every other harness path is `$HOME`-relative; on Bazzite (`/var/home/<user>`, #199) or any non-`deck` user the glob finds nothing and `hw_launch_orchestrator` fails with "no Steam shortcut found".
```diff
--- a/tests/hardware/lib/helpers.sh
+++ b/tests/hardware/lib/helpers.sh
@@ -768,8 +768,8 @@
 # launcher from shortcuts.vdf (gameid = appid<<32 | 0x02000000). Empty if absent.
 hw_shortcut_gameid() {
     python3 - <<'PYEOF' 2>/dev/null || true
-import glob, struct
-for path in glob.glob("/home/deck/.steam/steam/userdata/*/config/shortcuts.vdf"):
+import glob, os, struct
+for path in glob.glob(os.path.expanduser("~/.steam/steam/userdata/*/config/shortcuts.vdf")):
     data = open(path, "rb").read()
     appid, i = None, 0
     while i < len(data):
```
(Matches `remove-from-steam.py`'s resolution.)

### T16. Diagnostic gamescope scripts `pkill -f` window-title substrings
`tests/gamescope-override-redirect-test.sh:414`, `tests/gamescope-xdotool-test.sh:153`, `tests/gamescope-dex-test.sh:328`. Each runs e.g. `pkill -f "OVER_REDIRECT_L\|OVER_REDIRECT_R"` one line after `kill $W1_PID $W2_PID` — the tracked-PID kill already exists; the `pkill` is the belt PRINCIPLES #7 forbids and also matches an operator's `grep OVER_REDIRECT_L` in another terminal. Legacy diag scripts, no CI exposure. Fix: delete the three `pkill -f` lines (`:414`, `:153`, `:328`); the PIDs are killed on the preceding line.

### T17. `test_dock_detection.sh` unquoted trap expansion, dead constants
`tests/test_dock_detection.sh:78,98,117,132,201` use `trap "rm -rf $tmpdir" RETURN` — `$tmpdir` expands at definition time inside double quotes, so a `TMPDIR` containing a space or glob character would `rm -rf` the wrong words; every other suite uses the single-quoted form. `:11-12` `readonly TEST_PASSED=0` / `TEST_FAILED=1` and `:281` `local total=…` are never referenced.
```diff
--- a/tests/test_dock_detection.sh
+++ b/tests/test_dock_detection.sh
@@ -8,8 +8,6 @@
 # Run: bash tests/test_dock_detection.sh
 # =============================================================================
 
-readonly TEST_PASSED=0
-readonly TEST_FAILED=1
 readonly TEST_TOTAL=8
 
 # Find the repo root (parent of the tests/ directory)
@@ -75,7 +73,7 @@
 test_t1_3() {
     local tmpdir
     tmpdir=$(mktemp -d)
-    trap "rm -rf $tmpdir" RETURN
+    trap 'rm -rf "$tmpdir"' RETURN
 
     local drm_dir="$tmpdir/sys/class/drm/card0-eDP-1"
     mkdir -p "$drm_dir"
@@ -95,7 +93,7 @@
 test_t1_4() {
     local tmpdir
     tmpdir=$(mktemp -d)
-    trap "rm -rf $tmpdir" RETURN
+    trap 'rm -rf "$tmpdir"' RETURN
 
     local edp_dir="$tmpdir/sys/class/drm/card0-eDP-1"
     mkdir -p "$edp_dir"
@@ -114,7 +112,7 @@
 test_t1_5() {
     local tmpdir
     tmpdir=$(mktemp -d)
-    trap "rm -rf $tmpdir" RETURN
+    trap 'rm -rf "$tmpdir"' RETURN
 
     # Empty DRM dir — no connectors at all
     local drm_dir="$tmpdir/sys/class/drm"
@@ -129,7 +127,7 @@
 test_t1_6() {
     local tmpdir
     tmpdir=$(mktemp -d)
-    trap "rm -rf $tmpdir" RETURN
+    trap 'rm -rf "$tmpdir"' RETURN
 
     local hdmi_dir="$tmpdir/sys/class/drm/card0-HDMI-A-1"
     mkdir -p "$hdmi_dir"
@@ -198,7 +196,7 @@
 test_t1_8() {
     local tmpdir
     tmpdir=$(mktemp -d)
-    trap "rm -rf $tmpdir" RETURN
+    trap 'rm -rf "$tmpdir"' RETURN
 
     local drm_dir="$tmpdir/sys/class/drm"
     mkdir -p "$drm_dir/card0-eDP-1"
@@ -278,7 +276,6 @@
     test_t1_8
     echo ""
 
-    local total=$((TESTS_PASSED + TESTS_FAILED))
     echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
 
     if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
```

### T18. Backgrounded monitors/watchdogs inherit the CI capture pipe
`tests/test_controller_monitor.sh:517,543,639,947` (`start_controller_monitor docked &`), `tests/test_watchdog.sh:63,103,146,184,226,273,327,386,420,452,514` (`start_watchdog &`), `tests/test_dock_detection.sh:215` (`watch_display_mode &`). ci.yml wraps each suite in `out=$(bash "$suite" 2>&1)`; `kill "$monitor_pid"` ends the bash subshell but not its running child (`sleep 2` in the poll loop, or `inotifywait` if inotify-tools is ever on the runner — `dock_detection.sh:27` runs it with stdout inherited). Bounded today (orphans exit within seconds), which is why this is Low; PRINCIPLES #8 asks for the redirect regardless, and `test_orchestrator.sh` T6.8 already does it. Fix: append `>/dev/null 2>&1` (or `2>>"$tmpdir/log"` where a test greps stderr) to each backgrounded `start_*`/`watch_*` call — the FIFO is the only channel the assertions read.

### T19. `test_kwin_wrapper.sh` `command` shim reads `$2` unguarded
`tests/test_kwin_wrapper.sh:88-92` (the review's `:526-530` reference is stale; the file is 106 lines): the exported `command()` shim tests `"$2" == "setpriv"` and is inherited by a child that sources modules which turn on `set -u`; any single-arg `command foo` in that chain would abort with `$2: unbound variable` instead of running (none exists today, hence Info).
```diff
--- a/tests/test_kwin_wrapper.sh
+++ b/tests/test_kwin_wrapper.sh
@@ -88,4 +88,4 @@
 command() {
-    [[ "$1" == "-v" && "$2" == "setpriv" ]] && return 1
+    [[ "${1:-}" == "-v" && "${2:-}" == "setpriv" ]] && return 1
     builtin command "$@"
 }
```

### T20. `test_uninstall_purge.sh` T4.x/T5.1 depend on no real `steam` on the host
`tests/test_uninstall_purge.sh:468-497` (T5.1); sink `remove-from-steam.py:166-180` (`steam_is_running` scans `/proc/*/comm` for `steam`/`steamwebhelper` and exits 2). On a developer desktop with Steam open, T4.2-T4.6 fail (the remover never rewrites) and T5.1 passes vacuously without its own renamed-`sleep` fixture; there is no seam to point the guard at a fake `/proc`. Fix: give `remove-from-steam.py` an `MCSS_PROC_ROOT` env (default `/proc`) read by `steam_is_running`, and have the suite export a tmpdir with a fake `<pid>/comm` for T5.1 and an empty one for T4.x; or, minimally, detect a real Steam at suite start and print `[SKIP] Steam is running` for T4.x instead of a misleading `[FAIL]`.

### T21. `test_installer.sh` T7.17 tests bash, not the repo; T7.2 pins a magic total
`tests/test_installer.sh:514-533` (T7.17) asserts bash's readonly/prefix-assignment semantics with no repo code involved — it can never fail on a repo change (T7.18 is the real structural guard). `:83-101` (T7.2) hard-codes `total == 23`, a count its own comment admits has gone stale before. Fix: drop T7.17 (and `TEST_TOTAL` by one), and make T7.2 assert `installer_count == $(grep -c '\.sh"' <INSTALLER_MODULE_FILES block>)`-style structure — e.g. `installer_count >= 11 && runtime_count == $(grep -cvE '^\s*(#|$)' modules/runtime_modules.list)` — instead of a literal sum.

### T22. `mc_osk_type.sh` defines global helper functions from inside a function
`tests/lib/mc_osk_type.sh:70-83`. `_p`, `_h`, `_goto`, `_shift` are defined inside `mc_osk_type`; bash function definitions are global once executed, so they land in the caller's shell on first call and would shadow any same-named helper in a sourced lib (`uhid_rig`/`helpers` use `_rig_*`/`hw_*`, so no collision today — `_p`/`_h` are generic enough to collide later). Fix: rename to `_osk_press`, `_osk_hat`, `_osk_goto`, `_osk_shift` (four definitions plus their call sites inside the function; `sed -i 's/\b_p\b/_osk_press/g; …'` scoped to that file).

### T24. `helpers.sh` `eval`s xdotool output
`tests/hardware/lib/helpers.sh:473,522`: `eval "$geom"` where `geom` is `xdotool getwindowgeometry --shell` output. Trusted local tool with fixed `KEY=value` lines; noted only because the repo's own rules flag `eval`. Fix (both sites): replace with a `read -r` loop —
```bash
while IFS='=' read -r _k _v; do
    case "$_k" in X|Y|WIDTH|HEIGHT|SCREEN|WINDOW) printf -v "$_k" '%s' "$_v" ;; esac
done <<< "$geom"
```

### T25. Hardware harness operator prompts have no caret
`tests/hardware/lib/helpers.sh:190,210,592` (`read -r response` in `hw_prompt`, `hw_confirm`, `hw_checklist`). PRINCIPLES #6 asks operator scripts to make "waiting for YOU" visible; the probes do (`probe-evsieve-reconnect.sh:811 printf '> '`, `probe-uhid-feasibility.sh:112`), the harness prints the instruction block and then blocks silently. Intentionally unbounded (operator step), so Info. Fix: `printf '> ' >&2` immediately before each of the three `read -r response` lines (stderr, so a captured stdout is untouched).

## Hardware verification

Only T13, T15, T24 and T25 change behaviour on the Deck, all in the operator harness: run `bash tests/hardware/run_all.sh` end-to-end in Game Mode docked with 2 pads and confirm (T13) the run ends with stage6 and the session is torn down (`pgrep -a kwin_wayland` empty, Steam back at the library); (T15) on a non-`deck` user or Bazzite host `hw_launch_orchestrator` still finds the shortcut (`Launching via Steam shortcut (gameid …)` in `.workdir/hardware/splitscreen-hwtest-*.log`); (T24) `hw_assert_window_at` lines still report `actual=X,Y WxH` with real numbers; (T25) each `>>>` prompt is followed by a visible `> ` caret. Everything else is CI + unit test only (T11/T17/T18/T19/T20/T21 are suite hygiene; T12 is covered by the T2 issue; T14 is the Deck-only phase-B script, re-run it once after the accessor change and confirm it exits 1 when a `[FAIL]` line is present; T16 are legacy diag scripts; T22 is the OSK helper, exercised by the uhid rig's login typing in stage3 with `MCSS_VIRTUAL_PADS=1`).

## References

Review T11-T22, T24, T25 (docs/reviews/2026-09-28/T-tests.md; CODE-REVIEW-2026-09-28.md §5.7). PRINCIPLES #1 (accessors, T14), #6 (carets, T25), #7 (no name-matched kills, T16), #8 (capture pipe, T18), #9 (one encoding, T13/T14/T21). Related: #199 (Bazzite `/var/home`, T15), #172 (geom cache, T12), #125 (dialog tests, T20's neighbour suite), #38 PR3 (5-field CONTROLLER_ADD, T14). T12's fix ships in the T2 issue; T23 ships in the F2 CI-gate issue.
