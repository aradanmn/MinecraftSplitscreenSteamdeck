# Raw-device controller-bind rewrite — implementation plan

> Produced by a 4x (draft→adversarial-challenge→revise) planning loop, 2026-06-26.
> Gated behind **`CONTROLLER_MONITOR_RAW_BINDING` (default OFF)** — flip to `1` to test.

## Approach

Bind each REAL external pad's OWN raw legacy joystick node (jsN) into its slot sandbox instead of a Steam 28de:11ff virtual, via a NEW self-contained docked enumerator `_list_raw_external_pads`, gated behind env flag CONTROLLER_MONITOR_RAW_BINDING (default OFF) with the existing `_map_external_player_virtuals` (controller_monitor.sh 407-466) retained as the selectable fallback so flipping the flag is the only behavioral switch. PRIMARY BINDING IS js-ONLY: Steam Input's EVIOCGRAB lives on the evdev eventN, NOT on the separate legacy jsN char device (jsN is multiply-openable and has no grab ioctl), so under raw mode `_build_bwrap_command` (instance_lifecycle.sh 159-168) binds ONLY /dev/input/jsN and does NOT --dev-bind the eventN; the eventN stays the slot's identity (state file event_node + CONTROLLER_REMOVE matching) but never enters the namespace, so a grabbed/dead evdev can never be surfaced to Controlify's SDL. The new enumerator does its OWN single-pass /proc/bus/input/devices parse (mirroring _parse_all_gamepad_devices 124-203) and does NOT modify the shared 6-field parser, keeping the multi-word `B: KEY=` bitmap off every `read` boundary. Enumeration = evdev devices that HAVE a js handler AND vendor != 28de (excludes both 11ff virtuals and 1205 Steam/built-in, which has no raw js gamepad node so it becomes structurally unselectable — the core §3b fix), gamepad-capability gated INCLUSIVELY (BTN_SOUTH 0x130 OR BTN_JOYSTICK 0x120 OR unparseable → accept), shared-parent deduped (keep lowest jsN), ordered by (inputN, eventN). The producer's snapshot skew is fixed by having `_check_devices_changed` enumerate ONCE and echo the resulting current event-node set on stdout, so the producer sets prev_nodes from the SAME capture, removing the second independent enumeration (lines 680-690 / 699-706). A udev burst-coalescing drain plus a bounded asymmetric settle collapse the ~5 lines of one physical (dis)connect and also react to 'change' actions. The acquire↔baseline handoff gap is closed by passing the acquired event-node set to the monitor (CONTROLLER_MONITOR_ALREADY_ACQUIRED). SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD becomes per-slot+mode-independent but is DEFENSIVE-ONLY under js-only binding (no 28de node ever in a raw namespace). The validated SDL isolation hardening (--tmpfs /run/udev, steam.pipe mask, SDL_JOYSTICK_DISABLE_UDEV=1, HIDAPI=0, CLASSIC=1) is preserved verbatim. The fast-flap zombie-slot leak is DISCLOSED as a pre-existing orchestrator defect (CONTROLLER_REMOVE is a deliberate no-op, #37), NOT claimed fixed; inputN-based replacement detection is DROPPED as unsourced. Dead-code purge and the now-inert orchestrator mask plumbing removal are DEFERRED to a separate commit. DEFAULT stays OFF until the committed flip criterion (in-sandbox Controlify-reads-raw-js-with-Steam-Input-ON probe passes AND user confirms in-game on >=2 pads) is met; the §3b built-in leak remains live by default until then.

## Enumeration algorithm

NEW `_list_raw_external_pads` (controller_monitor.sh, inserted directly after `_map_external_player_virtuals` ends at line 466). It does its OWN single-pass parse of `$(_get_proc_input_path)`, mirroring the block structure of `_parse_all_gamepad_devices` (124-203), and does NOT touch `_parse_all_gamepad_devices` (keeps its shared 6-field contract intact and keeps the multi-word B: KEY bitmap from ever crossing a `read`).

PER-BLOCK CAPTURE (reset each block on blank line; handle trailing block as 186-202): `I:` Vendor/Product lowercased (regex as 166-171); `H: Handlers=` (as 173-174); `S: Sysfs=` (as 176-177); `P: Phys=` (as 179-180); NEW `B:*` case: when the line begins `B: KEY=`, store the remainder into a block-local `keybits` var (reset per block; ignore other B: subtypes like ABS=/REL=).

