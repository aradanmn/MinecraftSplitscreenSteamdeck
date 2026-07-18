# Design — #38 per-slot controller virtualization (v1.2 wiring)

> Implementation design, 2026-07-18. Turns the hardware-validated #38
> architecture (patched evsieve, per-slot persistent virtual device) into
> product wiring. Basis: issue #38's two 2026-07-18 on-Deck comments
> (root cause found + fixed), docs/RESEARCH-CONTROLLER-VIRTUALIZATION-
> 2026-07-17.md §3/§4, docs/RESEARCH-CONTROLLER-IDENTITY-2026-07-01.md,
> tests/probe-evsieve-reconnect.sh, tests/evsieve-persist-reopen.patch.
> Subsumes/frames #61, #62, #79; interacts with #33 (license).
>
> Status vocabulary (STYLE-GUIDE §4): VALIDATED = observed on our Deck;
> DESIGN = decided here, not yet built; CONFIRM-ON-DECK = a claim this
> design rests on that a listed hardware check must prove before the PR
> that depends on it may flip its flag.

---

## 0. What is already proven (do not re-derive)

From the #38 probe runs (patched binary, DS4 over BT, Game Mode):

- **P0** deck user creates uinput unprivileged (`user:deck:rw-` on
  /dev/uinput). No installer permission work. [VALIDATED]
- **A** the evsieve virtual output keeps an identical
  path+inode+major:minor+jsN across a DS4 battery-death power-cycle.
  A sandbox bound to that node never sees the disconnect. [VALIDATED]
- **B** with the bounded-retry patch, physical/virtual streams are
  byte-equivalent pre-cycle AND post-reconnect; recovery ~1s. The stock
  binary's bug (subsystem.rs:221-224 drops a blueprint on the FIRST
  EACCES while udev is still applying the uaccess ACL) is fixed by
  tests/evsieve-persist-reopen.patch. [VALIDATED]
- **Bonus** evsieve's evdev grab starves Steam's 28de:11ff virtual for
  that pad (game-layer isolation); Steam still reads the pad over
  **hidraw**, so the Steam UI/overlay still responds. [VALIDATED]
- `persist=full` exists in the binary (bare `persist` defaults to it,
  input.rs:69-77) though absent from `--help`. [VALIDATED]
- evsieve warns against persisting a bare `/dev/input/eventN` — a reused
  minor can be a different device. Production must watch a stable
  per-pad identity path. [from evsieve docs, VALIDATED as a constraint]

The one thing evsieve does NOT do: decide **which** physical pad feeds
**which** slot's virtual on reconnect. That matching stays ours, keyed on
the evdev `uniq` field (BT MAC / USB feature-report MAC on genuine
Sony pads), per docs/RESEARCH-CONTROLLER-IDENTITY-2026-07-01.md.

---

## 1. The shape in one paragraph

Each claimed slot gets its own evsieve process. evsieve reads ONE
physical pad (grabbed) and re-emits through a persistent uinput virtual
whose evdev+js nodes never change for the life of the slot. The bwrap
sandbox binds the **virtual** node, not the raw pad — so a
battery-death/reconnect is invisible to Minecraft. evsieve's `--input`
does not point at a churny `/dev/input/eventN`; it points at a
**userspace stable path we own** (a symlink under the runtime dir), which
the orchestrator re-points to the pad's current evdev node on reconnect,
matched by `uniq`. No udev rule, no root, no rootfs write. The whole path
is behind a new feature flag `MCSS_CONTROLLER_PROXY` (default OFF for the
v1.2 dark-launch), exactly as raw-binding was staged.

---

## 2. Design decisions

### D1 — evsieve lifecycle: per-slot, lazy start, slot-scoped death

**Decision.** One evsieve process per **claimed** slot, started lazily by
`spawn_instance` at CONTROLLER_ADD time (the pad is already present when a
slot is claimed), BEFORE the bwrap command is built. Killed by
`teardown_instance` and by orchestrator `cleanup()`. Mode: `persist=reopen`
plus our bounded-retry patch — the exact configuration probe B validated.

**Why lazy, not session-start priming.** `persist=full`
(start-before-connect, capability-cache-primed) is available and would let
a slot's node exist from session start with a deterministic shape. But it
buys nothing here: we claim a slot only when its pad is already connected,
so `persist=reopen` (device exists at start) is sufficient and is the
config with on-Deck evidence behind it. `persist=full` is recorded as a
future optimization (§7), not a v1.2 dependency — this keeps v1.2 on the
validated path.

