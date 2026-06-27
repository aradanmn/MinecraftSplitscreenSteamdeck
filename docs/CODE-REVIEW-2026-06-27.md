# Code review — feat/gamescope-windowing runtime modules

_Adversarially-verified multi-agent review, 2026-06-27. 18 confirmed findings: {"high": 5, "medium": 8, "low": 5}._

# Code Review — `feat/gamescope-windowing` runtime modules

Findings below are all code-confirmed. Two of the supplied items (the "state-file writes race" pair) are the same defect viewed from two angles and are merged into H3.

## Top 3 to fix first
1. **H3 — Unlocked state-file read-modify-write + shared `$$` temp** (`instance_lifecycle.sh`). Causes un-reapable zombie slots, double-spawn, and controller-on-wrong-player in the *common* 4-pads-at-dock case. Highest blast radius, common trigger.
2. **H4 — No `trap cleanup` on signal** (`orchestrator.sh`). A compositor/Steam teardown orphans every bwrap→java tree (the documented "5 leftover java/bwrap", ~1.5 GB each). RAM exhaustion + stale-socket fallout on next launch.
3. **H1 — Producer double-enumeration snapshot skew** (`controller_monitor.sh`). Can permanently strand a genuinely-connected controller as an absent player, unrecoverable within the session. Directly in the hot path changed this week.

---

## HIGH

### H1 — Producer loop enumerates twice per event; `prev_nodes` desyncs from the emitted ADD/REMOVE
`modules/controller_monitor.sh:926-936` (udev branch), `:945-955` (poll fallback), diff at `:781-847`/`:792`
- **Bug:** Each event builds `new_nodes` from ENUM A (926-933), then `_check_devices_changed` re-enumerates internally (ENUM B, line 792) to compute the diff, but the next baseline is set to `prev_nodes="$new_nodes"` (ENUM A). The diff and the new baseline come from two scans taken ~ms apart. If ENUM A sees pad X but ENUM B (later) transiently misses it during a hotplug storm, no ADD is emitted yet `prev_nodes` is poisoned to include X — X then counts as "already known" forever and never triggers an ADD. ADD debounce (820-825) only guards the duplicate direction; REMOVE (838-846) is unguarded.
- **Impact:** Connected controller never spawns its player after a connect/disconnect storm (permanently absent player); spurious REMOVE/ADD churn.
- **Fix:** Enumerate exactly once per event. Have `_check_devices_changed` echo its authoritative node list (or take `current_output` as a param); assign `prev_nodes` from that same snapshot and delete the separate `new_nodes` loop. (This is the deferred hardening noted in 9d8db12/c94e993.)

### H2 — `override_redirect` fallback un-manages a window irreversibly; KWin can never re-tile it
`modules/window_manager.sh:205-218`, `modules/dex.sh:344-388`
- **Bug:** `_position_slot` re-picks KWin-vs-OR per call from a live D-Bus probe (line 209, also gated on non-empty `pid`). Any transient miss (qdbus busy under launch load, env-import miss on the first window, or a state-write race that returns empty pid) routes through `_apply_override_redirect_cycle` → `action_move_resize_remap`, which sets `override_redirect=1` and reparents to root. KWin's `kwin_place_windows` only iterates `workspace.windowList()` and sets `frameGeometry` — it never clears OR or reparents back, so the window is NOMATCH (or its geometry is inert) on every later reflow. The transition is one-way.
- **Impact:** One flaky probe strands a slot at a fixed geometry: it won't collapse to fullscreen on scale-down, won't shrink to a quad on scale-up, and occludes neighbours — stuck-window / black-half, unrecoverable without killing the instance.
- **Fix:** Commit to one path per session and record it per-slot in state; or make the OR path reversible (clear `override_redirect`→0 + reparent back before the KWin path). At minimum, once a slot is OR'd keep using OR for that slot.

### H3 — Unsynchronized state-file RMW + shared `${target}.tmp.$$` → lost slot data (zombie slots, double-spawn)
`modules/instance_lifecycle.sh:109` (temp name), `:529-548` (update_slot_state); concurrency at `modules/orchestrator.sh:232,282-308,531-542`; reaper guards at `orchestrator.sh:191`, `watchdog.sh:98,104,115`
- **Bug:** `_atomic_write` uses `${target}.tmp.$$`; `$$` is the parent PID, identical in every backgrounded `{ } &` subshell (only `$BASHPID` differs), so concurrent spawns clobber one shared temp before `mv`. Independently, `update_slot_state` does an unlocked jq read→merge→write of the whole file (zero `flock` anywhere). At dock startup up to 4 `CONTROLLER_ADD` events each background a spawn that writes active/event/js, bwrap_pid, pid, wid over ~120 s — overlapping with the main loop's `active:true` reservation and with reap/teardown writes. A later writer merging from a stale snapshot reverts another slot's just-written field.
- **Impact:** (a) Lost `bwrap_pid` → `_reap_dead_slots` skips via `[[ -z "$bwrap_pid" ]] && continue` (191) and watchdog gates every death check on non-empty fields → permanent un-reapable zombie slot. (b) Overwritten `active:true` reservation → `_find_free_slot` hands the same slot out twice → double-spawn / controller bound to the wrong player. (c) Clobbered temp → corrupt JSON → `read_state` returns `null` → false-inactive.
- **Fix:** Wrap the read-modify-write in `flock` on a lock fd, and make the temp unique per writer (`mktemp "${target}.XXXXXX"` or `$BASHPID`). Apply the same lock to `_set_mode` (see L2).