ON EACH BLOCK TERMINATOR:
1) JS-GATE: scan `$handlers` for a `js*` token (as 142-146); if none, skip the block (drops DS4/DualSense TOUCHPAD + MOTION event-only nodes and the lizard-mode built-in/puck which expose no js). Extract the `event*` token too (as 148-153). Joydev only attaches a jsN to joystick-class devices (EV_ABS + BTN_JOYSTICK/BTN_GAMEPAD), so keyboards/mice never reach this gate.
2) GAMEPAD-CAPABILITY GATE (inclusive): call `_has_gamepad_buttons "$keybits"` (quoted → the whole bitmap is ONE arg). ACCEPT if BTN_SOUTH(0x130) OR BTN_JOYSTICK(0x120) is set, OR if keybits is empty/has <5 words (fail-OPEN, never false-negative a real pad). REJECT only when keybits parses AND neither bit is set; log rejects to >&2.
3) VENDOR GATE: reject vendor == CONTROLLER_MONITOR_STEAM_VENDOR (28de, line 26) regardless of product — drops 11ff virtuals AND any 1205 that bears a js. Keep ALL other vendors (054c, 045e, 2dc8, 2563, 0079, ...). Do NOT hardcode 054c.
4) Parse inputN from the sysfs tail: `[[ "$sysfs" =~ input([0-9]+)$ ]] && inputn="${BASH_REMATCH[1]}"` (mirrors 415). Skip rows with empty inputN, eventN, or jsN.
5) Collect surviving rows as internal records `"<inputN> <eventN> <jsN> <vendor> <product> <sysfs>"` (sysfs kept ONLY for in-pass dedup; never emitted).
6) SHARED-PARENT DEDUP: parent key = sysfs with a trailing `/input/inputN` (and bare `/inputN`) stripped via sed, leaving the device-node path; fall back to phys when sysfs empty. Keep only the LOWEST jsN row per key (collapses 8BitDo dual-js under one uhid). Limitations (comment): the BT uhid `.000A` segment is a per-CONNECTION counter so the key is NOT durable across reconnect (in-pass dedup only); it does NOT collapse one pad on two USB interfaces nor USB+BT simultaneously (two parents → two pads).
7) SORT survivors `sort -n -k1,1 -k2,2` (inputN, then eventN tiebreaker) — a TOTAL deterministic order. Comment separates the two guarantees: (i) deterministic ordering for unchanged sets (load-bearing for prev_nodes diffing and the acquire poll); (ii) cold-start creation order for initial slot assignment (cosmetic, NOT preserved across reconnect — a reconnected pad gets a higher inputN). NO 'stable across reconnect' claim. Identity NEVER keys on uniq/MAC (shared-MAC DS4 constraint); the orchestrator dedups by raw event_node path (_find_slot_by_event_node 111).
8) DUAL-TRANSPORT GUARD: after dedup+sort, if two or more surviving rows share the SAME vendor:product, emit ONE prominent >&2 WARNING ('possible same pad on USB+BT, OR two identical pads — spawning both; if a ghost player appears, disconnect the idle transport'). Do NOT auto-collapse (VID:PID dedup would wrongly merge two identical same-MAC DS4s).
9) CAP at CONTROLLER_MONITOR_MAX_PLAYERS (4, line 23) AFTER the sort.
10) EMIT one line per kept pad: `"<eventN> <jsN> <vendor> <product>"` — the pad's OWN raw nodes. `list_eligible_controllers docked` (502-506) prefixes `/dev/input/event` and `/dev/input/js` exactly as today, preserving the 4-field public contract consumed by the producer, get_controller_by_index (512-528), and orchestrator.sh:244 `read -r event_node js_node phys_vendor phys_product`. Because the path is js-gated, the docked source ALWAYS emits BOTH event and js or nothing — never a js-less single-node line — so the orchestrator event==js sentinel (247) and spawn_instance's js-empty branch are docked-unreachable (assert via unit test). keybits and sysfs are NEVER part of the emitted line.

## File changes

### `modules/controller_monitor.sh` — NEW helper _has_gamepad_buttons (insert immediately before _list_raw_external_pads, after line 466)

**Change:** Inclusive bit-test of a `B: KEY=` bitmap string passed as $1. Split on spaces into words (MSW first). The kernel omits leading-zero most-significant words, so count from the END: take the 5th word from the end (bits 256-319 — both BTN_GAMEPAD/BTN_SOUTH=304 and BTN_JOYSTICK=288 live there). Test `(( (0x${word} & (1<<48)) != 0 ))` for BTN_SOUTH and `(( (0x${word} & (1<<32)) != 0 ))` for BTN_JOYSTICK using the SIGN-SAFE mask form (NOT a right-shift, which sign-extends a 64-bit word with bit 63 set). Return 0 (accept) if EITHER set, OR if the bitmap is empty / has fewer than 5 whitespace-delimited words (fail-open). Otherwise return 1 and echo a one-line reject reason to >&2. Comment the 64-bit-word assumption (SteamOS x86-64).

**Why:** Restricts the js gate to gamepad-class devices without false-negativing dinput/8BitDo pads; mask form avoids signed 64-bit arithmetic-shift sign-extension; counting from the end is robust to omitted leading-zero MSWs.

### `modules/controller_monitor.sh` — NEW function _list_raw_external_pads (insert after _has_gamepad_buttons, after line 466; KEEP _map_external_player_virtuals untouched)

**Change:** Self-contained single-pass /proc parse capturing per block: vendor/product (lowercased, regex as 166-171), handlers (as 173-174), sysfs (as 176-177), phys (as 179-180), and NEW keybits from a `B: KEY=` line. On each block terminator apply the 10-step enumeration algorithm: js-gate; INLINE `_has_gamepad_buttons "$keybits"`; vendor!=28de (CONTROLLER_MONITOR_STEAM_VENDOR); inputN parse from sysfs tail (regex as 415); shared-parent dedup (sed-strip trailing /input/inputN and /inputN, lowest jsN per key, phys fallback); `sort -n -k1,1 -k2,2`; dual-transport same-VID:PID >&2 warning; cap at CONTROLLER_MONITOR_MAX_PLAYERS; emit 4 fields `<eventN> <jsN> <vendor> <product>`. Keep >&2 diagnostics mirroring the mapper's logging style (429-436). Do NOT modify _parse_all_gamepad_devices.

**Why:** Steam's 28de:11ff pool inputN ordering is decoupled from physical connection (the proven §3b leak where a pad claims the built-in's virtual); emitting the pad's OWN raw nodes removes the virtual layer and makes the built-in/puck (no raw js) structurally unselectable. Self-contained parse keeps the multi-word bitmap off every read boundary.

### `modules/controller_monitor.sh` — list_eligible_controllers docked branch (498-507)

**Change:** Gate the docked source: before the while loop add `local src; if [[ "${CONTROLLER_MONITOR_RAW_BINDING:-0}" == "1" ]]; then src=_list_raw_external_pads; else src=_map_external_player_virtuals; fi` and change the process substitution to `done < <("$src")`. Keep the IDENTICAL 4-field formatting (`/dev/input/event${_ev} /dev/input/js${_js} ${_vn} ${_pr}`). The handheld branch (481-496) is UNTOUCHED.

**Why:** Single gated call-site swap preserving the public stdout contract; the mapper stays selectable until the in-sandbox probe confirms raw js reads work, avoiding a total docked regression.

### `modules/controller_monitor.sh` — _check_devices_changed (535-601)

**Change:** NO new param, NO inputN tracking. Keep the single line-546 enumeration feeding BOTH the emitted ADD js/vendor/product AND the diff. At the END (after the remove loop, after line 600) add `echo "${!current_nodes[*]}"` to stdout so the producer can set prev_nodes from the SAME capture. Keep the existing line-598 debounce unset. Add an invariant comment that emitted fields and the returned node set come from one enumeration. Note: all existing diagnostic output already goes to >&2, so the new stdout echo is the function's only stdout — safe to capture.

