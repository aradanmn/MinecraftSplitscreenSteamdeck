# Review B — instance lifecycle / creation / slot manager / watchdog

Files read fully: `modules/instance_lifecycle.sh` (1276 lines), `modules/instance_creation.sh` (862),
`modules/slot_manager.sh` (279), `modules/watchdog.sh` (229). Cross-module contracts traced in
`modules/orchestrator.sh` (`_launch_slot`, `_handle_msg`, `cleanup`, `_find_*`, `_collect_mask_pairs`),
`modules/controller_proxy.sh` (`proxy_start_slot`, `proxy_stop_slot`, `proxy_quiesce_slot`,
`proxy_virtual_nodes`, `_proxy_live_pid`), `modules/dex.sh` (list/search output format),
`modules/controller_monitor.sh` (`parse_input_device_blocks` 8-field emit), `modules/runtime_context.sh`
(flag defaults), `tests/test_reconnect_dispatch.sh`, `tests/test_slot_manager.sh`.

Two facts that shaped the review:
- `MCSS_CONTROLLER_PROXY` defaults to **1** (`runtime_context.sh:210`), so the `slot_claim`/`slot_free` path is
  the shipped path, not the dark one.
- errexit is **off** for the whole runtime event loop: `handheld_flow()` and `docked_flow()` both begin with
  `set +e` (`orchestrator.sh:708,818`). Verified empirically that a backgrounded brace group inherits errexit
  from a plain call and dies at the first failing command, but that `set +e` in the enclosing function disables
  it. So "set -e kills the spawn-failure release path" is NOT a runtime bug; it is only a standalone-sourcing
  fragility (see B21).

---

