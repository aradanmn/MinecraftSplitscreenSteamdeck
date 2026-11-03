title: [D6-D21] Controllers/dock/evsieve: low and info findings (grouped checklist)
severity: low
security: yes
type: Task
related: #196, #133
---
- [ ] D6 — `proxy_start_slot` failure path leaves the pad symlink behind; `proxy_stop_all` reaper is never called in production
- [ ] D7 — `CONTROLLER_MONITOR_DEBOUNCE_MS` documented as an env override but `readonly …=500` clobbers it (moot if D2 lands)
- [ ] D8 — `CONTROLLER_PROXY_*_TIMEOUT_S` only ever printed; the real bound is `ITERS × INTERVAL`
- [ ] D9 — `watch_display_mode` silently returns if `inotifywait` fails; the poll path is an either/or, not a safety net
- [ ] D10 — Neither monitor traps TERM to reap its own child (`udevadm monitor` / `inotifywait`)
- [ ] D12 — `uniq` tokenised differently on the monitor's ADD paths (`awk '{print $5}'`) vs startup-acquire (`read -r` slurp)
- [ ] D13 — Dead code: `_eventN_to_virtual_idx`, `get_controller_by_index` (public API, 0 callers), `proxy_stop_all` (production)
- [ ] D14 — Duplicated/unnamed literals: `MCSS-slot` prefix in 3 sites, unnamed sleeps, node prefixes; includes B14's `:-28de` re-embed
- [ ] D15 — `_evsieve_build_in_box` splices `$src_dir` into a single-quoted `sh -c` script
- [ ] D17 — No install-time check that `/dev/uinput` is writable; `_evsieve_host_verify` only runs `--version`
- [ ] D18 — shellcheck not clean on `controller_monitor.sh` (2× SC2206, 5× SC2034)
- [ ] D19 — Per-field `$(echo … | awk)` forks in the hot enumeration paths (fixed by D12's tokeniser)
- [ ] D20 — Pidfile contents not validated as a PID before `kill -0`
- [ ] D21 — `proxy_start_slot` failure path uses an unbounded `wait` after a plain `kill`

## Summary
Low/Info findings from review D (controllers / dock / evsieve). D11 and D16 are folded into A13 and A12 respectively and are not listed here. Every diff below was generated against the current tree on a scratch copy, passes `bash -n`, passes `git apply --check` from the pristine repo root, and the combined set (D6, D7, D8, D9, D12, D13, D14, D15, D17, D18, D20 applied together) is shellcheck-clean on all four modules (only the pre-existing SC1091 info remains) and passes `tests/test_dock_detection.sh` 8/8, `tests/test_controller_monitor.sh` 22/22, `tests/test_controller_proxy.sh` 16/16, `tests/test_evsieve_management.sh` 20/20, `tests/test_instance_lifecycle.sh` 16/16 and `tests/test_runtime_context.sh` 30/30. Where a finding's fix overlaps D1-D5 (D7↔D2, D9↔D1, D12↔D2, D14↔D3, D15/D17↔D4/D5) the diff here is against the pristine file; apply the numbered issue first and re-resolve the trivial context conflict. The larger validated diffs (D9, D12, D13, D14, D17, D18) are attached in full in the appendix at the end so a maintainer can apply them without re-deriving.

### D6. `proxy_start_slot` failure path leaves the pad symlink behind; `proxy_stop_all` is never called
`modules/controller_proxy.sh:383` (`ln -sfn`), `:407-412` (failure path), `:591-604` (`proxy_stop_all`); header `:33-35` promises "PR4's cleanup() backstop + startup reap" that never landed. On "virtual never came up" the pads link survives (docstring says "no side effects survive"); stale `slot*` links and `proxy-slot*.pid` under the `/tmp` fallback are never reaped. Fix (one-liner, validated):
```diff
--- a/modules/controller_proxy.sh	2026-09-28 17:42:45.486727452 +0000
+++ b/modules/controller_proxy.sh	2026-09-28 18:07:38.457231746 +0000
@@ -408,6 +408,9 @@
         "${CONTROLLER_PROXY_START_TIMEOUT_S}s — killing" >&2
     kill "$pid" 2>/dev/null || true
     wait "$pid" 2>/dev/null || true
+    # D6: "no side effects survive" — the pads link (and any virt link
+    # evsieve managed to create before wedging) must not outlive the failure.
+    rm -f "$pad_link" "$virt_link"
     _proxy_forget_slot "$slot"
     return 1
 }
```
Plus wire `proxy_stop_all` (exit 0 always, identity-checked kills only) into `orchestrator.sh`'s `cleanup()` after `teardown_all_instances` and once at docked-flow startup, or delete the header promise (D13).

### D7. `CONTROLLER_MONITOR_DEBOUNCE_MS` env override is clobbered by `readonly …=500`
`modules/controller_monitor.sh:91`; header `:32-33`, `:66`. `X=1 bash -c 'readonly X=500; echo $X'` → `500`. Moot if D2 deletes the debounce (recommended); otherwise:
```diff
--- a/modules/controller_monitor.sh	2026-09-28 17:42:45.486651342 +0000
+++ b/modules/controller_monitor.sh	2026-09-28 18:07:38.531122535 +0000
@@ -88,7 +88,7 @@
 # modules are re-sourceable within one process, so an unguarded readonly
 # would abort on the second source.
 if [[ -z "${_CONTROLLER_MONITOR_CONSTANTS_LOCKED:-}" ]]; then
-    readonly CONTROLLER_MONITOR_DEBOUNCE_MS=500
+    readonly CONTROLLER_MONITOR_DEBOUNCE_MS="${CONTROLLER_MONITOR_DEBOUNCE_MS:-500}"
     readonly CONTROLLER_MONITOR_DEFAULT_PROC_PATH="/proc/bus/input/devices"
     _CONTROLLER_MONITOR_CONSTANTS_LOCKED=1   # process-local — NOT exported
 fi
```

### D8. `CONTROLLER_PROXY_*_TIMEOUT_S` are only printed; `ITERS × INTERVAL` is the real bound
`modules/controller_proxy.sh:122-124`, `:132-133`; uses at `:312`, `:408` (messages only); loops at `:299`, `:398`. Change one and the log lies (ARCHITECTURE §3 "a constant's existence obligates its use"). Derive the iterations:
```diff
--- a/modules/controller_proxy.sh	2026-09-28 17:42:45.486727452 +0000
+++ b/modules/controller_proxy.sh	2026-09-28 18:07:38.605619771 +0000
@@ -121,7 +121,10 @@
 # (§A: "~2s, iters x 0.1s"). Units in name (STYLE-GUIDE §6).
 readonly CONTROLLER_PROXY_START_TIMEOUT_S=2
 readonly CONTROLLER_PROXY_POLL_INTERVAL_S="0.1"
-readonly CONTROLLER_PROXY_START_POLL_ITERS=20
+# D8: iterations are DERIVED from the timeout (10 polls per second at the
+# 0.1 s interval) so the "within Ns" log strings can never drift from the
+# real bound (ARCHITECTURE §3: a constant's existence obligates its use).
+readonly CONTROLLER_PROXY_START_POLL_ITERS=$(( CONTROLLER_PROXY_START_TIMEOUT_S * 10 ))
 
 # Bounded poll for a SIGTERM'd evsieve to actually exit before the
 # SIGKILL fallback (review fix: `wait` cannot reap a non-child — the pid
@@ -130,7 +133,7 @@
 # kill -0 is the only reliable "did it actually die" signal across that
 # boundary). Same cadence as the start poll.
 readonly CONTROLLER_PROXY_STOP_TIMEOUT_S=2
-readonly CONTROLLER_PROXY_STOP_POLL_ITERS=20
+readonly CONTROLLER_PROXY_STOP_POLL_ITERS=$(( CONTROLLER_PROXY_STOP_TIMEOUT_S * 10 ))
 
 # --- Internal data structures ---
 
```

### D9. `watch_display_mode` returns silently if `inotifywait` exits; polling is never reached
`modules/dock_detection.sh:228-253`; comment `:239-240` ("the poll fallback below is unchanged as the safety net either way") is inaccurate — the poll loop only runs when the binary is *absent*. If `inotifywait` exits non-zero (watch limit, EACCES) the function falls off the end with exit 0 and the orchestrator heartbeat restarts it every ~5 s forever (a WARNING each time). Fix: log the exit and fall through into the poll loop (move the `while true` out of the `else`; 2 hunks, appendix). Test to add: T1.11 — put a fake `inotifywait` that `exit 1`s first on `PATH`, start the watcher, flip a fixture connector → `DISPLAY_MODE_CHANGE docked` must still arrive within `POLL_INTERVAL+2` s; mutation: restore the `else`-only poll → red (watcher exits, `read -t` times out). Note this touches the same lines as D1 (`get_display_mode "$current_mode"`); apply after D1.

### D10. Neither monitor traps TERM to reap its own child
`modules/controller_monitor.sh:965` (`< <(udevadm monitor …)`), `modules/dock_detection.sh:242` (`while inotifywait …`). Known (BUG-AUDIT-2026-06-24 N15; TODO #25). The only mitigation is `orchestrator.sh:1059-1090` (`_kill_tree`/`pkill -P`); any other caller's plain `kill $pid` (tests, the heartbeat restart path, a future refactor) orphans `udevadm monitor`/`inotifywait`, which keeps the FIFO write-end open across runs. Fix (sentence, design): run the producer as a named-pipe coprocess or `udevadm … > "$pipe" & child=$!` so `$!` is available, then `trap 'kill "$child" 2>/dev/null; exit' TERM` in each function. Minimum: document the orchestrator dependency in both module headers.

### D12. `uniq` is tokenised differently on the hotplug ADD paths vs startup-acquire
`modules/controller_monitor.sh:841`, `:919` (`awk '{print $5}'` — first token only) vs `:729-736` (`read -r … _uq`, slurps the remainder) and the consumer `modules/orchestrator.sh:530` (`read -r … phys_uniq`, slurps). A `U: Uniq=` containing whitespace (none of DS4/DualSense/Xbox do; PLAUSIBLE) yields two identity strings for the same pad → `slot_claim` cannot match the MAC → SPAWN/REJECT instead of RESUME on reconnect. Fix (5 hunks, appendix; also covers **D19**): one tokeniser everywhere — `read -r ev js_node phys_vendor phys_product phys_uniq <<< "$cline"` in `_check_devices_changed` and `start_controller_monitor`, `read -r eventN jsN vendor product _ <<< "$first"` in the handheld branch, and `read -r d_in d_ev d_js d_vn d_pr <<< "$_row"` for the mapper's diagnostics — removing 4-5 `echo|awk` forks per device per scan. Representative hunk:
```diff
@@ -910,13 +913,10 @@
     while IFS= read -r cline; do
         [[ -z "$cline" ]] && continue
         local ev js_node phys_vendor phys_product phys_uniq
-        ev=$(echo "$cline" | awk '{print $1}')
-        js_node=$(echo "$cline" | awk '{print $2}')
-        phys_vendor=$(echo "$cline" | awk '{print $3}')
-        phys_product=$(echo "$cline" | awk '{print $4}')
-        # #38 PR3: field 5, may be empty (clone/non-Sony pad or the legacy
+        # D12: same slurping tokeniser as _check_devices_changed (see there).
+        # #38 PR3: field 5 may be empty (clone/non-Sony pad or the legacy
         # virtual-mapper path — see list_eligible_controllers).
-        phys_uniq=$(echo "$cline" | awk '{print $5}')
+        read -r ev js_node phys_vendor phys_product phys_uniq <<< "$cline"
```
Test: a fixture with `U: Uniq=ABC 123` → T2.8-style monitor must emit `CONTROLLER_ADD … ABC 123` (mutation: restore `awk '{print $5}'` → `ABC`). `tests/test_controller_monitor.sh` 22/22 with the change applied.

### D13. Dead code: `_eventN_to_virtual_idx`, `get_controller_by_index`, `proxy_stop_all`
`modules/controller_monitor.sh:289-302`, `:750-766`; `modules/controller_proxy.sh:591-604`. Repo-wide grep incl. tests, probes and the launcher: 0 callers for the first two (`get_controller_by_index` is listed in the module's Public API); `proxy_stop_all` is referenced only by `tests/test_controller_proxy.sh`. Fix: delete the first two with STYLE-GUIDE §4 tombstone one-liners and drop the header mentions (4 hunks, appendix; 22/22 + 16/16 after); wire or delete the third per D6.

### D14. Duplicated / unnamed literals across the four modules (incl. B14's `28de` re-embed)
`MCSS-slot` prefix: `modules/controller_proxy.sh:389`, `:546` and `modules/controller_monitor.sh:551` (the identity gate keys on a literal another module owns — a rename in the proxy silently re-opens the 2026-07-25 bug). Sleeps: `controller_monitor.sh:959` (`sleep 0.1`), `:970` (`sleep 2`), `dock_detection.sh:244` (`sleep 0.5`). B14: `modules/instance_lifecycle.sh:509` `${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}` — the consumer-side `:-fallback` ARCHITECTURE §3 forbids. Node prefixes `/dev/input/event`/`js` (`controller_monitor.sh:701`, `:730-733`, `controller_proxy.sh:565`) are left as-is (sentence: a `MCSS_EVDEV_PREFIX` pair in runtime_context if ever touched again). Fix (11 hunks across 5 files, appendix): `MCSS_PROXY_DEVNAME_PREFIX="MCSS-slot"` in `runtime_context.sh`'s guarded block (exported + readonly), consumed by both modules; `CONTROLLER_MONITOR_SETTLE_S`, `CONTROLLER_MONITOR_POLL_INTERVAL_S`, `DOCK_DETECTION_SETTLE_S`; and the B14 one-liner:
```diff
-        if [[ "$_js_vendor" == "${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}" ]]; then
+        if [[ "$_js_vendor" == "$MCSS_STEAM_VENDOR_ID" ]]; then   # B14: canonical id, no re-embed
```
With D3 applied, the monitor-side consumer is the single `_is_mcss_proxy_virtual` helper. Suites: 22/22, 16/16, 8/8, 16/16 (instance_lifecycle), 30/30 (runtime_context).

### D15. `_evsieve_build_in_box` splices `$src_dir` into a single-quoted `sh -c` script
`modules/evsieve_management.sh:431` `cd "'"$src_dir"'"` — `src_dir` derives from `TARGET_DIR` (user/env-controlled). A `'` in the path ends the script early (fail-open → `degraded-build-failed`) or, crafted, runs arbitrary text inside the box. Self-inflicted, not cross-user. Fix (validated, 20/20):
```diff
--- a/modules/evsieve_management.sh	2026-09-28 17:42:45.486802887 +0000
+++ b/modules/evsieve_management.sh	2026-09-28 18:08:59.093877141 +0000
@@ -421,6 +421,10 @@
     # passwordless sudo somehow isn't set up instead of hanging on a hidden
     # password prompt. _evsieve_ensure_box has already entered/initialized the
     # box (NOPASSWD ready), so in the normal case sudo -n just works.
+    # D15: the source path rides in as a POSITIONAL ($1), never spliced into
+    # the single-quoted script — a quote in $TARGET_DIR used to end the
+    # script early (and could run arbitrary text inside the box).
+    # shellcheck disable=SC2016  # $1 is expanded by the box's sh, on purpose
     timeout "$EVSIEVE_BUILD_TIMEOUT_S" distrobox enter \
         --name "$EVSIEVE_DISTROBOX_NAME" -- sh -c '
             set -e
@@ -428,9 +432,9 @@
             sudo -n apt-get update
             sudo -n apt-get install -y --no-install-recommends \
                 git cargo libevdev-dev
-            cd "'"$src_dir"'"
+            cd "$1"
             cargo build --release
-        ' </dev/null >/dev/null 2>&1
+        ' _ "$src_dir" </dev/null >/dev/null 2>&1
 }
 
 # _evsieve_install_binary: Atomically copy a binary into place.
```

### D17. No install-time check that `/dev/uinput` is writable
`modules/evsieve_management.sh:498-500` (`_evsieve_host_verify` runs `--version` only); `uinput` appears nowhere else but comments. On a stock Deck udev `uaccess` grants it, so nothing is broken there; on any other host the install reports "evsieve installed" and the runtime degrades per D4's scenario (2 s poll + kill per slot per launch) with no diagnostic. Fix (3 hunks, appendix): `_evsieve_warn_uinput` — `[[ -w /dev/uinput ]] || print_warning "…seamless controller reconnect will be unavailable at runtime…"`, called after both success prints; soft, never fatal (PRINCIPLES #5). Correct posture confirmed: no host-side `sudo` anywhere in these modules.

### D18. shellcheck not clean on `controller_monitor.sh` (STYLE-GUIDE §7.8)
`shellcheck -x` 0.11.0: `:445` SC2206 (`local -a words=($keybits)`), `:813` SC2206 (`local prev_array=($prev_nodes)`), `:99` SC2034 (`CONTROLLER_MONITOR_STEAM_PRODUCT`), `:389`/`:396` SC2034 (`e_ev e_js v_ev v_js`). Fix (5 hunks, appendix): `read -ra words <<< "$keybits"` / `read -ra prev_array <<< "$prev_nodes"` (same word-split semantics, leading/trailing whitespace stripped), and `# shellcheck disable=SC2034  # reason` directly above the three `read`/`readonly` lines (the directive must precede the line that *assigns*, i.e. the `read`, not the `local`). Verified: `shellcheck -x` on all four modules → clean (SC1091 info only); 22/22.

### D19. Per-field `$(echo … | awk)` forks in the hot enumeration paths
`modules/controller_monitor.sh:807-810`, `:837-841`, `:914-919`, `:378-382` (`:297` goes with D13). Dozens of forks per udev event on a 4-pad rig, inside the `sleep 0.1` settle window. Fixed by D12's diff (same hunks); no separate change.

### D20. Pidfile contents are not validated as a PID before `kill -0`
`modules/controller_proxy.sh:199`, `:224-226`. `pid=$(<"$pidfile")` feeds `kill -0` directly; garbage such as `-1`, `0`, `%1` reaches `kill` and is only caught because `_proxy_pid_is_ours` happens to run second. Fix (validated, 16/16):
```diff
--- a/modules/controller_proxy.sh	2026-09-28 17:42:45.486727452 +0000
+++ b/modules/controller_proxy.sh	2026-09-28 18:07:39.261407224 +0000
@@ -197,6 +197,8 @@
     local slot="$1" pidfile pid=""
     pidfile=$(_proxy_pidfile "$slot")
     [[ -f "$pidfile" ]] && pid=$(<"$pidfile")
+    # D20: a pidfile holds a PID or nothing — never let "-1"/"0"/"%1" reach kill.
+    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid=""
     [[ -z "$pid" ]] && pid="${_CONTROLLER_PROXY_PIDS[$slot]:-}"
     echo "$pid"
 }
```

### D21. `proxy_start_slot` failure path uses an unbounded `wait` after a plain `kill`
`modules/controller_proxy.sh:409-410` `kill "$pid"; wait "$pid"` — the child IS this shell's child, so `wait` blocks until exit; an evsieve wedged in a libevdev grab (never observed; PLAUSIBLE) would stall `_maybe_proxy_swap` and that slot's spawn (PRINCIPLES #6). Do **not** reuse `_proxy_kill_verified` here as the review first suggested: it polls `kill -0`, and a direct child that has exited but not been reaped is a zombie for which `kill -0` still succeeds, so it would always cost the full 2 s (its identity check also rejects zombies, so no TERM is sent). Sentence fix: after `kill "$pid"`, poll up to `CONTROLLER_PROXY_STOP_POLL_ITERS × CONTROLLER_PROXY_POLL_INTERVAL_S` until `/proc/$pid` is gone **or** its state (first token after the `)` in `/proc/$pid/stat`) is `Z`, then `kill -KILL "$pid" 2>/dev/null || true` (no-op on a zombie) and the existing `wait "$pid"`. Same failure path as D6 — land them together.

## Hardware verification
One docked pass covers the group. Mode: **Game Mode, docked**, 2-4 pads, proxy at default. Run `bash tests/hardware/run_all.sh stage3` (D3.0-D3.8) and `stage4` on the combined patch; every checklist item must still pass with the new constants in place (D8/D14 change no values, only names; D12/D18 change no bytes on the wire for real pads — `grep 'CONTROLLER_ADD' /tmp/splitscreen-debug-latest.log` lines must be identical in shape to a pre-patch run). D6/D20/D21: after a session, `ls $XDG_RUNTIME_DIR/mcss/proxy-pads $XDG_RUNTIME_DIR/mcss/proxy-virt` must be empty and no `proxy-slot*.pid` left (with `proxy_stop_all` wired). D9/D10: not testable on a Deck without inotify-tools beyond confirming the `polling every 3s` line and that `ps -o pid,ppid,cmd -C udevadm` shows no orphan after quit. D13/D15/D17/D19: CI + unit test only (dead-code removal, installer string handling, a warning, and fork elimination have no runtime behaviour a Deck could distinguish beyond the suites above and a normal `stage0b_install.sh` run printing no unexpected `/dev/uinput` warning).

## References
Review D6-D10, D12-D15, D17-D21 (docs/reviews/2026-09-28/D-controllers.md); B14 (review B, folded into D14 here); CODE-REVIEW §5.4 table and cross-cutting clusters §7.3 (`/tmp` paths — A12/A13 own D11/D16), §7.4 (consumer-side `:-` re-embeds). PRINCIPLES #5, #6, #7, #9; ARCHITECTURE §3; STYLE-GUIDE §4 (tombstones), §7.8 (shellcheck), §7.9 (traps). Related: #196 (evsieve build fallback), #133 (dock detection; D9 shares its watcher), #86 (unnamed timing literals backlog), TODO #25/N15 (D10).

## Appendix — full validated diffs (D9, D12, D13, D14, D17, D18)
Each was produced with `diff -u` on a scratch copy and passes `git apply --check` against the pristine tree individually; they also apply together (combined clone tested as described in the summary).
<details><summary>D9 — dock_detection.sh (2 hunks)</summary>

```diff
--- a/modules/dock_detection.sh	2026-09-28 17:42:45.486779262 +0000
+++ b/modules/dock_detection.sh	2026-09-28 18:07:38.685143355 +0000
@@ -205,7 +205,8 @@
 }
 
 # watch_display_mode: Watch for display mode changes. Blocks indefinitely.
-# Uses inotifywait on the DRM path if available; otherwise polls.
+# Uses inotifywait on the DRM path if available; polls if it is absent OR
+# if it ever exits (D9).
 # Intended to be run as a background process by the orchestrator.
 # Inputs:
 #   Globals: DOCK_DETECTION_DRM_PATH (override), SPLITSCREEN_FIFO (read)
@@ -250,17 +251,22 @@
                 current_mode="$new_mode"
             fi
         done
+        # D9: inotifywait exiting non-zero (inotify watch limit exhausted,
+        # EACCES on sysfs, ...) used to end this function — the orchestrator
+        # heartbeat then restarted it every ~5 s forever and the poll loop
+        # below was never reached. Fall through to polling instead.
+        echo "[dock_detection] inotifywait exited — falling back to polling every ${DOCK_DETECTION_POLL_INTERVAL_S}s" >&2
     else
         echo "[dock_detection] inotifywait not available, polling every ${DOCK_DETECTION_POLL_INTERVAL_S}s" >&2
-        while true; do
-            sleep "$DOCK_DETECTION_POLL_INTERVAL_S"
-            local new_mode
-            new_mode=$(get_display_mode)
-            if [[ "$new_mode" != "$current_mode" ]]; then
-                echo "[dock_detection] Display mode changed: $current_mode → $new_mode" >&2
-                echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true  # H6: tolerate broken pipe
-                current_mode="$new_mode"
-            fi
-        done
     fi
+    while true; do
+        sleep "$DOCK_DETECTION_POLL_INTERVAL_S"
+        local new_mode
+        new_mode=$(get_display_mode)
+        if [[ "$new_mode" != "$current_mode" ]]; then
+            echo "[dock_detection] Display mode changed: $current_mode → $new_mode" >&2
+            echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true  # H6: tolerate broken pipe
+            current_mode="$new_mode"
+        fi
+    done
 }
```
</details>
<details><summary>D12 (+D19) — controller_monitor.sh (5 hunks)</summary>

```diff
--- a/modules/controller_monitor.sh	2026-09-28 17:42:45.486651342 +0000
+++ b/modules/controller_monitor.sh	2026-09-28 18:07:38.754403893 +0000
@@ -371,12 +371,14 @@
     (( ${#externals[@]} )) && mapfile -t e_sorted < <(printf '%s\n' "${externals[@]}" | sort -n -k1,1)
 
     echo "[controller_monitor] enumeration: ${#e_sorted[@]} external pad(s), ${#v_sorted[@]} virtual(s)" >&2
-    local _row
+    local _row d_in d_ev d_js d_vn d_pr
     for _row in "${e_sorted[@]}"; do
-        echo "[controller_monitor]   external: input${_row%% *} [$(awk '{print $4":"$5}' <<<"$_row")] event$(awk '{print $2}' <<<"$_row") js$(awk '{print $3}' <<<"$_row")" >&2
+        read -r d_in d_ev d_js d_vn d_pr <<< "$_row"   # D19: no awk forks
+        echo "[controller_monitor]   external: input${d_in} [${d_vn}:${d_pr}] event${d_ev} js${d_js}" >&2
     done
     for _row in "${v_sorted[@]}"; do
-        echo "[controller_monitor]   virtual : input${_row%% *} event$(awk '{print $2}' <<<"$_row") js$(awk '{print $3}' <<<"$_row")" >&2
+        read -r d_in d_ev d_js <<< "$_row"
+        echo "[controller_monitor]   virtual : input${d_in} event${d_ev} js${d_js}" >&2
     done
 
     # Proximity match: per external (oldest first), claim the lowest-inputN unclaimed
@@ -692,10 +694,7 @@
             return 0
         fi
         local eventN jsN vendor product
-        eventN=$(echo "$first" | awk '{print $1}')
-        jsN=$(echo "$first" | awk '{print $2}')
-        vendor=$(echo "$first" | awk '{print $3}')
-        product=$(echo "$first" | awk '{print $4}')
+        read -r eventN jsN vendor product _ <<< "$first"
         # #38 PR3: uniq is ALWAYS empty on this path
         # (_parse_all_gamepad_devices' 6-field output has no uniq to carry)
         # — omit rather than append a literal trailing space, so this line
@@ -805,7 +804,7 @@
     while IFS= read -r cline; do
         [[ -z "$cline" ]] && continue
         local ev_node
-        ev_node=$(echo "$cline" | awk '{print $1}')
+        read -r ev_node _ <<< "$cline"
         current_nodes["$ev_node"]="$cline"
     done <<< "$current_output"
 
@@ -832,13 +831,17 @@
             fi
             _CONTROLLER_MONITOR_DEBOUNCE_MAP["$ev"]=$now_ms
 
-            local js_node phys_vendor phys_product phys_uniq
-            js_node=$(echo "${current_nodes[$ev]}" | awk '{print $2}')
-            phys_vendor=$(echo "${current_nodes[$ev]}" | awk '{print $3}')
-            phys_product=$(echo "${current_nodes[$ev]}" | awk '{print $4}')
-            # #38 PR3: field 5, may be empty (clone/non-Sony pad or the
+            # D12: ONE tokeniser for uniq on every path — `read -r` slurps
+            # the remainder into the last var exactly as the orchestrator's
+            # _handle_msg and list_eligible_controllers do, so a uniq with
+            # whitespace yields the same identity string from hotplug and
+            # from startup-acquire (also removes 4 forks per device, D19).
+            # #38 PR3: field 5 may be empty (clone/non-Sony pad or the
             # legacy virtual-mapper path — see list_eligible_controllers).
-            phys_uniq=$(echo "${current_nodes[$ev]}" | awk '{print $5}')
+            local _ev_unused js_node phys_vendor phys_product phys_uniq
+            # shellcheck disable=SC2034  # _ev_unused: field 1 is $ev already
+            read -r _ev_unused js_node phys_vendor phys_product phys_uniq \
+                <<< "${current_nodes[$ev]}"
 
             echo "[controller_monitor] Controller added: $ev $js_node $phys_vendor $phys_product" >&2
             local _add_line
@@ -910,13 +913,10 @@
     while IFS= read -r cline; do
         [[ -z "$cline" ]] && continue
         local ev js_node phys_vendor phys_product phys_uniq
-        ev=$(echo "$cline" | awk '{print $1}')
-        js_node=$(echo "$cline" | awk '{print $2}')
-        phys_vendor=$(echo "$cline" | awk '{print $3}')
-        phys_product=$(echo "$cline" | awk '{print $4}')
-        # #38 PR3: field 5, may be empty (clone/non-Sony pad or the legacy
+        # D12: same slurping tokeniser as _check_devices_changed (see there).
+        # #38 PR3: field 5 may be empty (clone/non-Sony pad or the legacy
         # virtual-mapper path — see list_eligible_controllers).
-        phys_uniq=$(echo "$cline" | awk '{print $5}')
+        read -r ev js_node phys_vendor phys_product phys_uniq <<< "$cline"
         prev_nodes="$prev_nodes $ev"
         if [[ "$skip_emit" != "1" ]]; then
             echo "[controller_monitor] Initial controller present: $ev $js_node $phys_vendor $phys_product" >&2
```
</details>
<details><summary>D13 — controller_monitor.sh (4 hunks)</summary>

```diff
--- a/modules/controller_monitor.sh	2026-09-28 17:42:45.486651342 +0000
+++ b/modules/controller_monitor.sh	2026-09-28 18:07:38.835313343 +0000
@@ -27,7 +27,6 @@
 #   list_eligible_controllers(mode)     — stdout: "event_node js_node vendor
 #     product uniq" lines (uniq may be empty; #38 PR3 field 8, see below)
 #   start_controller_monitor(mode)      — blocks; writes CONTROLLER_ADD/REMOVE to FIFO
-#   get_controller_by_index(index, mode) — stdout: "event_node js_node" or empty
 #
 # Globals PROVIDED:
 #   CONTROLLER_MONITOR_DEFAULT_PROC_PATH — readonly, default /proc path
@@ -48,8 +47,8 @@
 #          D-Bus (referenced by the env override name; not queried directly
 #          in this file's current enumeration paths).
 # Outputs: CONTROLLER_ADD/CONTROLLER_REMOVE lines to $SPLITSCREEN_FIFO,
-#          eligible-controller data to stdout (list_eligible_controllers,
-#          get_controller_by_index), stderr `[controller_monitor]` prefix.
+#          eligible-controller data to stdout (list_eligible_controllers),
+#          stderr `[controller_monitor]` prefix.
 #
 # Environment overrides (for testing):
 #   PROC_INPUT_DEVICES              — override /proc/bus/input/devices path
@@ -280,25 +279,8 @@
 # _map_external_player_virtuals' inputN creation-order mapping. Name-keyed
 # scans, if ever needed again, ride parse_input_device_blocks' name field.)
 
-# _eventN_to_virtual_idx: Convert eventN to 1-based position in the sorted
-# virtual device list.
-# Inputs: $1 — target eventN
-# Outputs:
-#   stdout — 1-based index on match
-#   return — 0 on match, 1 if not found (no stdout emitted on failure)
-_eventN_to_virtual_idx() {
-    local target="$1" idx=1 vline
-    while IFS= read -r vline; do
-        local ven
-        ven=$(echo "$vline" | awk '{print $1}')
-        if [[ "$ven" == "$target" ]]; then
-            echo "$idx"
-            return 0
-        fi
-        idx=$((idx + 1))
-    done < <(_parse_steam_virtual_devices)
-    return 1
-}
+# (_eventN_to_virtual_idx deleted — D13 (2026-09-28): zero callers since the
+# Fix #51 cleanup removed its sibling _find_internal_by_pad_name.)
 
 
 # --- Public API ---
@@ -740,30 +722,9 @@
     done < <("$src")
 }
 
-# get_controller_by_index: Return the event node and js node for the Nth
-# eligible controller (1-based).
-# Inputs:
-#   $1 — index (1-4), $2 — mode ("handheld" or "docked")
-# Outputs:
-#   stdout — "<event_node> <js_node>", or empty string if not found
-#   return — 1 if index is not a positive integer
-get_controller_by_index() {
-    local index="${1:-1}"
-    local mode="${2:-}"
-
-    # M5: validate the index before feeding it to `sed -n "${index}p"` — a blank or
-    # non-numeric value would make sed error or behave unexpectedly.
-    if ! [[ "$index" =~ ^[1-9][0-9]*$ ]]; then
-        echo "[controller_monitor] WARNING: get_controller_by_index bad index '$index'" >&2
-        return 1
-    fi
-
-    local line
-    line=$(list_eligible_controllers "$mode" | sed -n "${index}p")
-    if [[ -n "$line" ]]; then
-        echo "$line" | awk '{print $1, $2}'
-    fi
-}
+# (get_controller_by_index deleted — D13 (2026-09-28): listed as Public API
+# but had zero callers anywhere, tests included; `list_eligible_controllers
+# <mode> | sed -n "${n}p"` is the one-liner if it is ever needed.)
 
 # _check_devices_changed: Compare current eligible device list against a
 # previously stored snapshot (tracked by event node).
```
</details>
<details><summary>D14 (+B14) — runtime_context.sh, controller_proxy.sh, controller_monitor.sh, dock_detection.sh, instance_lifecycle.sh (11 hunks)</summary>

```diff
--- a/modules/controller_monitor.sh	2026-09-28 17:42:45.486651342 +0000
+++ b/modules/controller_monitor.sh	2026-09-28 18:07:38.927320908 +0000
@@ -90,6 +90,9 @@
 if [[ -z "${_CONTROLLER_MONITOR_CONSTANTS_LOCKED:-}" ]]; then
     readonly CONTROLLER_MONITOR_DEBOUNCE_MS=500
     readonly CONTROLLER_MONITOR_DEFAULT_PROC_PATH="/proc/bus/input/devices"
+    # D14: named timing literals (ARCHITECTURE §3 / #86).
+    readonly CONTROLLER_MONITOR_SETTLE_S="0.1"       # udev event → /proc settle
+    readonly CONTROLLER_MONITOR_POLL_INTERVAL_S=2    # no-udevadm poll fallback
     _CONTROLLER_MONITOR_CONSTANTS_LOCKED=1   # process-local — NOT exported
 fi
 # One-release deprecation aliases for the ids (external consumers/tests);
@@ -548,7 +551,7 @@
         # on-Deck 2026-07-25 reconnect failure). Keyed on the MCSS-slot<N> name
         # controller_proxy sets (evsieve --output name=MCSS-slot<N>).
         local _nm="${name#\"}"; _nm="${_nm%\"}"
-        if [[ "$_nm" == MCSS-slot* ]]; then
+        if [[ "$_nm" == "${MCSS_PROXY_DEVNAME_PREFIX}"* ]]; then
             echo "[controller_monitor]   raw: drop event${_eventN} js${_jsN} [${vendor}:${product}] — MCSS proxy virtual (${_nm})" >&2
             return 0
         fi
@@ -956,7 +959,7 @@
 
             if [[ "$action" == "add" || "$action" == "remove" || "$action" == "change" ]]; then
                 # Brief settle time for the device to appear in /proc
-                sleep 0.1
+                sleep "$CONTROLLER_MONITOR_SETTLE_S"
 
                 # N16/H1: single enumeration inside _check_devices_changed feeds BOTH the
                 # diff AND the new baseline (its stdout) — no separate re-enumeration here.
@@ -965,9 +968,9 @@
         done < <("$udevadm_cmd" monitor --subsystem-match=input --udev 2>/dev/null)
     else
         # Fallback: poll
-        echo "[controller_monitor] $udevadm_cmd not available, polling every 2s" >&2
+        echo "[controller_monitor] $udevadm_cmd not available, polling every ${CONTROLLER_MONITOR_POLL_INTERVAL_S}s" >&2
         while true; do
-            sleep 2
+            sleep "$CONTROLLER_MONITOR_POLL_INTERVAL_S"
 
             # N16/H1: see the udevadm branch above — single enumeration, no re-scan.
             prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")
--- a/modules/controller_proxy.sh	2026-09-28 17:42:45.486727452 +0000
+++ b/modules/controller_proxy.sh	2026-09-28 18:07:38.926801273 +0000
@@ -386,7 +386,7 @@
     # Plain `&` (no setsid): evsieve is a single process with no child tree,
     # unlike bwrap — mirrors the probe's start_evsieve (spike §A step 5).
     "$bin" --input "$pad_link" grab persist=reopen \
-        --output create-link="$virt_link" name="MCSS-slot${slot}" \
+        --output create-link="$virt_link" name="${MCSS_PROXY_DEVNAME_PREFIX}${slot}" \
                  device-id="${phys_vendor}:${phys_product}" \
         >>"$logfile" 2>&1 &
     local pid=$!
@@ -543,7 +543,7 @@
         || virt_ev=""
     [[ -n "$virt_ev" && -e "$virt_ev" ]] || return 1
 
-    local devname="MCSS-slot${slot}"
+    local devname="${MCSS_PROXY_DEVNAME_PREFIX}${slot}"
     local vendor product name handlers sysfs phys keybits uniq _h jsn=""
     # Read-arity — critical (spike §A): an 8-variable read against today's
     # 7-field parse_input_device_blocks emit does NOT slurp (a read with
--- a/modules/dock_detection.sh	2026-09-28 17:42:45.486779262 +0000
+++ b/modules/dock_detection.sh	2026-09-28 18:07:38.927547723 +0000
@@ -50,6 +50,7 @@
 if [[ -z "${_DOCK_DETECTION_CONSTANTS_LOCKED:-}" ]]; then
     readonly DOCK_DETECTION_DEFAULT_DRM_PATH="/sys/class/drm"
     readonly DOCK_DETECTION_POLL_INTERVAL_S=3
+    readonly DOCK_DETECTION_SETTLE_S="0.5"   # D14: inotify event → sysfs settle
     _DOCK_DETECTION_CONSTANTS_LOCKED=1   # process-local — NOT exported
 fi
 
@@ -240,8 +241,8 @@
         # inotifywait exits with 0 when an event is received; the outer `while` loop
         # re-invokes it fresh each time, so it re-scans the current tree on every pass.
         while inotifywait -q -e modify,create,delete,moved_to,delete_self -r "$drm_path" 2>/dev/null; do
-            # Debounce: brief sleep then check
-            sleep 0.5
+            # Settle: brief sleep then check
+            sleep "$DOCK_DETECTION_SETTLE_S"
             local new_mode
             new_mode=$(get_display_mode)
             if [[ "$new_mode" != "$current_mode" ]]; then
--- a/modules/instance_lifecycle.sh	2026-09-28 17:42:45.486895266 +0000
+++ b/modules/instance_lifecycle.sh	2026-09-28 18:07:38.927969109 +0000
@@ -506,7 +506,7 @@
     if (( _js_bound == 1 )); then
         local _js_vendor
         _js_vendor=$(_vendor_of_js_node "$js_node")
-        if [[ "$_js_vendor" == "${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}" ]]; then
+        if [[ "$_js_vendor" == "$MCSS_STEAM_VENDOR_ID" ]]; then   # B14: canonical id, no re-embed
             _allow=1
         else
             _allow=0
--- a/modules/runtime_context.sh	2026-09-28 17:42:45.487318399 +0000
+++ b/modules/runtime_context.sh	2026-09-28 18:07:38.926402850 +0000
@@ -189,6 +189,12 @@
     # aliases in controller_monitor.sh for one release.
     export MCSS_STEAM_VENDOR_ID="${MCSS_STEAM_VENDOR_ID:-28de}"
     export MCSS_STEAM_PRODUCT_ID="${MCSS_STEAM_PRODUCT_ID:-11ff}"
+    # D14 (#38): the device-name prefix our evsieve proxy virtuals are created
+    # with (controller_proxy: `--output name=<prefix><slot>`) AND the identity
+    # gate controller_monitor keys on to keep them out of player enumeration.
+    # A cross-module contract: renaming it in one place silently re-opened
+    # the 2026-07-25 on-Deck reconnect failure, so it lives here once.
+    export MCSS_PROXY_DEVNAME_PREFIX="${MCSS_PROXY_DEVNAME_PREFIX:-MCSS-slot}"
     # Raw per-slot controller binding. Resolved ONCE from the legacy override:
     # controller_monitor (enumeration) and instance_lifecycle (sandboxing)
     # previously each defaulted this independently — they MUST agree or
@@ -238,7 +244,7 @@
              MCSS_DISPLAY_PROBE_TIMEOUT_S MCSS_CONTROLLER_PROXY \
              MCSS_CAP_FPS_TO_REFRESH MCSS_MAX_REFRESH_FALLBACK_HZ \
              MCSS_MAX_REFRESH_FLOOR_HZ MCSS_MAX_REFRESH_CEIL_HZ \
-             MCSS_NESTED_KWIN_NNP
+             MCSS_NESTED_KWIN_NNP MCSS_PROXY_DEVNAME_PREFIX
     _MCSS_CONSTANTS_LOCKED=1   # process-local — NOT exported (see load-guard rule)
 fi
 
```
</details>
<details><summary>D17 — evsieve_management.sh (3 hunks)</summary>

```diff
--- a/modules/evsieve_management.sh	2026-09-28 17:42:45.486802887 +0000
+++ b/modules/evsieve_management.sh	2026-09-28 18:07:39.093756738 +0000
@@ -473,6 +473,19 @@
     "$(_evsieve_bin)" --version >/dev/null 2>&1
 }
 
+# _evsieve_warn_uinput: D17 — evsieve's `--output create-link=` needs write
+# access to /dev/uinput at RUNTIME; `--version` proves nothing about that.
+# SteamOS grants it to the seat user via udev uaccess, so a stock Deck
+# never sees this; anywhere else the proxy would otherwise degrade silently
+# at every launch (2 s poll + kill per slot). Soft warning, never fatal.
+_evsieve_warn_uinput() {
+    [[ -w /dev/uinput ]] && return 0
+    print_warning "/dev/uinput is not writable by this user right now — \
+seamless controller reconnect will be unavailable at runtime until it is \
+(udev uaccess rules / seat session)."
+    return 0
+}
+
 # _evsieve_write_stamp: Write the commit + patch-sha stamp. Called ONLY
 # after _evsieve_host_verify passes, so a stamp never certifies a binary
 # the host cannot run.
@@ -557,6 +570,7 @@
         # shellcheck disable=SC2034  # PROVIDED global: read by callers/tests.
         EVSIEVE_INSTALL_STATUS="installed-prebuilt"
         print_success "evsieve installed from prebuilt release asset: $(_evsieve_bin)"
+        _evsieve_warn_uinput
         return 0
     fi
     print_info "Prebuilt evsieve unavailable or unusable — building from source instead."
@@ -633,5 +647,6 @@
     # never read inside this file (documented in the module header).
     EVSIEVE_INSTALL_STATUS="installed"
     print_success "evsieve built and installed: $(_evsieve_bin)"
+    _evsieve_warn_uinput
     return 0
 }
```
</details>
<details><summary>D18 — controller_monitor.sh (5 hunks)</summary>

```diff
--- a/modules/controller_monitor.sh	2026-09-28 17:42:45.486651342 +0000
+++ b/modules/controller_monitor.sh	2026-09-28 18:08:59.151382040 +0000
@@ -96,6 +96,7 @@
 # internal reads use the MCSS names. Guarded: re-sourcing must not re-readonly.
 if [[ ! -v CONTROLLER_MONITOR_STEAM_VENDOR ]]; then
     readonly CONTROLLER_MONITOR_STEAM_VENDOR="$MCSS_STEAM_VENDOR_ID"
+    # shellcheck disable=SC2034  # one-release deprecation alias for external consumers/tests
     readonly CONTROLLER_MONITOR_STEAM_PRODUCT="$MCSS_STEAM_PRODUCT_ID"
 fi
 
@@ -386,6 +387,8 @@
     for ei in "${!e_sorted[@]}"; do
         (( count >= MCSS_MAX_PLAYERS )) && break
         local e_input e_ev e_js e_ven e_prod
+        # shellcheck disable=SC2034  # e_ev/e_js: positional fields of the
+        # 5-field record; only input/vendor/product are used here.
         read -r e_input e_ev e_js e_ven e_prod <<< "${e_sorted[$ei]}"
         local picked=-1
         for vi in "${!v_sorted[@]}"; do
@@ -393,6 +396,7 @@
             for c in "${claimed[@]}"; do [[ "$c" == "$vi" ]] && { already=1; break; }; done
             (( already )) && continue
             local v_input v_ev v_js
+            # shellcheck disable=SC2034  # v_ev/v_js: positional; only v_input keys the match.
             read -r v_input v_ev v_js <<< "${v_sorted[$vi]}"
             if (( v_input > e_input )); then picked=$vi; break; fi
         done
@@ -442,7 +446,8 @@
     local keybits="$1"
     # FAIL-OPEN on an empty/whitespace-only bitmap.
     [[ -z "${keybits// /}" ]] && return 0
-    local -a words=($keybits)
+    local -a words
+    read -ra words <<< "$keybits"   # D18: deliberate word-split, done robustly
     local n=${#words[@]}
     # FAIL-OPEN when the BTN_ range word was never emitted (fewer than 5 words).
     (( n < 5 )) && return 0
@@ -810,7 +815,8 @@
     done <<< "$current_output"
 
     # Find added devices (in current but not in previous)
-    local prev_array=($prev_nodes)
+    local -a prev_array
+    read -ra prev_array <<< "$prev_nodes"   # D18: deliberate word-split, done robustly
     local ev
     for ev in "${!current_nodes[@]}"; do
         local found=0
```
</details>