**Why:** Fixes the snapshot read-skew by removing the producer's second independent enumeration; the inputN-replacement logic from a prior iteration is intentionally not added because inputN never reaches this function and the eligible contract is 4 fields.

### `modules/controller_monitor.sh` — start_controller_monitor udev producer loop (665-692) and poll fallback (694-711)

**Change:** Change the action regex to `(add|remove|change)` (line 671) and the guard at 675 to include change. On a match: (1) BURST-DRAIN pending lines from the loop's fd with `while IFS= read -r -t 0.05 _drain; do :; done` to coalesce the ~5-line udev burst; (2) replace the fixed `sleep 0.1` (677) with a BOUNDED ASYMMETRIC settle — poll the eligible event-node set every ~0.2s, stop on two equal consecutive reads or a HARD CEILING of ~2s for add/change and ~0.5s for remove; (3) replace lines 680-690 with `prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")`. Apply the same removal of the separate new_nodes enumeration in the poll fallback (699-709): replace 699-709 with `prev_nodes=$(_check_devices_changed "$mode" "$prev_nodes")` after the `sleep 2`. Comment the settle asymmetry as a latency improvement only, NOT a flap-correctness fix.

**Why:** Fixes the ADD race (js attaches late), the read-skew, reacts to BT 'change' link re-keys, and coalesces bursts; makes no claim about reused-eventN flaps.

### `modules/controller_monitor.sh` — start_controller_monitor initial scan / baseline (637-656)

**Change:** Read CONTROLLER_MONITOR_ALREADY_ACQUIRED (space-separated event nodes) into a lookup set. In the baseline loop (640-654): always set prev_nodes; when skip_emit==1, emit a CONTROLLER_ADD ONLY for a baseline eligible node NOT present in the acquired set (a pad that appeared after the orchestrator's last acquire scan), and baseline-only the acquired ones; when skip_emit!=1, behavior is unchanged (baseline AND emit, as today). When CONTROLLER_MONITOR_ALREADY_ACQUIRED is unset, treat the acquired set as empty so skip_emit==1 keeps its current 'baseline only, never emit' behavior.

**Why:** Closes the acquire↔baseline handoff gap where a pad appearing between docked_flow's final acquire scan (525) and the monitor baseline snapshot would never spawn.

### `modules/controller_monitor.sh` — Header docstring (4-20), list_eligible_controllers docstring (468-473)

**Change:** Document the flag-gated docked behavior: RAW_BINDING=1 → raw external gamepad js nodes (js-gated, gamepad+vendor gated, deduped, ordered by (inputN,eventN); built-in/28de excluded); flag unset → legacy mapper. Add the env override CONTROLLER_MONITOR_RAW_BINDING and CONTROLLER_MONITOR_ALREADY_ACQUIRED to the override list (16-20). State plainly: DEFAULT OFF so the §3b built-in-leak is LIVE by default; committed FLIP CRITERION = set default ON only after the in-sandbox Controlify-reads-raw-js-with-Steam-Input-ON probe passes AND a user confirms in-game on >=2 pads; PLAN-B decision tree (per-app Steam Input OFF, then passive event-correlation) if the probe fails.

**Why:** The gated code must not be mis-described as 'the fix'; the user-facing bug remains until the criterion is met.

### `modules/instance_lifecycle.sh` — NEW helper _vendor_of_js_node (insert before _build_bwrap_command, before line 119) + node binding (159-168) + ALLOW literal (225)

**Change:** Add `_vendor_of_js_node()` taking $1 = a /dev/input/jsN path: derive basename `js<N>`, scan /proc/bus/input/devices for the block whose `H: Handlers=` field contains the EXACT whitespace-delimited token == that basename (split on spaces, compare token equality, NEVER substring so js1 != js10), echo that block's lowercased Vendor or empty. In _build_bwrap_command: under `${CONTROLLER_MONITOR_RAW_BINDING:-0}`==1 AND non-empty js_node — bind js-ONLY (keep 164-168's --dev-bind js_node + SDL_JOYSTICK_DEVICE) and SKIP the eventN --dev-bind at 159-161; when the flag is OFF or handheld (empty nodes), bind BOTH exactly as today. Compute mode-independent `local _allow`: if a js is bound and its parsed vendor != 28de → 0; if a js is bound and vendor is unparseable/empty → 0; if vendor==28de OR no js bound → 1. Replace the literal `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1` at 225 with `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=${_allow}`. Do NOT add a positional arg (collides with the variadic mask-pair tail at 178-187) and do NOT touch SDL_GAMECONTROLLER_IGNORE_DEVICES (226).

**Why:** js-only binding sidesteps Steam Input's evdev EVIOCGRAB (the load-bearing hedge); mode-independent ALLOW (defensive-only under js-only) keeps handheld slot 1 working; /proc vendor read avoids the variadic-tail collision; exact-token match prevents js1/js10 mis-resolution.

### `modules/instance_lifecycle.sh` — env-var comment block (189-203) and mask-loop comment (170-187)

**Change:** Rewrite the env block (189-203) to describe the raw js-only model: ALLOW is per-slot/defensive (no 28de node in a raw namespace); add the EVIOCGRAB-is-on-evdev-not-the-legacy-jsN rationale for js-only binding; remove the stale 'the only device in this sandbox is the 28de:11ff virtual' claim (191-192) and the SDL_GAMECONTROLLER_IGNORE_DEVICES paragraph (193-196, which now no longer matches its purpose). Correct the mask-loop comment (170-177) to 'inert under --dev /dev + js-only binding; the fresh devtmpfs holds no input nodes except our bound jsN, so masked targets do not exist and the -e guard skips them; real isolation is --dev /dev + SDL_JOYSTICK_DISABLE_UDEV, proven by the live in-sandbox ls /dev/input test'.

**Why:** Current comments describe the abandoned virtual model and overstate the mask as isolation.

### `modules/orchestrator.sh` — _handle_msg CONTROLLER_ADD parse (242-248)