**Who supervises.** The orchestrator owns the processes the same way it
owns the monitors: a module-private `_SLOT_EVSIEVE_PIDS` map plus an
`evsieve_pid` field in slot state. The watchdog, which already polls each
active slot's bwrap/java pids, gains one check: a dead `evsieve_pid` for
an active slot.

**Crash handling.** If evsieve dies mid-session its uinput node is
destroyed — the sandbox's bind is now a dead inode and cannot be live
re-bound (bwrap mounts are fixed at launch). Restarting evsieve would mint
a NEW inode the running sandbox can't see, so an in-place restart is
futile. Therefore a genuine evsieve crash is treated as **slot-fatal**:
the watchdog emits `SLOT_DIED`, the orchestrator tears the slot down
cleanly (the node is gone anyway), and the player rejoins by reconnecting
(sticky-slot, D2). This is rare — the only observed failure class
(reconnect EACCES) is exactly what the patch converts into a ~1s recovery,
not a crash. Documented as degradation, not silently handled.

**Teardown.** `teardown_instance(slot)` calls `proxy_stop_slot(slot)`
which `kill`s the tracked evsieve pid (destroying its virtual node) and
removes the slot's symlink + create-link. `cleanup()` stops every slot's
proxy as a backstop (same discipline as its monitor kills).

CONFIRM-ON-DECK: evsieve started before bwrap, node present when the bind
is constructed; teardown leaves no evsieve and no dangling links.

### D2 — identity & the stable path: userspace symlink farm, uniq-keyed

**The tension.** evsieve inputs are path-based and it warns against bare
`eventN`. A kernel-stable per-pad path (`/dev/input/by-id`-style) normally
needs a udev rule, and udev rules need root + a writable
`/etc/udev/rules.d`. On stock SteamOS the rootfs (including `/etc`) is
read-only under `steamos-readonly`; disabling it does not survive an OS
update. **A udev rule is therefore rejected outright.**

**Decision — we own the stable path.** For each slot we create a symlink

    $MCSS_PROXY_PADS_DIR/slot<N>  ->  /dev/input/event<current>

under `$MCSS_HELPER_DIR` (already `$XDG_RUNTIME_DIR/mcss`, user-writable,
per-session). evsieve is launched with `--input
$MCSS_PROXY_PADS_DIR/slot<N> grab persist=reopen`. On reconnect the
orchestrator re-points the symlink to the pad's new evdev node; evsieve's
persist loop re-`exists()`/re-`open()`s its input path, which follows the
updated symlink, and resumes forwarding into the SAME virtual output.

This resolves "evsieve inputs are path-based" WITHOUT root or udev: the
stable identity is a path we mint and re-target, not one the kernel
guarantees.

**CONFIRM-ON-DECK — the load-bearing unknown (§8 open q1).** That
evsieve's `persist=reopen` re-resolves a symlink whose *target* changed
(rather than caching the resolved node) must be proven on the Deck before
PR4 flips anything. try_open (blueprint.rs) does `path.exists()` then
`File::open(path)`, both of which follow symlinks, so the code path
supports it — but it is unverified for our exact build. If it does NOT
re-resolve, the fallback is D2-alt below.

**D2-alt (fallback, only if the repoint is disproven).** Do not repoint;
instead, when the pad returns on a *different* eventN, stop+restart the
slot's evsieve on the new node. That mints a new virtual inode → the live
sandbox is stranded → this degrades to "reconnect requires slot relaunch"
(the relaunch-on-reconnect follow-up, worse UX but correct). We design for
D2, gate the flip on the D2 CONFIRM check, and keep D2-alt named so a
failed check has a defined answer rather than a dead end.

**Matching.** Identity is keyed on `uniq`:

- CONTROLLER_ADD carries the pad's `uniq` (D-plumbing below).
- **Returning pad:** if `uniq` matches a slot whose pad is currently
  missing (evsieve alive, symlink dangling), re-point that slot's symlink
  and do NOT allocate a new slot. This is the sticky-slot rejoin that
  **fixes #61**.
- **Never-seen pad:** no `uniq` match → `_find_free_slot` as today.
- **Empty/duplicate `uniq`** (clone DS4s that skip the MAC feature
  report, or non-Sony pads without a per-unit id): fall back to
  vendor:product + connection order, exactly the graceful degradation the
  identity research prescribed. Documented limitation, not a regression.