### H4 — No cleanup trap: a signalled orchestrator orphans every bwrap+java tree
`modules/orchestrator.sh:686` (cleanup), `:624-681` (main), sole trap at `:288`; spawn uses `setsid` at `instance_lifecycle.sh:734`
- **Bug:** `cleanup()` is reached only by falling off the end of `handheld_flow`/`docked_flow`. No `trap cleanup EXIT INT TERM HUP` is installed in main(). Instances are launched under `setsid` (own session/group), so SIGTERM/SIGKILL or a gamescope reset to the orchestrator leaves bwrap→PolyMC→java reparented to init. The outer trap in `minecraftSplitscreen.sh:667` is a bare `EXIT` (won't fire on TERM/KILL) and doesn't call `teardown_all_instances` anyway.
- **Impact:** The documented "compositor RESET orphans all instances — 5 leftover java/bwrap" gap; ~1.5 GB heap each → RAM exhaustion and stale `qtsingleapp` sockets racing the next launch. Watchdog/monitor/dock-monitor PIDs also leak.
- **Fix:** `trap cleanup EXIT INT TERM HUP` at the top of main() (explicitly list TERM/INT — a bare EXIT won't catch them); guard re-entry with a flag. On startup, reap orphans from a prior crashed session (kill leftover bwrap/PolyMC groups, `rm /tmp/qtsingleapp-*`) since their PIDs are lost after the state reset.

---

## MEDIUM

### M1 — `kwin_place_windows` returns 0 on NOMATCH; `_position_slot` discards the result → invisible placement failures
`modules/kwin_positioner.sh:147,166-173`; `modules/window_manager.sh:209-213`
- NOMATCH is only `print()`ed to the KWin journal; the function returns 0 unconditionally after load+run+unload, and `_position_slot` ignores even that and `return 0`. A pid mismatch / not-yet-mapped / OR-stranded window is reported placed; no retry, no OR fallback (the OR branch is only reachable when the KWin guard is false, never on in-script NOMATCH).
- **Impact:** Mis-/un-placed windows reported as success; window stays where it mapped (often 0,0 over slot 1). Contributes to black/occluded halves.
- **Fix:** Emit a machine-readable placed-count from the JS, surface a non-zero exit on total NOMATCH, and branch `_position_slot` to the OR path (or re-poll) on failure.

### M2 — `_verify_window_geometry` compares screen-target coords against parent-relative `XGetWindowAttributes`
`modules/window_manager.sh:152-172`; `modules/dex.sh:250-254`
- The default (managed) path leaves KWin reparenting the XWayland client into its frame; `action_getgeometry` returns parent-relative `attrs.x/y` (~0,0 in the wrapper), not screen coords. The exact-integer compare (line 165) cries wolf on every correctly-tiled managed window and can never flag a genuinely misplaced one. Correct only for the OR/reparent-to-root path.
- **Impact:** Diagnostic-only (no control flow depends on it), but the check meant to catch the unmap/not-sticking class is systematically wrong for the now-default path; misleading logs mask real regressions. (Realistically low-medium.)
- **Fix:** Use `XTranslateCoordinates(wid→root)` for the managed path (or query KWin's `frameGeometry` back), or skip verify on the KWin path.

### M3 — Residual occlusion black-out at 4 windows: raise-after-place has no escalation; comment promises a "remap kick" that doesn't exist
`modules/kwin_positioner.sh:136-142`
- The raise (commit 59f97a3) fixed 3 windows, not 4. The comment says "a no-op is fine (then we escalate to a remap kick)" but lines 139-143 are the whole logic — `try{raiseWindow/raise}catch{}` then `placed++`. If both raise APIs are absent/no-op, the culled 4th window stays BLACK. Each slot is also placed in a separate single-target `kwin_place_windows` invocation, so placement+raise across the four is non-atomic.
- **Impact:** With 4 players the last window mapped at 0,0 can remain a black quad.
- **Fix:** Implement the escalation — on no-op/still-occluded, force a recomposite via dex unmap+map kick or a `w.hidden` toggle. Consider batching all four targets in one call.

### M4 — Concurrent `_reflow_layout` from multiple spawn subshells races KWin placement
`modules/orchestrator.sh:142-172,200,306,364,396`
- No mutex. Invoked from each backgrounded spawn (after `ORCHESTRATOR_SPAWN_DELAY_S`, line 306) and from `_reap_dead_slots` (200) / SLOT_DIED (364) / mode-change (396). With 4 pads at startup, several reflows overlap; `apply_layout` snapshots `get_active_slots`, places per-window, sleeps 1.2 s, re-asserts — two overlapping calls with different snapshots push conflicting `frameGeometry` and the reassert phase can re-occlude a window the other run just raised.
- **Impact:** Transient mis-tiling (near-certain); plausible contributor to the 4th-window black-out (defeats the raise fix). *Note: no kwinrulesrc/temp clobber — JS name is unique per call (`mcss_place_$$_$RANDOM`); the race is purely logical conflicting placements (the line-140 "writes kwinrulesrc" docstring is stale).*
- **Fix:** Serialize/coalesce reflow behind a lock/flag, last-requested layout wins; have backgrounded spawns signal one post-settle reflow instead of each calling independently.

### M5 — `CONTROLLER_REMOVE` no-op leaks a slot on reused-node / silent-disappear
`modules/orchestrator.sh:313-346` (guards at `:187-201`, `watchdog.sh:88-139`)
- REMOVE deliberately preserves the world, but a reused `eventN` (fast reconnect) or a `jsN` that vanishes with no udev remove (driver crash / USB autosuspend) leaves a live bwrap leader. `_reap_dead_slots` skips it (bwrap alive, 192); watchdog only kills on destroyed window (still up). Nothing reaps it. Disclosed in-code (322-330) as a tracked follow-up.
- **Impact:** Permanently leaks 1 of 4 slots; bwrap mounts are fixed at launch so that player can't be re-bound for the session. Repeated flaps exhaust slots.
- **Fix:** On detected return/replacement of a removed node, teardown + respawn the same slot; or add an evdev-absent / controller-absent-timeout liveness signal beyond window-destroyed.

### M6 — `handheld_flow` spawns synchronously → blocks the event loop (and redock detection) up to ~180 s
`modules/orchestrator.sh:460-482` (poll timeouts at `instance_lifecycle.sh:38,47,742,750`)
- Handheld calls `spawn_instance` in the foreground (461), before the `while true` loop and first `_read_fifo_msg`. spawn blocks polling java (60 s) then window (120 s). The dock monitor is already running (443) and enqueues `DISPLAY_MODE_CHANGE` to the FIFO, but it isn't serviced until spawn returns; a failed launch leaves the loop dead ~180 s before `_reap_dead_slots` can recover.
- **Impact:** Handheld→docked transition stalls when the user docks mid-launch; loop unresponsive on a failed launch.
- **Fix:** Background the handheld spawn like docked (brace-group + `_SPAWN_PIDS`), keeping the N3 `slot_is_active` guard, so the FIFO loop and dock detection run immediately.

### M7 — `_SPAWN_PIDS` never pruned; cleanup may SIGKILL a reused PID
`modules/orchestrator.sh:49,310,714-723`
- Appended on every spawning CONTROLLER_ADD (310), only reset at end of cleanup (723). `cleanup()` does `kill -0` then `kill -TERM/-KILL` by bare PID over all entries; a long-finished subshell PID recycled by an unrelated process would be signalled. (Concurrent growth is capped at MAX_SLOTS since no-free-slot returns before the append, but it still grows across reconnects over a long session.)
- **Impact:** Latent: risk of killing an innocent reused PID on a long session; slowly growing array. (Arguably low.)
- **Fix:** Prune entries as subshells finish, and/or kill the process group (`-$pid`) instead of a bare PID.

---

## LOW

- **L1 — `_set_mode` unlocked RMW** `orchestrator.sh:85-89`: jq rewrites the whole state (incl. `.slots`) from a snapshot and `mv`s it; a mode change concurrent with a spawn's slot write reverts just-written fields. Same lost-update class as H3 (rare — mode changes infrequent). *Note: the finding's "clobbers `_atomic_write`'s tmp / two writers clobber `.tmp`" is wrong — different filename, and `_set_mode` is only called from the single main loop; the real defect is solely the lost update.* Fix: route through the same locked update path.
- **L2 — Integer-division 1px seam** `window_manager.sh:267,275-282`: `half_w/half_h` truncate; trailing cells use `half_*` instead of the remainder, leaving an uncovered black row/column on odd resolutions. Cosmetic; never hits even modes (Deck 1280×800, 1080p/1440p/2160p). Fix: give right/bottom cells `screen_ - half_`.
- **L3 — Untracked title-keeper subshell** `instance_lifecycle.sh:760-769`: detached `( ) &` runs ~15 s of `dex_set_name`, recorded nowhere; cleanup's single-PID `kill` doesn't reach the grandchild. Self-exits (no permanent leak) but can poke a destroyed/reused WID for up to 15 s post-teardown. Fix: track+kill it, or re-check `slot_is_active` before each rename.
- **L4 — Unscoped qtsingleapp glob** `instance_lifecycle.sh:728`: `rm -f /tmp/qtsingleapp-*` runs on every spawn in the host namespace; docked sockets live in per-slot tmpfs so it mostly hits nothing of its own, but it would clobber any unrelated host Qt single-instance app's IPC socket. Fix: scope to the slot or rely on the per-slot tmpfs.
- **L5 — Predictable `/tmp` KWin-JS temp files** `kwin_positioner.sh:104-107,189-190`: `cat > /tmp/mcss_*_$$_$RANDOM.js` (follows symlinks, no mktemp/O_EXCL) then `loadScript`+run → contents execute as session JS. Single-user Deck → negligible, but a symlink/TOCTOU + local-code-exec footgun. Fix: `mktemp` 0600 and pass that path to `loadScript`.

---

**Overall health:** The tiling/controller logic is functionally close, but the runtime is missing the two foundational safety nets it most needs — a state-file lock and a signal-time cleanup trap — so under the common 4-pads-docked case and any abnormal teardown it is prone to zombie slots, mis-bound controllers, black quads, and orphaned multi-GB process trees; not mergeable to `main` until at least H1–H4 are fixed and validated on hardware.

---

## Confirmed findings (structured)

### [HIGH] Producer loop uses two independent enumerations → prev_nodes desyncs from the ADD/REMOVE actually emitted
- **Where:** `modules/controller_monitor.sh` :928-936 (udevadm branch) and 945-955 (poll fallback)
- **Problem:** On each add/remove event the loop enumerates ONCE to build `new_nodes` (lines 928-933 / 947-952), then calls `_check_devices_changed "$mode" "$prev_nodes"` which enumerates AGAIN internally (line 792) to compute the diff, then assigns `prev_nodes="$new_nodes"` (line 936/955). The baseline that gets stored (ENUM A, captured first) is NOT the snapshot the ADD/REMOVE messages were derived from (ENUM B, captured ~ms later inside _check_devices_changed). During a hotplug storm (a single DS4 connect/disconnect fires many coalesced input `add`/`remove` udev lines, each an iteration) the two reads of /proc/bus/input/devices can disagree because the device is still appearing/leaving. Concretely: if ENUM A sees pad X but ENUM B (later) transiently misses it, no CONTROLLER_ADD is emitted for X yet `prev_nodes` is set to include X — so X is now treated as 'already known' and NEVER triggers an ADD again until the next physical hotplug. That player is permanently absent. The reverse skew (ENUM B sees X, ENUM A doesn't) emits an ADD but the debounce map at lines 820-825 only guards ADDs, while a spurious REMOVE path (debounce does not guard REMOVE at lines 838-846) can churn. The duplicate-ADD direction is mostly absorbed by the 500ms debounce and by the orchestrator's #37 REMOVE no-op, but the missed-ADD/absent-player direction is unrecoverable within a session.
- **Impact:** A connected controller can fail to ever spawn its player (stuck/absent player) after a connect/disconnect storm; spurious REMOVE/ADD churn. This is the exact 'controller mapped to absent player' failure class.
- **Fix:** Enumerate exactly once per event and use that single snapshot for BOTH the diff and the new baseline. Make `_check_devices_changed` echo the authoritative current node list (or take `current_output` as a param) and assign `prev_nodes` from that same enumeration, deleting the separate `new_nodes` loop. This is the deferred 'producer-loop hotplug hardening' called out in commits 9d8db12/c94e993.

### [HIGH] override_redirect fallback permanently un-manages a window; KWin can never re-tile it again
- **Where:** `modules/window_manager.sh:209-218 (+ modules/dex.sh:344-388 action_move_resize_remap)`
- **Problem:** _position_slot picks the path PER CALL from a single transient probe (kwin_positioner_available). If that probe fails for any one window (qdbus busy under launch load, env-import miss for the FIRST window), the window goes down the fallback _apply_override_redirect_cycle -> dex_move_resize_remap, which sets override_redirect=1 AND XReparentWindow(root). That makes the window unmanaged by KWin for the rest of the session. On every subsequent reflow KWin scripting becomes available again, _position_slot takes the KWin path, but kwin_place_windows iterates workspace.windowList() — which excludes override_redirect windows — so it reports NOMATCH and the window is never moved again. The two positioning paths are mutually exclusive and the OR transition is irreversible.
- **Impact:** A single flaky KWin probe (most likely on the first/under-load window) strands that instance at a fixed geometry: it won't collapse to fullscreen on scale-down, won't shrink to a quad on scale-up, and overlaps/occludes neighbours — the exact stuck-window / black-half symptom. Unrecoverable without killing the instance.
- **Fix:** Commit to ONE path per session: decide KWin-vs-OR once at session start and stick to it, OR make the OR path reversible (on the KWin path, first dex_set_override_redirect <wid> 0 + reparent back so KWin re-manages, before falling through). At minimum, never silently mix: if a slot was ever positioned via OR, keep using OR for that slot (record the path in state).

### [HIGH] State-file writes race: shared .tmp.$$ + unlocked read-modify-write across concurrent background spawn subshells → lost slot data, zombie slots, double-spawn
- **Where:** `modules/instance_lifecycle.sh:109,529-549`
- **Problem:** _atomic_write() writes to "${target}.tmp.$$". $$ is the PARENT shell PID and is IDENTICAL in every backgrounded subshell (only $BASHPID differs), so the multiple spawn_instance brace-groups launched concurrently from _handle_msg (orchestrator.sh:282-308) all use the SAME tmp filename. They `echo content > tmp` then `mv tmp target` — one writer clobbers the other's tmp mid-flight, and the loser's `mv` either moves the wrong content or fails (tmp already gone), silently dropping its update. Compounding this, update_slot_state() does an unserialized read(jq)→modify→mv with NO flock, so even non-colliding writers lose updates: a slow background writer that snapshotted the file before the main loop's `update_slot_state slot '{"active":true}'` reservation (orchestrator.sh:232) writes its stale snapshot back and ERASES the reservation. Genuinely concurrent writers exist: 4 pads connecting at startup (docked_flow startup-acquire, orchestrator.sh:531-542) fire 4 background spawns each writing active/event/js/bwrap_pid/pid/wid for its slot, while the main loop reserves further slots and teardown/reap may write another slot.
- **Impact:** Lost/corrupt state under the common 4-controllers-at-once case. Concrete failures: (a) a slot's bwrap_pid write is lost → _reap_dead_slots treats it as 'still launching' forever (orchestrator.sh:191) so a dead instance is NEVER reaped = permanent zombie slot; (b) an active:true reservation is overwritten → _find_free_slot hands the same slot out twice = double-spawn / two instances+windows on one slot, and the controller mapped to the wrong/overwritten player; (c) a partial mv can briefly leave jq unable to parse → read_state returns 'null' → slot_is_active falsely reports inactive.
- **Fix:** Serialize all state mutation with flock on the state file (e.g. wrap jq+mv in `flock "$state.lock"`), and make the tmp name unique per writer with $BASHPID or mktemp (`tmp=$(mktemp "${target}.XXXXXX")`) instead of $$. Apply the same lock to update_slot_state's read-modify-write so concurrent slots can't lose each other's updates.

### [HIGH] No cleanup trap: a compositor/orchestrator kill orphans every bwrap+java tree (memory leak)
- **Where:** `modules/orchestrator.sh:686,739-741`
- **Problem:** cleanup() is only reached by FALLING OFF the end of handheld_flow/docked_flow (normal session end). There is NO `trap cleanup EXIT INT TERM` installed anywhere in orchestrator.sh or main_workflow.sh (grep confirms the only trap is the per-spawn temp-file EXIT trap at line 288). If the orchestrator is signalled — gamescope/nested-compositor reset, Steam tearing the session down, SIGTERM/SIGKILL — the flow functions never return, cleanup() never runs, teardown_all_instances() never executes, and the setsid process groups (bwrap→PolyMC→java) survive as orphans reparented to init.
- **Impact:** Exactly the documented 'gamescope/compositor RESET orphans all instances — 5 leftover java/bwrap observed' gap. Each orphaned instance holds ~1.5GB heap + JVM overhead; several leftovers exhaust RAM and the next launch races stale qtsingleapp sockets. The watchdog/controller-monitor/dock-monitor background PIDs are also leaked.
- **Fix:** Install `trap cleanup EXIT INT TERM HUP` at the top of main() (cleanup is idempotent enough — guard re-entry with a flag). On startup, also reap any orphans from a prior crashed session (kill leftover bwrap/PolyMC groups, rm /tmp/qtsingleapp-*) since the state file is reset and their PIDs are lost.

### [HIGH] Concurrent state-file writes lose updates → zombie slot stuck active with bwrap_pid:null
- **Where:** `modules/instance_lifecycle.sh:106-113, 529-549; modules/orchestrator.sh:282-310`
- **Problem:** State mutation is an unsynchronized read-modify-write of the whole JSON: update_slot_state() reads the file with jq and _atomic_write() writes target.tmp.$$ then mv's it. There is NO lock (grep confirms no flock anywhere). docked_flow's startup acquisition (orchestrator.sh:531-542) dispatches up to 4 CONTROLLER_ADD events, each backgrounding a spawn_instance brace group `{ … } &` (orchestrator.sh:282-308). Each backgrounded spawn then calls update_slot_state several times (active/event/js line 715, bwrap_pid line 737, pid line 744, wid line 752) CONCURRENTLY with the others. Two interleaved read-modify-writes lose one writer's field (A reads, B reads, A writes slot1.bwrap_pid, B writes slot2.bwrap_pid from its older snapshot that lacked A's change → A's bwrap_pid is dropped). The temp path makes it worse: _atomic_write uses ${target}.tmp.$$, and $$ is the SAME for every backgrounded subshell (verified: parent and brace-group child both report $$=29567 while $BASHPID differs), so the concurrent subshells clobber each other's temp file before mv.
- **Impact:** A slot left active:true with bwrap_pid:null is permanently stuck: _reap_dead_slots skips it forever (`[[ -z "$bwrap_pid" ]] && continue`, orchestrator.sh:191) treating it as 'still launching', and the watchdog's bwrap check is `[[ -n "$bwrap_pid" ]]`-gated so it also never reaps it. One of 4 player slots becomes a dead, un-reapable zombie; a lost wid write also breaks layout/window-gone detection. Most likely exactly when 2-4 pads are connected at launch (the common docked case).
- **Fix:** Serialize the read-modify-write with flock on the state file (e.g. wrap update_slot_state in `flock 9` against a lock fd), or make _atomic_write use a unique temp (mktemp / $BASHPID) AND re-read-merge under a lock so updates can't be lost. At minimum, replace `${target}.tmp.$$` with a per-call unique name to stop temp clobbering, but the lost-update race needs an actual lock.

### [MEDIUM] kwin_place_windows returns 0 on NOMATCH and _position_slot discards its result — placement failures are invisible, no retry/fallback
- **Where:** `modules/kwin_positioner.sh:147,166-173; modules/window_manager.sh:210-212`
- **Problem:** kwin_place_windows returns 0 whenever the script merely loaded+ran, regardless of whether any target window actually matched (NOMATCH is only print()ed to the KWin journal). _position_slot then ignores even that return value and unconditionally returns 0 on the KWin branch. So if the pid never matches (e.g. KWin's _NET_WM_PID differs from the stored host pid, window not mapped yet, or the OR-stranded case above), apply_layout believes the slot was placed, never retries, and never falls back to the override_redirect path.
- **Impact:** Mis-placed or unplaced windows are reported as success; a window that fails to tile stays wherever it mapped (often 0,0 on top of slot 1) and there is no recovery path — contributes to black/occluded halves and overlapping instances.
- **Fix:** Have the KWin JS report a machine-readable placed-count, surface it back through kwin_place_windows as a non-zero exit on NOMATCH, and have _position_slot check kwin_place_windows's return and fall through to the OR path (or re-poll the window) on failure instead of return 0.

### [MEDIUM] _verify_window_geometry compares screen-target coords against parent-relative XGetWindowAttributes — false mismatch on every KWin-managed (primary-path) window
- **Where:** `modules/window_manager.sh:152-172; modules/dex.sh:250-254 action_getgeometry`
- **Problem:** The primary path leaves the window KWin-MANAGED, so KWin reparents the XWayland client into its own wrapper/frame window (it does this even with noBorder/_MOTIF_WM_HINTS decorations off). action_getgeometry uses XGetWindowAttributes, whose x/y are relative to the PARENT, i.e. ~0,0 inside the KWin wrapper — NOT the screen coordinates that frameGeometry was set to. So _verify_window_geometry compares e.g. expected (640,0) against actual (0,0) and logs a geometry MISMATCH for correctly-placed windows. (It is only correct for the OR/reparent-to-root path, where parent==root.)
- **Impact:** The verification step cries wolf on every correctly-tiled window and, conversely, can never detect a genuinely misplaced managed window — the diagnostic the code relies on to catch the unmap/not-sticking class of bugs is systematically wrong for the path that is now default. Misleading logs mask real regressions.
- **Fix:** For the managed path, read true screen coords via XTranslateCoordinates(wid -> root) (or query KWin's frameGeometry back through the script) instead of raw XGetWindowAttributes; or skip verify on the KWin path and verify only OR-path windows.

### [MEDIUM] Residual occlusion black-out at 4 windows: raise-after-place has no escalation; comment promises a 'remap kick' that does not exist
- **Where:** `modules/kwin_positioner.sh:136-142`
- **Problem:** The new raise-after-place (commit 59f97a3) forces a recomposite of an occlusion-culled window, but per the session notes it only fixed 3 windows, not 4. The code comment says 'a no-op is fine (then we escalate to a remap kick)' — but there is NO escalation: if both workspace.raiseWindow and w.raise are absent/no-op, nothing else happens, the culled 4th window stays BLACK. Also each slot is placed in a SEPARATE kwin_place_windows invocation (apply_layout calls _position_slot per slot), so the batch raise-ordering can't guarantee the previously-culled window ends up re-exposed in one atomic pass.
- **Impact:** With 4 players, the last-spawned window that mapped at 0,0 over the existing three can remain a black half/quad — a direct black-window defect that the fix only partially addresses.
- **Fix:** Implement the promised escalation: if raise is a no-op (geometry unchanged / still occluded on verify), force a real recomposite via an unmap+map kick (dex XUnmap/XMap) or a w.hidden toggle on the affected window. Consider batching all targets in one kwin_place_windows call so placement+raise of all four is atomic.

### [MEDIUM] Concurrent _reflow_layout from multiple background spawn subshells races KWin scripting / kwinrulesrc
- **Where:** `modules/orchestrator.sh:142-172,306,200,364`
- **Problem:** _reflow_layout() (writes kwinrulesrc + calls sync_apply_layout, which loads a KWin script) is invoked from several places that can overlap in time: each backgrounded spawn brace-group sleeps ORCHESTRATOR_SPAWN_DELAY_S then calls it (line 306), while the main loop also calls it from _reap_dead_slots (line 200) and the SLOT_DIED handler (line 364). With 4 pads at startup, 4 spawn subshells each fire _reflow_layout within a few seconds of each other. There is no mutex, so two reflows concurrently rewrite kwinrulesrc and push overlapping KWin scripting placements for the same active set.
- **Impact:** Racing placement is a strong contributor to the known '4th window maps at 0,0, gets occluded/culled → BLACK and never repaints' bug — a later reflow can place a window over one a concurrent reflow is still positioning/raising, defeating the raise-after-place fix. At minimum produces transient mis-tiling.
- **Fix:** Serialize reflow behind a lock/flag so only one runs at a time and the last requested layout wins (coalesce). Have the backgrounded spawns signal the main loop to reflow once after settle, rather than each calling _reflow_layout independently.

### [MEDIUM] CONTROLLER_REMOVE no-op leaks a slot on reused-node / silent-disappear (zombie slot)
- **Where:** `modules/orchestrator.sh:313-346`
- **Problem:** CONTROLLER_REMOVE is a deliberate no-op (preserve the instance/world on a battery/idle dropout). As the in-code disclosure admits, a controller whose eventN is reused by a fast reconnect, or a jsN that vanishes with no udev remove (driver crash / USB autosuspend), leaves a still-alive instance whose bwrap leader is up. _reap_dead_slots skips it (bwrap alive, lines 191-197) and watchdog only kills on a destroyed WINDOW — the game window is still up — so nothing ever reaps it.
- **Impact:** Permanently leaks 1 of 4 slots; that player's controller can never be re-bound (bwrap mounts are fixed at launch) and the seat is gone for the rest of the session. With repeated flaps the session can run out of slots while players are stuck on dead instances.
- **Fix:** On a detected replacement/return of a removed node, relaunch the SAME slot (teardown_instance then respawn with the new node) as the code's own follow-up note proposes; or add a liveness signal beyond window-destroyed (e.g. evdev open-failure / controller-absent timeout) to reap a truly-gone seat.

### [MEDIUM] handheld_flow spawns synchronously — blocks the event loop (and redock detection) up to 120s
- **Where:** `modules/orchestrator.sh:460-482`
- **Problem:** In handheld_flow, spawn_instance is called in the FOREGROUND (line 461, piped through sed), unlike docked_flow which backgrounds it. spawn_instance blocks polling for java (up to 60s) and the window (up to 120s, _poll_for_window). The `while true` event loop and _read_fifo_msg do not start until spawn_instance returns.
- **Impact:** A DISPLAY_MODE_CHANGE docked (user docks the Deck) emitted by watch_display_mode during handheld launch is queued in the FIFO but not serviced until the window appears or the 120s poll times out — the handheld→docked transition stalls. If the window never appears (failed launch), the loop is dead for the full 120s before _reap_dead_slots can recover the slot.
- **Fix:** Background the handheld spawn the same way docked_flow does (brace-group + _SPAWN_PIDS tracking) so the FIFO loop and dock detection run immediately, and let _reap_dead_slots/the slot-1-inactive check end the session.

### [MEDIUM] _SPAWN_PIDS never pruned; cleanup() kills possibly-reused PIDs and the array grows unbounded
- **Where:** `modules/orchestrator.sh:310, 714-723`
- **Problem:** Every CONTROLLER_ADD appends the spawn brace-group PID to _SPAWN_PIDS (line 310) but nothing ever removes completed entries. Over a long docked session with controllers flapping (disconnect is a no-op, each reconnect spawns again and appends), the array only grows. cleanup() then iterates ALL of them and does `kill -0` followed by `kill -TERM`/`kill -KILL` (lines 715-721). By teardown a long-finished spawn PID may have been recycled by an unrelated process, which cleanup would then signal/kill.
- **Impact:** Unbounded (if slowly) growing array, and a real risk of cleanup SIGKILLing an innocent reused PID on a long-running session. Not corrupting in the common short session, but a latent stability/safety bug.
- **Fix:** Prune _SPAWN_PIDS as subshells finish (or store with a generation/marker and drop entries once `kill -0` fails the first time), and/or kill the spawn subshell's process GROUP rather than a bare PID to avoid the reuse hazard. Reset the array after each session, not only at end of cleanup.

### [MEDIUM] Hotplug producer re-enumerates twice per event (snapshot skew) → duplicate or missed CONTROLLER_ADD
- **Where:** `modules/controller_monitor.sh:911-937, 781-847`
- **Problem:** On each udev add/remove the monitor enumerates once to build new_nodes (lines 928-933), then _check_devices_changed enumerates AGAIN independently (line 792) to compute the diff, and finally prev_nodes is set to the FIRST snapshot (line 936). The diff and the next baseline therefore come from two different point-in-time scans. A device that appears between the two scans yields an ADD from _check_devices_changed that is absent from new_nodes, so it is re-detected (and re-emitted) next iteration. Adds are partially protected by the 500ms debounce (line 821) but REMOVE is not debounced at all. This is the acknowledged-but-unhardened producer path under raw binding default.
- **Impact:** Spurious/duplicate CONTROLLER_ADD (mostly absorbed by debounce) and, on event-node reuse during fast flap, a CONTROLLER_ADD carrying a js node that has been recycled — a controller could be bound for the wrong/absent player. Removes are a deliberate no-op so a missed remove is benign, but the skew undermines the prev_nodes invariant the acquire/diff logic relies on.
- **Fix:** Enumerate ONCE per event: have _check_devices_changed return (or accept) the fresh snapshot and use that exact list as the new prev_nodes, eliminating the double scan. Debounce removes too, or coalesce bursts of udev events before diffing.

### [LOW] Integer-division quad/half geometry leaves a 1px unpainted seam on odd resolutions
- **Where:** `modules/window_manager.sh:267,275-282`
- **Problem:** half_w=$((screen_w/2)) and half_h=$((screen_h/2)) truncate. For odd screen_w (or screen_h), the right column starts at half_w with width half_w, covering only up to 2*half_w == screen_w-1, leaving a one-pixel column (and similarly a one-pixel row) of the screen uncovered. The backdrop is black (plasmashell killed), so it shows as a thin black seam at the right/bottom edge.
- **Impact:** Cosmetic black seam between/at edges of tiles on any odd-pixel display mode; never covered by any cell.
- **Fix:** Give the right/bottom cells the remainder: width = screen_w - half_w (and height = screen_h - half_h) for cells 2/3/4 and the bottom half, so the grid sums exactly to screen_w x screen_h.

### [LOW] _set_mode uses a fixed-name temp file (racy with concurrent state writers)
- **Where:** `modules/orchestrator.sh:85-89`
- **Problem:** _set_mode writes `${state}.tmp` (a single fixed filename) then `mv`s it over the state file, with no lock. This collides with _atomic_write's tmp and with any concurrent update_slot_state, and `jq ... > ${state}.tmp` overwriting the state via a stale read drops slot data (the whole `.slots` object is rewritten from _set_mode's snapshot).
- **Impact:** A mode change firing concurrently with a spawn's slot-state write can revert just-written slot fields, or two writers can clobber the shared .tmp. Rare (mode changes are infrequent) but same corruption class as the high finding.
- **Fix:** Route mode changes through the same locked, unique-tmp update path used for slot state.

### [LOW] Title-keeper background subshell is untracked and survives teardown, poking X after the window is gone
- **Where:** `modules/instance_lifecycle.sh:760-769`
- **Problem:** After storing the WID, spawn_instance launches a detached `( … ) &` loop that calls dex_set_name 15 times over ~15s. It is spawned by the backgrounded spawn brace group but is NOT recorded anywhere. cleanup()/_SPAWN_PIDS only knows the brace-group PID; `kill -TERM $_sp` on that PID does not reach this grand-child. If the slot is torn down within those 15s, the keeper keeps issuing X requests (dex_set_name) against a WID that may already be destroyed.
- **Impact:** Minor: an orphaned process pokes X for up to 15s after teardown; self-exits, so no permanent leak. Could log BadWindow noise or briefly rename an unrelated reused WID.
- **Fix:** Track the keeper PID and kill it in teardown_instance/cleanup, or have it re-check slot_is_active / window presence before each dex_set_name and exit early.

### [LOW] spawn_instance removes ALL hosts' qtsingleapp sockets with an unscoped glob
- **Where:** `modules/instance_lifecycle.sh:728`
- **Problem:** `rm -f /tmp/qtsingleapp-* 2>/dev/null` deletes every qtsingleapp-* socket in the host /tmp on each spawn, not just this slot's. For docked the real socket lives inside the per-slot bwrap tmpfs so this mostly hits nothing, but it will also clobber the socket of any other Qt single-application the user is running on the host (or a concurrently-spawning handheld instance), and it runs on every spawn.
- **Impact:** Low: can break an unrelated host Qt app's single-instance IPC, or interfere if two launches overlap. Not a crash, but an over-broad destructive side effect.
- **Fix:** Scope the removal to this slot (or rely entirely on the per-slot tmpfs /tmp, which already isolates the socket) instead of a global /tmp glob.

### [LOW] KWin script temp files use predictable /tmp names with cat > (symlink/TOCTOU, code executed as KWin JS)
- **Where:** `modules/kwin_positioner.sh:104-107, 189-190`
- **Problem:** kwin_place_windows and kwin_set_noborder write JS to `/tmp/mcss_place_$$_$RANDOM.js` / `/tmp/mcss_noborder_${pid}_$RANDOM.js` via `cat > "$jsfile"` with no O_EXCL / mktemp and no `set -C`. `cat >` follows symlinks, and the file content is then loaded and executed by KWin (loadScript). On a shared host a local user could pre-create a symlink at the predictable path to redirect the write or to get attacker JS run in the session.
- **Impact:** On the single-user Deck this is low, but it is a temp-file-safety / local-code-execution footgun (KWin runs whatever is at that path).
- **Fix:** Create the script file with mktemp (0600) and pass the mktemp path to loadScript, or open with O_EXCL. Avoid predictable names in a world-writable directory.