**Change:** No logic change to slot assignment, masking, or the event==js sentinel (247). Add a one-line comment: under CONTROLLER_MONITOR_RAW_BINDING, event_node/js_node are the pad's RAW nodes (js bound into the sandbox, event recorded as slot identity only), and the docked producer always emits BOTH (js-gated), so the sentinel and spawn_instance's js-empty branch are docked-unreachable. Do NOT thread a vendor arg (keeps the variadic mask contract intact).

**Why:** Orchestrator keys identity on event_node path (unique per raw pad even for same-MAC DS4s), so it works unchanged.

### `modules/orchestrator.sh` — CONTROLLER_REMOVE handler (305-328)

**Change:** No logic change. Extend the existing comment (305-313) to DISCLOSE honestly: CONTROLLER_REMOVE is a deliberate no-op (#37 preserve), and a reused-eventN fast-flap or a js-vanish-without-remove leaves a STILL-ALIVE zombie slot that _reap_dead_slots (183-202) and window-death never reap — a PRE-EXISTING defect identical under the old virtual path, UNCHANGED and OUT OF SCOPE here. Mark the concrete fix as a tracked follow-up: on a detected replacement, RELAUNCH the SAME slot (teardown_instance then respawn with the new node) since v1 bwrap mounts cannot live-rebind.

**Why:** Avoids falsely claiming the flap nets to correct and gets reaped; the real leak must be disclosed, not silently shipped.

### `modules/orchestrator.sh` — docked_flow acquire→monitor handoff (538-542)

**Change:** Pass the acquired event-node set to the monitor: change line 539 to `CONTROLLER_MONITOR_ALREADY_ACQUIRED="${!_acquired[*]}" CONTROLLER_MONITOR_SKIP_INITIAL_EMIT=1 start_controller_monitor docked &`. (_acquired is built at 515-528.)

**Why:** Lets the monitor emit ADD for a pad that appeared between the final acquire scan (525) and the baseline snapshot, closing the handoff gap.

### `modules/orchestrator.sh` — docked_flow isolation-note comment (498-505)

**Change:** Correct the stale comment block (498-505) that references `_identify_internal_virtual_index()` and built-in masking: under raw binding the built-in is excluded by enumeration (no raw js gamepad node), not by masking. Note _identify_internal_virtual_index is dead and scheduled for the deferred cleanup commit. No code change here.

**Why:** The comment describes a masking strategy that the raw path makes obsolete; leaving it would mislead implementers.

### `modules/orchestrator.sh` — handheld_flow slot-1 spawn (445-452) — OPTIONAL

**Change:** Add a comment that handheld slot 1 passes empty event/js (→ ALLOW=1) and depends on Steam minting the built-in's 28de:11ff virtual; the raw flag is irrelevant to handheld. OPTIONALLY (out-of-scope-able) apply _has_gamepad_buttons to the handheld head-1 selection for symmetry. No required code change.

**Why:** Documents the virtual-timing dependency and the gate asymmetry rather than implying handheld is affected by the flag.

### `modules/controller_monitor.sh + modules/orchestrator.sh` — DEFERRED dead-code cluster: _parse_steam_virtual_devices (50-119), _eventN_to_virtual_idx (249-261), _identify_internal_virtual_index (272-332), _find_internal_by_pad_name (209-245), get_internal_event_node (354-372), _get_physical_devices (336-348); orchestrator _collect_mask_pairs (127-136) + the _mask_pairs plumbing (262-267) + spawn_instance mask-arg passing

**Change:** DEFER removal to a SEPARATE follow-up commit, removed atomically with rewriting the now-stale tests. Grep-verify no live caller before deleting (note: get_internal_event_node and _parse_steam_virtual_devices may still be referenced — confirm with grep). Do NOT bundle into this behavioral PR. _map_external_player_virtuals stays until raw is hardware-confirmed.

**Why:** Incremental, reviewable, revertable; the cluster is one dependency unit and the mapper is the flag fallback.

### `tests/test_controller_monitor.sh` — TEST_TOTAL (line 12, currently 11) and the runner block (645-655)

**Change:** Replace the hardcoded `readonly TEST_TOTAL=11` and the flat list of `test_t2_N` calls (645-655) with a runner ARRAY of test-function names iterated in a loop, deriving TEST_TOTAL from the array length; add a self-check that TESTS_PASSED+TESTS_FAILED == number of names run (catches a test that crashes before calling _pass/_fail). Add the new raw-path test functions (see test_plan); keep the legacy-path tests runnable with the flag OFF until the mapper is removed in the follow-up.

**Why:** Prevents TEST_TOTAL desync and lets new tests be added without manual count bumps.

## SDL env changes

- PRIMARY HEDGE — js-ONLY BINDING (instance_lifecycle.sh _build_bwrap_command 159-168): under raw mode (`${CONTROLLER_MONITOR_RAW_BINDING:-0}`==1 AND js_node non-empty), bind ONLY the jsN (keep the --dev-bind js_node + --setenv SDL_JOYSTICK_DEVICE=js_node at 164-167) and SKIP the eventN --dev-bind at 159-161. EVIOCGRAB is on the evdev eventN, not the legacy jsN (separate char device, multiply-openable, no grab ioctl); never placing the eventN in the namespace means Steam Input's grab can never surface a dead/duplicate evdev to Controlify's SDL. The raw eventN is still passed by the orchestrator and recorded in state purely as slot identity for CONTROLLER_REMOVE matching. When the flag is OFF (legacy virtual path) OR handheld (empty nodes), binding is UNCHANGED (bind both as today).
- SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD becomes per-slot AND mode-independent via the NEW helper _vendor_of_js_node <js_node> (NOT a positional arg — that collides with the variadic mask-pair tail at 178-187). Rule: js bound AND vendor parsed != 28de → _allow=0; js bound AND vendor unparseable → _allow=0; vendor==28de OR no js bound → _allow=1. Replace the literal `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1` (line 225) with `=${_allow}`. DOWNGRADE its stated importance: under js-only raw binding NO 28de node is in the namespace, so ALLOW is DEFENSIVE-ONLY; correctness rests on js-only binding + DISABLE_UDEV scandir, not on this hint.
- KEEP SDL_GAMECONTROLLER_IGNORE_DEVICES empty (line 226). Do NOT add 0x28de/0x11ff: no 28de node is ever in a raw namespace, the 0xVVVV/0xPPPP format is unverified against Controlify's SDL, and js-only binding already removes the contention.
- KEEP SDL_JOYSTICK_DISABLE_UDEV=1 (line 236) unchanged — the live-validated hint forcing scandir(/dev/input)-only enumeration so SDL sees only the single bound jsN. Its live-confirmed efficacy is also evidence that Controlify's SDL honors SDL_JOYSTICK_* hints.
- KEEP SDL_JOYSTICK_HIDAPI=0 (line 227): raw js read via the classic joystick interface, not hidraw (no /dev/hidraw* bound). With HIDAPI=0 SDL never opens hidraw and (js-only binding) never opens evdev, so neither Steam-Input contention blocks the jsN read.
- KEEP SDL_LINUX_JOYSTICK_CLASSIC=1 (line 228): forces the classic joystick path that honors SDL_JOYSTICK_DEVICE pinning to the raw jsN and steers SDL away from the now-unbound evdev backend.
- KEEP SDL_JOYSTICK_DEVICE set to the bound js_node (line 167) — now the RAW jsN under the flag — unchanged code, correct value.
- Rewrite the env comment block (189-203): describe the raw js-only model; ALLOW is per-slot/defensive; remove the stale 'the only device is the 28de:11ff virtual' claim (191-192) and the IGNORE_DEVICES paragraph (193-196); add the EVIOCGRAB-is-evdev-not-js rationale.
- PROBE REQUIREMENT (gate for flipping the default): the in-sandbox probe must report Controlify's bundled SDL VERSION (SDL2 vs SDL3) and confirm the hints are honored (DISABLE_UDEV already proven live; verify SDL_JOYSTICK_DEVICE pinning + the CLASSIC path), so correctness is not predicated on hints whose effect is unverified for the real consumer.

## Edge cases

- **DS4 gamepad(js+event)+touchpad(event)+motion(event); wired DS4 splits these across USB interfaces :1.0/:1.1/:1.2 with DIFFERENT sysfs parents** — js-gate (step 1) drops touchpad/motion (no js) BEFORE dedup, so only the :1.0 gamepad survives regardless of interface split. Unit fixtures for BOTH wired (multi-interface) and BT (shared uhid) DS4.
- **DualSense (054c:0ce6) / DualSense Edge — separate motion/touchpad evdev set, sometimes a 2nd 'wireless controller' interface over USB** — Same js-gate handling; the gamepad node passes both gates, motion/touchpad lack js. DualSense fixture added.
- **8BitDo / generic dinput gamepad reports BTN_JOYSTICK/BTN_TRIGGER instead of BTN_SOUTH** — INCLUSIVE gate accepts BTN_SOUTH(0x130) OR BTN_JOYSTICK(0x120) OR unparseable keybits → never false-negatives a real dinput pad. Unit fixtures: REAL 8BitDo dinput KEY line (accepted) AND xinput KEY line (accepted).
- **Non-gamepad joystick with a js handler (flight stick BTN_JOYSTICK-only, racing wheel)** — Would PASS the inclusive gate → could spawn a phantom player. DOCUMENTED v1 limitation (evdev caps cannot reliably separate a gamepad from a flight stick); a test asserts the current accept-behavior so future tightening is deliberate. Rejecting them was traded away to avoid dropping real dinput gamepads.
- **Single physical pad with TWO js nodes sharing one sysfs parent (8BitDo dual-mode uhid)** — Shared-parent dedup (step 6) keeps the lowest jsN → one line. Unit test on the REAL captured 8BitDo S: string asserts exactly one line.
- **Same pad on USB AND BT simultaneously (charging over USB while paired BT) → two parents, two js** — Dedup does NOT collapse (different keys) → two players AND a loud >&2 dual-transport warning (step 8). Cannot VID:PID-dedup (would merge two identical same-MAC DS4s). Test asserts current two-line behavior; follow-up proposes Bus(USB 0003 vs BT 0005)+activity-based active-transport selection.
- **Two DS4s with identical Uniq/MAC, distinct inputN/event/js** — Both enumerated as separate lines in (inputN,eventN) order; identity keyed on event_node path, never uniq/MAC. Unit test.
- **Hotplug DS4: js handler materializes AFTER its event nodes; an enumeration in the gap yields zero eligible pads** — Burst-coalescing drain + bounded settle (≤2s on add, two-equal-reads, hard ceiling) re-enumerates until the js appears; js-gating means an intermediate poll simply yields no line until js is present. Unit test js-absent→present; live hotplug test.
- **DS4/DualSense Edge firmware exposes the gamepad evdev WITHOUT a js until joydev attaches — COLD start inside the acquire window** — js-gate makes it invisible until the js attaches; the 5s startup-acquire poll (orchestrator 517-528) retries; if slower than 5s, the monitor's hotplug settle catches it post-handoff. Same shape as the hotplug gap but at cold start.
- **Fast disconnect+reconnect on a REUSED eventN minor** — NO inputN-replacement claim (no data source for it). The asymmetric short remove-settle makes REMOVE precede a typical >1s human replug as a LATENCY improvement only. If the kernel reuses the same eventN with no net set change, a reused-eventN no-flap is UNDETECTABLE and the slot keeps a now-dead bound fd — disclosed as the pre-existing zombie-slot defect, NOT claimed handled.
- **eventN minor reused by a DIFFERENT physical device after unplug while the orchestrator holds the old event_node as slot identity** — _find_slot_by_event_node (111) could match a REMOVE for the new device to the old slot. Known limitation (inputN detection dropped as unsourced); the short remove-settle reduces the window. Documented, not silently relied upon.
- **Steam Input mints a 28de:11ff virtual for the SAME pad bound raw** — Under js-only binding + DISABLE_UDEV scandir, only the bound raw jsN is in the namespace; no 28de node is bound, so SDL cannot see the virtual. ALLOW=0 is moot/defensive. Resolved structurally by js-only binding.
- **8BitDo live mode-switch (Xinput↔Dinput↔Switch) changes VID:PID and BTN profile mid-session** — Re-enumerates as new inputN/eventN → REMOVE(old)+ADD(new) → respawn. The INCLUSIVE gate accepts both BTN_SOUTH (xinput) and BTN_JOYSTICK (dinput), so a post-switch profile is not dropped. Documented v1 behavior.
- **Wired DS4 touchpad interface (:1.1) transiently gets a js during hid-playstation probe → two js under different parents mid-probe** — Bounded settle (two-equal consecutive reads + burst coalesce) waits past the transient; the spurious js disappears post-probe so the stable enumeration is clean. Documented.
- **udev 'change' actions (BT link re-key / wake-from-idle) drop+restore the js without a clean remove/add pair** — Producer regex ALSO matches 'change' (line 671 + 675) and re-enumerates, so a transport state change re-triggers the diff.
- **udev fires a BURST of ~5 input lines per physical (dis)connect** — After any add/remove/change line, drain pending lines from the loop's fd with `read -t 0.05` until quiet, then run ONE settle+diff pass. Tested with a captured multi-line single-DS4 burst.
- **Pad appears BETWEEN the final acquire scan (orchestrator 525) and the monitor's baseline snapshot → in neither set** — docked_flow passes the acquired event-node set as CONTROLLER_MONITOR_ALREADY_ACQUIRED; the monitor's initial scan (637-656) emits a CONTROLLER_ADD for any baseline node NOT in that set and baselines the acquired ones without re-emitting.
- **Four pads connect within one settle window; 'two equal reads' may never converge while pads keep arriving** — Hard settle CEILING (~2s) emits whatever is stable; later arrivals come as their own udev events. Cold-start first-pad-at-t=0 is owned by the orchestrator startup-ACQUIRE loop (517-528, dispatches each pad immediately), NOT the monitor settle, so the ceiling does not delay the first cold-start spawn.
- **Snapshot skew: producer sets prev_nodes from a SEPARATE enumeration than the one that emitted ADD fields** — _check_devices_changed enumerates ONCE (line 546) feeding BOTH the emitted js/vendor/product AND the diff, and ECHOES the current event-node set on stdout; the producer sets prev_nodes from THAT return — the second enumeration (680-690/699-709) is removed. Unit test asserts emitted ADD fields and prev_nodes come from the same capture.
- **_vendor_of_js_node token match js1 vs js10/js11** — EXACT whitespace-delimited token compare (== js<N>), never substring. Unit test with js1 and js10 both present asserts the correct vendor so ALLOW can't be flipped by a wrong-but-parseable 28de match.
- **Raw pad whose I: line parse fails → vendor 0000** — _build_bwrap_command: bound js with unparseable/empty vendor → ALLOW=0 (mode-independent rule). No bound js (handheld) → ALLOW=1.
- **Steam Deck OLED vs LCD built-in (and future revisions) VID:PID** — vendor==28de gate excludes any 28de built-in regardless of product or whether a future revision bears a js. 28de:1205-with-js exclusion unit test; OLED verified on real hardware.
- **Pad bound raw whose js node disappears (driver crash / USB autosuspend) WITHOUT a udev remove for the event node** — SDL loses input with no REMOVE emitted and no reap (window alive) — same zombie class as the reused-eventN case. Documented as the pre-existing zombie-slot defect, tracked with the preserve-vs-relaunch follow-up; out of scope here.
- **Cross-slot mask (--bind /dev/null, 178-187) under --dev /dev + js-only binding** — INERT: the fresh devtmpfs contains no input nodes except our bound jsN, so masked targets don't exist and the -e guard (181-182) skips them. KEEP for revert-safety; comment corrected to 'inert; real isolation is --dev /dev + DISABLE_UDEV, proven by the live in-sandbox ls /dev/input test'. Orchestrator mask plumbing flagged for the deferred cleanup.
- **User expects the built-in pad or a Valve puck to drive a docked player** — Document: docked requires an external raw gamepad (built-in/puck expose no raw js gamepad node); handheld still uses the built-in via its 28de:11ff virtual (flag irrelevant to handheld).

## Risks

- **Steam Input EVIOCGRABs the raw evdev so Controlify's SDL reads nothing, OR disabling per-app Steam Input breaks Game-Mode navigation into the app** → PLAN-B DECISION TREE, committed before building: (1) PRIMARY = bind js-ONLY (EVIOCGRAB is on evdev, not the legacy jsN; jsN is multiply-openable), which structurally sidesteps the grab; (2) if the in-sandbox probe shows js reads still fail with Steam Input ON, FALLBACK = require per-app Steam Input OFF/desktop layout on the launcher shortcut with the Game-Mode-navigation tradeoff documented; (3) if Steam Input must stay ON AND raw fully fails, FALLBACK = replace the broken proximity mapper with passive event-correlation (read each raw evdev for activity, bind the virtual that mirrors it). The whole raw path stays gated OFF until the probe passes.
- **THIS PR ships NO default-path fix; the §3b built-in-leak remains live and the flip could be deferred indefinitely** → State plainly in docstrings/PR body that the raw path is dark-launched and the bug is live by default. Commit the testable FLIP CRITERION (in-sandbox probe passes AND user confirms on >=2 pads) AND the plan-B tree, so a probe failure has a defined §3b fix rather than an open-ended TODO.
- **inputN-based replacement detection has NO data source (inputN never reaches _check_devices_changed; eligible output is 4 fields; the producer drops inputN)** → DROP inputN-replacement detection entirely. Rely on the asymmetric REMOVE-before-ADD window as a latency improvement only, and DISCLOSE that a reused-eventN no-flap is undetectable. No 5th field, so the orchestrator 4-field read (244) and the FIFO contract are untouched.
- **A detected/undetected fast-flap leaves a still-alive zombie slot that _reap_dead_slots (183-202) and window-death never reap, leaking 1 of 4 slots and dropping the player into a fresh world** → Do NOT claim the flap is handled. Disclose it as a PRE-EXISTING orchestrator defect (identical under the old virtual path), unchanged here. Track the concrete fix (REMOVE→relaunch the SAME slot, since v1 cannot live-rebind) as a follow-up, and ship a test that ASSERTS the current leak plus a live test that reports slot COUNT.
- **Binding BOTH eventN and jsN could surface the grabbed (dead) evdev to SDL** → Under raw mode bind js-ONLY; keep eventN as slot identity only (not in the namespace). The probe explicitly compares js-only vs js+event.
- **A BTN_SOUTH-only gamepad gate false-negatives legitimate dinput/8BitDo pads (BTN_JOYSTICK/BTN_TRIGGER)** → INCLUSIVE gate: accept BTN_SOUTH(0x130) OR BTN_JOYSTICK(0x120) OR unparseable keybits. Tested against REAL 8BitDo dinput AND xinput KEY lines. The consequence (a flight stick/wheel could pass) is a documented, tested limitation, preferred over dropping a real player.
- **The multi-word B: KEY bitmap as an appended field corrupts a future six-var `read` (phys absorbs keybits)** → Do NOT append keybits to _parse_all_gamepad_devices. _list_raw_external_pads does its own single-pass parse and tests _has_gamepad_buttons "$keybits" INLINE; keybits is never emitted or crossed by a read.
- **udev fires a burst of ~5 input lines per (dis)connect; single-event settle latches mid-burst** → Drain pending fd lines with `read -t 0.05` after any add/remove/change, then run ONE settle+diff pass. Tested with a captured multi-line single-DS4 burst.
- **Same pad on USB+BT spawns two players (common footgun)** → Loud >&2 VID:PID-collision warning + a test asserting the two-line behavior; cannot VID:PID-dedup (would merge two identical same-MAC DS4s). Follow-up proposes Bus(USB vs BT)+activity-based active-transport selection.
- **Controlify's bundled SDL may ignore SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD (SDL2 vs SDL3 hint differences), making per-slot ALLOW a no-op** → Under js-only binding ALLOW is defensive-only (no 28de node in the namespace), so correctness does not depend on it. The probe reports the SDL version and confirms which hints are honored; DISABLE_UDEV is already proven honored live.
- **Acquire↔baseline handoff gap: a pad appearing between the final acquire scan (525) and the monitor baseline never spawns** → Pass CONTROLLER_MONITOR_ALREADY_ACQUIRED to the monitor; its initial scan emits ADD for baseline nodes not in the acquired set.
- **Single-snapshot skew: producer set prev_nodes from a separate enumeration than the ADD emit** → _check_devices_changed enumerates once, emits from it, and echoes the node set; the producer's separate enumeration (680-690/699-709) is removed and prev_nodes comes from the return.
- **sort -n -k1,1 alone is not a total order (ties on inputN are nondeterministic)** → Use `sort -n -k1,1 -k2,2`; skip rows with empty inputN before the sort; comment separates deterministic-for-diffing (load-bearing) from cold-start order (cosmetic).
- **BTN bit extraction sign-extends or assumes 64-bit words** → Use the mask form `(word & (1<<48))`; state the 64-bit-word (SteamOS x86-64) assumption; count words from the END so omitted leading-zero MSWs don't shift the index.
- **Cross-slot masking is inert under --dev /dev + js-only binding but described as isolation** → Keep for revert-safety; correct comments to 'inert; real isolation is --dev /dev + DISABLE_UDEV'; flag the orchestrator mask plumbing for the deferred cleanup; prove isolation with the live ls /dev/input test.
- **Deleting the virtual-identification cluster breaks tests / orphans callers (get_internal_event_node and _parse_steam_virtual_devices may still be referenced)** → Defer the cluster AND the inert orchestrator mask plumbing to a separate commit, removed atomically with the stale tests; grep-verify every symbol has no live caller; keep the mapper as the flag fallback.
- **Hardcoded TEST_TOTAL (line 12) desyncs as tests are added/removed** → Derive TEST_TOTAL from a runner array; self-check passed+failed == names run.
- **inputN order not preserved across reconnect → a player can land in a different quadrant** → Drop any 'stable' claim; v1 preserves connection ORDER at cold start only; reconnect assigns first-free-slot by event_node. Durable mapping deferred (would need a phys/port key; uniq forbidden).
- **A js node vanishing without a udev remove (driver crash / USB autosuspend) leaves a zombie slot** → Documented as the same pre-existing zombie class as the reused-eventN flap; tracked with the preserve-vs-relaunch follow-up; out of scope here.
- **User expects the built-in pad or a Valve puck to drive a docked player** → Document that docked requires an external raw gamepad (built-in/puck have no raw js gamepad node); handheld still uses the built-in via its 28de:11ff virtual.

## Test plan

- Run new raw-path unit tests under CONTROLLER_MONITOR_RAW_BINDING=1; keep legacy-path tests (T2.5/T2.7/T2.10/T2.11) runnable with the flag OFF until the mapper is removed in the follow-up commit.
- Unit test_t2_raw_basic: /proc fixture with 054c:05c4 (event+js, gamepad KEY bits, inputN), its DS4 touchpad (event-only), DS4 motion (event-only), a 28de:11ff virtual (event+js), a 28de:1205 (no js); flag ON → list_eligible_controllers docked outputs ONLY '/dev/input/eventX /dev/input/jsY 054c 05c4'.
- Unit test_t2_wired_ds4_multiinterface: wired DS4 gamepad :1.0 (event+js), touchpad :1.1, motion :1.2 on DIFFERENT REAL sysfs parents → exactly ONE eligible line (:1.0).
- Unit test_t2_dualsense: 054c:0ce6 gamepad + motion/touchpad set → exactly one line.
- Unit test_t2_gate_accepts_dinput: REAL 8BitDo DINPUT KEY line (BTN_JOYSTICK, no BTN_SOUTH) with a js → ACCEPTED; xinput KEY line (BTN_SOUTH) → ACCEPTED; a keybits-less/short bitmap → ACCEPTED (fail-open).
- Unit test_t2_gate_mask_form: a KEY word with bit 63 set in the 5th-from-end word does NOT corrupt the BTN_SOUTH/BTN_JOYSTICK test (sign-safe mask form).
- Unit test_t2_dedup_shared_parent: REAL 8BitDo dual-js shared-uhid S: string → exactly ONE line (lowest jsN).
- Unit test_t2_dual_transport: same VID:PID on two parents (USB+BT) → TWO lines AND a warning emitted to stderr.
- Unit test_t2_same_mac: two 054c blocks with identical Uniq, distinct inputN/event/js → both lines in (inputN,eventN) order; no VID:PID collapse beyond the warning.
- Unit test_t2_exclusion_1205_with_js: synthetic 28de:1205 WITH a js handler → excluded.
- Unit test_t2_hotplug_jsgate: gamepad EVENT node present but js ABSENT → 0 eligible; js present → emitted.
- Unit test_t2_deterministic_order: multi-pad fixture enumerated twice → byte-identical output.
- Unit test_vendor_token_match: /proc with both js1 and js10; assert _vendor_of_js_node /dev/input/js1 returns js1's vendor (exact token, not js10).
- Unit test_allow_per_slot: _build_bwrap_command for a bound 28de:11ff → ALLOW=1; bound raw 054c → ALLOW=0; bound js unparseable vendor → ALLOW=0; NO bound js (handheld) → ALLOW=1.
- Unit test_js_only_binding: with RAW_BINDING=1 the emitted bwrap command --dev-binds /dev/input/jsN but NOT /dev/input/eventN; with the flag OFF (or handheld empty nodes) both bind as before.
- Unit test_snapshot_return: drive _check_devices_changed and assert the emitted CONTROLLER_ADD js/vendor/product AND the stdout-returned node set come from ONE enumeration; producer uses the return for prev_nodes.
- Unit test_burst_coalesce: feed the producer a captured multi-line single-DS4 connect burst → exactly ONE CONTROLLER_ADD emitted.
- Unit test_change_action_triggers: a udev 'change' line re-enumerates and emits the appropriate diff.
- Unit test_acquire_baseline_handoff: with CONTROLLER_MONITOR_ALREADY_ACQUIRED set and SKIP_INITIAL_EMIT=1, a baseline node NOT in the acquired set emits an ADD; an acquired node does not.
- Unit test_zombie_slot_documented (orchestrator): a CONTROLLER_REMOVE followed by a CONTROLLER_ADD on a reused event node leaves the original slot ACTIVE (asserts the current pre-existing leak so a future fix is deliberate — NOT a 'never stuck' pass).
- Unit test_docked_always_both_nodes: no docked eligible line ever has event==js (js-gated) → sentinel/js-empty path docked-unreachable.
- Unit (INVERT) T2.8 under flag ON → 'CONTROLLER_ADD /dev/input/event20 /dev/input/js1 054c 09cc' (the RAW node, not a virtual).
- Unit (INVERT) T2.9 under flag ON → 'CONTROLLER_REMOVE /dev/input/event20' (raw eventN identity).
- Unit (INVERT) T2.11 under flag ON → a raw 054c with NO virtual yields ONE player '/dev/input/event4 /dev/input/js1 054c 05c4' (opposite of the current legacy expectation of 0).
- Unit (retarget) T2.5 under flag ON → the DS4's OWN raw node; built-in 28de excluded.
- Unit (retarget) T2.7 under flag ON → 5 raw DS4s + built-in + virtuals → 4 lines (capped); first line lowest-(inputN,eventN).
- Unit T2.10 under flag ON → phantom 28de-only pool → 0 players (unchanged outcome, raw path).
- Maintenance: TEST_TOTAL derived from a runner array; self-check passed+failed == names run.
- Capture REAL /proc/bus/input/devices on the Deck (wired DS4, BT DS4, DualSense, 8BitDo dinput AND xinput, a flight stick if available, the built-in, several 28de:11ff virtuals) and use those exact S:/B: strings as fixtures — not synthetic. Store under tests/ for reuse.
- HARDWARE PROBE (BEFORE flipping the default or claiming fixed): launch Controlify (or an SDL binary matching its SDL version) INSIDE the actual bwrap sandbox with Steam Input ON, with js-ONLY binding, and confirm it enumerates AND reads the raw pad while Steam Input grabs the evdev. ALSO compare js-only vs js+event binding, report the SDL VERSION, and confirm SDL_JOYSTICK_DEVICE pinning + DISABLE_UDEV are honored. cat jsN/evtest are NOT sufficient.
- Live Deck (cp into ~/.local/share/PolyMC, tmux mcss) RAW_BINDING=1: 1 DS4 docked → CONTROLLER_ADD carries 054c RAW event/js and Controlify in-game lists exactly one pad.
- Live Deck isolation proof: ls /dev/input from INSIDE a slot's sandbox shows ONLY the bound jsN (no eventN, no other pads) while a second pad is connected.
- Live Deck: built-in pad and a Valve puck do NOT spawn a docked player (§3b leak closed under the flag).
- Live Deck: 4 DS4s, each instance responds only to its own pad; report the slot COUNT, not merely 'a pad drives something'.
- Live Deck hotplug: plug a DS4 AFTER launch → it spawns (validates burst-coalesce + settle).
- Live Deck FAST-FLAP: yank+replug a DS4 within ~1s → report the resulting slot COUNT vs the pre-flap count (expose the zombie-slot leak as DATA; do NOT assert 'never stuck').
- Live Deck phantom check: connect a flight stick/wheel → report whether a docked player spawns (documents the inclusive-gate limitation as DATA).
- Live Deck mixed: DS4 v1 (054c:05c4) + DS4 v2 (054c:09cc) + one wired + one BT simultaneously → report per-pad slot mapping and whether the dual-transport warning fired for any.
- Live Deck handheld regression (flag irrelevant): undocked, built-in drives slot 1 (ALLOW=1 path).
- Grep gate for the deferred purge: grep -rn each dead-code symbol plus _collect_mask_pairs/_mask_pairs across modules/ + tests/ + launcher.sh; confirm no live caller before deleting.
- Lint: shellcheck modules/controller_monitor.sh and modules/instance_lifecycle.sh after edits.
- Per project rule: report captures as DATA and ASK the user what they see in-game; reserve 'fixed' for user-confirmed controller response with the flag ON; do not flip the default until the flip criterion is met.