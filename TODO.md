# TODO

## Immediate — Phase B testing

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
