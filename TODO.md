# TODO

## ☐ Architecture audit + placement law — 2026-07-17 (docs + issues only, no code changed)

Full script-interaction audit (3-agent: runtime map / installer map / cross-cutting
sweep) answering "why is duplication still appearing after the D-sweeps?" Answer:
the canonical homes exist (#43/#45/#50/#51 worked) — the residue is sites that
BYPASS them, plus missing placement rules for new code.

- **[NEW] docs/AUDIT-ARCHITECTURE-2026-07-17.md** — block diagrams (module graph,
  install flow, runtime FIFO flow) + full findings: 5 constant-bypass clusters,
  12 duplication clusters, dead-code inventory, merge candidates.
- **[NEW] docs/ARCHITECTURE.md** — the placement law: domain-ownership table
  (which module owns what), globals decision ladder (runtime_context vs installer
  block vs PAIRED vs module-local), sourcing rules, standalone-script duplication
  budget, pre-commit placement checklist. Companion to STYLE-GUIDE.md (#52):
  style guide = how code looks, ARCHITECTURE.md = where code goes.
- **Issues filed:** #85 (_reflow_layout bypasses mcss_resolve_screen + 1280/800
  hardcode — wrong-screen risk per #83's two-X-servers finding), #86 (constants
  hygiene batch: flock -w 5 ×2, timeout-3 ×4, 2 dead constants, WATCHDOG_MAX_SLOT
  third "4", Steam-shutdown literals), #87 (JVM mem defaults source-order
  coupling), #88 (version-match ladder ×4 — sibling of #47), #89 (manifest parse
  ×4 + stamp sed ×2), #90 (delete legacy prototype path + unused dex API +
  setSplitscreenModeForPlayer + shims), #91 (installer merges: lwjgl→version_mgmt,
  desktop_launcher+steam_integration, launcher_setup split).
- **Suggested order (audit §7):** #86 → #85+#87 → #47+#88 together → #90 (own
  deletions-only PR, stage1 smoke + one prod launch) → #89/#91 (merge BEFORE the
  #52 retrofit so we don't retrofit files about to disappear).
- **[CODE] Fix batch implemented + adversarially verified — 2026-07-17, NOT
  Deck-validated.** Six commits on this branch (Sonnet implemented, Fable
  verified): #86 (1ae42c0), #85 (0920e93 — `mcss_resolve_screen --refresh`
  post-mode-change), #87 (026f165), #47+#88 (82bf2aa — token helper in
  utilities.sh; canonical ladders `match_modrinth_version`/
  `match_curseforge_version`; three pre-existing divergences preserved by
  parameter, documented at each site), #90 (1c138fd launcher −461 lines,
  dead fallbacks now hard-error; 345a469 dex −8 unused wrappers+actions,
  3 kept as annotated test-only). Verification caught and fixed one real
  bug pre-push: 17 API URLs with in-string line continuations embedding
  whitespace (would have broken every Modrinth/CurseForge call; amended
  into 82bf2aa). test_installer baseline 10/10→9/9 (T7.6 asserted the
  deleted `ensure_bwrap_installed` shim existed — CI unaffected, suite is
  informational there). All gated suites at baseline; `--version` smoke OK.
  **NEXT: Deck-validate (stage1 smoke + one prod launch + one mod-check
  install run), then close #85/#86/#87/#47/#88/#90. #89/#91 not started.**
- Supersedes the stale "Module boundary cleanup — dex.sh vs window_manager.sh"
  section below: TinyWM/gamescope_windowing items there are already done;
  the still-live dex items are folded into #90.

## ☐ Codebase review + v1.1 fix batch — 2026-07-01 (ALL [CODE], NOT Deck-validated)

Full-codebase review + GitHub issue triage, followed by a same-session fix pass across
architecture, controller/window-manager robustness, and process hygiene. Nothing below
has been run on a Deck — same rule as everywhere else in this file.

