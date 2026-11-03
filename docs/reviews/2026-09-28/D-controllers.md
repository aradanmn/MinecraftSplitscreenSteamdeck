# Review D — controllers / dock / evsieve

Files reviewed in full: `modules/controller_monitor.sh` (976 lines),
`modules/controller_proxy.sh` (604), `modules/evsieve_management.sh` (637),
`modules/dock_detection.sh` (266). Cross-module contracts traced into
`orchestrator.sh` (`_handle_msg`, docked startup-acquire, monitor start/kill,
`_read_fifo_msg`), `instance_lifecycle.sh` (`_maybe_proxy_swap`,
`_vp_of_js_node`), `runtime_context.sh` (`mcss_resolve_paths`,
`mcss_query_displays`), `utilities.sh` (`fetch_url`, `run_with_spinner`),
`main_workflow.sh` (`install_evsieve` call site), the launcher's FIFO sites,
and GitHub issues #133/#134 (via API; `gh` is not installed here).

Empirical probes (scratchpad, no repo files touched):
- Sourced `controller_monitor.sh` against a 4-block `/proc` fixture (3 DS4 +
  one `MCSS-slot1` virtual) and a held-open FIFO to confirm D2, D3, D7.
- `X=1 bash -c 'readonly X=500; echo $X'` → `500` (D7).
- `bash -c 'f(){ trap ... RETURN; }; f; g'` → RETURN trap does NOT leak past
  the function that set it (the `trap … RETURN` pattern in `install_evsieve`
  is sound — no finding).
- `shellcheck -x` 0.11.0 on all four files (D18).

---

