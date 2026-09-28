title: [B10-B28] Lifecycle/creation/slot-manager/watchdog low & info batch (19 items, checklist)
severity: low
security: no
type: Task
related: #14, #135
---
- [ ] B10 — `_ensure_state_file` called outside the lock from `update_slot_state`; hardcoded 4-slot schema
- [ ] B11 — `spawn_instance`'s late reserve write can clobber a RESUME'd `event_node`
- [ ] B12 — Watchdog's proxy check mutates proxy state (deletes the pidfile)
- [ ] B13 — `rm -f /tmp/qtsingleapp-*` is a name-matched delete on shared host /tmp
- [ ] B14 — Legacy vendor alias with a re-embedded `28de` literal
- [ ] B15 — `MCSS_STATE_LOCK` exported but never used
- [ ] B16 — `MCSS_RECONNECT_GRACE_S` defined outside `runtime_context.sh`
- [ ] B17 — Consumer-side fallbacks and magic literals in logic
- [ ] B18 — Dead code / stale plumbing
- [ ] B19 — `spawn_instance` rc 2 ("already running") makes the caller RELEASE the live slot
- [ ] B20 — bwrap required even for the handheld direct launch
- [ ] B21 — errexit fragility when the module is sourced standalone under `set -e`
- [ ] B22 — `teardown_instance` blocks the FIFO loop up to 10 s per hung slot (Info, KNOWN)
- [ ] B23 — `slot_claim` comment says "newest" but `head -n 1` returns the LOWEST slot (Info)
- [ ] B24 — Keeper subshells are untracked PIDs that outlive `cleanup()` (Info)
- [ ] B25 (+C12) — Two derivations of the instance number; required-mod check is a PREFIX match
- [ ] B26 — `handle_instance_update` sed edits unescaped for `&`/`|` in `JAVA_PATH` (Info)
- [ ] B27 — Redundant `command -v jq` guards; duplicated Controlify write; proxy gate evaluated twice (Info)
- [ ] B28 — `create_instances` unconditionally re-enables errexit (Info, KNOWN)

## Summary
Low/Info findings from review B (instance lifecycle, instance creation, slot manager, watchdog) that are individually small but mostly cheap: a handful of one-line drift/hygiene fixes (B13, B14, B19, B21, B23, B25/C12, B26), three robustness items with a slightly larger shape (B10, B11, B12), and five hardcoded/dead-code/consistency clean-ups (B15-B18, B20, B27). Two are Info-only and already tracked elsewhere (B22 in `docs/TODO.md:307`, B28 in `docs/CODE-REVIEW-2026-07-21-CLOSED.md:18`) and are listed so the checklist is complete. None changes the shipped launch path's behaviour on its own; the ones that touch runtime code (B10-B13, B19-B21, B24) should ride along with the B1/B3/B4/B9 changes and be validated through the same hardware stages. Line numbers refer to the current files.

### B10. `_ensure_state_file` outside the lock; schema literal drifts from slot_manager's fields
`modules/instance_lifecycle.sh:765-768` (init-if-missing BEFORE `flock`), `:157-165` (4-slot literal without `phys_*`/`disconnected*`). Two concurrent `update_slot_state` calls on a missing file can each reset it before locking, losing one merge; `_set_mode` initializes inside its lock, so the two writers disagree on ordering, and the initializer ignores `MCSS_MAX_PLAYERS`. Fix: move the `[[ ! -f "$state_file" ]] && _ensure_state_file` inside the `flock` subshell in `update_slot_state`, and generate the slot map with `jq -n --argjson n "${MCSS_MAX_PLAYERS:-4}" '{mode:$mode, slots: ([range(1;$n+1) | {key:(.|tostring), value:{active:false,pid:null,bwrap_pid:null,wid:null,event_node:null,js_node:null,phys_uniq:null,phys_vendor:null,phys_product:null,disconnected:false,disconnected_at:null}}] | from_entries)}'` (one schema, PRINCIPLES #9; T4.9 keeps passing — it asserts inactive/null only).

### B11. Late reserve write can clobber a RESUME'd `event_node`
`modules/instance_lifecycle.sh:1058` writes the spawn's ORIGINAL `event_node`/`js_node` from local variables; if the pad drops and returns between `_launch_slot` backgrounding and this line (0.2-2 s: cfg edits + `proxy_start_slot`'s virtual-node poll), `slot_release` + `slot_claim→RESUME→slot_touch` already updated the node and this write reverts it (same downstream as B5). Fix: write only what the spawn owns — `{"active": true, "pid": null, "bwrap_pid": null, "wid": null}` — and let `slot_reserve`/`_launch_slot` own identity (with the flag off the legacy path still writes `event_node`/`js_node` itself at `orchestrator.sh:_launch_slot`; keep a flag-off branch that includes them so that path stays byte-identical).