- **[CODE] #43 — authoritative runtime-context global.** New `modules/runtime_context.sh`
  (`mcss_resolve_environment`/`mcss_require_gamescope`), resolved once from
  `XDG_CURRENT_DESKTOP`/`XDG_SESSION_DESKTOP` before any nesting happens. Wired into both
  installer module-deploy lists (`install-minecraft-splitscreen.sh`, `launcher_setup.sh`).
- **[CODE] #42 — Desktop-Mode runaway.** The bare `*)` dispatch in `minecraftSplitscreen.sh`
  now refuses to call `main()` unless `MCSS_NESTED_SESSION=1` (set by
  launchFromPlasma/testPlasma/nestedPlasma/launchNested before they re-invoke the script)
  or the outer context is gamescope — closing the root cause, not just the symptom.
  `launchFromPlasma`'s STARTUP GUARD also stops any stale `app-MinecraftSplitscreen@*`
  systemd unit before a fresh launch. Desktop shortcut's Comment now states Game-Mode-only.
- **[CODE] #40 — `_set_mode` crash on missing state file.** No longer hard `exit 1`s under
  `set -e`; initializes a default state file and tolerates a `jq` failure instead of
  killing the whole launcher on first call (regression from the H3 flock fix).
- **[CODE] #15/D6 — nested-session teardown (Abort-Game overlay).** `launchFromPlasma` no
  longer `exec`s into `dbus-run-session startplasma-wayland` — it stays alive as an outside
  supervisor (bounded wait, then a NEW `_supervise_reap_nested_session`: tries
  `systemctl --user stop plasma-workspace.target` first, then retries the kill sweep in a
  bounded loop to out-wait systemd's Restart=on-failure/burst-limit instead of a single
  one-shot pass).
- **[CODE] #16/H9 — monitor heartbeat.** New `_check_monitor_heartbeats` (orchestrator.sh),
  called every event-loop tick in both flows; restarts controller_monitor/dock_monitor/
  watchdog if any died.
- **[CODE] #17/H10 — reflow retry.** `_reflow_layout` sets `_REFLOW_NEEDED`; both event
  loops retry on the next tick instead of logging once and leaving the layout wrong.
- **[CODE] #23/N16 (+H1) — controller_monitor snapshot skew.** `_check_devices_changed` now
  enumerates ONCE and echoes the authoritative node set on stdout; both the udevadm and
  poll-fallback call sites use that return value instead of re-enumerating separately.