### B1. SLOT_DIED (proxy on) frees the slot BEFORE teardown, so the process kill is skipped and stale pid/wid poison the slot's next occupant
- **Severity:** Critical
- **Category:** bug
- **File:** `modules/instance_lifecycle.sh:1200-1203` (guard), `modules/instance_lifecycle.sh:1250` (the only writer that nulls `pid/bwrap_pid/wid/js_node`), `modules/slot_manager.sh:274-279` (`slot_free` clears identity only), `modules/orchestrator.sh:634-640` (call order), `modules/watchdog.sh:183-199` (stale-wid escalation), `modules/instance_lifecycle.sh:1058` (spawn's reserve write does not null `wid`)
- **Status:** CONFIRMED (by code trace; not covered by any test — `tests/test_reconnect_dispatch.sh:43` stubs `teardown_instance`, so `test_on_slot_died_stops_and_frees` asserts only call order and can never see the real guard)
- **What:** With the proxy flag on, the SLOT_DIED handler runs `slot_free "$slot"` (writes `active:false`) and only THEN `teardown_instance "$slot"`. `teardown_instance` runs its two idempotent cleanups, then hits
  ```bash
  if ! slot_is_active "$slot"; then
      echo "[teardown_instance] Slot $slot is not active, nothing to tear down" >&2
      return 0
  fi
  ```
  and returns without sending SIGTERM/SIGKILL to the bwrap group and without executing line 1250 (`{"active": false, "pid": null, "bwrap_pid": null, "event_node": null, "js_node": null, "wid": null}`). `slot_free` only nulls `phys_*`/`event_node`/`disconnected*`, so `pid`, `bwrap_pid`, `wid`, `js_node` survive on the now-inactive slot. The #174 commit message on `teardown_instance` even records the symptom ("a normal quit logged only 'Slot 1 is not active, nothing to tear down'") and fixed only the geom/proxy cleanups, not the skipped kill.
- **Failure scenario:**
  1. **Hung JVM never killed (defeats #37 Bug B).** Player quits in-game; window destroyed; JVM hangs in shutdown. Watchdog emits SLOT_DIED (window gone). Handler: `slot_free` → `teardown_instance` no-ops. The hung JVM (3 GiB heap) and its bwrap/PolyMC tree live on, untracked. `cleanup()` → `teardown_all_instances` iterates `get_active_slots` only, so they also survive session exit.
  2. **Next occupant of the slot is killed ~4 s into its launch.** A new pad claims the freed slot (`slot_claim` → SPAWN). `spawn_instance` line 1058 writes `active:true, pid:null, bwrap_pid:null` but NOT `wid`, so the dead window's WID is still in state. Watchdog: `bwrap_pid` empty → not dead; `wid` non-empty → `_watchdog_window_present` returns 1 (window genuinely destroyed) twice → `SLOT_DIED` for the launching slot after 2 ticks. The handler frees the slot again while the new bwrap/PolyMC/java keep launching — an unmanaged orphan instance appears on screen, not in any layout, and the slot is handed out a third time.
  3. Re-spawn on the slot inherits the old hung JVM via `_poll_for_java`'s `pgrep ... | head -1` (lowest pid = oldest process) — see B4.
  Flag OFF is unaffected (teardown runs while `active` is still true), so this is a PR-c-wiring regression that shipped with the #150 default flip.
- **Fix:** In `orchestrator.sh` SLOT_DIED, call `teardown_instance "$slot"` FIRST, then `proxy_stop_slot`/`slot_free`. Independently harden the module (PRINCIPLES #5/#1): make `teardown_instance`'s guard about *processes*, not the flag — e.g. read `bwrap_pid`/`pid`/`wid` first and skip only when all three are empty; always execute the line-1250 write. Also make `spawn_instance`'s reserve write at line 1058 include `"wid": null` so no earlier occupant's WID can ever be evaluated against a new incarnation. Add a dispatch test that uses the REAL `teardown_instance` against a live `sleep` PID and asserts the PID is gone (mutation-test per PRINCIPLES #4).

### B2. Orchestrator keeps raw-jq near-duplicates of the slot_manager verbs and reads `.slots`/`.mode` outside the accessors
- **Severity:** Medium
- **Category:** principle-violation
- **File:** `modules/orchestrator.sh:168` (`_get_mode` raw jq), `modules/orchestrator.sh:226-233` (`_find_free_slot` ≡ `slot_find_free`), `modules/orchestrator.sh:246-253` (`_find_slot_by_event_node` ≡ `slot_find_by_event_node`), `modules/orchestrator.sh:266-274` (`_find_slot_by_uniq` ≡ `slot_find_by_uniq`, and DEAD — header line 58 says "defined (unused)"), `modules/orchestrator.sh:286-296` (`_collect_mask_pairs` raw `.slots` walk), `modules/slot_manager.sh:45-48` (header promises PR-c retires them)
- **Status:** CONFIRMED
- **What:** ARCHITECTURE §2 says "ALL state-file reads go through [instance_lifecycle's] accessors — no raw jq elsewhere", and PRINCIPLES #1/#9 want one encoding. `slot_manager.sh`'s header states "PR-c retires the orchestrator's near-duplicate `_find_free_slot` / `_find_slot_by_uniq` / `_find_slot_by_event_node` in favor of the `slot_find_*` verbs" — but all three still exist, two are still called (`_handle_msg` REMOVE path uses `_find_slot_by_event_node` at 599; legacy ADD uses `_find_free_slot` at 564), and the jq bodies are byte-for-byte parallel copies of `slot_manager.sh:104-120`. `_get_mode` and `_collect_mask_pairs` also read the state file directly. Also stale: `slot_manager.sh:15-19` still says "DARK ON ARRIVAL … ZERO runtime callers", which is false since PR-c.
  Full raw-`jq`-on-state inventory across `modules/`: instance_lifecycle.sh (owner, OK), slot_manager.sh:104-174 (designated per-slot owner, OK per PRINCIPLES #1's list of accessor verbs), orchestrator.sh:168/250/271/291 (bypasses). All other `jq` hits in `modules/` operate on API JSON, not the state file.
- **Failure scenario:** Schema drift — a future change to how "active" or "event_node" is stored (e.g. moving identity under a sub-object for #38 follow-ups) is applied in `slot_manager` and silently missed in the orchestrator copies; CONTROLLER_REMOVE then resolves to "no active slot" and drops the abandoned-mark.
- **Fix:** Delete `_find_slot_by_uniq`; replace `_find_free_slot`→`slot_find_free`, `_find_slot_by_event_node`→`slot_find_by_event_node`; add `slot_mask_pairs_excluding(slot)` and a `get_mode` accessor in instance_lifecycle/slot_manager and route `_get_mode`/`_collect_mask_pairs` through them. Refresh the slot_manager header.

### B3. Watchdog dedup is keyed on slot only — a slot freed and re-claimed within one poll interval is never re-armed
- **Severity:** Medium
- **Category:** logic
- **File:** `modules/watchdog.sh:212-226`
- **Status:** PLAUSIBLE (timing-dependent; the fast path in B1 makes the window realistic)
- **What:** `_WATCHDOG_REPORTED[$slot]=1` is cleared only in the `else` branch, i.e. only when a poll observes `active != true`. The SLOT_DIED handler now runs in well under a second (teardown no-ops per B1; `slot_free` + `_reflow_layout`), and a CONTROLLER_ADD queued behind it (returning pad, startup-acquire straggler) re-reserves the same slot with `active:true`. If both happen inside one `sleep "$poll_interval"` (2 s), the watchdog never sees the inactive gap.
- **Failure scenario:** Slot 2's first occupant dies → reported. Slot 2 is freed and re-claimed within 2 s. The second occupant later quits (window gone) → `dead=true` but `_WATCHDOG_REPORTED[2]` is still set → no SLOT_DIED. `_reap_dead_slots` only covers the process-dead case, so a hung-JVM/black-screen slot is never reclaimed.
- **Fix:** Key the dedup on the incarnation: store `_WATCHDOG_REPORTED[$slot]="$bwrap_pid"` and treat `${_WATCHDOG_REPORTED[$slot]} != "$bwrap_pid"` (or an empty→non-empty bwrap_pid transition) as a new incarnation; likewise reset `_WATCHDOG_WINDOW_GONE_COUNT` when `wid` changes.

### B4. Startup reset orphans a crashed session's instances, and `_poll_for_java`'s `pgrep | head -1` then binds the NEW slot to the OLD JVM
- **Severity:** Medium
- **Category:** robustness
- **File:** `modules/instance_lifecycle.sh:151-165` (`_ensure_state_file` "Always reset"), `modules/instance_lifecycle.sh:628` (`pgrep -af "$search_pattern" | head -1`), `modules/instance_lifecycle.sh:652` (`_collect_slot_pids` roots on every match)
- **Status:** PLAUSIBLE (each step confirmed in code; the combined scenario requires a prior crash or B1's orphan)
- **What:** `_ensure_state_file` discards the previous state (including its recorded `bwrap_pid`/`pid`) without attempting to reap them. `_poll_for_java` matches ANY process whose cmdline contains `instances/latestUpdate-N/natives` and takes the first (lowest PID = oldest). `_collect_slot_pids` feeds every match into the window search.
- **Failure scenario:** Session A crashes (or leaks via B1) leaving `latestUpdate-2`'s JVM alive. Session B spawns slot 2: `_poll_for_java` returns the OLD JVM's pid before the new one even starts; `_poll_for_window` may find the OLD window (`dex_search --pid`) and store its WID; `apply_layout` positions the stale window; the watchdog later fires SLOT_DIED for the new instance when the old JVM finally exits. `teardown_instance` then group-kills only the new bwrap's group — the old JVM survives again.
- **Fix:** Before the reset in `_ensure_state_file`, read each slot's recorded `bwrap_pid`/`pid`, identity-verify via `/proc/<pid>/cmdline` containing the slot's `instances/<prefix><slot>/` marker (the pattern `controller_proxy.sh:_proxy_pid_is_ours` already uses — PRINCIPLES #7 compliant because these are PIDs a previous incarnation of this launcher started and recorded), and SIGTERM/SIGKILL them. In `_poll_for_java`, restrict to descendants of `$bwrap_pid` (`pgrep -P` walk from the tracked leader) instead of a global name match.

### B5. `slot_claim` REJECTs a known pad whose event node silently changed, leaving stale identity that can never be released
- **Severity:** Medium
- **Category:** logic
- **File:** `modules/slot_manager.sh:209-221`
- **Status:** CONFIRMED (decision-matrix gap; the underlying "no udev remove" case is disclosed as a pre-existing defect in `orchestrator.sh:578-590`'s comment, but that comment covers the flag-off path only)
- **What:** Step 1: known `uniq` on an active slot that is NOT flagged disconnected → `REJECT`, no mutation, regardless of whether `$ev` equals the stored `event_node`. A pad that re-enumerates without a processed CONTROLLER_REMOVE (USB autosuspend, driver reset, remove event lost during a burst, or the REMOVE arriving after the ADD on a fast flap) therefore keeps the OLD `event_node` in state.
- **Failure scenario:** Pad on slot 2 was `/dev/input/event7`; it re-appears as `event9` with no REMOVE processed. `slot_claim A … event9` → REJECT. Proxy evsieve keeps waiting on the `slot2` symlink → `event7` (persist=reopen); if the kernel reuses `event7` for a different pad, slot 2's sandbox is driven by the wrong player; if not, slot 2 is input-dead. A later real REMOVE of `event9` is looked up by event node → no match → the slot is never marked disconnected, so it can't be resumed/adopted and only a window-gone SLOT_DIED frees it.
- **Fix:** In step 1, compare `$ev` with `_get_slot_field "$slot" event_node`; if different, `slot_touch "$slot" "$ev"` and return `RESUME $slot` (the orchestrator's RESUME path already re-points evsieve). Keep REJECT only for the exact-echo case (same node). Add the case to the `test_slot_manager.sh` matrix.

### B6. `create_instances` runs the whole Fabric+mod install TWICE per instance on the update path and discards `handle_instance_update`'s instance.cfg edits
- **Severity:** Medium
- **Category:** logic
- **File:** `modules/instance_creation.sh:207-209` (calls `handle_instance_update`), `modules/instance_creation.sh:839` (which itself calls `install_fabric_and_mods … true`), `modules/instance_creation.sh:225-243` (then instance.cfg is rewritten from scratch), `modules/instance_creation.sh:251` (mmc-pack.json rewritten again), `modules/instance_creation.sh:280` (second `install_fabric_and_mods`), `modules/instance_creation.sh:817-836` (the sed edits that get overwritten)
- **Status:** CONFIRMED
- **What:** For an existing instance, `handle_instance_update` clears mods, seds `instance.cfg`, calls `install_fabric_and_mods` (instance 1 downloads every mod; 2-N copy), restores options.txt, writes mmc-pack.json, and echoes true/false. `create_instances` then overwrites `instance.cfg` with the fresh heredoc (so the sed edits — and any user customisation of instance.cfg such as a hand-tuned `JvmArgs` — are thrown away, contradicting "Your existing settings and preferences will be preserved" at line 787), rewrites mmc-pack.json, and calls `install_fabric_and_mods` a second time. Because the first call runs inside `$(…)`, its `MISSING_MODS+=` additions are lost in the subshell and only the second run's survive.
- **Failure scenario:** 4-instance update with 12 mods: 24 Modrinth/CurseForge downloads instead of 12, "Downloading mods for first instance..." printed twice, and a user's custom `JvmArgs`/`MaxMemAlloc` in instance.cfg silently reset.
- **Fix:** Make `handle_instance_update` do only what its name says (clear mods, back up options.txt, return the flag) and drop its `install_fabric_and_mods`/`write_mmc_pack_json` calls, OR have `create_instances` `continue` after `handle_instance_update` returns. Either way the instance.cfg rewrite at 225 should merge (`setInstanceCfgValue`) rather than clobber on the update path.

### B7. `install_fabric_and_mods` carries its own 5-tier Modrinth version ladder, ending in an "any Fabric release" fallback that ignores the target MC version
- **Severity:** Medium
- **Category:** principle-violation
- **File:** `modules/instance_creation.sh:401-443`
- **Status:** CONFIRMED; [KNOWN-adjacent: `docs/IMPROVEMENTS-ANALYSIS-2026-08-15.md:294,373` (#88 ladder consolidation) — but that consolidation counted "Modrinth ×2" in mod_management/version_management; this copy in instance_creation was not retired]
- **What:** Four near-identical inline `jq` filters (exact / major.minor / `major.minor.x` / previous patch) duplicate `match_modrinth_version` (`mod_management.sh:221`), and then line 441 adds a tier the canonical ladder deliberately does not have:
  ```bash
  mod_url=$(printf "%s" "$resolve_data" | jq -r '.[] | select(.loaders[] == "fabric") | (.files | map(select(.primary)) | .[0].url) // (.files[0].url)' … | head -n1)
  ```
  i.e. take the first Fabric file for ANY Minecraft version, with none of `_version_fallback_allowed`'s gating.
- **Failure scenario:** Dependency X only publishes for MC 1.20.x; target is 1.21.4. Tiers 1-4 miss; tier 5 picks a 1.20 jar → installed → Fabric refuses to load the mod (or crashes) on every instance.
- **Fix:** Replace the block with `match_modrinth_version "$resolve_data" "$MC_VERSION"` and drop the any-version tier (PRINCIPLES #9, ARCHITECTURE §2 "version-match policy lives here ONCE").

### B8. Mod jars are downloaded and later executed with no integrity verification although Modrinth supplies hashes
- **Severity:** Medium
- **Category:** security
- **File:** `modules/instance_creation.sh:402-441` (URL selection discards `.files[].hashes`), `modules/instance_creation.sh:501` (`fetch_url "$mod_url" "$mod_file" 0`)
- **Status:** CONFIRMED (no `sha1`/`sha512`/`hashes`/`checksum` reference anywhere in instance_creation.sh, mod_management.sh or utilities.sh)
- **What:** Every Modrinth `version.files[]` carries `hashes.sha1`/`hashes.sha512`; the URL is taken and the hash ignored, so a truncated CDN download, a stale mirror, or a tampered CDN object is written straight into `.minecraft/mods/` and loaded into the JVM (the installer's `java_management.sh:196` does verify the JDK checksum, so the pattern already exists in-repo).
- **Failure scenario:** A partial download (fetch_url timeout 0, but a reset mid-stream) leaves a truncated jar → Fabric fails at startup for all four instances with an opaque zip error.
- **Fix:** Select `.files[] | select(.primary) | [.url, .hashes.sha512]` and verify with `sha512sum -c` after `fetch_url`; delete and record in `MISSING_MODS` on mismatch. CurseForge's `/mods/{id}/files/{fileId}` also returns `hashes` (algo 1 = sha1).

### B9. Title-keeper and map-keeper background subshells hold the capture pipe — handheld_flow blocks up to ~90 s before entering its event loop
- **Severity:** Medium
- **Category:** principle-violation
- **File:** `modules/instance_lifecycle.sh:1114-1121` (title-keeper `( … ) &`), `modules/instance_lifecycle.sh:1149-1161` (map-keeper `( … ) &`, with a bare `echo … >&2` at 1156), `modules/orchestrator.sh:754` (`spawn_instance 1 "" "" 2>&1 | sed … >&2 || true`), `modules/orchestrator.sh:460` (mktemp-failure fallback pipes too)
- **Status:** CONFIRMED
- **What:** Neither keeper redirects its stdout/stderr off the fds it inherits. In `handheld_flow` `spawn_instance` is run synchronously through `2>&1 | sed`; the pipeline only completes when every writer of the pipe closes, i.e. when the map-keeper exits (45 × 2 s ≈ 90 s) — exactly the #80/#103 class PRINCIPLES #8 forbids. In the docked path the keepers inherit `>"$_si_log"`, which is `sed`'d and unlinked by the EXIT trap as soon as `spawn_instance` returns, so their "re-mapped unmapped window" diagnostics are written to a deleted file and lost.
- **Failure scenario:** Handheld launch: the window appears; for the next ~90 s `_reap_dead_slots`, `_check_monitor_heartbeats`, SLOT_DIED and DISPLAY_MODE_CHANGE (user docks during loading) are not processed. If the game crashes in that window the user stares at a black screen until the keeper loop times out.
- **Fix:** Redirect both keepers: `( … ) >>"${LOG:-/dev/null}" 2>&1 </dev/null &` (and drop the `>&2` at 1156 in favour of that log), per PRINCIPLES #8. Optionally record their PIDs so `cleanup()` can signal them (they are children of the spawn subshell and survive `kill $_sp`).

### B10. `_ensure_state_file` is called outside the lock from `update_slot_state`, and both writers embed schema literals that drift from slot_manager's fields
- **Severity:** Low
- **Category:** robustness
- **File:** `modules/instance_lifecycle.sh:765-768` (init-if-missing before `flock`), `modules/instance_lifecycle.sh:157-165` (4-slot literal schema without `phys_*`/`disconnected*`)
- **Status:** CONFIRMED
- **What:** If the state file is missing, two concurrent `update_slot_state` calls (background spawns) each call `_ensure_state_file` BEFORE taking the lock; the second reset can erase the first's merge. `_set_mode` does the same init inside its lock, so the two writers disagree on ordering. The initializer also hardcodes exactly four slots (`"1"…"4"`) independent of `MCSS_MAX_PLAYERS` and omits the slot_manager fields, so `_get_slot_field … disconnected` on a fresh file relies on the jq `//` default rather than the schema.
- **Failure scenario:** Startup burst with the state file deleted between `main()`'s init and the first ADD (unlikely but possible via a stale-cleanup path) → one reservation lost → double-spawn on one slot.
- **Fix:** Move the `[[ ! -f "$state_file" ]] && _ensure_state_file` inside the `flock` subshell; generate the slot map from `MCSS_MAX_PLAYERS` with `jq -n --argjson n …`, including the slot_manager fields (one schema, PRINCIPLES #9).

### B11. `spawn_instance`'s late reserve write can clobber a RESUME'd `event_node`
- **Severity:** Low
- **Category:** bug (race)
- **File:** `modules/instance_lifecycle.sh:1058`, `modules/slot_manager.sh:191-195` (`slot_touch`)
- **Status:** PLAUSIBLE (window = the time between `_launch_slot` backgrounding and line 1058: cfg edits + `proxy_start_slot`'s virtual-node poll, typically 0.2-2 s)
- **What:** Line 1058 writes the spawn's ORIGINAL `event_node`/`js_node` from local variables, not from state. If the pad drops and returns inside that window, `slot_release` + `slot_claim→RESUME→slot_touch` have already updated `event_node` to the new node; line 1058 then reverts it.
- **Failure scenario:** State says `event7` while the proxy was re-pointed to `event9`; a later REMOVE of `event9` finds no slot → never marked disconnected (same downstream as B5).
- **Fix:** At line 1058 write only what the spawn owns (`active`, `pid`, `bwrap_pid`, `wid:null`) and let `slot_reserve`/`_launch_slot` own identity; or re-read `event_node` from state immediately before the write.

### B12. Watchdog's proxy check mutates proxy state (deletes the pidfile) — a read path with a destructive side effect
- **Severity:** Low
- **Category:** principle-violation
- **File:** `modules/watchdog.sh:112` (`_proxy_live_pid` call), `modules/controller_proxy.sh:270-283` (`_proxy_live_pid` → `_proxy_forget_slot` on any dead/unverified pid)
- **Status:** CONFIRMED
- **What:** ARCHITECTURE §2 says the watchdog "fixes nothing itself" and PRINCIPLES' CQS note says queries don't mutate, but `_proxy_live_pid` `rm -f`s the slot's pidfile and unsets the cache when the pid is dead OR fails the identity check. The watchdog process therefore erases the orchestrator's on-disk proxy record. It works today only because the same poll immediately escalates SLOT_DIED; if that escalation is ever suppressed (B3 dedup, or `dead` already set), the proxy record is gone and `proxy_start_slot`'s idempotence check will start a SECOND evsieve on the same pad symlink on the next repoint/start.
- **Failure scenario:** Slot in `_WATCHDOG_REPORTED` (B3) with a crashed evsieve: pidfile deleted silently, no SLOT_DIED, next RESUME → `proxy_repoint_slot` sees no proxy.
- **Fix:** Give the watchdog a pure predicate (e.g. `_proxy_pid_verified_alive slot` that does the `kill -0` + `_proxy_pid_is_ours` without forgetting), and keep `_proxy_forget_slot` in the command-side verbs (`proxy_stop_slot`).

### B13. `rm -f /tmp/qtsingleapp-*` is a name-matched delete on shared host /tmp and is ineffective for the sandboxed path
- **Severity:** Low
- **Category:** robustness
- **File:** `modules/instance_lifecycle.sh:1071`
- **Status:** CONFIRMED
- **What:** Runs on the HOST before every spawn. For docked spawns the sandbox has `--tmpfs /tmp` (line 451), so PolyMC's QtSingleApplication socket lives in a fresh tmpfs and can never be stale — the host rm does nothing for that path. For the handheld direct path it does matter, but it also deletes every other `qtsingleapp-*` socket/lockfile on the host (Prism Launcher, qBittorrent, any QtSingleApplication app the user has open), breaking their single-instance behaviour. Same spirit as PRINCIPLES #7 (name-matched blast radius).
- **Failure scenario:** User has Prism Launcher open on the desktop while launching splitscreen; its socket is removed; the next Prism launch opens a duplicate instance.
- **Fix:** Guard with `[[ -z "$js_node" ]]` (direct path only) and restrict the glob to PolyMC's own name (`/tmp/qtsingleapp-PolyMC-*` or whatever `QtSingleApplication` id PolyMC uses), or set `TMPDIR` to a per-slot dir for the direct launch instead.

### B14. Legacy vendor alias with a re-embedded literal instead of the canonical constant
- **Severity:** Low
- **Category:** hardcoded
- **File:** `modules/instance_lifecycle.sh:509` (`"${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}"`), `modules/controller_monitor.sh:97-98` (alias defined from `MCSS_STEAM_VENDOR_ID`), `modules/runtime_context.sh:190` (canonical)
- **Status:** CONFIRMED
- **What:** ARCHITECTURE §3 corollary: consumers use the bare canonical `MCSS_*` name; a `:-` fallback re-embeds the literal. Here the module reads a legacy alias that only exists if controller_monitor was sourced first, and embeds `28de` a second time.
- **Fix:** `[[ "$_js_vendor" == "$MCSS_STEAM_VENDOR_ID" ]]`; delete the alias once no other reader remains.

### B15. `MCSS_STATE_LOCK` is exported but never used; both writers derive their own `.lock` path
- **Severity:** Low
- **Category:** dead-code
- **File:** `modules/runtime_context.sh:80` (export), `modules/instance_lifecycle.sh:778` (`lock_file="${state_file}.lock"`), `modules/orchestrator.sh:199` (same), `tests/test_slot_manager.sh:49`, `tests/test_reconnect_dispatch.sh:60` (tests also export it, still unused)
- **Status:** CONFIRMED
- **What:** "A constant's existence obligates its use" (ARCHITECTURE §3). The #50 comment explains why use-time derivation is preferred (tests re-point `SPLITSCREEN_STATE` after sourcing), which is a fine reason to delete the export, not to keep both.
- **Fix:** Remove the export (and the test exports), or convert both sites to a `_state_lock_path()` helper in instance_lifecycle that derives from `SPLITSCREEN_STATE` and delete the literal `.lock` duplication.

### B16. `MCSS_RECONNECT_GRACE_S` is an `MCSS_*` global defined outside `runtime_context.sh`
- **Severity:** Low
- **Category:** principle-violation
- **File:** `modules/slot_manager.sh:66-71`
- **Status:** CONFIRMED
- **What:** ARCHITECTURE §3 rung 1: "Never define an `MCSS_*` anywhere else on the runtime side"; single-module constants are `MODULENAME_UPPER`. It is env-overridable, which the ladder says belongs at the canonical home only.
- **Fix:** Either move it to runtime_context's constants block (it is read by one module, but is a tunable) or rename to `SLOT_MANAGER_RECONNECT_GRACE_S`.

### B17. Consumer-side fallbacks and magic literals in logic
- **Severity:** Low
- **Category:** hardcoded
- **File:** `modules/instance_lifecycle.sh:173,1198` (`${MCSS_GEOM_DIR:-/tmp/mcss-geom}` ×2, duplicating `runtime_context.sh:327`), `modules/instance_lifecycle.sh:781` and `modules/orchestrator.sh:199` (`${MCSS_STATE_LOCK_TIMEOUT_S:-5}`, duplicating `runtime_context.sh:197`), `modules/slot_manager.sh:126` and `modules/watchdog.sh:60` (`${MCSS_MAX_PLAYERS:-4}`), `modules/instance_lifecycle.sh:707` (`(( _i > 10 ))` warm-up before PID search = 5.5 s at 0.5 s interval), `modules/instance_lifecycle.sh:1087` (`sleep 0.3` liveness grace), `modules/instance_lifecycle.sh:960` (`sleep 86400`), `modules/instance_lifecycle.sh:1077` (`/tmp/splitscreen-bwrap-${slot}.log` fallback), `modules/instance_lifecycle.sh:472` (`$HOME/.steam/steam.pipe`), `modules/instance_lifecycle.sh:351` (`RADV_SYS_MEM_LIMIT=50`), `modules/instance_creation.sh:379` (`/tmp/mcss-debug-api`, duplicated with main_workflow's clear site), `modules/instance_creation.sh:390` (`e0M1UDsY` Collective project id), `modules/instance_creation.sh:560-563` (`0.3`/`1.0`/`0.0` volumes), `modules/instance_creation.sh:588,621,616-617` (`version:3465`, `maxFps:120`, render/simulation distance 12)
- **Status:** CONFIRMED
- **What:** Each is either a second copy of a value that has a canonical home (drift risk, PRINCIPLES #9) or an unnamed tunable in logic (ARCHITECTURE §3 corollary). The `/tmp/splitscreen-bwrap-<slot>.log` fallback is additionally a predictable name in shared `/tmp` opened with `>>` (symlink-append hazard; same class as the N6/N7 `/tmp` items in `docs/BUG-AUDIT-2026-06-24-followup.md:102-110`, though `LOG` is always set on the real launch path).
- **Fix:** Bare `$MCSS_GEOM_DIR`/`$MCSS_STATE_LOCK_TIMEOUT_S`/`$MCSS_MAX_PLAYERS` reads (the modules already source runtime_context); name the rest (`INSTANCE_LIFECYCLE_PID_SEARCH_WARMUP_ITERS`, `INSTANCE_LIFECYCLE_LAUNCH_GRACE_S`, `INSTANCE_CREATION_OPTIONS_VERSION`, …); route the debug dir through one constant shared with main_workflow.

### B18. Dead code / stale plumbing
- **Severity:** Low
- **Category:** dead-code
- **File:** `modules/instance_creation.sh:267-270` (`"$instances_dir" != "$TARGET_DIR/instances"` can never be true — `instances_dir` is defined as exactly that at line 173, so the "existing instance in a different location" branch and its `preserve_options_txt=true` are unreachable), `modules/instance_lifecycle.sh:974` (`controllable/selected_controllers.json` — Controllable was replaced by Controlify; nothing writes this file), `modules/instance_lifecycle.sh:881-891` (`-Dorg.lwjgl.opengl.Window.title` is an LWJGL 2 property; lines 681-683 admit LWJGL 3 ignores it — the JvmArgs merge machinery only serves poll strategy 1, which "rarely hits"), `modules/orchestrator.sh:266-274` (`_find_slot_by_uniq`, unused — see B2)
- **Status:** CONFIRMED
- **Fix:** Delete the unreachable branch and the Controllable rm; keep or drop the title property with a comment tying it to strategy 1; delete `_find_slot_by_uniq`.

### B19. `spawn_instance` return code 2 ("already running") is treated by the caller as a failure that RELEASES the live slot
- **Severity:** Low
- **Category:** logic (contract mismatch)
- **File:** `modules/instance_lifecycle.sh:941-947` (return 2), `modules/orchestrator.sh:463-465` (`(( _si_rc != 0 ))` → `active:false, pid:null, bwrap_pid:null, …`)
- **Status:** CONFIRMED (unreachable today because `_launch_slot` is only reached for a slot `slot_find_free`/`_find_free_slot` reported inactive, and the reserve is synchronous; it becomes reachable the moment a reserve write fails silently — see [KNOWN: `docs/AUDIT-2026-07-21.md:59`])
- **What:** The module documents 2 as "slot is already active with a running bwrap", i.e. "do nothing, the instance is fine"; the orchestrator's single non-zero branch then wipes the running instance's pids from state, orphaning it (watchdog and reaper both skip a slot with no `bwrap_pid`).
- **Fix:** In `_launch_slot`, `case $_si_rc in 0) …;; 2) echo "already running — not releasing";; *) release;; esac`.

### B20. bwrap is required even for the handheld direct launch, which never uses it
- **Severity:** Low
- **Category:** logic
- **File:** `modules/instance_lifecycle.sh:934-938` (check precedes the mode branch at 1048)
- **Status:** CONFIRMED
- **What:** `command -v "$bwrap_cmd"` gates every spawn; the `-z "$js_node"` path builds `_build_direct_command` and never invokes bwrap. Harmless today (preflight hard-requires bwrap) but it makes the direct path's documented "full system access, nothing to isolate" contract false in a subtle way and blocks a test of the handheld path on a box without bubblewrap.
- **Fix:** Move the check under the `elif` branches that actually build a bwrap command.

### B21. errexit fragility when the module is sourced standalone under `set -e`
- **Severity:** Low
- **Category:** robustness
- **File:** `modules/instance_lifecycle.sh:322-323` (`_detect_xauthority`'s last pipeline returns 1 under `pipefail` when grep finds nothing), `modules/instance_lifecycle.sh:372,566` (`_xauth=$(_detect_xauthority)` — the assignment fails), `modules/instance_lifecycle.sh:280` (`read -r vendor product < <(_vp_of_js_node …)` returns 1 on empty output)
- **Status:** CONFIRMED that the commands return non-zero; PLAUSIBLE as a failure because the runtime flows run `set +e` (`orchestrator.sh:708,818`), so it only bites callers that source the module under `set -euo pipefail` (probes, hardware harnesses, `minecraftSplitscreen.sh` paths outside the flows)
- **What:** Under errexit, `_build_bwrap_command` aborts inside its `$(…)` → `bwrap_command` is empty → `setsid bash -c ""` exits immediately → "died immediately". Under errexit `_maybe_proxy_swap` aborts before echoing → both bind nodes empty → the sandbox is built with NO controller bound, silently.
- **Fix:** End `_detect_xauthority` with `|| true` (it is documented to return empty when undetectable), and write `read -r vendor product < <(_vp_of_js_node "$js_node") || true`.

### B22. `teardown_instance` blocks the FIFO loop for up to 10 s per hung slot
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/instance_lifecycle.sh:1222-1236`
- **Status:** [KNOWN: `docs/TODO.md:307` (teardown timing)]
- **What:** The SIGTERM grace loop (`INSTANCE_LIFECYCLE_TEARDOWN_GRACE_S` × `sleep 1`) runs synchronously inside `_handle_msg`; a hung JVM stalls every other event (including a DISPLAY_MODE_CHANGE) for 10 s. Bounded, so PRINCIPLES #6 is satisfied; noted for completeness.

### B23. `slot_claim` comment says "newest/first" but `head -n 1` on `to_entries` order returns the LOWEST slot
- **Severity:** Info
- **Category:** logic (comment/behaviour mismatch)
- **File:** `modules/slot_manager.sh:211`, `modules/slot_manager.sh:104-108`
- **Status:** CONFIRMED
- **What:** jq preserves key insertion order (`"1"…"4"`), so a clone multi-match resumes the lowest-numbered slot, not the most recent. `tests/test_slot_manager.sh:134-146` accepts either, so the test can't pin it. Only matters for counterfeit duplicate MACs.
- **Fix:** Either sort by `disconnected_at` descending in `slot_find_by_uniq` or fix the comment.

### B24. Keeper subshells are untracked PIDs that outlive `cleanup()`
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/instance_lifecycle.sh:1114-1121,1149-1161`, `modules/orchestrator.sh:1094-1105` (`_SPAWN_PIDS` tracks only the brace group)
- **Status:** CONFIRMED
- **What:** `kill -TERM $_sp` signals the spawn subshell; its keeper children are reparented and keep calling `dex_set_name`/`dex_map_raise` against a torn-down X server for up to 90 s. Bounded and harmless (dex errors are swallowed), but contrary to the "track every PID you spawn" discipline of PRINCIPLES #7.
- **Fix:** See B9 — redirect and, if kept, record their PIDs in a module array `cleanup()` can walk.

### B25. Two derivations of the instance number in one function, and a prefix match for "required" mods
- **Severity:** Info
- **Category:** principle-violation
- **File:** `modules/instance_creation.sh:333` (`${instance_name##*-}`) vs `modules/instance_creation.sh:557` (`grep -oE '[0-9]+$'`), `modules/instance_creation.sh:470` (`[[ "$mod_name" == "$req"* ]]`)
- **Status:** CONFIRMED
- **What:** Same datum, two encodings (#9). The required-mod check is a prefix match, so an optional "Sodium Extra" failing to download is reported as CRITICAL "Sodium".
- **Fix:** Compute once; use `==` (or `==` against a normalised name).

### B26. `handle_instance_update`'s sed edits are unescaped for `&`/`|` in `JAVA_PATH`
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/instance_creation.sh:824` (`sed -i "s|^JavaPath=.*|JavaPath=$JAVA_PATH|"`)
- **Status:** CONFIRMED (and currently moot — the whole file is rewritten at 225, see B6)
- **What:** A Java path containing `&` (sed "matched text") or `|` (the delimiter) corrupts the line. `setInstanceCfgValue` in instance_lifecycle already escapes these; the installer has its own unescaped copy (#9).
- **Fix:** Reuse `setInstanceCfgValue` (guarded `type` check per ARCHITECTURE §1) or copy its escaping.

### B27. Redundant guards and a duplicated Controlify write
- **Severity:** Info
- **Category:** principle-violation
- **File:** `modules/instance_lifecycle.sh:994` and `modules/instance_creation.sh:743` (`command -v jq` guards — jq is a preflight hard requirement and `read_state` already depends on it), `modules/instance_lifecycle.sh:996` vs `modules/instance_creation.sh:745` (the same `jq '.global.out_of_focus_input = true'` set in two products — documented as belt-and-suspenders for #95, but it is two encodings of one fact), `modules/instance_lifecycle.sh:1043` vs `modules/instance_lifecycle.sh:275` (flag + js_node gate evaluated twice)
- **Status:** CONFIRMED
- **Fix:** Drop the `command -v jq` guards; keep the belt-and-suspenders if desired but source the jq expression from one constant; remove one of the two proxy gates.

### B28. `create_instances` unconditionally re-enables errexit; `install_fabric_and_mods` restores correctly
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/instance_creation.sh:199,284` vs `modules/instance_creation.sh:311-312,764-766`
- **Status:** [KNOWN: `docs/CODE-REVIEW-2026-07-21-CLOSED.md:18` ("Broad set +e spans — non-manifesting"), `docs/TODO.md:234`]
- **What:** Inconsistent pattern only; no runtime effect today because the installer entry always runs with `-e`.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 1 (B1) |
| High | 0 |
| Medium | 8 (B2, B3, B4, B5, B6, B7, B8, B9) |
| Low | 12 (B10–B21) |
| Info | 7 (B22–B28) |

**Top three:**

1. **B1 — SLOT_DIED frees the slot before `teardown_instance`, so with the shipped default (`MCSS_CONTROLLER_PROXY=1`) the kill is skipped, hung JVMs leak past session exit, and the dead window's WID stays in state and gets the slot's NEXT occupant killed ~4 s into its launch.** One-line ordering fix in the orchestrator plus a process-based (not flag-based) guard in `teardown_instance` and `"wid": null` in spawn's reserve write. Needs a real-process dispatch test; the existing one stubs teardown and cannot see this.
2. **B2 — the orchestrator still carries raw-jq duplicates of the slot_manager verbs (`_find_free_slot`, `_find_slot_by_event_node`, dead `_find_slot_by_uniq`, `_get_mode`, `_collect_mask_pairs`)** despite slot_manager's own header promising PR-c retired them — the exact PRINCIPLES #1/#9 drift class this repo has already paid for.
3. **B3 + B5 (slot-claim/watchdog identity gaps)** — the watchdog's per-slot dedup never re-arms when a slot is freed and re-claimed inside one poll, and `slot_claim` REJECTs a known pad whose event node silently changed, leaving identity that can never be released. Both are cheap to fix (key the dedup on `bwrap_pid`; compare `$ev` to the stored node before REJECT) and both need matrix tests.

Also worth a maintainer's attention because they cost real user time: B6 (update path installs every mod twice and clobbers instance.cfg customisations) and B9 (handheld launch stalls the event loop up to ~90 s because the keepers hold the `| sed` pipe — PRINCIPLES #8).