### B12. Watchdog proxy check deletes the pidfile
`modules/watchdog.sh:112` calls `_proxy_live_pid`, which (`modules/controller_proxy.sh:270-283`) `rm -f`s the slot's pidfile and unsets the cache on any dead/unverified pid — the watchdog PROCESS erases the orchestrator's on-disk proxy record. Harmless today only because the same poll escalates `SLOT_DIED`; if that escalation is suppressed (B3 dedup, or `dead` already set) the record is gone and `proxy_start_slot`'s idempotence check starts a SECOND evsieve on the next repoint. Fix: add a pure predicate in controller_proxy.sh — `_proxy_pid_verified_alive slot` = `kill -0` + `_proxy_pid_is_ours`, no forget — and call it from `_watchdog_proxy_dead`; keep `_proxy_forget_slot` in the command-side verbs (`proxy_stop_slot`). ARCHITECTURE §2 "watchdog fixes nothing itself" / CQS.

### B13. Name-matched delete on host /tmp, ineffective for the sandboxed path
`modules/instance_lifecycle.sh:1071` `rm -f /tmp/qtsingleapp-*` runs on the HOST before every spawn. Docked spawns have `--tmpfs /tmp` (`:451`) so the sandbox socket can never be stale; the handheld direct path is the only one it helps, and it also deletes every other QtSingleApplication socket the user has open (Prism Launcher, qBittorrent). Fix (PRINCIPLES #7 spirit):
```diff
-    rm -f /tmp/qtsingleapp-* 2>/dev/null || true
+    # Direct (handheld) launch only — docked sandboxes get a private --tmpfs /tmp.
+    # Restricted to PolyMC's own socket: a bare qtsingleapp-* glob also breaks
+    # every other QtSingleApplication app the user has open.
+    [[ -z "$js_node" ]] && rm -f /tmp/qtsingleapp-*[Pp]oly[Mm][Cc]* 2>/dev/null || true
```
(confirm the exact socket name PolyMC uses on the Deck with `ls /tmp/qtsingleapp-*` while it runs, and pin the glob to it.)

### B14. Legacy vendor alias with a re-embedded literal
`modules/instance_lifecycle.sh:509` reads `${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}` — an alias that exists only if controller_monitor was sourced first, plus a second copy of the literal (`runtime_context.sh:190` is canonical).
```diff
-        if [[ "$_js_vendor" == "${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}" ]]; then
+        if [[ "$_js_vendor" == "$MCSS_STEAM_VENDOR_ID" ]]; then
```
Delete the alias in `controller_monitor.sh:97-98` once no other reader remains.

### B15. `MCSS_STATE_LOCK` exported but never used
`modules/runtime_context.sh:80` exports it; both writers derive `"${state_file}.lock"` themselves (`instance_lifecycle.sh:778`, `orchestrator.sh:199`); `tests/test_slot_manager.sh:49` and `tests/test_reconnect_dispatch.sh:60` export it too. Fix: remove the export and the two test exports (the #50 comment explains why use-time derivation is right — that argues for deleting the constant, not keeping both), or add `_state_lock_path()` in instance_lifecycle and route both sites through it.

### B16. `MCSS_RECONNECT_GRACE_S` lives in slot_manager.sh
`modules/slot_manager.sh:66-71` defines an env-overridable `MCSS_*` outside `runtime_context.sh` (ARCHITECTURE §3 rung 1). Fix: move it into runtime_context's constants block (it is a tunable) or rename to `SLOT_MANAGER_RECONNECT_GRACE_S`; update the module header and `docs/DESIGN-38-RECONNECT-WIRING.md` mention.

### B17. Consumer-side fallbacks and magic literals
`modules/instance_lifecycle.sh:173,1198` `${MCSS_GEOM_DIR:-/tmp/mcss-geom}` (x2, duplicating `runtime_context.sh:327`); `:781` and `orchestrator.sh:199` `${MCSS_STATE_LOCK_TIMEOUT_S:-5}`; `slot_manager.sh:126` and `watchdog.sh:60` `${MCSS_MAX_PLAYERS:-4}`; `:707` `(( _i > 10 ))` warm-up; `:1087` `sleep 0.3`; `:960` `sleep 86400`; `:1077` `/tmp/splitscreen-bwrap-${slot}.log` fallback (predictable name in shared /tmp opened with `>>`); `:472` `$HOME/.steam/steam.pipe`; `:351` `RADV_SYS_MEM_LIMIT=50`; `instance_creation.sh:379` `/tmp/mcss-debug-api` (duplicated with `main_workflow.sh:61`), `:390` `e0M1UDsY`, `:560-563` volumes, `:588,621,616-617` `version:3465`/`maxFps:120`/distance 12. Fix: bare `$MCSS_GEOM_DIR`/`$MCSS_STATE_LOCK_TIMEOUT_S`/`$MCSS_MAX_PLAYERS` reads (modules already source runtime_context); name the rest (`INSTANCE_LIFECYCLE_PID_SEARCH_WARMUP_ITERS=10`, `INSTANCE_LIFECYCLE_LAUNCH_GRACE_S=0.3`, `INSTANCE_CREATION_OPTIONS_VERSION=3465`, …) in the guarded constants blocks; one `MCSS_DEBUG_API_DIR` shared with main_workflow; make the bwrap-log fallback `mktemp`-based or drop it (`LOG` is always set on the real launch path).

### B18. Dead code / stale plumbing
`modules/instance_creation.sh:267-270` — `"$instances_dir" != "$TARGET_DIR/instances"` can never be true (`instances_dir` is defined as exactly that at `:173`), so the "existing instance in a different location" branch and its `preserve_options_txt=true` are unreachable: delete. `modules/instance_lifecycle.sh:974` — `controllable/selected_controllers.json` rm: Controllable was replaced by Controlify, nothing writes it: delete. `:881-891` — `-Dorg.lwjgl.opengl.Window.title` is LWJGL 2 only (`:681-683` admits it): keep with a comment tying it to poll strategy 1, or drop with the JvmArgs merge machinery. `modules/orchestrator.sh:266-274` — `_find_slot_by_uniq` unused: delete (see B2).

### B19. rc 2 "already running" treated as failure — releases the live slot
`modules/instance_lifecycle.sh:941-947` documents return 2 as "slot is already active with a running bwrap" (do nothing); `modules/orchestrator.sh:463-465`'s single non-zero branch then wipes the running instance's pids from state, orphaning it (watchdog and reaper skip a slot with no `bwrap_pid`). Unreachable today (reserve is synchronous) but one silent reserve failure away.
```diff
-        if (( _si_rc != 0 )); then
-            echo "[orchestrator] spawn_instance failed for slot $_slot — slot released" >&2
-            update_slot_state "$_slot" '{"active": false, "pid": null, "bwrap_pid": null, "event_node": null, "js_node": null, "wid": null}'
-        else
+        if (( _si_rc == 2 )); then
+            echo "[orchestrator] spawn_instance: slot $_slot already running — not releasing" >&2
+        elif (( _si_rc != 0 )); then
+            echo "[orchestrator] spawn_instance failed for slot $_slot — slot released" >&2
+            update_slot_state "$_slot" '{"active": false, "pid": null, "bwrap_pid": null, "event_node": null, "js_node": null, "wid": null}'
+        else
```

### B20. bwrap required even for the handheld direct launch
`modules/instance_lifecycle.sh:934-938` gates every spawn on `command -v "$bwrap_cmd"`, but the `-z "$js_node"` branch at `:1048` builds `_build_direct_command` and never invokes bwrap. Harmless (preflight hard-requires bwrap) but it falsifies the direct path's "nothing to isolate" contract and blocks testing handheld on a box without bubblewrap. Fix: move the check under the two `elif` branches that build a bwrap command (T4.6 then needs a `js_node` argument — it already passes one).

### B21. errexit fragility when sourced standalone under `set -e`
`modules/instance_lifecycle.sh:322-323` — `_detect_xauthority`'s last pipeline returns 1 under `pipefail` when grep finds nothing, so `_xauth=$(_detect_xauthority)` (`:372,566`) fails; `:280` `read -r vendor product < <(_vp_of_js_node …)` returns 1 on empty output. Runtime flows run `set +e` (`orchestrator.sh:708,818`), so this only bites probes/harnesses that source the module under `set -euo pipefail` — where it yields an empty bwrap command ("died immediately") or a sandbox with NO controller bound, silently.
```diff
     ps -C kwin_wayland -o args= 2>/dev/null \
-        | grep -oP '(?<=--xwayland-xauthority )\S+' | head -1
+        | grep -oP '(?<=--xwayland-xauthority )\S+' | head -1 || true
```
```diff
-    read -r vendor product < <(_vp_of_js_node "$js_node")
+    read -r vendor product < <(_vp_of_js_node "$js_node") || true
```

### B22. `teardown_instance` blocks the FIFO loop up to 10 s per hung slot (Info)
`modules/instance_lifecycle.sh:1222-1236` — the SIGTERM grace loop runs synchronously inside `_handle_msg`; a hung JVM stalls every other event (including `DISPLAY_MODE_CHANGE`) for `INSTANCE_LIFECYCLE_TEARDOWN_GRACE_S`. Bounded (PRINCIPLES #6 satisfied); [KNOWN: `docs/TODO.md:307`]. No action beyond that TODO.

### B23. "newest/first" comment vs `head -n 1` = LOWEST slot (Info)
`modules/slot_manager.sh:211` comments "newest/first" but jq preserves key insertion order (`"1"…"4"`), so a clone multi-match resumes the lowest-numbered slot; `tests/test_slot_manager.sh:134-146` accepts either. Only matters for counterfeit duplicate MACs. Fix the comment (`# lowest slot; multi only on clones`) or sort by `disconnected_at` descending in `slot_find_by_uniq`.

### B24. Keeper subshells are untracked PIDs that outlive `cleanup()` (Info)
`modules/instance_lifecycle.sh:1114-1161`, `modules/orchestrator.sh:1094-1105` — `_SPAWN_PIDS` tracks only the brace group; `kill -TERM $_sp` reparents the keepers, which keep calling `dex_*` against a torn-down X server for up to 90 s (bounded, errors swallowed). Fix after B9: record each keeper's `$!` in a module array (`_INSTANCE_LIFECYCLE_KEEPER_PIDS`) that `cleanup()` walks with `kill -TERM` (PRINCIPLES #7 "track every PID you spawn").

### B25 (+C12). Two instance-number derivations; required-mod check is a PREFIX match
`modules/instance_creation.sh:333` (`${instance_name##*-}`) vs `:557` (`grep -oE '[0-9]+$'`) — same datum, two encodings (#9): compute once and reuse. `:470` `[[ "$mod_name" == "$req"* ]]` and the same pattern at `modules/mod_management.sh:1984`, `:2102` — glob prefix, so an optional "Sodium Extra" / "Sodium Options API" failing to download is reported as CRITICAL "Sodium", and (C12) any optional mod whose name starts with a required mod's name is hidden from selection and force-installed. Latent while every `mods.conf` entry is `required`, but `mods.conf`'s own examples start with "Sodium".
```diff
-                if [[ "$mod_name" == "$req"* ]]; then
+                if [[ "$mod_name" == "$req" ]]; then
```
Better: compare by `(platform, id)` via `REQUIRED_SPLITSCREEN_IDS`/`REQUIRED_SPLITSCREEN_PLATFORMS` (`install-minecraft-splitscreen.sh:366-367`) at all three sites.

### B26. `handle_instance_update` sed edits unescaped for `&`/`|` in `JAVA_PATH` (Info)
`modules/instance_creation.sh:824` `sed -i "s|^JavaPath=.*|JavaPath=$JAVA_PATH|"` corrupts the line for a path containing `&` or `|`; `setInstanceCfgValue` (instance_lifecycle.sh) already escapes these. Moot while B6's clobber stands; once B6 lands the in-place edit is the only writer, so reuse `setInstanceCfgValue` behind a guarded `type` check (ARCHITECTURE §1) or copy its escaping.

### B27. Redundant guards and a duplicated Controlify write (Info)
`modules/instance_lifecycle.sh:994` and `modules/instance_creation.sh:743` — `command -v jq` guards (jq is a preflight hard requirement and `read_state` already depends on it): drop. `:996` vs `instance_creation.sh:745` — the same `jq '.global.out_of_focus_input = true'` in two products (documented belt-and-suspenders for #95, but two encodings of one fact): source the expression from one constant. `:1043` vs `:275` — the flag+js_node proxy gate evaluated twice: remove one.

### B28. `create_instances` unconditionally re-enables errexit (Info)
`modules/instance_creation.sh:199,284` `set +e` … `set -e` vs `:311-312,764-766` (`install_fabric_and_mods` saves/restores `$-`). Inconsistent only; the installer entry always runs with `-e`. [KNOWN: `docs/CODE-REVIEW-2026-07-21-CLOSED.md:18`, `docs/TODO.md:234`]. Align to the save/restore pattern when next touching the function.

## Hardware verification
Most items are CI + unit test only (B10, B14-B18, B21-B23, B25-B28 — installer/standalone/hygiene). For the runtime-touching ones, one docked 2-pad session (stage3_hotplug + stage6_teardown) after they land: B13 — open Prism Launcher (or any QtSingleApplication app) on the desktop side, launch splitscreen handheld, confirm the other app's `/tmp/qtsingleapp-*` socket survives and PolyMC still starts; B12/B19/B20/B24 — a normal 2-up launch, a quit and a session exit with `grep -E 'proxy|already running|keeper' /tmp/splitscreen-debug-latest.log` showing no `command not found`, no second evsieve per slot (`pgrep -af evsieve | wc -l` equals the number of live slots), and no keeper processes left after exit; B11 — unplug/replug a pad within 1 s of its `CONTROLLER_ADD` and confirm `jq '.slots["N"].event_node'` ends on the NEW node.

## References
Review IDs: B10-B28, C12 (merged into B25), B2 (the `_find_slot_by_uniq` deletion in B18). PRINCIPLES #1, #5, #6, #7, #8, #9; ARCHITECTURE §1-§3. Related: #14 (B22 teardown timing for a hung JVM), #135 (B24 orphaned keepers at session end), #95 (B27 Controlify seed), #50/#86 (B15/B17 constant-naming history), `docs/BUG-AUDIT-2026-06-24-followup.md:102-110` (B17 /tmp class).