- **[CODE] #21/N10 — KWin PID-only window match.** `kwin_place_windows`' JS now
  disambiguates multiple pid-matching windows (a splash/launcher sharing the game's PID) by
  `resourceClass`/`resourceName` before falling back to the first match.
- **[CODE] #22/N11 — bwrap liveness check.** `spawn_instance` checks `kill -0` on the bwrap
  PID (after a brief grace) before burning the full 60s java poll.
- **[CODE] #19/M7 — dex temp file leak.** `orchestrator.sh cleanup()` removes
  `$DEX_PY_SCRIPT` on the way out (dex.sh itself still deliberately doesn't self-trap it).
- **[CODE] #18/L3 — jq `--arg` hygiene.** Fixed in `dex.sh`/`window_manager.sh`'s
  state-file reads (the "fail on unpaired mask arg" half was already handled).
- **[CODE] #24/N13 — `cp -r` empty-mod-set false failure.** `nullglob` + per-file copy in
  `instance_creation.sh`, so an empty mod set isn't reported as a failure and one bad file
  doesn't fail the whole batch.
- **[CODE] #25/N14 — inotifywait missed hotplug.** Dropped the `--include 'status'` filter
  (was invisible to a connector directory itself being created/removed) and added
  `moved_to`/`delete_self`.
- **[CODE] #26/N15 — leaked dock monitor.** `cleanup()` now kills `watch_display_mode`'s
  `inotifywait` child (via `_kill_tree`/`pkill -P`), not just the parent PID.
- **[CODE] #27 — low-severity batch:** 720→800 fallback consistency; non-GNU `date +%s%N`
  guard; udev `change` action now handled (not just add/remove); preflight now checks
  `kwin_wayland_wrapper` (hard) and `inotifywait` (soft warning); `DEBUG_MODE` mod-resolver
  debug output corralled into `/tmp/mcss-debug-api` and cleared at the start of each
  `--debug` run; `kwin_positioner.sh`'s generated JS files now use `mktemp` instead of a
  predictable `/tmp` name.
- **[CODE] #31/G6 — accounts.json.** A missing/undownloadable file (with no local fallback)
  is now install-fatal, and a new smoke test validates it parses and contains all 4 P1-P4
  profiles before the installer proceeds.
- **[CODE] #32/G7 — sound effect overlap.** Extended the existing music-mute pattern:
  instances 2-4 now also mute the shared-world ambient/environment categories
  (weather/block/hostile/neutral/ambient/record), leaving `player` (genuinely per-player)
  and `master` untouched.
- **[NEW] CI.** `.github/workflows/ci.yml` — shellcheck (error-severity gate, 0 pre-existing
  errors; warnings reported non-blocking) + the 5 CI-safe unit-test suites, gated on a
  documented baseline pass-count per suite (not 100%, to avoid failing on pre-existing
  known gaps — see the workflow's own comments). Hardware/session tests stay Deck-only.
- **[NEW] docs/RESEARCH-CONTROLLER-IDENTITY-2026-07-01.md** — how Steam/SDL/InputPlumber
  actually handle controller reconnect identity (answer: SDL's GUID is model-level, not
  per-unit; Steam/InputPlumber's real trick is a persistent virtual-pad proxy, not serial
  matching), feeding #38 and the still-gated `RAW-CONTROLLER-BIND-PLAN.md`.

## ☐ OPEN ITEMS — consolidated 2026-06-25

> Single source of truth for what's left. Status tags: **[OPEN]** not started ·
> **[CODE]** fixed in code, NOT Deck-validated · **[WIP]** in progress now.
> Rule: nothing is "done" until maintainer-confirmed on the Deck (see SPEC §3a/§3b).

### v1 blockers (the three open bugs — SPEC §3b)
- **[CODE] D4 — controller enumeration.** Root cause found (2026-06-24/25 live recon):
  InputPlumber D-Bus is a DEAD END on SteamOS (service disabled, autostart skips Valve);
  `"pad 0 = built-in"` name-scan unsound; "first in list" breaks on Steam's startup pool.
  **FIX IMPLEMENTED + UNIT-TESTED (commit pending, NOT Deck-validated):** new
  `_map_external_player_virtuals` positively IDs external pads (real vid:pid + jsN, not
  28de:11ff/1205) and maps each to its Steam virtual by `inputN` creation proximity; built-in
  (no jsN) + phantoms never claimed. `list_eligible_controllers docked` rewired; old
  `_identify_internal_virtual_index` deprecated. 11/11 `test_controller_monitor.sh` pass incl.
  new regression tests (phantom pool→0, external-virtual-not-ready→0/no-leak, external→its
  virtual, cap-at-4). **NEXT: deploy + Deck-validate (built-in excluded, DS4 maps 1:1).**
  Open: D4 *isolation* (each pad drives only its slot) is separate (N5/G2 masking) and may
  need bind-raw-vs-virtual design call. Steam Controller has NO evdev jsN → unsupported as a
  player (G-doc + task #4).
- **[OPEN] Bug B — JVM shutdown D-state hang (intermittent).** Hypothesis only (controller/SDL
  teardown); needs live `/proc/<pid>/stack|wchan|syscall` capture next hang to confirm. May
  share a root with D4. Diagnostic procedure saved to memory.
- **[OPEN] D6 — nested-session teardown → Abort-Game.** Root cause confirmed (research):
  gamescope subreaper + `plasma_session` respawns helpers killed from inside the session →
  Steam never sees exit. Fix = supervise the session from OUTSIDE (non-exec parent) and
  collapse the whole process group, not kill named helpers from within. NOTE (per maintainer):
  may partly resolve once D4/Bug-B let instances exit cleanly, but §3b showed it fired
  independently — keep as its own item.

### Follow-up audit (docs/BUG-AUDIT-2026-06-24-followup.md) — still open
- **[OPEN] Partials never finished:** H9 (monitor heartbeat — dead monitor hangs loop),
  H10 (reflow retry flag), L3 (remaining jq `--arg` at dex.sh:595 / window_manager.sh:183,195
  + fail-on-unpaired-mask), M7 (dex `/tmp/dex_$$.py` cleanup trap when XDG_RUNTIME_DIR unset).
- **[OPEN] Security (entry script):** N6 (predictable `/tmp/kwin_wayland_wrapper` + `PATH=/tmp:$PATH`
  → local code-exec/TOCTOU), N7 (`_restore_session_env` reads `/tmp` file into `systemctl --user
  set-environment` → env injection). N6/N7 overlap the D6 rewrite (the entry script).
- **[OPEN] Runtime correctness:** N5 (controller-mask: reject odd arg counts, exclude own node —
  ties into D4), N10 (KWin PID-only match → add caption/resourceClass), N11 (post-launch bwrap
  `kill -0` liveness), N16 (controller_monitor enumeration race — capture device list once).
- **[OPEN] Install/robustness:** N12 (mod-filename path traversal), N13 (`cp -r */` empty-set
  false failure), N14 (inotifywait on vanishing sysfs connector misses hotplug), N15 (leaked
  inotify/watch monitors survive teardown).
- **[OPEN] Low:** 720-vs-800 res fallback; non-GNU `date +%s%N`; ignored bind/unbind/change udev
  actions; preflight omits `kwin_wayland_wrapper`/`inotifywait`; DEBUG_MODE temp leak;
  predictable `/tmp/mcss_place_*.js` no trap.

### Flow gaps (install → play) — still open
- **[OPEN] G1** — install-time preflight is a silent no-op (`preflight.sh` not sourced by the
  installer); README's "installer tells you right away" is false.
- **[OPEN] G4** — no automated shared-world / Open-to-LAN join; the part that makes it co-op is
  manual. *Open design item.*
- **[OPEN] G5** — README never states docking + external pads are mandatory for multiplayer.
- **[OPEN] G6** — missing `accounts.json` is a silent launch blocker (only warns); no install
  smoke test. Make missing accounts fatal / ship locally + add one-instance smoke test.
- **[OPEN] G7** — instances 2–4 mute music only; sound effects still overlap into one sink.

### Security carry-over
- **[OPEN]** `token.enc` + hard-coded passphrase still committed (lower impact since required
  mods moved to Modrinth, but rotate + stop committing).

### Cleared in code since the audit (⚠️ NONE Deck-validated)
- **[CODE]** N1 (leaked slot), N2 (orphan spawn subshells), N3 (slot-1 double-spawn),
  N4 (EWMH state), N8 (dead `spawn_placeholder`), N9 (format-32 `c_long` — *N9 seen working
  on screen in the D3 borderless validation*), H8 (2nd `tr -dc` site) — commit `30e6536`.
- **[CODE]** G2 (controller-mask wiring), G3 (memory cap 4×3072) — commit `c8122f2`. ⚠️ G2/N5
  rest on the evdev model D4 is currently reworking — may not isolate correctly until D4 lands.
- **License (DECISION-4):** parked — distribution blocked; personal use OK.

---

## Production launch (A1) — 2 bugs FIXED IN CODE, pending Deck re-validation (2026-06-24)
Windowing engine VALIDATED (test 4: borderless + tile + scale-down + clean exit). Mod removed
from instances + installer. Production `launchFromPlasma` wired + spawns. Both production-only
bugs the real-shortcut test surfaced are now fixed in code (32219db) — the test path bypassed
the producer half (hand-injected 2-field FIFO messages), which is why it never hit them:
- [x] **CONTROLLER_ADD field mismatch (C1).** orchestrator `_handle_msg` now `read -r`s all 4
  fields instead of `${msg_arg#* }`. Test harness updated to inject the real 4-field format so
  the seam can't silently diverge again.
- [x] **Window not detected (`wid=null`).** `_poll_for_window` now searches the slot's WHOLE
  java subtree by `_NET_WM_PID` (`_collect_slot_pids`), not just the stored pid, and re-asserts
  the `SplitscreenP{slot}` title (incl. a bounded background title-keeper) so it survives the
  game's caption flash to `Minecraft* <ver>`.
- [x] **Live Deck validation (2026-06-24):** fresh run confirmed on screen — clean js_node
  (C1 fixed in prod), borderless, 1→2→3→4 tiling (full/half/quad), scale-down collapse
  (P3 quit → survivors re-tile), 4 distinct wids. Producer fixes work on hardware.
- [x] **CONTROLLER_REMOVE event-node bug (C1 twin), found live → fixed (6c24642).** Handler
  was treating the device-node arg as a slot number → disconnects ignored, no re-tile.
  Now format-aware (slot number OR event node via _find_slot_by_event_node). Deployed.
- [x] **Docked session lifecycle bookends → fixed in code, pending Deck validation.**
  - END (43f7639): all players quit → exit. had_players latch + ORCHESTRATOR_EMPTY_EXIT_TICKS
    grace so it ends once everyone who joined has quit, without exiting at startup.
  - START (3114691): docked_flow now does a 5s controller-acquisition poll at the start —
    spawns already-connected pads (robust to Steam's staggered virtual-pad creation, which
    the old one-shot monitor scan raced), and exits to Steam if none appear. Monitor is now
    hotplug-only (SKIP_INITIAL_EMIT) to avoid double-spawn. Slot now reserved synchronously
    in _handle_msg before backgrounding spawn (no rapid-ADD slot collision).
  - NEXT: live-verify — (a) launch with pads already connected → all spawn; (b) launch with
    none → exits to Steam after 5s; (c) all quit mid-session → returns to Steam.
- [ ] **Real deploy step (NEW).** Launcher runs from `~/.local/share/PolyMC/`, a separate
  copy from the git clone — `git pull` alone doesn't update it (caused a stale-code run).
  Wire a deploy/self-update so pull≠deploy can't recur.
- [ ] **Then: re-run the full scale-down→fullscreen→clean-exit chain on fresh code**, STRIP
  test code, merge branch→main (branch tree wins).

## Codebase bug audit (2026-06-23) — ALL 27 ADDRESSED IN CODE (2026-06-24) — docs/BUG-AUDIT-2026-06-23.md
Multi-agent audit, adversarially verified: 27 distinct confirmed bugs (2 Critical, 14 High,
8 Medium, 3 Low). Every item is now fixed in code or reviewed-as-not-applicable. Commits:
32219db (C1, H1, window-detection) · 7cab3bb (dex H2/H3/M7) · 1fc05c2 (H4/H5/H7/H8) ·
2bf65e9 (M5/M6) · a0ec2b8 (H9/H10/M1/M2/M4/L2; M3 reviewed n/a) · f9a401c (H6/L1/H14) ·
3ec2df1 (H12/H13; M8 reviewed n/a) · e4538a0 (H11) · a39a4ab (L3 jq --arg).
- Reviewed-as-not-applicable: **M3** (apply_layout's empty-W/H path re-queries live via
  `_get_screen_resolution`, not stale), **M8** (bash `${arr[@]:0:20}` is safe on short arrays;
  `set +e` windows in instance_creation are intentional).
- Deferred (LOW, very low risk): the DEBUG_MODE temp file in instance_creation (off by default)
  and a couple of vague L3 mask-arg/magic-sleep notes — see the audit doc.

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
  - **DEEP-RESEARCH VERDICT 2026-06-22 (Path B sound for XWayland):** KWin keeps SYNCHRONOUS geometry authority for XWayland/X11 windows (frameGeometry + Position/Size rules honored); the "client ignores size / async configure" failures are NATIVE-Wayland-only, not ours. → removing override_redirect should let frameGeometry work. Canonical: write window.frameGeometry, hook workspace.windowAdded (reactive, fires after initial placement; match by pid — windowId undefined in 6.4). REFUTED/avoid: Force does NOT stop on-map re-placement; "Ignore requested geometry" unreliable; noBorder/geometry-scripting not "canonical" (noBorder still works; no-titlebar RULE is documented). NO clean re-tile stopper → RE-ASSERT frameGeometry on reflow + delayed re-asserts (NOT a persistent hook — Border-Enforcer leak). MUST VERIFY: nested-gamescope XWayland untested by sources → first rewrite step = remove OR, confirm move=true + frameGeometry STICKS via kwin-diag. REWRITE PLAN: (1) drop _apply_override_redirect_cycle from apply_layout, (2) position via kwin_place_windows (frameGeometry+noBorder, by pid), (3) re-assert on reflow + 1-2 delayed, (4) fallback = per-slot window rules matching unique "SplitscreenP{slot}" titles.
  - **PATH B STEP 1 TESTED 2026-06-22 (commit 8617404): mechanism WORKS, noBorder-toggle is the new bug.** Removing OR → all windows `move=true resize=true` (KWin-managed) and KWin's diag REPORTED accepting frameGeometry. ⚠️ CORRECTION: that AFTERSET=640x360+640+0 is the script's OWN readback, NOT screen-confirmed — the user NEVER saw slot 2 move. SCREEN GROUND TRUTH (user, all attempts incl. step 2): same layout every time — P2 stuck half-height bottom, P3/P4 drawn over it; P1 missing. So under OR, KWin frameGeometry, AND re-assert, slot 2 has NEVER been confirmed to move on screen. The readbacks (OR + KWin AFTERSET) are instrument data that has NOT translated to the surface. OPEN: is Minecraft/GLFW actively reverting, OR does KWin frameGeometry not actually move the XWayland SURFACE in nested gamescope (research flagged this topology untested)? NEXT: get SCREEN-confirmed evidence — user watches whether P2 ever flashes to top-right when positioning runs (flash-then-revert = reverter; never moves = frameGeometry not affecting surface). Step-2 code (frameGeometry-only + settle/re-assert, cf6e349) did NOT change the on-screen result.
  - **PATH B STEP 2 IMPLEMENTED+DEPLOYED 2026-06-22 (commit cf6e349) — UNTESTED.** (a) kwin_place_windows = frameGeometry ONLY (removed the noBorder toggle that was recreating frames → unmaps; tile/maximize/fullscreen cleared only when actually set). (b) apply_layout does ONE settle + re-assert pass after positioning (MCSS_REASSERT=1, MCSS_REASSERT_DELAY_S=1.2). NEXT TEST (test 4): verify slot 1 stays MAPPED/visible, slot 2 STICKS at top-right, survivors re-tile on scale-down; then check if title bars appear (no → done; yes → add one-time "No titlebar and frame" window rule).
  - **★ ROOT CAUSE FOUND 2026-06-23 (deep-research on the mod): the Splitscreen MOD owns the window and is the reverter.** Mod = pcal43/splitscreen "Splitscreen Support" (or fork FlyingEwok/splitscreen), confirmed from its Java source. It calls `glfwSetWindowMonitor(handle,0L,x,y,w,h,-1)` + toggles GLFW_DECORATED, reads splitscreen.properties ONCE at init (no reload → our reflow rewrite is ignored), and **re-asserts geometry on window-create/F11/framebuffer-RESIZE/setMode** (event-driven, not per-frame). So a pure move sticks but any RESIZE snaps the window back to its startup rectangle — the consistent reverter under OR, KWin frameGeometry, and noBorder. P2 started BOTTOM→pinned bottom forever; our resize to quad-top-right fires onFramebufferResize→snap-back. slot1 WINDOWED→decorated (the title bar). **FIX (both research rounds converge): REMOVE the splitscreen mod / neuter its WindowMixin, let KWin own ALL geometry (frameGeometry, proven) + decoration via a "No titlebar and frame" window rule. The mod does nothing else essential.** Steps: (1) stop installing the mod (or remove jar from instances), (2) drop splitscreen.properties writing, (3) add KWin de-decoration rule, (4) verify with test 8 (single window should move+resize through all positions and STAY), (5) keep KWin positioning from step 1/2. Verify WHICH jar is installed first.
  - **✅✅ CONFIRMED ON SCREEN 2026-06-23: mod disabled → KWin positioning STICKS.** Renamed Splitscreen_Support.jar→.disabled in all 4 Deck instances, ran test 8. USER SAW the single window move AND resize through all 7 positions (full, top/bottom half, 4 quads) and STAY. Sweep log: immediately==after-15s at every step = ZERO snap-back. KWin places the frame exactly on target (client inset by the 28px decoration). Root cause proven at source AND on screen; KWin frameGeometry works once the mod is gone. PRODUCTION PLAN (validated, ready to implement): (1) stop installing the splitscreen mod + stop writing splitscreen.properties; (2) add a KWin "No titlebar and frame" window RULE (match Minecraft class, noborder=true/noborderrule=2) applied once — NOT per-reflow noBorder toggle; (3) fix wrapper-exit teardown (kill kwin_wayland_wrapper, not just kwin_wayland); (4) re-confirm with multi-instance test 4. Mod currently DISABLED on Deck only (runtime, reversible — installer unchanged).
  - **TEST 4 (mod disabled) 2026-06-23 — ENGINE VALIDATED, 4 follow-ups.** KWin positioned + dynamically re-tiled on join; slot2 reached TOP-RIGHT (638x331+641+28) — the cell it never reached. Wrapper teardown fix worked (compositor fully exited). FOLLOW-UPS: (1) **grid-mode by COUNT not highest-slot** + map active slots to cells by order (so 2 players→halves, 1→fullscreen; currently slots 2+4 active stays quad, lone slot-4 stays bottom-right); (2) **placeholder leak** — stale SplitscreenBlack{1..4} cover real windows (P4 was at 641,388 behind SplitscreenBlack4) because _WINDOW_MANAGER_PLACEHOLDER_PIDS doesn't survive apply_layout's background subshells; (3) **title bars** — KWin title-rule misses at map (Minecraft sets caption/WM_CLASS late), fix = noBorder by PID after window detected; (4) **clean-exit stragglers** — wrapper fix exits the compositor but baloo_file (+ other Plasma helpers) survive and the Steam reaper waits on the whole tree → gamescope Abort-Game overlay (manual reaper kill returned to library); fix = reap full nested-session tree. Mod DISABLED on Deck only; installer removal is the final step after these + clean re-test.
  - **ALL 4 FOLLOW-UPS IMPLEMENTED + DEPLOYED 2026-06-23 (UNTESTED together):** #2 placeholders removed entirely (5199adc — black backdrop covers empty cells; no more SplitscreenBlack covering windows); #4 _end_nested_session reaps the WHOLE nested session incl. baloo_file/kded/etc (10221fb — fixes game-won't-exit); #1 compute_grid_mode by COUNT + apply_layout maps active slots to cells by ORDER (1b1b88e — 2 players→halves, 1→fullscreen, removes slot-1-hardcoded full branch); #3 kwin_set_noborder by PID at spawn step 7.5 (518096e — replaces the at-map rule that missed because Minecraft sets caption late). NEXT: run test 4 to validate all together — windows visible+borderless, scale-down collapses (halves→fullscreen), clean exit to Steam (no Abort Game). Then #4-installer: remove the mod from the installer (currently disabled on Deck only) + drop splitscreen.properties writing.
  - **✅✅✅ FULLY VALIDATED ON SCREEN 2026-06-23 (test 4, all fixes, deploy d58b6f3): complete 4-player dynamic splitscreen WORKS.** Borderless (all 4 via dex _MOTIF_WM_HINTS), quad tiling, all 4 visible (P4 present), scale-down 4→3→2-halves→1-fullscreen (incl. survivor ≠ slot 1), clean exit to Steam (NO Abort Game). Architecture: mod removed; KWin owns geometry (frameGeometry by pid, grid-by-count + cell-by-order); decoration via dex _MOTIF (NOT KWin-script noBorder, which hung); teardown reaps whole session. ONLY REMAINING (production): mod is disabled on Deck at RUNTIME only — stop the INSTALLER installing the Splitscreen mod + drop splitscreen.properties writing. Then merge branch→main.
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

## Deferred to Phase 3/4 — production landing (feat/gamescope-windowing → main)

Until then: development workflow is `git pull` on the Deck.
Full analysis (install→run flow trace, runtime-deps table, merge mechanics) is archived in
[docs/archive/INTEGRATION-PLAN.md](docs/archive/INTEGRATION-PLAN.md).

Decisions locked (2026-06-22): launcher = deploy the hand-written modular script + auto-detect
config at runtime (generator retired); platform = hard-stop on missing KDE/gamescope (no
DE-agnostic windowing); targets = SteamOS/Deck, Bazzite KDE/handheld, CachyOS-with-KDE.

- [ ] **A1 (BLOCKER) — wire the production `launchFromPlasma` flow.** The Steam shortcut runs
  `minecraftSplitscreen.sh launchFromPlasma`, but no such case exists → it falls through to `*)` →
  bare `main()` with NO nested compositor and NO panel strip. The working windowing lives only in
  the test path (`testPlasma`→`launchTestFromPlasma`). Fix: factor the nested-Plasma session setup
  into a shared helper; `launchFromPlasma` runs it with `main()` inside (production), `test` runs it
  with the harness inside. Without this, a real Steam launch gets no splitscreen — single most
  important functional item.
- [ ] **G — dependency + KDE/gamescope preflight HARD STOP** (install-time in `main_workflow.sh`
  near `ensure_bwrap_installed`, and launch-time at the top of `minecraftSplitscreen.sh`). Required:
  `jq python3 bwrap dbus-run-session kwin_wayland startplasma-wayland kscreen-doctor xdpyinfo`
  (+ `gamescope` for the Game Mode path). Missing any → hard stop with a distro-aware hint
  (CachyOS/Arch `pacman -S`; SteamOS `steamos-readonly disable && pacman`; Bazzite GNOME = unsupported).
- [ ] Rename `minecraftSplitscreen.sh` → `mcss.sh` (cascades: `launcher_setup.sh`
  `launcher_script`/`local_script`/`remote_script`; `desktop_launcher.sh` `launcher_script_path` +
  prints; `add-to-steam.py`).
- [ ] Add test-script deployment to installer (`tests/` → device, e.g. `~/.local/share/PolyMC/tests/`).
- [ ] **B — PR/merge the branch as the new `main`.** History diverged (main +51 / branch +234, no
  fast-forward; main's tree is fully superseded). Make the branch tree authoritative (merge `-X theirs`,
  or reset main to the branch after review) — do NOT hand-resolve conflicts against the dead architecture.
- [ ] **C — after merge, verify** a clean `curl | bash` install from main on each target. The
  hardcoded-`main` URLs (`install-minecraft-splitscreen.sh` `REPO_BASE_URL`; `launcher_setup.sh`
  `base_url`/`remote_script`; `main_workflow.sh` accounts.json; `steam_integration.sh` add-to-steam.py)
  auto-resolve once the branch IS main — just re-verify, no edits needed.
- [ ] **F (deferred/optional):** bare-KWin research round (`kwin_wayland_wrapper` vs raw `kwin_wayland`;
  `KWIN_COMPOSE=Q`; EGL platform env) — keep `feat/gamescope-bare-kwin` separate, not mergeable.

Done on the branch (previously tracked here / in INTEGRATION-PLAN): A0 launcher decision + version
stamping & `--version` (71c1112); `launcher_script_generator.sh` retired (831b6cd); TinyWM removed
(d96ad38); gamescope-windowing dead code incl. `modules/gamescope_windowing.sh` removed (5bec629);
H — README "Will it work on my device?" platforms/requirements section (4aa536f); Splitscreen mod
removed from the installer (bdf08af).