`uniq` is a *soft* hint: a miss always degrades to first-free-slot (today's
behavior), never to an error.

### D3 — sandbox bind swap: bind the virtual, discover its js by name

**Today** (`_build_bwrap_command`, MCSS_RAW_BINDING=1): binds the pad's
raw `jsN` only, records the raw `eventN` as slot identity, never binds the
evdev eventN (so Steam's EVIOCGRAB can't surface a dead evdev to SDL).

**Decision.** Under `MCSS_CONTROLLER_PROXY=1`, bind the **virtual's** js
node instead of the raw pad's. The virtual is a uinput evdev device;
joydev attaches a `jsN` to it. We keep the js-only binding model verbatim
(EVIOCGRAB reasoning is moot for the virtual — evsieve owns it, nobody
grabs it — but js-only keeps one code path and the validated SDL isolation
hints unchanged).

- evsieve `--output create-link=$MCSS_PROXY_VIRT_DIR/slot<N>
  name=MCSS-slot<N>` gives us a stable **evdev** symlink.
- **js-node discovery:** the virtual's `jsN` is found by parsing
  /proc/bus/input/devices for the block whose `N: Name=` equals
  `MCSS-slot<N>` and reading its `js*` handler — the exact technique
  `record_virtual_node()` already uses in the probe. `proxy_virtual_nodes
  slot<N>` returns `"<evdev-link> /dev/input/js<M>"`.