### D1. dock_detection emits a destructive DISPLAY_MODE_CHANGE from ONE un-corroborated sysfs read (the HW-2 force-reboot path is still live)
- **Severity:** High
- **Category:** principle-violation (PRINCIPLES #5 fail-open) / robustness
- **File:** `modules/dock_detection.sh:242-252`, `modules/dock_detection.sh:255-264`, `modules/dock_detection.sh:85-101`; consumer `modules/orchestrator.sh:660-685`
- **Status:** CONFIRMED — [KNOWN: docs/HW2-VALIDATION-2026-07-22.md §"The opening crash"; GitHub #133 closed `not_planned` 2026-07-25 after the #138 debounce was reverted]
- **What:** Both watch paths do a single read and emit immediately:
  ```bash
  sleep 0.5
  local new_mode
  new_mode=$(get_display_mode)
  if [[ "$new_mode" != "$current_mode" ]]; then
      echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true
  ```
  `_detect_via_drm` keys ONLY on `status` (`status=$(cat "$status_file" 2>/dev/null || true)`; anything but the literal `connected` — including a failed read — counts as "not connected"), never corroborating with the sibling `enabled`/`dpms` attributes. The orchestrator's `DISPLAY_MODE_CHANGE handheld` handler then runs `teardown_instance` on every slot but 1 (orchestrator.sh:670-675). PRINCIPLES.md #5 states dock_detection "(post-#133 design) confirms a mode across reads" — the code does not; the #138 fix was reverted and the issue closed as not-reproduced, so the doc and the code disagree.
- **Failure scenario:** Docked 4-up session; one transient `card0-DP-1/status = disconnected` read (HW-2 log: DP-1 read `connected` immediately before and after) → `handheld` emitted → three players' instances torn down, MC moved to the internal panel, froze; force reboot. Also: any transient `cat` failure (EIO / sysfs hiccup) on every connector reads as `handheld`, the destructive direction, instead of "can't tell — keep last-good".
- **Fix:** Implement the corroboration the #133 close-out itself recommends, cheaply and fail-open: (a) in `_detect_via_drm`, when `status` is not `connected` but the connector's `enabled` file reads `enabled` (and/or `dpms` = `On`), treat the read as inconclusive and return a distinct code (e.g. `2`) so `get_display_mode` keeps the previous answer; (b) in `watch_display_mode`, only emit a `handheld` transition after the candidate persists across `DOCK_DETECTION_CONFIRM_SAMPLES` reads spaced `DOCK_DETECTION_CONFIRM_INTERVAL_S` (docked→handheld is the destructive direction; handheld→docked can stay immediate). (c) Either way, fix PRINCIPLES.md #5 so it stops describing a design that isn't shipped.

### D2. The controller-monitor add debounce is dead code: `_CONTROLLER_MONITOR_DEBOUNCE_MAP` is only ever written inside a `$(…)` subshell — and if it ever DID fire it would permanently swallow a pad
- **Severity:** Medium
- **Category:** bug (subshell-lost variable) / logic
- **File:** `modules/controller_monitor.sh:963`, `modules/controller_monitor.sh:973` (callers), `modules/controller_monitor.sh:828-833`, `modules/controller_monitor.sh:858`, `modules/controller_monitor.sh:864`
- **Status:** CONFIRMED (probe: after `prev=$(_check_devices_changed docked "")` the map is `declare -A _CONTROLLER_MONITOR_DEBOUNCE_MAP` (empty); after an in-process call it holds 3 entries)
- **What:** The N16/H1 fix made both loops call
  `prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")`. Every write to the debounce map (`_CONTROLLER_MONITOR_DEBOUNCE_MAP["$ev"]=$now_ms`, line 833; `unset …`, line 858) now happens in the command-substitution subshell and is discarded. In the parent the map is always empty, so `last_ms` is always `0` and `(( now_ms - 0 <= 500 ))` is never true: the 500 ms "debounce" never engages. Worse, the logic is wrong even in-process: on a debounce hit the code does `continue` (no ADD) but the node is still in `current_nodes`, so line 864 returns it as part of the new baseline — the next scan sees it as "already known" and the CONTROLLER_ADD is never sent.
- **Failure scenario:** Today: no debounce at all (harmless but the constant, docstring, header and stderr message all claim one). If someone "fixes" the subshell loss without fixing the `continue`: pad flaps add→remove→add inside 500 ms → second add debounced → node enters the baseline silently → that pad never spawns / never RESUMEs until it is unplugged again.
- **Fix:** Either delete the debounce (the orchestrator's serial loop + slot_claim already tolerate duplicate ADDs) and remove `CONTROLLER_MONITOR_DEBOUNCE_MS` + its docs, or keep state out of the subshell (write the map via a nameref/out-param, or move the diff loop so `_check_devices_changed` runs in-process and returns the baseline through a `local -n` out variable) AND on a debounced add, omit the node from the returned baseline so it is re-diffed next pass.

### D3. The MCSS-virtual identity gate exists only in `_list_raw_external_pads`; the two other enumeration sources still enumerate our own evsieve virtuals as player pads
- **Severity:** Medium
- **Category:** logic / principle-violation (#9 one encoding of the identity gate)
- **File:** `modules/controller_monitor.sh:551` (the only gate), `modules/controller_monitor.sh:341-350` (`_map_external_player_virtuals`), `modules/controller_monitor.sh:246-276` + `:689` (`_parse_all_gamepad_devices` / handheld branch)
- **Status:** CONFIRMED (probe with `CONTROLLER_MONITOR_RAW_BINDING=0`: `enumeration: 4 external pad(s)` including `external: input30 [054c:09cc] event9 js3` — the `MCSS-slot1` block)
- **What:** The #38 fix for the on-Deck "MCSS-virtual pollution" bug added `if [[ "$_nm" == MCSS-slot* ]]` inside `_consider` of the raw enumerator only. `_map_external_player_virtuals` (selected when `CONTROLLER_MONITOR_RAW_BINDING=0`, a documented, supported escape hatch) classifies every non-28de js device as an external — our virtuals advertise the pad's real `054c:09cc`, so they pass — and the handheld branch of `list_eligible_controllers` picks "the first gamepad-capable device (any VID:PID)" from `_parse_all_gamepad_devices`, which has no name gate either. `parse_input_device_blocks` already delivers the `name` field to all three readers, so the gate could live once at the shared boundary.
- **Failure scenario:** `CONTROLLER_MONITOR_RAW_BINDING=0` with the (default-on) proxy: each real pad's evsieve virtual is enumerated as a 5th/6th "external", claims a Steam virtual, and its create/destroy churn misroutes CONTROLLER_ADD/REMOVE exactly as in the 2026-07-25 on-Deck failure — the escape hatch is now the polluted path. Handheld: if a `MCSS-slot<N>` virtual outlives a docked→handheld transition (evsieve is only stopped on SLOT_DIED), `list_eligible_controllers handheld` can return the proxy virtual as "the" pad.
- **Fix:** Move the `MCSS-slot*` name gate into the one reader every path uses (`parse_input_device_blocks` cannot filter — it is the raw parser — so add a thin `_is_mcss_proxy_virtual "$name"` helper and call it in `_parse_all_gamepad_devices` and `_map_external_player_virtuals` as well). Share the `MCSS-slot` literal with `controller_proxy.sh` via one `MCSS_PROXY_DEVNAME_PREFIX` in `runtime_context.sh` (see D14).

### D4. Prebuilt evsieve is installed OVER the existing binary before the host-exec check, with no rollback
- **Severity:** Medium
- **Category:** bug / robustness
- **File:** `modules/evsieve_management.sh:241`, `modules/evsieve_management.sh:555-561`, `modules/evsieve_management.sh:487-492` (`_evsieve_install_binary`)
- **Status:** CONFIRMED
- **What:** `_evsieve_try_prebuilt` ends with `_evsieve_install_binary "$bin_file"` (atomic `mv` onto `$TARGET_DIR/bin/evsieve`), and only THEN does `install_evsieve` run `&& _evsieve_host_verify`. If the downloaded binary passes the SHA check but does not execute on this host (glibc/libevdev ABI, a bad CI build), the previously-installed, working binary has already been replaced; the code "falls through to build-at-install", which on a Deck without git/podman/distrobox degrades (`degraded-no-toolchain`) and leaves the broken file in place, executable, with no stamp. Same ordering on the build path (line 597→604), but there the prior binary is only lost if a build succeeded and then failed to run.
- **Failure scenario:** Pin bump → stale stamp → prebuilt fetched → `mv` over the good v-old binary → `--version` fails → toolchain absent → install ends "degraded" but `$MCSS_EVSIEVE_BIN` is `-x`. At runtime `_proxy_evsieve_bin` says "available", `proxy_start_slot` spawns it, polls 2 s, kills it, returns 1 — every slot, every launch — and `_maybe_proxy_swap` falls back to raw binding: seamless reconnect silently lost plus a ~2 s launch penalty per player, with no message anywhere near the user.
- **Fix:** Verify before install: run `"$bin_file" --version` on the candidate (it already has +x) inside `_evsieve_try_prebuilt` before `_evsieve_install_binary`; on the build path run the same check on `target/release/evsieve` before copy-out. Alternatively have `_evsieve_install_binary` keep `bin_path.prev` and restore it if `_evsieve_host_verify` fails.

### D5. Prebuilt evsieve integrity rests on a checksum fetched from the same mutable location as the binary; the release owner is hard-coded and diverges from the installer's repo constants
- **Severity:** Medium
- **Category:** security / hardcoded
- **File:** `modules/evsieve_management.sh:98-102`, `modules/evsieve_management.sh:213-239`
- **Status:** CONFIRMED
- **What:** `EVSIEVE_RELEASE_ASSET_BASE_URL="https://github.com/aradanmn/MinecraftSplitscreenSteamdeck/releases/latest/download"`; `.stamp`, `.sha256` and the binary are all fetched from that URL and compared against each other. The only pinned values are `commit=`/`patch_sha256=` in the stamp, which the same publisher writes. Unlike the source path (pinned `EVSIEVE_SOURCE_ARCHIVE_SHA256`, pinned commit, SHA-verified patch), nothing in the tree pins the BINARY's digest, so "checksum-verified" here detects transport corruption only, not a swapped release asset. Separately, every other network location in the installer derives from `MCSS_REPO_RAW_URL` (install-minecraft-splitscreen.sh:115, which itself hard-codes `aradanmn`), but this URL is an independent literal — a fork installing from its own `REPO_REF` still executes aradanmn's binary, and `releases/latest` ignores `REPO_REF` entirely.
- **Failure scenario:** A mistaken or malicious re-upload of the `latest` release assets (or a fork owner who expects their fork's binary) passes all checks and a binary that grabs every player's input device is installed with no local pin to catch it.
- **Fix:** Pin `EVSIEVE_PREBUILT_SHA256` in the module next to the source-archive SHA (release.yml can print it; bump both together), compare the downloaded binary against THAT, and keep the remote `.sha256` only as an early-abort. Derive the owner/repo from one installer constant (e.g. `MCSS_REPO_SLUG`) shared with `MCSS_REPO_RAW_URL`.

### D6. `proxy_start_slot` failure path leaves the pad symlink behind (docstring says "no side effects survive"), and the crash-residue reaper `proxy_stop_all` is never called in production
- **Severity:** Low
- **Category:** logic / dead-code
- **File:** `modules/controller_proxy.sh:383`, `modules/controller_proxy.sh:407-412`, `modules/controller_proxy.sh:591-604`; header claim `:346-348`
- **Status:** CONFIRMED (repo-wide grep: `proxy_stop_all` is referenced only by `tests/test_controller_proxy.sh`)
- **What:** On "virtual never came up" the function kills its child and calls `_proxy_forget_slot` (pidfile + cache only) — `$MCSS_PROXY_PADS_DIR/slot<N>` created by `ln -sfn` at line 383 stays. The module header (`proxy_stop_all … called by nobody until PR4's cleanup() backstop + startup reap`) describes wiring that never happened after PR4 landed, so stale `slot*` links and `proxy-slot*.pid` files (which survive under the `/tmp` fallback) are never reaped.
- **Failure scenario:** Mostly cosmetic today (next `proxy_start_slot` re-`ln -sfn`s; stale pids are identity-checked). But a stale pad link left after a start failure points at an eventN the kernel will reuse — if a later `proxy_repoint_slot`/manual evsieve is ever pointed at that dir before a fresh start, it is the #151 shape again.
- **Fix:** In the failure path `rm -f "$pad_link"` (and the virt link if evsieve managed to create it). Wire `proxy_stop_all` into the orchestrator's `cleanup()` and a startup reap as the header promises, or delete the promise.

### D7. `CONTROLLER_MONITOR_DEBOUNCE_MS` is documented as an env override but `readonly …=500` clobbers any inherited value
- **Severity:** Low
- **Category:** hardcoded / bug
- **File:** `modules/controller_monitor.sh:91`; header `:32-33`, `:66`
- **Status:** CONFIRMED (`X=1 bash -c 'readonly X=500; echo $X'` prints `500`)
- **What:** `readonly CONTROLLER_MONITOR_DEBOUNCE_MS=500` assigns unconditionally, unlike the `EVSIEVE_DISTROBOX_NAME="${EVSIEVE_DISTROBOX_NAME:-…}"` pattern used elsewhere. The header lists it under "Environment overrides (for testing)". Moot while D2 makes the debounce dead, but a test written to the documented contract could never exercise it.
- **Fix:** `readonly CONTROLLER_MONITOR_DEBOUNCE_MS="${CONTROLLER_MONITOR_DEBOUNCE_MS:-500}"` — or drop the override claim if D2 is resolved by deletion.

### D8. `CONTROLLER_PROXY_START_TIMEOUT_S` / `_STOP_TIMEOUT_S` are only ever printed; the real bound is `ITERS × INTERVAL`, so the three constants can drift apart
- **Severity:** Low
- **Category:** hardcoded (ARCHITECTURE §3 "a constant's existence obligates its use") / principle-violation (#9)
- **File:** `modules/controller_proxy.sh:122-124`, `:132-133`; uses at `:312`, `:408` (messages only); loops at `:299`, `:398`
- **Status:** CONFIRMED
- **What:** The poll loops iterate `CONTROLLER_PROXY_START_POLL_ITERS`/`STOP_POLL_ITERS` × `CONTROLLER_PROXY_POLL_INTERVAL_S`; the `_TIMEOUT_S` values appear only in the "within Ns" log strings. Change one and the log lies.
- **Fix:** Derive iterations from the timeout (`ITERS=$(( TIMEOUT_S * 10 ))` with `INTERVAL_S=0.1`), or drop the `_TIMEOUT_S` names and print `$(( ITERS ))×$INTERVAL_S`.

### D9. `watch_display_mode` silently returns if `inotifywait` fails to start; the poll fallback is not a safety net, it is an either/or
- **Severity:** Low
- **Category:** robustness / principle-violation (#5)
- **File:** `modules/dock_detection.sh:228-253`, comment at `:239-240`
- **Status:** CONFIRMED
- **What:** `while inotifywait … 2>/dev/null; do … done` — if `inotifywait` exits non-zero (inotify watch limit exhausted, EACCES on sysfs, an unexpected `-r` failure), the loop body never runs and the function falls off the end with exit 0. The orchestrator heartbeat then restarts it every ~5 s forever (a WARNING per restart), and the poll path (which only runs when the binary is ABSENT) is never used. The in-code comment ("The poll fallback below is unchanged as the safety net either way") is inaccurate.
- **Fix:** After the `while inotifywait` loop, log the exit and fall through into the poll loop instead of returning (`echo "… inotifywait exited — falling back to polling" >&2` then the existing `while true` loop).

### D10. Neither monitor traps TERM to reap its own child (udevadm process substitution / inotifywait)
- **Severity:** Low
- **Category:** robustness (STYLE-GUIDE §7.9) — [KNOWN: docs/BUG-AUDIT-2026-06-24-followup.md N15; docs/TODO.md #25/N15]
- **File:** `modules/controller_monitor.sh:965`, `modules/dock_detection.sh:242`
- **Status:** CONFIRMED (the mitigation lives entirely in orchestrator.sh:1059-1090 via `_kill_tree`/`pkill -P`)
- **What:** `start_controller_monitor` and `watch_display_mode` spawn long-lived children but install no `trap … TERM` of their own, so a plain `kill $pid` from any caller other than the orchestrator's cleanup (tests, the heartbeat restart path, a future refactor) orphans `udevadm monitor` / `inotifywait` — which, per N15, keeps the FIFO write-end open across runs.
- **Fix:** In each function, record the child PID (`< <(…)` → `$!` is not available; use a coprocess or `udevadm … & pid=$!` with a named pipe) and `trap 'kill "$child" 2>/dev/null' TERM EXIT`. Minimum: document the orchestrator dependency in both headers.

### D11. FIFO writes in controller_monitor have no `-p` guard and no `|| true`; a missing/replaced FIFO path silently becomes a regular file the reader never sees
- **Severity:** Low
- **Category:** robustness / security (predictable `/tmp` path — owned by runtime_context/orchestrator, exercised here)
- **File:** `modules/controller_monitor.sh:847`, `:856`, `:926`; contrast `modules/dock_detection.sh:249` (H6 `|| true`)
- **Status:** PLAUSIBLE (mechanism verified by reading; needs a pre-existing non-FIFO at `$SPLITSCREEN_FIFO` to trigger)
- **What:** `echo "$_add_line" >> "$fifo"` — `>>` on a path that is not a FIFO creates/appends a regular file with no error. The orchestrator creates the FIFO with `mkfifo … || true` (orchestrator.sh:979) and its reader refuses anything that is not `-p` (orchestrator.sh:157). The default path `/tmp/minecraft-splitscreen.fifo` is fixed and world-writable-parent; any stale regular file (or another local user's file — single-user Deck makes this Low) at that path means every CONTROLLER_ADD lands in a plain file and no player ever spawns, with only the generic "could not open persistent FIFO reader" warning.
- **Fix:** Guard the writer: `[[ -p "$fifo" ]] || { echo "[controller_monitor] FIFO gone" >&2; return 1; }` before writing, and `|| true` the write like dock_detection does. Longer term, put the FIFO under `$MCSS_HELPER_DIR` (0700) rather than `/tmp`.

### D12. `uniq` is tokenised differently on the monitor's two ADD paths vs the orchestrator's startup-acquire path
- **Severity:** Low
- **Category:** logic (contract mismatch)
- **File:** `modules/controller_monitor.sh:841`, `:919` (`awk '{print $5}'`), `modules/controller_monitor.sh:729-736` (raw `${_uq}` emit via `read -r … _uq`, which slurps the remainder); consumer `modules/orchestrator.sh:866` (`_handle_msg "CONTROLLER_ADD $_aq_line"`) and `:530` (`read -r … phys_uniq`)
- **Status:** PLAUSIBLE (requires a device whose `U: Uniq=` contains whitespace; all DS4/DualSense/Xbox pads report a MAC or serial without spaces)
- **What:** `list_eligible_controllers` emits uniq exactly as `read -r … _uq` captured it (everything after the 4th field). The orchestrator's startup-acquire passes that whole line into `_handle_msg`, whose `read -r` also slurps the remainder into `phys_uniq`; but the hotplug path in `_check_devices_changed`/`start_controller_monitor` extracts `awk '{print $5}'` — the FIRST token only. A whitespace-bearing uniq therefore yields two different identity strings for the same pad depending on which path emitted the ADD.
- **Failure scenario:** Pad with `Uniq=ABC 123` acquired at startup (identity `ABC 123`), disconnects, reconnects via hotplug (identity `ABC`) → `slot_claim` cannot match the MAC → SPAWN/REJECT instead of RESUME.
- **Fix:** Use one tokeniser: replace the per-field `awk` calls with `read -r ev js_node phys_vendor phys_product phys_uniq <<< "$cline"` (same slurp semantics as the orchestrator), which also removes 4-5 forks per device per scan (see D19).

### D13. Dead code: `_eventN_to_virtual_idx`, `get_controller_by_index` (public API), `proxy_stop_all` (production)
- **Severity:** Low
- **Category:** dead-code
- **File:** `modules/controller_monitor.sh:289-302`, `modules/controller_monitor.sh:750-766`, `modules/controller_proxy.sh:591-604`
- **Status:** CONFIRMED (repo-wide grep incl. tests and the launcher: `_eventN_to_virtual_idx` 0 callers; `get_controller_by_index` 0 callers; `proxy_stop_all` tests only)
- **What:** `_eventN_to_virtual_idx` survived the Fix #51 cleanup that removed its sibling `_find_internal_by_pad_name` and has no callers. `get_controller_by_index` is listed in the module's Public API but nothing (not even the tests) calls it. `proxy_stop_all` — see D6.
- **Fix:** Delete the first two (tombstone one-liner per STYLE-GUIDE §4); wire or delete the third.

### D14. Duplicated / unnamed literals across the four modules
- **Severity:** Low
- **Category:** hardcoded / principle-violation (#9)
- **File:** `MCSS-slot` device-name prefix: `modules/controller_proxy.sh:389`, `:546` and `modules/controller_monitor.sh:551` (the identity gate keys on a literal another module owns). Settle/poll sleeps: `modules/controller_monitor.sh:959` (`sleep 0.1`), `:970` (`sleep 2`), `modules/dock_detection.sh:244` (`sleep 0.5`). Node prefixes `/dev/input/event`/`/dev/input/js`: `modules/controller_monitor.sh:701`, `:730-733`, `modules/controller_proxy.sh:565`. `*/evsieve` basename: `modules/controller_proxy.sh:252`. `28de` re-embedded default: `modules/instance_lifecycle.sh:509` (`${CONTROLLER_MONITOR_STEAM_VENDOR:-28de}` — the consumer-side `:-fallback` ARCHITECTURE §3 forbids).
- **Status:** CONFIRMED
- **What:** The `MCSS-slot` prefix is the cross-module contract that makes the #38 pollution gate work; three sites, no shared constant, so a rename in `controller_proxy.sh` silently re-opens the 2026-07-25 bug. The sleeps are unnamed timing literals in the class ARCHITECTURE §3 lists as backlog (#86).
- **Fix:** `MCSS_PROXY_DEVNAME_PREFIX="MCSS-slot"` in runtime_context.sh, consumed by both modules; `CONTROLLER_MONITOR_SETTLE_S`, `CONTROLLER_MONITOR_POLL_INTERVAL_S`, `DOCK_DETECTION_SETTLE_S` module constants; drop the `:-28de` in instance_lifecycle.

### D15. `_evsieve_build_in_box` splices `$src_dir` into a single-quoted `sh -c` script
- **Severity:** Low
- **Category:** security (injection, self-inflicted) / robustness
- **File:** `modules/evsieve_management.sh:431`
- **Status:** CONFIRMED
- **What:** `cd "'"$src_dir"'"` — `src_dir` derives from `TARGET_DIR` (user/env-controlled, may contain `'`). A single quote in the path ends the `sh -c` string early: the build breaks (fail-open → `degraded-build-failed`) or, with a crafted value, runs arbitrary text inside the box. Not exploitable across users, but fragile.
- **Fix:** Pass the path as a positional: `sh -c 'set -e; …; cd "$1"; cargo build --release' _ "$src_dir"`.

### D16. `/tmp` fallback for `MCSS_HELPER_DIR` puts evsieve logs, pidfiles and both symlink farms at predictable world-writable-parent paths
- **Severity:** Low
- **Category:** security (owned by runtime_context.sh:346-348; exercised by controller_proxy)
- **File:** `modules/controller_proxy.sh:385-392` (`>>"$logfile"`), `:379-383` (`mkdir -p` + `ln -sfn` under `$MCSS_HELPER_DIR`), `:189-201` (pidfile)
- **Status:** CONFIRMED (mechanism); low impact on a single-user Deck
- **What:** When `$XDG_RUNTIME_DIR/mcss` is unwritable, `MCSS_HELPER_DIR=/tmp`, so `/tmp/evsieve-slot1.log` is opened with `>>` (classic symlink-clobber), `/tmp/proxy-pads` and `/tmp/proxy-virt` are `mkdir -p`'d (a pre-existing directory owned by someone else is accepted silently), and `/tmp/proxy-slot1.pid` is read (mitigated by `_proxy_pid_is_ours`). The pidfile side is already hardened; the log and dirs are not.
- **Fix:** Fall back to `mktemp -d /tmp/mcss.XXXXXX` (0700) rather than bare `/tmp`, or at minimum refuse a pre-existing `$MCSS_PROXY_*_DIR` not owned by `$UID` (`[[ -O "$dir" ]]`).

### D17. No install-time or preflight check that the user can open `/dev/uinput`; `_evsieve_host_verify` only runs `--version`
- **Severity:** Info
- **Category:** robustness
- **File:** `modules/evsieve_management.sh:498-500`; (absent from `modules/preflight.sh`)
- **Status:** CONFIRMED (repo-wide grep: `uinput` appears only in comments/probes)
- **What:** evsieve's `--output create-link=` needs write access to `/dev/uinput` and read access to `/dev/input/event*`. SteamOS grants both to the seat user via udev `uaccess` tags, so nothing is broken on a stock Deck, but the install reports "evsieve installed" from `--version` alone; on a host without those rules the runtime degrades per D4's scenario (2 s poll + kill per slot per launch) with no diagnostic at install time. No `sudo` is used on the host anywhere in these modules (only `sudo -n` inside the distrobox) — that is the correct posture.
- **Fix:** In `_evsieve_host_verify` (or preflight, soft warning) add `[[ -w /dev/uinput ]]` and log a clear "seamless reconnect will be unavailable: /dev/uinput not writable" — fail-open, never fatal.

### D18. shellcheck is not clean on `controller_monitor.sh` (STYLE-GUIDE §7.8)
- **Severity:** Info
- **Category:** test-quality / style
- **File:** `modules/controller_monitor.sh:445` (SC2206 `local -a words=($keybits)`), `:813` (SC2206 `local prev_array=($prev_nodes)`), `:99` (SC2034 `CONTROLLER_MONITOR_STEAM_PRODUCT`), `:389`, `:396` (SC2034 `e_ev e_js v_ev v_js`)
- **Status:** CONFIRMED (`shellcheck -x` 0.11.0)
- **What:** Two deliberate word-splits lack the required `# shellcheck disable=SC2206  # reason` suppression; four unused `read` targets and the exported-for-consumers alias lack their `SC2034` annotations (the sibling sites in the same file have them).
- **Fix:** Add the suppressions with reasons, or use `read -ra words <<< "$keybits"` / `read -ra prev_array <<< "$prev_nodes"`.

### D19. Per-field `$(echo … | awk)` forks in the hot enumeration paths
- **Severity:** Info
- **Category:** robustness (performance) / style
- **File:** `modules/controller_monitor.sh:807-810`, `:837-841`, `:914-919`, `:297`, `:378-382`
- **Status:** CONFIRMED
- **What:** Each scanned device costs 4-5 `echo|awk` subshell pairs in `_check_devices_changed` and again in `start_controller_monitor`, plus 2-3 per row in `_map_external_player_virtuals` diagnostics — dozens of forks per udev event on a 4-pad rig, inside the `sleep 0.1` settle window the monitor relies on. A single `read -r a b c d e <<< "$line"` is both faster and the fix for D12.
- **Fix:** As D12.

### D20. Pidfile contents are not validated as a PID before `kill -0`
- **Severity:** Info
- **Category:** robustness (defense in depth)
- **File:** `modules/controller_proxy.sh:199`, `:224-226`
- **Status:** CONFIRMED (safe today: `kill -0 -1` succeeds but `_proxy_pid_is_ours -1` then fails on `/proc/-1/cmdline`, so the record is forgotten and nothing is signalled)
- **What:** `pid=$(<"$pidfile")` is fed straight to `kill -0 "$pid"`. Garbage such as `-1`, `0`, or `%1` reaches `kill`; the identity check catches it, but only because it happens to run second.
- **Fix:** `[[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid=""` in `_proxy_tracked_pid`.

### D21. `proxy_start_slot` failure path uses an unbounded `wait` after a plain `kill`
- **Severity:** Info
- **Category:** principle-violation (#6 bounded waits)
- **File:** `modules/controller_proxy.sh:409-410`
- **Status:** PLAUSIBLE (evsieve exits promptly on SIGTERM in every probe log; a hung evsieve has not been observed)
- **What:** `kill "$pid"; wait "$pid"` — the child IS this shell's child here, so `wait` blocks until it exits; if evsieve wedges in a libevdev grab it never returns, stalling `_maybe_proxy_swap` and therefore the spawn of that slot. `_proxy_kill_verified` already implements the right pattern (TERM, bounded poll, KILL).
- **Fix:** Reuse `_proxy_kill_verified "$pid" "$slot"` on the failure path instead of the bare kill/wait.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 1 (D1) |
| Medium | 4 (D2, D3, D4, D5) |
| Low | 11 (D6–D16) |
| Info | 5 (D17–D21) |

**Top 3**

1. **D1** — dock_detection still tears down a live docked session on a single un-corroborated DRM `status` read (the HW-2 force-reboot path). Issue #133 was closed `not_planned` after the debounce was reverted, yet PRINCIPLES.md #5 documents a confirmation design that is not in the code. The issue's own close-out names the cheap, fail-open fix (corroborate `status` with `enabled`/`dpms`; confirm the destructive direction across reads).
2. **D2** — the controller-monitor add debounce is dead code: its map is only ever written inside `$(…)`, so the parent's map is always empty. The latent `continue`-then-baseline logic would permanently hide a pad if the subshell loss were ever "fixed" in isolation.
3. **D4 + D5** — the #126 prebuilt evsieve path installs over a working binary before verifying it runs (no rollback), and its "checksum verification" pins nothing locally (the digest, stamp and binary all come from the same mutable `releases/latest` URL, hard-coded to one owner). Together they can silently replace a working proxy with a broken or unexpected one, degrading every launch to raw binding with a 2 s-per-slot penalty and no user-visible diagnosis.

Also worth a quick fix because it is a one-liner each: D3 (extend the `MCSS-slot*` gate to the other two enumeration sources so the escape-hatch and handheld paths stop enumerating our own virtuals) and D9 (fall through to polling when `inotifywait` fails instead of returning).
