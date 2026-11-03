# Review A — launcher entry + orchestrator + runtime context + preflight + installer main

Files read fully: `minecraftSplitscreen.sh` (1213), `modules/orchestrator.sh` (1141),
`modules/main_workflow.sh` (245), `modules/runtime_context.sh` (794),
`modules/runtime_modules.list`, `modules/preflight.sh` (189). Traced into
`instance_lifecycle.sh` (accessors, `spawn_instance`, `teardown_instance`),
`slot_manager.sh` (all), `controller_proxy.sh` (repoint/quiesce/stop),
`controller_monitor.sh` (message formats, `start_controller_monitor`),
`dock_detection.sh`, `watchdog.sh`, `window_manager.sh`, `install-minecraft-splitscreen.sh`
(TARGET_DIR, manifest reader), `add-to-steam.py` (Exe/LaunchOptions),
`tests/test_orchestrator.sh` (T6.3 only, to judge whether a finding is masked).

Two claims below were verified empirically in the sandbox (procps `pkill -f` self-match;
`/proc/PID/environ` not reflecting post-exec `export`).

---

### A1. Startup guard's `pkill -9 -f "$_launcher_name"` SIGKILLs the launcher itself (and Steam's reaper)
- **Severity:** Critical
- **Category:** bug / principle-violation (#7)
- **File:** `minecraftSplitscreen.sh:447` (also `:445-446`, guard condition `:439`)
- **Status:** CONFIRMED
- **What:** The STARTUP GUARD reaps leftovers with name-matched kills:
  ```bash
  _launcher_name=$(basename "$MCSS_LAUNCHER_ROOT")        # "PolyMC"
  ...
  pkill -9 -f "$MCSS_INSTANCE_PREFIX" 2>/dev/null || true
  pkill -9 -f "bwrap.*$_launcher_name" 2>/dev/null || true
  pkill -9 -f "$_launcher_name" 2>/dev/null || true       # <-- matches OUR OWN cmdline
  ```
  The launcher is deployed at `TARGET_DIR/minecraftSplitscreen.sh` with
  `readonly TARGET_DIR="$HOME/.local/share/PolyMC"` (`install-minecraft-splitscreen.sh:334`),
  and Steam runs it as `.../PolyMC/minecraftSplitscreen.sh launchFromPlasma`
  (`add-to-steam.py:131-133`). `pgrep/pkill -f` matches the full cmdline, and procps
  excludes only its own PID — not its parent shell. So the third pkill matches
  `bash /home/deck/.local/share/PolyMC/minecraftSplitscreen.sh launchFromPlasma` (this
  process) and Steam's `reaper SteamLaunch AppId=… -- /home/deck/.local/share/PolyMC/minecraftSplitscreen.sh …`.
  Verified in-sandbox: a script at `/tmp/x/PolyMC/t.sh` running `pkill -9 -f PolyMC` never
  reaches the next line. The `|| true` cannot help against SIGKILL.
- **Failure scenario:** Any launch where the guard fires (a stale nested session, a leftover
  `latestUpdate-` JVM, a stale `prodFromPlasma` tree) → first two pkills kill instances → third
  pkill kills the supervisor mid-sweep (the session-level `_mcss_nested_pids` kills, `rm -rf
  "$MCSS_GEOM_DIR"`, the systemd unit stop, and the actual launch never run) → Steam sees the
  "game" exit → bounced to the library. This is exactly the "first launch after leftovers
  bounces, second works" symptom the #58 comment attributes solely to errexit. It also
  SIGKILLs any unrelated user process whose cmdline contains "PolyMC" (a Desktop-Mode PolyMC,
  a `PolyMC.AppImage` extraction), and Steam's reaper for this AppId.
- **Fix:** Drop the bare-name pkill; keep the two scoped patterns and scope them further, or
  restrict to processes that are NOT in our ancestor chain. Minimal:
  ```bash
  for _pid in $(pgrep -f "$_launcher_name" 2>/dev/null || true); do
      [[ "$_chain" == *" $_pid "* ]] && continue      # reuse _mcss_stale_tree_pids' chain
      grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$_pid/environ" 2>/dev/null && kill -9 "$_pid" 2>/dev/null || true
  done
  ```
  Better: only kill PIDs the previous run recorded (PRINCIPLES #7), e.g. from the state file's
  `bwrap_pid`/`pid` fields plus the `_mcss_nested_pids` marker set.

---

### A2. `SLOT_DIED` with the proxy ON (the default) marks the slot inactive BEFORE `teardown_instance`, so the live game tree is never killed
- **Severity:** High
- **Category:** bug / logic
- **File:** `modules/orchestrator.sh:633-640`; `modules/slot_manager.sh:274-279`; `modules/instance_lifecycle.sh:1197-1200`
- **Status:** CONFIRMED
- **What:**
  ```bash
  if [[ "${MCSS_CONTROLLER_PROXY:-0}" == "1" ]]; then
      proxy_stop_slot "$slot" 2>/dev/null || true
      slot_free "$slot" 2>/dev/null || true          # -> update_slot_state {active:false,...}
  fi
  ...
  teardown_instance "$slot" >"$_td_log" 2>&1 || true
  ```
  `slot_free` writes `active:false` (slot_manager.sh:276-278). `teardown_instance` then hits
  `if ! slot_is_active "$slot"; then echo "... not active, nothing to tear down"; return 0`
  (instance_lifecycle.sh:1197-1200) — the SIGTERM/SIGKILL of the bwrap process group never
  runs. `MCSS_CONTROLLER_PROXY` defaults to `1` (runtime_context.sh:210), so this is the
  production path. The instance_lifecycle comment at :1181-1185 even records observing "Slot 1
  is not active, nothing to tear down" on a normal quit and treated it as benign — it is benign
  only when the JVM already exited on its own.
- **Failure scenario:** Watchdog emits `SLOT_DIED` for (a) "window gone (player quit)" while the
  JVM is hung (watchdog.sh:181-185 explicitly targets this), (b) "proxy evsieve died"
  (watchdog.sh:206-209, a LIVE instance), or (c) bwrap leader gone but java alive. In all three
  the game tree is orphaned: `active:false` hides it from `_reap_dead_slots`, the watchdog and
  `teardown_all_instances`; its window stays on screen un-tiled; `bwrap_pid`/`pid` remain in
  the record (slot_free does not null them), so the NEXT `SPAWN` on that slot fails with
  `spawn_instance` exit 2 ("already active (bwrap_pid=…)") once. At session end the orphan
  (setsid'd) is adopted by Steam's reaper → the Abort-Game overlay class of hang.
  Test T6.3 (`tests/test_orchestrator.sh:155-179`) stubs `teardown_instance` to `touch
  sentinel; return 0`, so it cannot detect this (PRINCIPLES #4 — a stub that ignores the
  active guard certifies nothing here).
- **Fix:** Reorder: `teardown_instance "$slot"` first, then `proxy_stop_slot`/`slot_free`
  (both idempotent). Or make `teardown_instance` kill by recorded PIDs regardless of `active`.

---

### A3. docked→handheld re-entry leaks the docked flow's monitors (controller monitor, dock monitor, watchdog) and the persistent FIFO fd
- **Severity:** High
- **Category:** bug / robustness
- **File:** `modules/orchestrator.sh:918-919` (docked_flow `return 1`), `:1011-1016` (main re-entry), `:732-746` (handheld_flow), `:120-124` (`_open_fifo_reader`)
- **Status:** CONFIRMED
- **What:** On `DISPLAY_MODE_CHANGE handheld`, `docked_flow` does `return 1` immediately
  (no monitor teardown), `main()` calls `handheld_flow`, which does
  `_CONTROLLER_MONITOR_PID=""` (:732) — blanking the PID of a monitor that is STILL RUNNING —
  then starts a SECOND dock monitor (`watch_display_mode &`, :736) and a SECOND watchdog
  (`start_watchdog &`, :743), overwriting the old PIDs. `_open_fifo_reader` (:722) runs
  `exec {_SPLITSCREEN_FIFO_FD}<> "$fifo"` again, allocating a new fd and losing the old one.
- **Failure scenario:** After undocking mid-session: (1) the orphaned docked controller
  monitor keeps emitting `CONTROLLER_ADD` on any pad hotplug → `_handle_msg` in handheld_flow
  → `slot_claim`→`SPAWN 2` → a second instance in handheld mode (the very "handheld bug" the
  :144-151 comment says is prevented by never running the monitor); (2) two dock monitors and
  two watchdogs each emit every event twice; (3) at session end `cleanup()` kills only the
  PIDs it still holds — the docked controller monitor and its `udevadm monitor` child survive
  (the #26/#60 "game still Running" symptom); the old FIFO fd is never closed.
- **Fix:** Before `return 1` in docked_flow (or at the top of handheld_flow when re-entered),
  kill `_CONTROLLER_MONITOR_PID`/`_DOCK_MONITOR_PID`/`_WATCHDOG_PID` via `_kill_tree` and
  blank them; make `_open_fifo_reader` a no-op when `_SPLITSCREEN_FIFO_FD` is already set.

---

### A4. In handheld_flow a `DISPLAY_MODE_CHANGE handheld` message ENDS the session (dock/undock cycle while playing handheld)
- **Severity:** High
- **Category:** bug / principle-violation (#5 fail-open)
- **File:** `modules/orchestrator.sh:774`, `:649-686`
- **Status:** CONFIRMED
- **What:** `handheld_flow`'s loop is `_handle_msg "$msg" || break` (:774). `_handle_msg`
  returns 1 for `DISPLAY_MODE_CHANGE handheld` (:685, "so the caller can re-enter
  handheld_flow") — but when the caller IS handheld_flow, `break` falls through to
  `cleanup` (:778) → `teardown_all_instances` → slot 1 killed → `main()` returns → session over.
  `DISPLAY_MODE_CHANGE docked` in handheld_flow only does `_set_mode "docked"` (:657-660) and
  keeps looping, so the sequence docked→handheld is reachable from handheld_flow.
- **Failure scenario:** Player in handheld_flow plugs the dock in (→ `DISPLAY_MODE_CHANGE
  docked`, ignored) and pulls it out again (→ `DISPLAY_MODE_CHANGE handheld`) → the running
  single-player game is torn down and gamescope returns to Steam. Same outcome after an A3
  re-entry with two dock monitors: the first further mode flip kills the session. A display
  blip escalating to teardown is the exact HW-2 class PRINCIPLES #5 forbids.
- **Fix:** Give `_handle_msg` a distinct return code (e.g. 3 = "switch to handheld") and have
  handheld_flow treat it as a no-op (`[[ $rc == 3 ]] && continue`), or check
  `"$(_get_mode)" == handheld` before returning 1.

---

### A5. Stranded autostart `.desktop` + unguarded `prodFromPlasma` dispatch → the launcher can run on the REAL desktop at the next Plasma login
- **Severity:** High
- **Category:** robustness / security (#42-class regression path)
- **File:** `minecraftSplitscreen.sh:286-292` (autostart written), `:508-535` (supervisor never removes it), `:554` (only the inner handler removes it), `:1043-1052` (`prodFromPlasma` case has no `MCSS_NESTED_SESSION`/gamescope guard), `:557-558` (`pkill -x plasmashell`)
- **Status:** CONFIRMED (code path); the trigger — inner handler never starting — is PLAUSIBLE
- **What:** `_start_nested_plasma` writes `~/.config/autostart/splitscreen-prod.desktop`
  whose `Exec=env … minecraftSplitscreen.sh prodFromPlasma`. The ONLY `rm -f` of that file is
  inside `launchProdFromPlasma` (:554), i.e. it is removed only if the autostart actually ran.
  `launchFromPlasma`'s boot phase explicitly tolerates "inner handler ABSENT" (:514) and then
  proceeds to teardown without ever removing the file. runtime_context.sh:362-363 warns about
  precisely this ("a missed rm here strands an autostart that relaunches the game on every
  Plasma login"). The `prodFromPlasma)` dispatch arm runs `launchProdFromPlasma` unconditionally
  — unlike `*)` (:1185) and `launchFromPlasma` (:402), it never checks `MCSS_NESTED_SESSION`
  or `mcss_require_gamescope`.
- **Failure scenario:** Nested Plasma fails to run autostart (crash, session start failure,
  90 s budget exceeded) → file stranded → user switches to Desktop Mode → Plasma runs the
  autostart with `MCSS_NESTED_SESSION=plasma` → `launchProdFromPlasma` on the real desktop:
  `pkill -x plasmashell` every 2 s (panel/desktop gone), the real orchestrator spawns
  instances on the desktop, and on exit `qdbus org.kde.Shutdown … logout` logs the user out.
- **Fix:** In `launchFromPlasma`, after the boot phase (or unconditionally at the end),
  `rm -f "$MCSS_AUTOSTART_DIR/$MCSS_AUTOSTART_PROD_DESKTOP"`; in the `prodFromPlasma)` arm
  require `[[ "$MCSS_NESTED_SESSION" != 0 && "$MCSS_ENV_CONTEXT" == gamescope ]]` (both ride
  the Exec line) or refuse with `mcss_notify_user`.

---

### A6. handheld→docked transition never switches to `docked_flow` (contract in the header is not implemented)
- **Severity:** Medium
- **Category:** logic / dead-code (unimplemented contract)
- **File:** `modules/orchestrator.sh:700-701` (header), `:657-660` (docked case), `:774`, `:1005-1023` (main has no handheld→docked path)
- **Status:** CONFIRMED
- **What:** Header: "On DISPLAY_MODE_CHANGE docked, returns so the caller switches to
  docked_flow." Code: the `docked)` arm only calls `_set_mode "docked"` and `_handle_msg`
  returns 0, so handheld_flow keeps looping; `main()` has no branch that enters docked_flow
  after handheld_flow returns anyway.
- **Failure scenario:** Start handheld, dock later: state `.mode` flips to docked, but no
  controller monitor is ever started, so external pads never spawn players; the screen is
  re-probed to the external resolution while the single-player layout is never reflowed
  (`_reflow_layout` is not called on the docked arm either).
- **Fix:** Either implement (return a distinct code, kill handheld monitors, have main() loop
  `handheld_flow ↔ docked_flow` on mode codes) or delete the header claim and log "docking
  mid-session is unsupported".

---

### A7. `pkill -x plasmashell` (and its 2 s respawn-killer loop) are name-matched kills
- **Severity:** Medium
- **Category:** principle-violation (#7)
- **File:** `minecraftSplitscreen.sh:557-558`, `:743-744`
- **Status:** CONFIRMED
- **What:** `pkill -x plasmashell 2>/dev/null || true; ( while :; do pkill -x plasmashell …; sleep 2; done ) &`
  kills every `plasmashell` of this user, not the nested one. Safe only because Game Mode has
  no host plasmashell; combined with A5 (or any Desktop-Mode entry) it destroys the user's
  real desktop shell continuously.
- **Fix:** Find the nested plasmashell by marker/tree (`_mcss_own_run_pids plasmashell`, or
  `pgrep -P` under `$_session_pid`) and kill that PID set only.

---

### A8. `_mcss_stale_tree_pids` cannot see the processes its comment says it reaps (outer supervisor, Steam reaper); `systemctl --user stop plasma-workspace.target` is unscoped
- **Severity:** Medium
- **Category:** logic (comment/contract mismatch) / robustness
- **File:** `minecraftSplitscreen.sh:326-370` (`_mcss_nested_pids`, `_mcss_stale_tree_pids`), `:87` (export after exec), `:683-685`
- **Status:** CONFIRMED
- **What:** The marker filter is `grep -qz 'SPLITSCREEN_DEBUG_LOG=' /proc/$pid/environ`.
  `/proc/PID/environ` is the execve-time environment block; a later `export` (:87) does not
  change it, and forked subshells inherit the unchanged block. Verified in-sandbox: after
  `export`, `grep -c … /proc/$$/environ` → 0 for the shell and for a `( … ; : )` subshell.
  Consequently the outer `launchFromPlasma` supervisor (exec'd by Steam without the var), the
  Steam reaper, and all of the launcher's own `$(…)`/`&` subshells are INVISIBLE to
  `_mcss_nested_pids`. The comment at :346-356 claims the sweep catches "a prior run's …
  supervisor, or Steam reaper" and that "the $(…) subshell evaluating this function can list
  itself" — neither is true. Only exec'd children (startplasma, kwin, the nested
  `prodFromPlasma` bash, udevadm, …) carry the marker.
  Separately, `_supervise_reap_nested_session` runs `systemctl --user stop
  plasma-workspace.target` (:683-685) with no scoping at all; a stale supervisor still in its
  retry loop while a NEWER session is booting stops the new session's target (the very
  overlap #60 describes).
- **Failure scenario:** A stale outer supervisor (bounded but up to ~8 passes + 30 s grace +
  90 s boot) survives the "stale tree" sweep; if a new launch overlaps it, the old supervisor's
  target-stop tears down the new session's Plasma.
- **Fix:** Mark the launcher's own process by re-exec'ing once with the var set
  (`[[ -z ${SPLITSCREEN_DEBUG_LOG:-} ]] && exec env SPLITSCREEN_DEBUG_LOG=$LOG "$0" "$@"`), or
  record the supervisor PID in a run file and reap by PID; guard the target stop with a check
  that no other marked `prodFromPlasma`/`startplasma-wayland` with a DIFFERENT log path exists.
  Fix the comment either way.

---

### A9. Marker variables (and PATH) likely leak into the systemd `--user` manager via startplasma's env import, defeating the "real desktop is unmarked" assumption
- **Severity:** Medium
- **Category:** robustness / security
- **File:** `minecraftSplitscreen.sh:146-198` (leak guard restores only WAYLAND_DISPLAY/DISPLAY), `:277` (`export PATH="$MCSS_HELPER_DIR:$PATH"`), `:302`
- **Status:** PLAUSIBLE — confirm on Deck with `systemctl --user show-environment | grep -E 'SPLITSCREEN|MCSS_|^PATH='` after one nested session
- **What:** The file's own "Session-env leak guard" documents that the nested startplasma pushes
  its environment into the shared `systemd --user` manager (`dbus-update-activation-environment
  --systemd`); startplasma uses `--all`, so `SPLITSCREEN_DEBUG_LOG`, `LOG`, every `MCSS_*`
  export and the shim-prepended `PATH` go with it. `_restore_session_env` only restores
  `WAYLAND_DISPLAY`/`DISPLAY`. Services the REAL Desktop-Mode session later starts through the
  user manager (Plasma 6 systemd boot: `plasma-kwin_wayland`, `plasma-plasmashell`, baloo,
  kded…) would then carry `SPLITSCREEN_DEBUG_LOG=` in `/proc/PID/environ`, so `_mcss_nested_pids`
  (any marker value) matches the real desktop — the case the #58 scoping was added for ("a
  dying desktop is left alone").
- **Failure scenario:** Desktop→Game Mode with the outgoing desktop still tearing down → the
  STARTUP GUARD's `kill -9` over `_mcss_nested_pids 'kwin_wayland' / 'plasma_session' /
  'baloo_file'` hits the real session's processes.
- **Fix:** In `_restore_session_env`, also `systemctl --user unset-environment
  SPLITSCREEN_DEBUG_LOG LOG MCSS_NESTED_SESSION PATH …` (snapshot PATH too), or use a marker
  unique per run AND compare against the current `$LOG` for the guard as `_mcss_own_run_pids`
  already does.

---

### A10. Missing runtime modules are silently skipped when sourcing the manifest
- **Severity:** Medium
- **Category:** robustness / principle-violation (#9 rationale)
- **File:** `minecraftSplitscreen.sh:137-143`
- **Status:** CONFIRMED
- **What:**
  ```bash
  _mod_path="$SCRIPT_DIR/modules/$_mod"
  if [[ -f "$_mod_path" ]]; then source "$_mod_path"; fi
  ```
  A missing manifest FILE is FATAL (:133-136) but a missing manifest ENTRY is ignored with no
  log line. Every later use is `declare -f`/`type`-guarded, so a partial deploy degrades
  silently (no `controller_proxy.sh` → `proxy_*` undefined → under `set -e` in the nested
  process the first unguarded call such as `slot_claim`'s neighbours or
  `proxy_repoint_slot` aborts the session with only an xtrace line).
- **Failure scenario:** `deploy.sh`/installer partially copies modules → "nothing launches" with
  no diagnostic naming the missing file.
- **Fix:** `else echo "FATAL: manifest module $_mod missing — broken deploy" | tee -a "$LOG" >&2; exit 1`
  (the manifest is the contract; treat a missing entry like the missing manifest).

---

### A11. Orchestrator keeps raw-`jq` state readers and duplicate slot finders that slot_manager was supposed to retire; one is production-dead
- **Severity:** Medium
- **Category:** principle-violation (#1, #9) / dead-code
- **File:** `modules/orchestrator.sh:166-169` (`_get_mode`), `:246-253` (`_find_slot_by_event_node`), `:266-275` (`_find_slot_by_uniq`), `:287-296` (`_collect_mask_pairs`), `:226-234` (`_find_free_slot`); `modules/slot_manager.sh:43-48`
- **Status:** CONFIRMED (`_collect_mask_pairs` is mentioned in `docs/BUG-AUDIT-2026-06-24-followup.md:207` but not as a violation)
- **What:** ARCHITECTURE §2: "ALL state-file reads go through [instance_lifecycle's] accessors
  … no raw jq elsewhere". Four functions in orchestrator.sh run `jq … "$state"` directly on
  `.slots[]`. `_find_slot_by_event_node` (used at :599) duplicates
  `slot_find_by_event_node`; `_find_free_slot` (used at :564) duplicates `slot_find_free`;
  `_find_slot_by_uniq` has NO production caller (only `tests/test_controller_monitor.sh:1075`).
  slot_manager.sh's header states "PR-c retires the orchestrator's near-duplicate
  _find_free_slot / _find_slot_by_uniq / _find_slot_by_event_node" — PR-c shipped, the
  retirement did not.
- **Failure scenario:** Schema drift: `slot_free` now nulls `phys_*`/`disconnected*` fields
  that `_collect_mask_pairs`/`_find_slot_by_*` know nothing about; any future field rename is
  a two-place edit that silently breaks CONTROLLER_REMOVE resolution.
- **Fix:** Delete `_find_slot_by_uniq`; route `_find_slot_by_event_node`→`slot_find_by_event_node`,
  `_find_free_slot`→`slot_find_free`; move `_collect_mask_pairs` into instance_lifecycle (it is
  a `.slots` schema read) or express it via `_get_slot_field`.

---

### A12. `/tmp` fallback for `MCSS_HELPER_DIR` puts `/tmp` at the FRONT of `PATH` and writes the executed KWin shim to a predictable world-writable path
- **Severity:** Medium
- **Category:** security
- **File:** `modules/runtime_context.sh:343-350`; `minecraftSplitscreen.sh:274-277`
- **Status:** PLAUSIBLE (only when `/run/user/$UID/mcss` is unusable — containers, CI, odd hosts)
- **What:** `export MCSS_HELPER_DIR="/tmp"` on fallback, then the launcher does
  `_kwin_wrapper_script … > "$MCSS_KWIN_WRAPPER_PATH"` (= `/tmp/kwin_wayland_wrapper`, follows a
  pre-planted symlink) and `export PATH="$MCSS_HELPER_DIR:$PATH"` → `PATH=/tmp:…`. From then on
  EVERY command lookup in this process and all children (`jq`, `python3`, `bwrap`, `kwin_wayland`,
  `pkill`, …) resolves in `/tmp` first. The comment acknowledges "N6/N7 hardening degraded" but
  the PATH prepend is a full local-user hijack, not just the shim.
- **Failure scenario:** Multi-user host with `/run/user/$UID` absent: another user drops
  `/tmp/jq` → executed as the Deck user by the launcher.
- **Fix:** Fall back to `mktemp -d "${TMPDIR:-/tmp}/mcss.XXXXXX"` (0700, unpredictable) instead
  of bare `/tmp`; never prepend a world-writable dir to PATH (the shim can be passed via an
  absolute path / a dedicated 0700 dir only).

---

### A13. FIFO lives at a fixed, world-known `/tmp` path; a pre-existing non-FIFO makes the whole session silently deaf
- **Severity:** Medium
- **Category:** robustness / security / hardcoded
- **File:** `modules/runtime_context.sh:326`; `minecraftSplitscreen.sh:580`, `:827`, `:876`; `modules/orchestrator.sh:973-980`
- **Status:** CONFIRMED (silent-deaf path); injection is local-user only
- **What:** `SPLITSCREEN_FIFO` defaults to `/tmp/minecraft-splitscreen.fifo`. Every creator does
  `[[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true`. If the path exists as a regular
  file/symlink (crash leftover, another user), mkfifo fails silently; `_open_fifo_reader`
  returns 1 (warning only), `_read_fifo_msg` returns 1 forever (`[[ -p ]]` fails), while the
  monitors happily `echo >> "$fifo"` into the regular file. The session runs with no events
  (no hotplug, no SLOT_DIED, no dock changes) and no error naming the cause. A same-host user
  who owns that path can inject `SLOT_DIED 1` / `CONTROLLER_ADD …` lines.
- **Failure scenario:** `touch /tmp/minecraft-splitscreen.fifo` by any process → next launch:
  players join at startup (acquisition path bypasses the FIFO) but nothing reacts afterwards.
- **Fix:** Default the FIFO under `$MCSS_HELPER_DIR` (0700, per-user) and make a non-FIFO at
  the path fatal-loud (`rm -f` a regular file we own, else `mcss_notify_user` + exit).

---

### A14. State-mutating calls run inside `| sed` pipelines (subshells) at several sites, inconsistently with the SLOT_DIED path that was rewritten to avoid exactly that
- **Severity:** Low
- **Category:** bug (subshell-lost state) / robustness
- **File:** `modules/orchestrator.sh:412`, `:673`, `:754`, `:1109`, `:1114`
- **Status:** CONFIRMED
- **What:** `teardown_instance "$slot" 2>&1 | sed … >&2 || true` (:412, :673),
  `spawn_instance 1 "" "" 2>&1 | sed …` (:754), `teardown_all_instances 2>&1 | sed …` (:1109).
  The left side of a pipeline runs in a subshell; in-process globals it updates
  (`_CONTROLLER_PROXY_PIDS` via `proxy_stop_slot`/`proxy_start_slot`, any spawn bookkeeping)
  are discarded, and `|| true` applies to `sed`, not the function. The SLOT_DIED arm (:637-645)
  uses a temp file precisely to keep `teardown_instance` in-process. controller_proxy.sh:48-58
  documents the array as a cache with the pidfile authoritative, so today the impact is a
  stale cache, but the pattern is a trap for any future in-memory state.
- **Fix:** Use the temp-file pattern everywhere, or `{ teardown_instance "$slot"; } 2> >(sed … >&2)`.

---

### A15. `main()` re-embeds the FIFO default literal
- **Severity:** Low
- **Category:** hardcoded (duplicated constant, ARCHITECTURE §3 corollary)
- **File:** `modules/orchestrator.sh:973-977` vs `modules/runtime_context.sh:326`
- **Status:** CONFIRMED
- **What:** `fifo="/tmp/minecraft-splitscreen.fifo"; export SPLITSCREEN_FIFO="$fifo"` duplicates
  the canonical default that `mcss_resolve_paths` already exports (orchestrator sources
  runtime_context at :66). Two encodings of a cross-process contract value (#9).
- **Fix:** `mcss_resolve_paths; local fifo="$SPLITSCREEN_FIFO"` and drop the literal.

---

### A16. Command substitutions with pipelines run under the leaked `set -e -o pipefail` in the launcher prologue paths
- **Severity:** Low
- **Category:** robustness (set -e pitfall)
- **File:** `minecraftSplitscreen.sh:171` (`_snapshot_session_env`), `:363` (`_mcss_stale_tree_pids`)
- **Status:** PLAUSIBLE
- **What:** Sourced modules turn on `set -euo pipefail` for the launcher shell (documented at
  :414-420). `cur=$(systemctl --user show-environment 2>/dev/null | sed -n … | head -1)` and
  `_p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')` are assignments from pipelines: a
  non-zero `systemctl` (no user bus reachable) or `ps` (an ancestor exiting mid-walk) makes the
  assignment fail and errexit terminates the launcher before Plasma starts, with only an
  xtrace line in the log.
- **Fix:** Append `|| true` inside the substitution (`… | head -1 || true`), as the rest of
  the file does for `pgrep`.

---

### A17. `kill "${_PANEL_KILLER_PID:-0}"` defaults to `kill 0` (signal the whole process group)
- **Severity:** Low
- **Category:** bug (latent)
- **File:** `minecraftSplitscreen.sh:567`, `:596`, `:750`, `:773`
- **Status:** CONFIRMED (latent — the var is always set at :559/:745 before the trap can fire)
- **What:** `kill "${_PANEL_KILLER_PID:-0}" 2>/dev/null` — with the variable unset/empty this
  becomes `kill 0`, which signals every process in the launcher's process group (in the nested
  session: the orchestrator, monitors, in-flight spawns). The intent is "no-op if unset".
- **Fix:** `[[ -n "${_PANEL_KILLER_PID:-}" ]] && kill "$_PANEL_KILLER_PID" 2>/dev/null`.

---

### A18. Persistent FIFO fd is inherited by every child (including the bwrap/JVM sandbox) and re-opened without closing
- **Severity:** Low
- **Category:** robustness / resource leak
- **File:** `modules/orchestrator.sh:120-124`, `:722`, `:833`, `:1130-1133`
- **Status:** CONFIRMED
- **What:** `exec {_SPLITSCREEN_FIFO_FD}<> "$fifo"` opens without `FD_CLOEXEC`; bash leaves
  it open across `exec`, so the fd rides into `start_controller_monitor`, `udevadm`, `inotifywait`,
  `evsieve`, `bwrap` and the game JVM (the sandbox gets a read-write handle to the orchestrator's
  control channel). A second `_open_fifo_reader` call (flow re-entry, A3) allocates another fd
  and orphans the first; `cleanup()` closes only the last.
- **Fix:** Close it in children (`{ … } {_SPLITSCREEN_FIFO_FD}<&- &` / `spawn_instance …
  {_SPLITSCREEN_FIFO_FD}<&-`), and make `_open_fifo_reader` idempotent.

---

### A19. Advertised launcher overrides (`N_SLOTS`, `INSTANCES_DIR`, `LAUNCHER_EXEC`, `SPLITSCREEN_SCREEN_W/H`, `MCSS_RAW_BINDING`, `MCSS_NESTED_KWIN_NNP`) are not carried across the autostart re-exec
- **Severity:** Low
- **Category:** logic / contract mismatch
- **File:** `minecraftSplitscreen.sh:11-14` (header), `modules/runtime_context.sh:739-764` (canonical env list)
- **Status:** PLAUSIBLE (depends on how Plasma launches autostart entries — the file itself asserts "env does NOT carry over", :280, :312)
- **What:** `mcss_exec_env_string` carries `MCSS_CONTROLLER_PROXY` "so the child does not
  re-derive its own default" but omits `MCSS_MAX_PLAYERS`/`N_SLOTS`, `MCSS_RAW_BINDING` (the
  comment at :745-750 admits the same risk), `MCSS_INSTANCES_DIR`, `MCSS_LAUNCHER_EXEC`,
  `MCSS_SCREEN_W/H` (:754-757 says MCSS_SCREEN_* is a carried contract — it is not in the list)
  and `MCSS_NESTED_KWIN_NNP`. The nested `prodFromPlasma` process re-resolves all of them from
  ITS environment.
- **Failure scenario:** Steam LaunchOptions `N_SLOTS=2 launchFromPlasma` → nested orchestrator
  runs with 4 slots; `MCSS_RAW_BINDING=0` outer vs `1` inner → enumeration/sandbox disagree
  (the exact drift runtime_context.sh:192-196 says "MUST agree").
- **Fix:** Add the resolved values (`MCSS_MAX_PLAYERS MCSS_RAW_BINDING MCSS_INSTANCES_DIR
  MCSS_LAUNCHER_EXEC MCSS_NESTED_KWIN_NNP`) to `_canonical`; carry screen overrides as
  `SPLITSCREEN_SCREEN_W/H` when set.

---

### A20. Hard-coded paths/names that bypass the resolvers or drift by Plasma version
- **Severity:** Low
- **Category:** hardcoded
- **File:** `modules/runtime_context.sh:76` (state file root), `:269-272,280` (PolyMC root literal, no `# PAIRED` with `install-minecraft-splitscreen.sh:334`); `minecraftSplitscreen.sh:238` (`/usr/bin/kwin_wayland_wrapper`), `:642-645` (`kded6`); `modules/preflight.sh:146-147` (probes `kwin_wayland_wrapper` on PATH)
- **Status:** CONFIRMED
- **What:** (a) `SPLITSCREEN_STATE` defaults to `$HOME/.local/share/PolyMC/splitscreen_state.json`
  regardless of the `MCSS_LAUNCHER_ROOT` cascade — a PrismLauncher install writes its state
  (and `mkdir -p`s) under a PolyMC directory. (b) The shim hardcodes `/usr/bin/kwin_wayland_wrapper`
  while preflight only checks that SOME `kwin_wayland_wrapper` is on PATH — on a distro that ships
  it elsewhere preflight passes and the nested session silently fails to start (the failure
  mode :140-145 says preflight exists to prevent). (c) `_end_nested_session` lists `kded6` only;
  SteamOS ≤3.6 (Plasma 5.27) has `kded5`, which then survives and keeps the "game" alive.
- **Fix:** derive the state path from `MCSS_LAUNCHER_ROOT` inside `mcss_resolve_paths`; resolve
  the wrapper with `command -v kwin_wayland_wrapper` at shim-write time (excluding
  `$MCSS_HELPER_DIR`); list `kded5 kded6`.

---

### A21. Debug log is a predictable world-readable file in `/tmp` with `set -x`, and records controller identities
- **Severity:** Low
- **Category:** security
- **File:** `minecraftSplitscreen.sh:70`, `:87-90`
- **Status:** CONFIRMED
- **What:** `LOG=/tmp/splitscreen-debug-$(date +%Y%m%d-%H%M%S).log`, then `exec 2>>"$LOG"; set -x`.
  Predictable to the second (symlink pre-planting → append to an attacker-chosen file as the
  Deck user), created with the default umask (world-readable), and the xtrace captures every
  expanded command — including `CONTROLLER_ADD … <phys_uniq>` lines (Bluetooth MACs) and the
  full env strings emitted by `mcss_exec_env_string`.
- **Fix:** Put the log under `$MCSS_HELPER_DIR` (0700) or `mktemp`, `umask 077` before `exec`,
  keep only the `-latest` symlink in `/tmp` if needed.

---

### A22. Three encodings of the "reset this slot" record
- **Severity:** Low
- **Category:** principle-violation (#9)
- **File:** `modules/orchestrator.sh:465`; `modules/instance_lifecycle.sh:1246`; `modules/slot_manager.sh:276-278`
- **Status:** CONFIRMED
- **What:** `_launch_slot`'s failure path and `teardown_instance` each inline
  `{"active": false, "pid": null, "bwrap_pid": null, "event_node": null, "js_node": null, "wid": null}`;
  `slot_free` writes a third, different subset (nulls `phys_*`, `disconnected*`, NOT
  `pid`/`bwrap_pid`/`wid`). None resets everything, which is what lets A2 leave live PIDs
  behind on an `active:false` record.
- **Fix:** One `slot_reset <n>` in instance_lifecycle (or slot_manager) that nulls every field
  of the schema; all three sites call it.

---

### A23. `_check_monitor_heartbeats` restarts the controller monitor with `SKIP_INITIAL_EMIT=1`, dropping pads that connected during the outage
- **Severity:** Low
- **Category:** logic
- **File:** `modules/orchestrator.sh:362-364`
- **Status:** CONFIRMED
- **What:** The restarted monitor re-baselines `prev_nodes` from the current device list
  without emitting, so a pad that appeared while the monitor was dead is in the baseline and
  never produces a `CONTROLLER_ADD`.
- **Fix:** On restart, run the docked acquisition pass once (dispatch `list_eligible_controllers`
  through `_handle_msg`; `slot_claim` de-duplicates known pads as REJECT), then start the
  monitor hotplug-only.

---

### A24. `docked_flow`'s return code 1 is overloaded ("FIFO unset" and "re-enter handheld"); `main()` acts on both
- **Severity:** Low
- **Category:** logic / contract
- **File:** `modules/orchestrator.sh:821-824`, `:918-919`, `:1011-1016`
- **Status:** CONFIRMED
- **What:** Header (:791-792) documents both meanings for `1`. `main()` treats any `1` as
  "requested re-entry as handheld" and runs `handheld_flow`, which fails the same FIFO check.
  Harmless today (main always sets the FIFO) but makes A3/A4-style fixes fragile.
- **Fix:** Use `2` for the FIFO error (or `return 3` for re-entry) and document.

---

### A25. Installer main(): misleading "Run:" hint, duplicated repo URL, shared `/tmp` debug dir, non-local loop var
- **Severity:** Low
- **Category:** hardcoded / robustness
- **File:** `modules/main_workflow.sh:230` (`Run: $TARGET_DIR/minecraftSplitscreen.sh`), `:243` (GitHub URL, duplicate of `install-minecraft-splitscreen.sh:252`), `:61` (`rm -rf "/tmp/mcss-debug-api"`), `:216` (`for mod in …` not `local`)
- **Status:** CONFIRMED
- **What:** (a) The completion banner tells the user to run the launcher directly; the launcher's
  `*)` dispatch REFUSES a bare invocation outside gamescope (`minecraftSplitscreen.sh:1176-1211`),
  so following the printed instruction yields "nothing happens" + a kdialog. (b) The support URL
  is a second literal of the repo base that `REPO_BASE_URL`/`MCSS_REPO_RAW_URL` already encode.
  (c) `/tmp/mcss-debug-api` is a fixed, shared-namespace path that `instance_creation.sh` then
  writes into (another user can own it). (d) `mod` leaks as a global (STYLE §7.4).
- **Fix:** Print "Launch from the Steam library entry"; derive the URL from the constants; use
  `${TMPDIR:-/tmp}/mcss-debug-api-$UID` or a `mktemp -d`; `local mod`.

---

### A26. Dead code: `restorePanels` never exists (tests stub it), unreachable `--version` arm, prod-dead `_find_slot_by_uniq`
- **Severity:** Info
- **Category:** dead-code
- **File:** `modules/orchestrator.sh:1113-1115`; `minecraftSplitscreen.sh:1027-1032` (`--version|-v) : ;;` — `:58-61` already `exit 0`ed); `modules/orchestrator.sh:266-275`
- **Status:** CONFIRMED
- **What:** `grep -rn restorePanels` finds only the guarded call and two test stubs
  (`tests/test_orchestrator.sh:225,380`) — the stubs make the tests pass against a function
  the product never defines. The preflight `case` arm for `--version` can never run because the
  build-provenance block exits first.
- **Fix:** Delete all three.

---

### A27. Minor hygiene: globals leaked from helpers; `_run_phase_b_session` regresses Fix #80 and trips `set -u`
- **Severity:** Info
- **Category:** robustness / style
- **File:** `modules/orchestrator.sh:144,158` (`msg` global), `:227` (`slot` global); `minecraftSplitscreen.sh:838` (`SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"` — `$0`, not `BASH_SOURCE`, overwriting the prologue's global), `:835` (`(DISPLAY=$DISPLAY)` unguarded under the leaked `set -u` — `testDirect` from SSH without DISPLAY dies with "unbound variable"), `:841` (`timeout 7200` magic), `:750` (test-path trap is `EXIT` only, unlike the H4-fixed prod trap)
- **Status:** CONFIRMED
- **Fix:** `local msg`/`local slot`; use `$SCRIPT_DIR` from the prologue; `${DISPLAY:-unset}`;
  name the timeout; add `INT TERM HUP` to the test trap.

---

### A28. `*)` nested-session entry into `main()` never resets the state file (unlike `prodFromPlasma`)
- **Severity:** Info
- **Category:** robustness
- **File:** `minecraftSplitscreen.sh:1185-1188`; `modules/orchestrator.sh:209-214`
- **Status:** CONFIRMED
- **What:** `launchProdFromPlasma` calls `_ensure_state_file` (:585) to wipe a crashed run's
  `active:true` slots; the `*)` arm (MCSS_NESTED_SESSION=kwin path / gamescope bare) goes
  straight to `main()`, whose `_set_mode` only initializes a MISSING/invalid file. Stale
  `active:true` records from a crash are then handed to `_reap_dead_slots` (fine) but also to
  `slot_claim`'s `slot_find_by_uniq` (RESUME onto a slot with no instance until the reap runs).
- **Fix:** Call `_ensure_state_file` at the top of `main()` (idempotent, and `_atomic_write`
  makes it safe).

---

## Summary

Counts: Critical 1 · High 4 · Medium 8 · Low 12 · Info 3 (28 findings; 2 PLAUSIBLE-only: A9, A19;
A12/A16 PLAUSIBLE in the sense that a precondition is needed, code path confirmed).

Top three:
1. **A1** — `pkill -9 -f "$_launcher_name"` in the STARTUP GUARD SIGKILLs the launcher (and
   Steam's reaper) whenever the guard fires; empirically confirmed self-kill. Any launch that
   finds leftovers bounces to the library before the sweep or the launch completes.
2. **A2** — With `MCSS_CONTROLLER_PROXY=1` (default), `SLOT_DIED` calls `slot_free` before
   `teardown_instance`, whose active-guard then skips the kill: hung-JVM / dead-proxy /
   bwrap-gone instances are orphaned for the session and adopted by Steam's reaper at exit.
   The unit test (T6.3) stubs `teardown_instance`, so it cannot fail on this.
3. **A3 + A4** — Mode transitions are unsafe in both directions: docked→handheld leaks the docked
   monitors (duplicate spawns/events, orphaned `udevadm`), and a dock/undock cycle while in
   handheld_flow makes `_handle_msg` return 1 → `break` → `cleanup` → the single-player game is
   torn down (PRINCIPLES #5).

Also worth scheduling together: A5 (stranded autostart + unguarded `prodFromPlasma` can run the
launcher on the real desktop) with A7 (`pkill -x plasmashell`) — the second is what makes the
first destructive.
