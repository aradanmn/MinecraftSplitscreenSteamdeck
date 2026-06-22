# TODO

## Research — bare nested KWin on SteamOS 3.8 (Game Mode)

- [ ] Deep-research running a **bare nested `kwin_wayland`** (no Plasma shell) as a
  Steam-launched game under gamescope on SteamOS 3.8, for full-screen splitscreen
  with no panel. Blocked during 2026-06-21 session by three gamescope/KWin walls:
  1. SSH/systemd-run-launched nested kwin runs but gamescope never gives it focus
     (only displays apps launched through Steam).
  2. A throwaway Wayland probe (wlr-randr) before kwin made gamescope think the
     game exited and kill it — fixed by removing all pre-kwin compositor probes.
  3. `kwin_wayland … --xwayland -- <cmd>` did NOT launch the session command under
     gamescope (process tree showed kwin → only Xwayland, no session child), and
     gamescope shows its loading spinner for an EMPTY nested compositor.
  Investigate: correct kwin session-leader invocation on 6.4.3 (positional arg vs
  `--`; `--exit-with-session`?), making kwin present an immediate surface, and
  gamescope focus/atom association (STEAM_GAME / GAMESCOPE_FOCUSABLE_APPS). For now
  we ship nested Plasma with the panel stripped (proven to display in gamescope).
  - **DEEP-RESEARCH ANSWER (2026-06-22):** root cause was the kwin invocation. The
    `-- <cmd>` form is WRONG (verified killed 0-3). Correct form is
    `dbus-run-session kwin_wayland --xwayland --no-lockscreen --no-global-shortcuts
    --width W --height H --exit-with-session bash "$0" _nestedSession` — command goes
    after `--exit-with-session`, SPACE-separated (NOT `=`, verified killed 1-2; NOT
    positional, killed 0-3). Source: blog.broulik.de 2025 (2-1) + elimination of all
    alternatives. Bonus: --exit-with-session makes kwin exit when the session cmd
    exits (also fixes the "Steam doesn't return" hang for the bare-kwin path).
  - All 3 walls were ONE wall: bad `-- <cmd>` syntax → session cmd never ran → kwin
    had no window → no focusable top-level surface → gamescope spinner + no focus.
    gamescope focus = pick_primary_focus_and_override() over candidates that have a
    focusable top-level surface; Steam-launched apps win via non-zero appID +
    GAMESCOPECTRL_BASELAYER_APPID ordering (gamescope steamcompmgr.cpp, 3-0).
  - DEAD END: manually spoofing the STEAM_GAME atom does NOT grant focus (killed
    0-3 multiple times). Rely on the Steam launch for the appID.
  - Nested kwin CAN host X11 clients (Graesslin rootless-XWayland demo, 3-0); our
    override_redirect tiling lives inside the nested kwin XWayland — gamescope only
    sees kwin's single composited output surface.

## Immediate — Phase B testing