- `spawn_instance` receives the VIRTUAL event/js nodes (not the raw pad's)
  and passes them to `_build_bwrap_command`, which binds
  `/dev/input/js<M>` and sets `SDL_JOYSTICK_DEVICE` to it. All the
  validated strict-isolation hints (--tmpfs /run/udev, steam.pipe mask,
  SDL_JOYSTICK_DISABLE_UDEV=1, HIDAPI=0, CLASSIC=1) are preserved
  verbatim.
- **MCSS_RAW_BINDING interaction:** proxy supersedes raw when
  `MCSS_CONTROLLER_PROXY=1`. The state file's `event_node` becomes the
  VIRTUAL's stable identity; a new `phys_uniq` field carries the physical
  pad's identity for reconnect matching. When the proxy flag is 0, nothing
  changes — raw js-only binding stays the default, so v1.2 ships dark.

CONFIRM-ON-DECK: joydev attaches a stable jsN to the evsieve output;
in-sandbox `ls /dev/input` shows ONLY that jsN; Controlify reads it in
game.

### D4 — binary distribution: build-at-install in distrobox (GPL-clean)

evsieve is **GPL-2.0**. Two distribution models:

- Ship a prebuilt patched binary in releases → GPL-2.0 §3 obliges us to
  accompany it with the corresponding source (our patched tree) or a
  written offer valid 3 years.
- **Build at install from patched source we host** → we distribute
  *source*, the user's machine compiles it. This is the cleanest GPL
  posture (no binary-redistribution offer to track) AND it matches the
  existing "no toolchain on the SteamOS host, build in the distrobox"
  reality and the JDK model (download + SHA-256 verify, `java_management.
  sh`).

**Decision.** Mirror the JDK flow: the installer fetches a **pinned**
evsieve source (upstream commit + tests/evsieve-persist-reopen.patch),
SHA-256-verifies it, applies the patch, and `cargo build --release`
**inside the existing distrobox** (the same one that builds it today).
Resolve `MCSS_EVSIEVE_BIN` to the built artifact under
`$MCSS_LAUNCHER_ROOT`. Rebuild is skipped if a good binary of the pinned
version already exists (JDK-style idempotence). If the distrobox/toolchain
is absent, the installer degrades: proxy stays OFF, raw binding remains
the default, and the user sees a clear "seamless reconnect unavailable"
note — never a hard install failure.

**License placement (interacts with #33).** Our ~35-line patch is a
derivative of evsieve → it is GPL-2.0 and must be offered as source (it
already lives in-repo as tests/evsieve-persist-reopen.patch; move/copy it
under a clearly GPL-2.0 `third_party/evsieve/` with evsieve's own LICENSE
and a provenance README). We invoke evsieve as a **separate process**
(arm's-length exec, not linking) → this is mere aggregation; it does NOT
pull the rest of MCSS under GPL-2.0. So the evsieve component is
independently GPL-compliant regardless of #33. **#33 still blocks public
release for the installer's own unresolved (FlyingEwok all-rights-
reserved) license** — the evsieve addition neither fixes nor worsens that;
it just adds a second, self-contained, already-compliant license island.
Flag for the #33 resolution: the repo will carry mixed licensing and needs
a top-level LICENSING note enumerating the islands.

CONFIRM-ON-DECK: installer produces a working `evsieve --version` in the
distrobox; the #38 probe harness runs green against `MCSS_EVSIEVE_BIN`.

### D5 — Steam hidraw side-channel: document as limitation

Steam reads pads via hidraw independently of our evdev grab, so the Steam
UI/overlay still responds to a pad even while evsieve grabs its evdev
(VALIDATED, and unchanged from today's shipped behavior). Game-layer
isolation is complete; UI-layer double-input is not.

**Decision.** Document as a known limitation. We do NOT attempt to mask
hidraw (needs root/Steam config we don't own). Per-pad "Disable Steam
Input" on the launcher shortcut is offered as an OPTIONAL user mitigation
to quiet overlay contention, with the Game-Mode-navigation tradeoff noted
— it is not required for correctness (evsieve's grab already diverts the
game-facing route). No code owns this; it is a docs/limitation entry.

### D6 — failure modes & degradation (explicit table)

| Case | Behavior |
|---|---|
| evsieve dies mid-session | node destroyed → bind dead, can't re-bind live → watchdog `SLOT_DIED` → clean teardown → player rejoins on reconnect (D1) |
| pad never returns | evsieve stays alive holding the virtual; sandbox + world PRESERVED (#37); slot occupied until window-death/session end (unchanged) |
| capability-differed reattach (firmware mode-switch, cross-model on same uniq) | evsieve destroys+recreates the output (new inode) → bind stranded → input lost for that slot; non-fatal warning logged; relaunch-on-reconnect follow-up. Same-model DS4→DS4 (the common case) keeps caps identical → fine |
| 5th pad | `_find_free_slot` returns nothing → CONTROLLER_ADD ignored, no evsieve started (unchanged) |
| wrong-pad reconnect (eventN minor reused by a DIFFERENT device) | `uniq` mismatch → treated as a new pad (new slot), NOT re-pointed into the old slot's symlink → strictly better than today. Empty-uniq clones fall back to vendor:product+order, documented |
| pad on USB+BT at once | two `uniq`-distinct (or dual-transport-warned) entries → two slots, as today's raw path already warns |

---

## 3. CONTROLLER_ADD / REMOVE flow — before/after

### CONTROLLER_ADD, today (raw binding)

1. monitor emits `CONTROLLER_ADD <ev> <js> <vnd> <prd>` (raw pad nodes).
2. orchestrator `_find_free_slot`; reserve `{active:true}`.
3. collect other slots' mask pairs.
4. background `spawn_instance slot <ev> <js> <mask…>` → binds raw jsN,
   records raw eventN as identity.

### CONTROLLER_ADD, v1.2 (proxy flag ON)

1. monitor emits `CONTROLLER_ADD <ev> <js> <vnd> <prd> <uniq>` (raw pad
   nodes + uniq; 5th field, §4 D-plumbing).
2. orchestrator: **sticky-slot match** — `_find_slot_by_uniq <uniq>`
   against slots whose pad is missing.
   - **hit** → `proxy_repoint_slot slot <ev>` (re-point symlink);
     evsieve resumes into the existing virtual; the running instance
     never noticed. DONE — no spawn, no reflow. (fixes #61)
   - **miss** → `_find_free_slot`; reserve `{active:true}`.
3. `proxy_start_slot slot <uniq> <ev>` — create
   `pads/slot<N> -> <ev>`, launch evsieve (grab, persist=reopen,
   create-link `virt/slot<N>`), wait for the virtual node.
4. `proxy_virtual_nodes slot<N>` → `<virt_ev> <virt_js>`.
5. background `spawn_instance slot <virt_ev> <virt_js> <mask…>`; store
   `{event_node:<virt_ev>, js_node:<virt_js>, phys_uniq:<uniq>,
   evsieve_pid:<pid>}`.

### CONTROLLER_REMOVE, today

no-op preserve (#37): instance kept, no reflow; disconnect detected later
via window-death → SLOT_DIED. A reused-eventN flap can leak a zombie slot
(disclosed pre-existing defect).

### CONTROLLER_REMOVE, v1.2 (proxy flag ON)

Still a preserve no-op for teardown — but now **seamless**: evsieve holds
the virtual open, the sandbox never sees the disconnect, the world keeps
running with zero visible interruption. The symlink `pads/slot<N>` is left
dangling (evsieve's persist loop waits on it); the slot is marked
pad-missing for the sticky-slot rejoin. The zombie-flap concern is
**subsumed**: a returning pad re-points its own slot by uniq instead of
racing a reused eventN, and a truly-gone pad is reaped by window-death as
today.

---

## 4. Module-by-module change list (file + function)

### NEW `modules/controller_proxy.sh`

Owns the symlink farm + per-slot evsieve. Added to
`modules/runtime_modules.list` immediately BEFORE `instance_lifecycle.sh`
(instance_lifecycle consumes its accessors). Functions:

- `proxy_start_slot(slot, uniq, phys_event_node)` — mkdir the runtime
  dirs; `ln -sfn phys_event_node pads/slot<N>`; launch
  `$MCSS_EVSIEVE_BIN --input pads/slot<N> grab persist=reopen --output
  create-link=virt/slot<N> name=MCSS-slot<N>` backgrounded; record pid in
  `_SLOT_EVSIEVE_PIDS[slot]`; poll until `virt/slot<N>` resolves; return
  the pid on stdout-free (data via state). Traps + tracked-pid discipline
  mirror the probe's `start_evsieve`.
- `proxy_repoint_slot(slot, phys_event_node)` — `ln -sfn` the pads symlink
  to the new node; no process restart. (D2)
- `proxy_stop_slot(slot)` — kill+reap the tracked evsieve; rm the pads +
  virt links.
- `proxy_virtual_nodes(slot)` — resolve `virt/slot<N>` to its realpath;
  find its `jsN` by `N: Name==MCSS-slot<N>` via
  `parse_input_device_blocks` (controller_monitor is sourced earlier);
  echo `"<virt_ev> <virt_js>"`.
- `_evsieve_bin()` — resolve/validate `MCSS_EVSIEVE_BIN`; if absent, all
  proxy_* become no-ops that signal "proxy unavailable" so callers fall
  back to raw binding.

### `modules/runtime_context.sh`

- Add `MCSS_CONTROLLER_PROXY` (default 0) to the resolved+readonly block.
- Add `MCSS_EVSIEVE_BIN` (default `$MCSS_LAUNCHER_ROOT/bin/evsieve`).
- Add `MCSS_PROXY_PADS_DIR` / `MCSS_PROXY_VIRT_DIR` under
  `$MCSS_HELPER_DIR`. Bump version line; update PROVIDED list.

### `modules/controller_monitor.sh`

- `parse_input_device_blocks` — capture the `U: Uniq=` line; emit an 8th
  field `uniq`. Contract change → bump the module version + update every
  consumer's `IFS=$'\x1f' read` arity (three call sites in this file, one
  in the probe, one in instance_lifecycle's `_vendor_of_js_node`). This is
  the one wide-blast-radius edit; isolate it in its own PR (§5 PR3).
- `_list_raw_external_pads` — carry `uniq` through the record and emit a
  5th field `<eventN> <jsN> <vendor> <product> <uniq>`.
- `_map_external_player_virtuals` (legacy) — emit an empty 5th field to
  keep arity uniform.
- `list_eligible_controllers` docked branch — pass the 5th field through.
- `_check_devices_changed` — thread `uniq` into the emitted
  `CONTROLLER_ADD` line (now 5 data fields).
- Header docstring — document the 5-field ADD contract and `uniq`
  semantics (soft hint, degrades to first-free).

### `modules/orchestrator.sh`

- `_handle_msg` CONTROLLER_ADD — `read -r event_node js_node phys_vendor
  phys_product phys_uniq`; add the sticky-slot branch (D2/§3); when proxy
  on, call `proxy_start_slot` / `proxy_repoint_slot` and pass VIRTUAL
  nodes to `spawn_instance`; store `phys_uniq`.
- NEW `_find_slot_by_uniq(uniq)` — first pad-missing active slot whose
  stored `phys_uniq` matches (parallels `_find_slot_by_event_node`).
- CONTROLLER_REMOVE — under proxy, mark the slot pad-missing (leave
  evsieve running); keep the preserve no-op. Update the honest-disclosure
  comment: the zombie-flap defect is subsumed under proxy (uniq rejoin),
  not merely disclosed.
- DISPLAY_MODE_CHANGE→handheld — repoint slot 1's proxy to the built-in's
  evdev (D-#79, §5 PR6).
- `cleanup()` — stop every slot's proxy (backstop), same discipline as the
  monitor kills.

### `modules/instance_lifecycle.sh`

- `spawn_instance(slot, event_node, js_node, …)` — signature unchanged;
  under proxy the caller simply passes the virtual nodes. State write adds
  `phys_uniq` + `evsieve_pid` (via `update_slot_state`; extend
  `_ensure_state_file`'s slot template with the two new fields, both
  null).
- `_build_bwrap_command` — no structural change: it already binds "the
  js_node it's given" and skips the eventN under js-only. Add a comment
  that under proxy the js_node is the VIRTUAL's jsN and the grab reasoning
  is moot (nobody grabs the virtual). The `_vendor_of_js_node`/`_allow`
  logic sees the virtual's vendor (uinput device-id we set via evsieve
  `device-id=` — set it to the physical vendor so ALLOW stays 0 for real
  pads).
- `teardown_instance(slot)` — call `proxy_stop_slot slot` (guarded
  `declare -f`).

### `modules/watchdog.sh`

- `start_watchdog` loop — for an active slot, also read `evsieve_pid`; if
  set and `! kill -0`, mark dead with reason "evsieve gone" → SLOT_DIED
  (D1). Dedup via the existing `_WATCHDOG_REPORTED`.

### Docs

- New limitations section (hidraw double-input D5; capability-differ D6;
  clone-uniq fallback) in this doc + a one-liner in ARCHITECTURE.md
  placing `controller_proxy.sh` in the runtime product boundary.

---

## 5. Phased PR breakdown (each independently Deck-verifiable)

House style: each PR ships behind the OFF flag until its own owner-runnable
check passes; "fixed" is reserved for user-confirmed in-game response.

**PR1 — evsieve acquisition (build-at-install).** installer fetches
pinned source + patch, SHA-256 verify, `cargo build` in distrobox,
resolve `MCSS_EVSIEVE_BIN`; graceful degrade if no toolchain; GPL license
island under `third_party/evsieve/`. No runtime behavior change.
  - Owner check: run the installer's evsieve step on the Deck →
    `evsieve --version` works; `bash tests/probe-evsieve-reconnect.sh`
    (P0/A/B) green against the built binary.

**PR2 — `controller_proxy.sh` (dark).** the module + symlink farm +
start/repoint/stop/virtual_nodes; unit tests; NOT wired into spawn.
  - Owner check: a standalone driver (reuse the probe harness scaffolding)
    on ONE DS4 — `proxy_start_slot`, capture the virtual node identity,
    battery-death + reconnect, assert node inode STABLE and forwarding
    resumes; then `proxy_repoint_slot` after a forced eventN change and
    assert forwarding resumes (this is the D2 CONFIRM check).

**PR3 — uniq plumbing (no behavior change).**
`parse_input_device_blocks` 8th field + all read-arity updates;
`_list_raw_external_pads`/`list_eligible_controllers`/
`_check_devices_changed` emit uniq; orchestrator stores `phys_uniq` +
`_find_slot_by_uniq` (defined, not yet used to branch). Proxy still off.
  - Owner check: docked launch, `grep CONTROLLER_ADD` in the debug log →
    each line carries the correct per-pad uniq (cross-checked against
    `/proc/bus/input/devices` `U:` lines); unit fixtures for two same-MAC
    DS4s and an empty-uniq pad.

**PR4 — bind swap + orchestrator wiring (flag-gated).** spawn binds the
virtual under `MCSS_CONTROLLER_PROXY=1`; sticky-slot rejoin; watchdog
evsieve supervision; state schema fields.
  - Owner check (flag ON, 1 DS4 docked): Controlify lists exactly one pad
    and responds in game; in-sandbox `ls /dev/input` shows only the
    virtual jsN; battery-death → reconnect resumes seamlessly, SAME slot,
    world preserved, no window flicker.

**PR5 — #61/#62 acceptance (flag ON).** the sticky-slot + subsumption
proof.
  - Owner check: the #61 repro (3 healthy pads + plug the 4th) → no slot
    theft, no P2/P3 degradation; disconnect+reconnect a mid-list pad →
    rejoins its OWN quadrant (not a fresh slot). Report slot COUNT before/
    after, not "a pad drives something".

**PR6 — #79 docked→handheld repoint (flag ON).** on the transition,
repoint slot 1's proxy from the external pad to the built-in's evdev.
  - Owner check: docked with an external pad on slot 1 → undock → the
    surviving handheld instance responds to the Deck's BUILT-IN controls
    (not the external pad left on the couch).

**PR7 — flip the default.** set `MCSS_CONTROLLER_PROXY=1` once PR2's D2
check, PR4's, and PR5's all pass on the Deck and the user confirms in
game; write the limitations doc (D5/D6). Keep the flag as an escape hatch.

---

## 6. Hardware-verification matrix (claim → on-Deck check)

| # | Design claim | On-Deck check | Gates |
|---|---|---|---|
| H1 | deck user runs evsieve unprivileged | probe P0 PASS | PR1 |
| H2 | virtual node inode STABLE across battery-death | probe A STABLE | PR1 |
| H3 | forwarding resumes post-reconnect (patched) | probe B OK | PR1 |
| H4 | installer builds patched evsieve in distrobox | `evsieve --version` + probe green | PR1 |
| H5 | **persist=reopen re-resolves a repointed symlink** (D2, the load-bearing unknown) | PR2 driver: repoint after forced eventN change → forwarding resumes | PR2 |
| H6 | joydev attaches a stable jsN to the virtual | `proxy_virtual_nodes` returns a jsN; stable across reconnect | PR2 |
| H7 | teardown leaves no evsieve / dangling link | `pgrep evsieve` empty; links gone | PR2 |
| H8 | CONTROLLER_ADD carries correct per-pad uniq | log grep vs `/proc` `U:` | PR3 |
| H9 | same-MAC DS4s stay distinct; empty-uniq degrades | fixtures + 2× same-MAC live | PR3 |
| H10 | sandbox sees ONLY the virtual jsN; Controlify reads it | in-sandbox `ls /dev/input`; in-game | PR4 |
| H11 | seamless reconnect: same slot, world preserved | battery-death live, 1 pad | PR4 |
| H12 | evsieve-death → clean SLOT_DIED (no hang) | kill evsieve; slot reaps, no black screen | PR4 |
| H13 | #61 sticky-slot: no theft, rejoin own quadrant | #61 repro, report slot count | PR5 |
| H14 | #62 subsumed: bound node survives re-enumeration | re-enumerate mid-session; input holds | PR5 |
| H15 | #79: undock → built-in drives survivor | dock→undock live | PR6 |
| H16 | Steam UI still sees pad via hidraw (limitation) | overlay responds under grab (expected) | PR7 docs |

---

## 7. Deferred / future (not v1.2)

- `persist=full` session-start priming (start-before-connect, cache-primed
  deterministic node shape) — lets a slot's virtual pre-exist. Not needed
  under lazy-start; revisit if we want pre-warmed slots or if D2's repoint
  interacts badly with reopen.
- Upstreaming the bounded-retry patch to KarsMulder/evsieve (the bug is
  general: any BT evdev consumer using persist hits the udev-ACL EACCES
  race). Reduces our maintenance surface if merged.
- relaunch-on-reconnect for the capability-differ / D2-alt cases (respawn
  the SAME slot on a new node), the concrete answer to the pre-existing
  zombie-flap the raw-bind plan disclosed.

---

## 8. Open questions (genuinely unresolved)

1. **Does our built evsieve's `persist=reopen` re-resolve a symlink whose
   TARGET changed?** (D2.) The code path follows symlinks on every
   try_open, so it should — but it is unverified for our exact build and
   is the single load-bearing assumption of the whole reconnect story.
   H5/PR2 must prove it; D2-alt is the named fallback if it fails. This is
   the one thing that could force a design change.
2. **Does grabbing the physical evdev while evsieve forwards interact with
   Steam re-grabbing on reconnect?** The probe showed Steam's 28de virtual
   starved under our grab, but the reconnect re-grab ordering (who wins the
   evdev when the pad returns) was not stress-tested across many cycles.
   Low risk (our sandboxes already coexist with Steam's grabs), but worth a
   multi-cycle soak in PR4.
3. **8BitDo / Xbox pads without a genuine per-unit uniq** — sticky-slot
   degrades to vendor:product+order for them. Acceptable for v1.2 (DS4/
   DualSense is the validated case), but the multi-identical-non-Sony-pad
   experience is unmeasured.
