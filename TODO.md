# TODO

## Research — bare nested KWin on SteamOS 3.8 (Game Mode)

- [ ] **TESTED 2026-06-22 (testNested 2 on feat/gamescope-bare-kwin):** the
  `--exit-with-session` invocation fix WORKED — kwin launched the session command
  (was the `-- <cmd>` blocker). BUT bare `kwin_wayland` failed to bring up its
  compositor under gamescope: journal ended at `kwin_scene_opengl: Could not delete
  render time query because no context is current`, NO nested XWayland socket ever
  appeared, test harness never ran, kwin exited. CONTRAST: nested-Plasma's kwin
  composites Minecraft fine under gamescope (tests 2-4) — so the full Plasma session
  / `kwin_wayland_wrapper` provides GL/EGL/session setup that the bare invocation
  lacks. NEW bare-kwin blocker = GL/EGL context init. Next experiments: (a) launch
  via `kwin_wayland_wrapper` (what nestedPlasma/testPlasma use) instead of raw
  `kwin_wayland`; (b) try `KWIN_COMPOSE=Q` software compositing (caveat: may not
  composite XWayland GL/dmabuf clients); (c) investigate EGL platform env for nested
  GL-in-gamescope. Until solved, SHIP nested-Plasma-panel-less (`test N`).

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

  - **DEEP-RESEARCH #2 (2026-06-22) — the GL-context error + fixes:**
    KEY: nested-Plasma IS the maintainer-recommended pattern (David Edmundson's gist
    'Run plasma from within gamescope' launches full `dbus-run-session startplasma-wayland`,
    NOT bare kwin_wayland; no known-good example of bare kwin compositing GL clients in
    gamescope). → nested-Plasma-panel-less is the REAL answer; bare kwin is optional.
    IF pursuing bare kwin, two concrete fixes:
    (1) `unset LD_PRELOAD` — MISSING from launchNested (nestedPlasma/testPlasma DO it).
        Steam overlay preload (gameoverlayrenderer.so, seen in our logs) 'meddles with
        nested compositor tasks' (3-0). Genuine omission/bug.
    (2) `KWIN_COMPOSE=Q` (QPainter software comp) — documented KDE workaround for 'KWin
        can't start a working Xwayland nested with the OpenGL compositor' = our error (3-0).
        Try Q, then KWIN_COMPOSE=O2ES.
    BIG CAVEAT: NOT confirmed Q (software) composites XWayland GL/dmabuf windows like
    Minecraft — may black-screen them. On-Deck test only.
    REFUTED (don't chase): KWIN_DRM_DEVICES/wrong-DRM/simpledrm (0-3), llvmpipe-specific
    (0-3), kms_swrast perms (0-3), EGL-init-fails (0-3), KWIN_OPENGL_INTERFACE=egl (no-op),
    --expose-wayland requirement (unestablished 1-2). Exact root cause not pinned to a source.

## Immediate — Phase B testing

- [ ] Test 3.4 FAIL is teardown TIMING, not windowing: when P1 disconnects, teardown (SIGTERM→10s grace→SIGKILL→watchdog SLOT_DIED) + 3-player load takes >30s, so `_wait_for_slot_inactive 1 30` times out. Fix: bump that assertion window (e.g. 45–60s) and/or speed teardown. Confirmed 2026-06-21: windows tile correctly (half→quad→half), 3.1/3.2/3.3/3.5 pass, only 3.4 times out.
- [ ] Run `test 4` (quad, all 4) + desktop-mode pass of the nested-Plasma path.
- [x] test 4 RAN (4-player): 4.2/4.3 PASS. Issue A (P2 lost) reproduced at quad scale; issue B partially fixed.
- [ ] BUG (issue B) — REFINED: nested-Plasma session now EXITS cleanly (no orphan procs; startplasma "Shutting down" logged via qdbus logout + pkill), BUT gamescope STILL shows its game overlay (Menu/Abort Game) after exit. So it is gamescope GAME-END DETECTION, not orphan processes. Likely fixed by the bare-KWin path (--exit-with-session makes the Steam-launched kwin itself exit = cleaner end signal). Test feat/gamescope-bare-kwin to confirm.
- [ ] Teardown timing: slots still hit ">30s" on cleanup (test 3 3.4, test 4 cleanup). Bump _wait_for_slot_inactive window to 45-60s and/or speed teardown.
- [ ] BUG (issue A) — **DEFINITIVE DIAGNOSIS (test 4, 2026-06-22, AFTER the reparent-to-root fix f6d7061): we are fighting KWin's window manager and losing for every window except the first.** Full per-phase capture (/tmp/mcss-monitor.log auto-capture loop) showed slot 2 = `1280x359+0+361` **byte-identical across EVERY phase** — 2-player half, quad, scale-down 3, scale-down 2 — i.e. slot 2 NEVER moves a single pixel the entire run (not a revert-after-move; it just never lands). The `XReparentWindow` fix DID land the move at the X level: dex readback returned `[640 0 640 360]` every call (incl. on SETTLED scale-down with slot 1 already gone) — so it is NOT a timing race and NOT a stale-reflow race (no half reflow ever ran; all apply_layout calls were quad). The tell is the geometry: **slot 1 = `640x360+0+0` (clean, frameless → our OR won); slots 2,3,4 all carry KWin's ±1 decoration offset (`639x359`, `+...+361`) → still KWin-MANAGED/framed.** KWin re-grabs the client a beat after our cycle and re-places it (3&4 land near their cells via KWin's own placement; 2 lands full-width-bottom). override_redirect only sticks for slot 1 (OR'd while it was the lone fullscreen window, KWin idle). CONCLUSION: the OR-wrestling approach is structurally fragile against KWin — stop patching dex. FORK: **(A)** prevent KWin from ever managing the window (set override_redirect at window-CREATION time before KWin grabs it, or disable KWin placement/tiling in the nested session); **(B, RECOMMENDED)** position via KWin's scripting API (`workspace.windowList()`, `win.frameGeometry={...}`, `win.tile=null`) — work WITH KWin instead of against it (maintainer-blessed; API already researched). Awaiting user's A-vs-B decision.
  - **UPDATE 2026-06-22 (Path B tested): KWin's OWN scripting API also CANNOT move slot 2.** Built modules/kwin_positioner.sh (one-shot KWin JS over qdbus6: match by pid → tile=null → setMaximize(false) → noBorder → set frameGeometry) + tests/kwin-place-test.sh. KWin 6.4.3. The script matched slot 2 by pid and reported `placed -> 640,0 640x360`, but xwininfo showed it STAYS at `1280x359+0+361` across 8 retries. So the bug was never override_redirect-vs-KWin — **slot 2's window is pinned by some state that defeats geometry changes from ANY method** (likely a KWin quick-tile/maximize lock or fixed WM size-hints min==max; our tile=null/setMaximize(false) isn't clearing it). slot 1 moves (OR'd while lone fullscreen → free); 3/4 land via KWin's tiler. NEXT: run tests/kwin-diag.sh (built+deployed, all active slots) — dumps moveable/resizeable/tile/maximizeMode/minSize/maxSize + frameGeometry read-back INSIDE the script; geomAfterSet==cell → accepted-then-reverted, unchanged → KWin refused (reason in the fields). Run for ALL windows (compare slot 1 vs 2/3/4), don't special-case P2. Bus note: external SSH reaches the nested KWin via the addr in kwin_wayland's /proc/environ (unix:path=/tmp/dbus-*), NOT /run/user/1000/bus.
  - **CONFIRMED 2026-06-22 (kwin-diag, ALL slots, all stages): every window is `move=false resize=false` (override_redirect/unmanaged); tile=null, maxMode=0, min=0x0/max=huge → tile/maximize/size-hint guesses RULED OUT.** KWin's scripting API can't move ANY of them because our own dex OR cycle made them all unmanaged. THE REAL PATH B = remove override_redirect from apply_layout, keep windows KWin-managed, position via kwin_place_windows + noBorder. UNVERIFIED (deep-research/first test): that managed windows accept frameGeometry in nested gamescope + KWin doesn't auto-tile on map. (window.windowId is undefined in KWin 6.4 → match by pid.)
  - [history] wrong-WID hypothesis REFUTED by wintree-capture (test 4, 2026-06-22). The live xwininfo -tree (via tests/wintree-capture.sh) showed slot 2's PID owns EXACTLY ONE window = the STORED wid (25165831), sitting at 1280x359+0+361 (FULL-WIDTH bottom = the HALF-grid slot-2 geometry), while slots 3 & 4 were correctly in their quad cells. So we ARE moving the right window; it's at the WRONG GEOMETRY. => NOT wrong-WID / not a window-identity bug. ROOT CAUSE = the stale-`active` reflow race: a reflow computed a 2-player half layout and applied half-grid (1280-wide bottom) to slot 2, and the correct quad placement didn't stick. (Matches "flash to cell then snaps to bottom".) FIX DIRECTION: serialize reflows (flock) so the orchestrator _reflow_layout and spawn_instance step-8 apply_layout can't interleave, and ensure each apply_layout uses the CURRENT active set (the last writer must win with correct geometry); investigate why slot 2 specifically gets a stale 2-player set. NOTE: capture landed during teardown (test ran faster than estimated) — for a pristine all-4-up capture, re-run with SPLITSCREEN_TEST_OBSERVE_DELAY_S=60+ to widen the window. Also affects scale-down (survivors don't resize). [superseded earlier theory below kept for history] [old note: In test 3, slot 2 was commanded half-bottom→quad-top-right (readback=[640 0 640 360]) but stayed visually at half-bottom; P1 (also re-moved) and P3 (fresh map) were correct. So freshly-mapped windows tile fine; RE-tiling an already-override_redirect window is the problem. Next: reproduce test 3, during the quad phase poll the ACTUAL geometry of slot 2's WID via xwininfo on the nested display — determine if X really has it at top-right (→ compositor/repaint issue, maybe need an expose/damage or restack) or it bounced back (→ a racing reflow). Possibly fix by mapping at the new geom in one shot, or forcing a redraw.
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