- [ ] Test 3.4 FAIL is teardown TIMING, not windowing: when P1 disconnects, teardown (SIGTERM→10s grace→SIGKILL→watchdog SLOT_DIED) + 3-player load takes >30s, so `_wait_for_slot_inactive 1 30` times out. Fix: bump that assertion window (e.g. 45–60s) and/or speed teardown. Confirmed 2026-06-21: windows tile correctly (half→quad→half), 3.1/3.2/3.3/3.5 pass, only 3.4 times out.
- [ ] Run `test 4` (quad, all 4) + desktop-mode pass of the nested-Plasma path.
- [x] test 4 RAN (4-player): 4.2/4.3 PASS. Issue A (P2 lost) reproduced at quad scale; issue B partially fixed.
- [ ] BUG (issue B) — REFINED: nested-Plasma session now EXITS cleanly (no orphan procs; startplasma "Shutting down" logged via qdbus logout + pkill), BUT gamescope STILL shows its game overlay (Menu/Abort Game) after exit. So it is gamescope GAME-END DETECTION, not orphan processes. Likely fixed by the bare-KWin path (--exit-with-session makes the Steam-launched kwin itself exit = cleaner end signal). Test feat/gamescope-bare-kwin to confirm.
- [ ] Teardown timing: slots still hit ">30s" on cleanup (test 3 3.4, test 4 cleanup). Bump _wait_for_slot_inactive window to 45-60s and/or speed teardown.
- [ ] BUG (issue A) — REFINED by test 4 (4-player) user obs: P2 "lost". P3(bottom-left)+P4(bottom-right) cover the bottom half and P2 is visually a FULL-WIDTH half-height window at the bottom (its OLD half-grid size), while X reports the WID we move (25165831) correctly at the top-right quad cell. User saw a FLASH at top-right then it "snaps" to bottom. => we are moving a window that is NOT P2's actual visible surface (wrong-WID / window-identity), not a remap failure. dex remap readback was top-right 6x, never bottom, yet visual stayed bottom. NEXT: reproduce, during the quad phase run `xwininfo -tree` on the nested display, enumerate ALL windows for slot 2's PID, compare to state wid; fix _poll_for_window WID capture (GLFW/LWJGL may expose >1 X window). Also affects scale-down (survivors don't resize). [old note: In test 3, slot 2 was commanded half-bottom→quad-top-right (readback=[640 0 640 360]) but stayed visually at half-bottom; P1 (also re-moved) and P3 (fresh map) were correct. So freshly-mapped windows tile fine; RE-tiling an already-override_redirect window is the problem. Next: reproduce test 3, during the quad phase poll the ACTUAL geometry of slot 2's WID via xwininfo on the nested display — determine if X really has it at top-right (→ compositor/repaint issue, maybe need an expose/damage or restack) or it bounced back (→ a racing reflow). Possibly fix by mapping at the new geom in one shot, or forcing a redraw.
- [ ] BUG (issue B): nested Plasma session didn't exit after the test → Steam stayed on the running-game overlay until 'Abort Game'. Added explicit session logout + startplasma kill at end of launchTestFromPlasma (UNVERIFIED) — confirm it returns to Steam cleanly next session.

- [ ] Complete Phase B test run (Tests 1–7) on Deck — never finished cleanly
  - Deck: `ssh deck@192.168.1.131` → `git pull origin feat/gamescope-windowing`
  - Launch Steam shortcut; watch `~/splitscreen-phase-b-test-latest.log` + `/tmp/splitscreen-debug-latest.log`
  - Expected first failure: SingleApplication forwarding — slots 2-4 PolyMC bwrap exits after
    forwarding to slot 1 primary; watchdog may fire spurious SLOT_DIED. Check `modules/watchdog.sh:64-74`
    (already checks EITHER bwrap_pid OR java_pid — may already handle it).

---

## Module boundary cleanup — dex.sh vs window_manager.sh

Can be done any time; not blocking Phase B.

**dex.sh — remove domain logic that doesn't belong in the X11 layer:**
- [ ] `dex_wid_from_state()` — reads `splitscreen_state.json`; delete (duplicated in `_get_wid_from_state` in window_manager.sh)
- [ ] `dex_find_minecraft_windows()` — knows about `SplitscreenP{N}` naming; move to window_manager.sh or delete
- [ ] `dex_spawn_placeholder()` — spawns a GTK window; delete (window_manager.sh has `_spawn_placeholder` via tkinter/xterm)

**window_manager.sh — remove dead code:**
- [ ] TinyWM block (lines 449–654): `start_tinywm`, `stop_tinywm`, `is_tinywm_running`, `signal_tinywm_layout`, `_install_tinywm` — dead; we use nested KWin + dex
- [ ] `sync_apply_layout()` — delegates to `gamescope_windowing_apply_layout` which is in the confirmed-dead `gamescope_windowing.sh`; delete, callers use `apply_layout` directly
- [ ] `_GW_ANCHOR_PID` checks — gamescope windowing anchor; dead

**Consolidate placeholder:**
- [ ] Pick one implementation: tkinter (window_manager.sh `_spawn_placeholder`) or GTK (dex.sh `dex_spawn_placeholder`). Delete the other.

---

## Deferred to Phase 3/4 (PR time — when merging feat/gamescope-windowing → main)

Until then: development workflow is `git pull` on the Deck.

- [ ] Rename `minecraftSplitscreen.sh` → `mcss.sh`
  - Update `launcher_setup.sh`: `launcher_script`, `local_script`, `remote_script` variables
  - Update `desktop_launcher.sh`: `launcher_script_path` + print statements
- [ ] Fix installer hardcoded `main` branch URLs
  - `install-minecraft-splitscreen.sh` `REPO_BASE_URL`
  - `launcher_setup.sh` `base_url` in `install_runtime_modules`
  - `setup_splitscreen_launcher_script` `remote_script`
- [ ] Add test script deployment to installer (`tests/test_phase_b_lifecycle.sh` → `~/.local/share/PolyMC/tests/`)
- [ ] Update `launcher_script_generator.sh` to match current `minecraftSplitscreen.sh` (windowing code, dex.sh sourcing, session-env guard, timestamped logs, etc.)
- [ ] PR `feat/gamescope-windowing` → `main`

---

## Stale files to clean up

- [ ] `DECISION_NEEDED.md` — from Bazzite Rev3 / Border Enforcer era. Superseded: we now run KWin nested inside gamescope via `nestedPlasma()`, so "skip KWin in Game Mode" is moot. Delete.
- [ ] `GAMESCOPE_INVESTIGATION.md`, `GAMESCOPE_RESEARCH.md` — same era, same conclusion. Archive or delete.
- [ ] `modules/gamescope_windowing.sh` — confirmed dead code (marked DEAD/UNUSED in header). Delete when cleaning up.
