# DESIGN — #38 seamless controller reconnect (slot-manager wiring)

Status: DRAFT for review (2026-07-25). Author: Claude, orchestrating; design
calls by Scott (manager separation; resume-first-with-grace intent policy).
Basis: #112 on-Deck evdev captures (2026-07-25) + full code trace this session.

Decisions LOCKED 2026-07-25 (Scott): Q1 grace=180s. Q2 A — the proxy virtual's
identity follows the physical pad (ADOPT restarts with the new device-id; prompts
become correct for the pad in hand). Q3 A — proxy-OFF reconnect is a no-op
(reconnect is a proxy-ON feature; no throwaway relaunch stopgap). Q4 — on-Deck
verify only, folded into the #112 session (no design change unless grab breaks the
guide button). Q5 — REJECT-when-full LOGS ONLY (no user-message surface); the
4-player limit is documented in the README instead (couch co-op de facto standard).

--------------------------------------------------------------------------------
## 1. Problem

A controller that drops (dead battery, idle power-off) and comes back must
re-attach to its running instance without the player losing their session. Today
it can't: the live path RAW-binds the pad's own `jsN` into the bwrap sandbox at
launch, and bwrap mounts are fixed for the life of the mount — the reconnected
pad arrives as a NEW device node the sandbox can never see (#61/#62). Sticky
slots (#37/#84) keep the *instance* alive, but it's input-dead. HW-2 showed it
exactly: "P2 dropped, session persisted, but was un-controllable."

The fix (#38): put a per-slot persistent virtual device between the physical pad
and the sandbox. The sandbox binds the STABLE virtual; a userspace proxy
(evsieve) reads whatever physical pad currently belongs to the slot and re-emits
into that virtual. Reconnect = re-point the proxy at the pad's new node; the
sandbox's binding never breaks.

That proxy exists (`controller_proxy.sh`) but is DARK — zero callers. This design
wires it in, and adds the missing piece: deciding WHICH slot a
connecting/reconnecting pad belongs to.

--------------------------------------------------------------------------------
## 2. What exists today (do not rebuild)

- `controller_proxy.sh` (DARK, zero callers, fully unit-tested):
  - `proxy_start_slot(slot, ev, vendor, product)` — `ln -sfn ev pads/slot<N>`,
    spawns `evsieve --input pads/slot<N> grab persist=reopen --output
    create-link=virt/slot<N> name=MCSS-slot<N> device-id=vendor:product`. Polls
    for the virtual to appear. Returns evsieve pid.
  - `proxy_repoint_slot(slot, ev)` — moves the `pads/slot<N>` symlink only;
    assumes evsieve's `persist=reopen` re-resolves it. Returns 0 (live) / 1
    (evsieve dead → caller escalates) / 2 (no binary).
  - `proxy_stop_slot(slot)` — SIGTERM/KILL the tracked+verified evsieve, rm links.
- `controller_monitor` — parses `/proc/bus/input/devices`, dedups a controller's
  sub-devices by UHID-parent, keeps the js-owner node, STRUCTURALLY EXCLUDES the
  `28de` Steam virtuals in raw-binding mode, and emits
  `CONTROLLER_ADD ev js vendor product uniq` (5 fields; **uniq = the MAC**).
  `CONTROLLER_REMOVE ev` on disappearance.
- `orchestrator._handle_msg` — the FIFO event loop (SERIAL: one message at a
  time). Today CONTROLLER_ADD always `_find_free_slot`→spawn; **phys_uniq parsed
  then DISCARDED**. CONTROLLER_REMOVE preserves the instance (#37) but only LOGS.
  SLOT_DIED (window gone) tears the slot down.
- Live bind = RAW (`instance_lifecycle`, no evsieve).

--------------------------------------------------------------------------------
## 3. Hardware facts that constrain the design (#112, on-Deck)

- **Pad role = "has a `js` handler."** A DS4 = 3 nodes: pad(`event`+`js`),
  touchpad(`event`+`mouse`), motion(`event` only). A reopen keyed on `eventN`
  grabs the touchpad after reconnect → evsieve "capabilities different" → death.
- **`eventN` and the UHID instance are per-CONNECTION** — both churn on every
  reconnect (eventN via lowest-free reallocation; UHID via `.000B`→`.000C`…).
- **MAC (`uniq`) is the only stable key**, present on DS4 AND Xbox physical pads.
  EMPTY on the `28de` Steam virtuals — which ALSO carry `js` handlers. So:
  select physical pads by vendor-exclusion (drop `28de`), key on the physical
  `uniq`; NEVER treat "has js" as the sole physical-pad test.
- MAC is *mostly* unique. Cheap DS4 clones can duplicate it (Scott). Design must
  degrade, not break, on collision.
- Deck caps at 4-up (VRAM ceiling, #70) → a 5th instance is never possible.

--------------------------------------------------------------------------------
## 4. Architecture — a slot manager owns all slot state

Event handlers hold NO policy. `CONTROLLER_ADD` is a fact ("a pad appeared");
interpreting it (new player? reconnect? adopt an orphan?) is a separate
responsibility. A **`slot_manager`** owns the slot record schema and every state
transition, giving `add` and `remove` ONE consistent get/set/release surface,
with the intent policy in exactly one function. It is pure state+policy: no FIFO,
no bwrap, no evsieve — so it is unit-testable as a decision table.

New module `slot_manager.sh` (consolidates today's scattered `_find_free_slot`,
`update_slot_state`, `slot_is_active`, `_find_slot_by_event_node`; migrate
incrementally so nothing regresses).

Layering:
  monitor (raw device facts) → slot_manager (decide transition) →
  orchestrator handler (execute the side effect) → proxy / instance_lifecycle.

### 4.1 Slot record  (SPLITSCREEN_STATE `.slots["N"]`)
```
active          bool     slot is occupied by an instance
phys_uniq       str      the pad MAC — reconnect key           (NEW)
phys_vendor     4hex     for the proxy virtual's device-id     (NEW)
phys_product    4hex                                            (NEW)
phys_event_node str      the pad's CURRENT js-owner event node  (NEW)
disconnected    bool     controller gone, instance preserved    (NEW)
disconnected_at epoch-s  grace-window anchor                    (NEW)
bwrap_pid / spawn / …    existing lifecycle fields (unchanged)
```
Empty `phys_uniq` (e.g. handheld built-in, or a would-be Steam-virtual slot that
must never be created) is never a reconnect key — matching skips empties.

### 4.2 Manager API

GET (pure, no mutation):
```
slot_by_uniq(uniq)            -> "<slot>…"  all slots whose phys_uniq==uniq (may be >1: clones)
slot_by_event_node(ev)        -> "<slot>"   active slot whose phys_event_node==ev
free_slot()                   -> "<slot>"   lowest inactive slot, or ""
most_recent_abandoned_within(grace) -> "<slot>"  newest disconnected_at within grace, or ""
any_abandoned()               -> "<slot>"   newest disconnected slot regardless of age, or ""
slot_get(slot, field)         -> value
slot_is_active(slot) / slot_is_disconnected(slot)   -> exit 0/1
```

SET (transitions — POLICY LIVES HERE AND ONLY HERE):
```
slot_claim(uniq, vendor, product, ev) -> "<OUTCOME> <slot>"
    The one decision verb. Mutates state to reserve/refresh the slot's identity
    ATOMICALLY (safe because _handle_msg is serial), returns a token the caller
    executes. See §5 for the full matrix. Outcomes:
        RESUME <slot>   same pad returning to its own slot (same device-id)
        ADOPT  <slot>   a DIFFERENT pad taking over an orphaned slot (device-id CHANGES)
        SPAWN  <slot>   genuine new player, fresh instance
        REJECT          nothing to do (full, none adoptable)
slot_reserve(slot, uniq, vendor, product, ev)   low-level set used by claim/spawn
slot_touch(slot, ev)                            update phys_event_node, clear disconnected
```

RELEASE:
```
slot_release(ev|slot)   controller gone: set disconnected=true, disconnected_at=now;
                        KEEP the instance (#37). What CONTROLLER_REMOVE calls.
slot_free(slot)         hard free: clear the whole record. What SLOT_DIED calls
                        (real player-leave = game window destroyed).
```

--------------------------------------------------------------------------------
## 5. The intent policy  (inside `slot_claim`; Scott: resume-first-with-grace)

Given a physical pad (uniq, vendor, product, ev). Evaluate in order:

```
1. KNOWN MAC, its slot is disconnected      -> RESUME  (identity definitive; NO time limit)
2. KNOWN MAC, its slot is active+connected  -> (no-op REJECT: duplicate add / echo)
3. UNKNOWN MAC:
   a. no free slot AND an abandoned slot     -> ADOPT (most-recent)   # 4-up full: only option
   b. abandoned slot within GRACE window     -> ADOPT (most-recent)   # battery-death-grab-a-spare
   c. a free slot                            -> SPAWN                 # genuine new player
   d. abandoned slot PAST grace, a free slot -> SPAWN (case c wins)   # explicit: grace expired = new player
   e. nothing free, nothing abandoned        -> REJECT               # log only; 4p limit in README
```

Notes:
- **RESUME vs ADOPT is not cosmetic.** RESUME = same physical pad → same
  vendor:product → the proxy just re-points (device-id unchanged, Controlify sees
  the same controller). ADOPT = a different pad → vendor:product may change → the
  proxy must RESTART with the new device-id (see §6), and the manager overwrites
  the slot's phys_uniq/vendor/product.
- **Grace governs only the ambiguous case** (both a free slot and an orphan). When
  the session is full, an unknown pad ADOPTs regardless of age — it is the only
  physically possible outcome (no 5th instance). When a free slot exists and the
  orphan is past grace, we treat the pad as a new player.
- An abandoned slot never auto-frees on grace expiry — it persists as a live,
  input-less instance (sticky, #37/#84) until its MAC returns (RESUME), a game
  window death frees it (SLOT_DIED→slot_free), or an unknown pad ADOPTs it.
- **Identical-MAC multi-match (the true floor):** if `slot_by_uniq` returns >1
  disconnected slot (cloned pads, both dropped), the manager RESUMEs the
  most-recently-disconnected. The pads are physically indistinguishable, so no
  property can do better; documented as the known limit (also in
  tests/probe-controller-reconnect.sh). Non-issue unless ≥2 identical pads are
  simultaneously disconnected.

--------------------------------------------------------------------------------
## 6. Executing outcomes — the (thin) handlers + proxy actions

```
CONTROLLER_ADD ev js vendor product uniq:            # 28de excluded; ev = js-owner event node (§7)
    read outcome slot <<< "$(slot_claim "$uniq" "$vendor" "$product" "$ev")"
    case "$outcome" in
      SPAWN)  spawn_instance "$slot" "$ev" …            # existing launch path …
              proxy_start_if_enabled "$slot" "$ev" "$vendor" "$product" ;;   # §8
      RESUME) proxy_repoint_slot "$slot" "$ev" || proxy_restart "$slot" "$ev" "$vendor" "$product" ;;
      ADOPT)  proxy_restart "$slot" "$ev" "$vendor" "$product" ;;   # device-id changed → full restart
      REJECT) log only ;;                            # session full; 4p limit documented in README
    esac

CONTROLLER_REMOVE ev:
    slot_release "$ev"                                 # mark abandoned; instance + evsieve stay

SLOT_DIED slot:                                        # window destroyed = real leave
    proxy_stop_slot "$slot"; slot_free "$slot"; teardown_instance "$slot"; reflow

proxy_restart(slot, ev, v, p): proxy_stop_slot slot; proxy_start_slot slot ev v p   # watchdog path
```

RESUME uses bare `proxy_repoint_slot` (fast, ideally seamless). If it reports the
evsieve dead (return 1) — or if the on-Deck verification (§9) shows persist=reopen
does NOT honor a moved symlink — RESUME falls through to `proxy_restart`. ADOPT
always restarts because the virtual's advertised device-id changes.

--------------------------------------------------------------------------------
## 7. The js-owner guarantee (#112 crash fix)

The `ev` handed to the manager/proxy MUST be the pad's js-owner event node, never
the touchpad/motion sibling — that is the entire #112 crash fix (evsieve then
reopens a PAD, matching caps). The monitor's UHID-parent dedup already keeps the
js-owner and emits its event node in raw-binding mode, so this holds today.
Belt-and-suspenders: the manager MAY re-verify by confirming `ev`'s input device
has a sibling `jsN` under the same UHID parent, rejecting a non-js node. Cheap;
guards against a future monitor change silently reintroducing #112.

--------------------------------------------------------------------------------
## 8. Launch wiring (flag-gated: `MCSS_PROXY_ENABLE`, default OFF)

On a SPAWN, when the proxy is enabled:
1. `proxy_start_slot slot ev vendor product` → the `virt/slot<N>` node path.
2. Bind the **virt** node into bwrap instead of the raw `jsN` (the sandbox now
   holds a stable node the reconnect never invalidates).
3. `slot_reserve` records phys_uniq/vendor/product/event_node.

With the flag OFF, SPAWN keeps today's RAW bind and RESUME/ADOPT degrade to
today's behavior (no live reconnect; the orphan persists). Reconnect is therefore
a proxy-ON capability; raw-binding remains a fully working default until §9 is
verified on-Deck. (Alternative for proxy-OFF RESUME — teardown+relaunch the same
slot with the new node — is possible but loses game state; NOT chosen as default.)

--------------------------------------------------------------------------------
## 9. The one open verification (#112 step-2, needs the Deck)

`proxy_repoint_slot` assumes evsieve `persist=reopen` re-reads the MOVED symlink.
Unknown whether it does, or caches the original device (the #112 death hints at
the latter). Impact is bounded either way:
- If it re-reads → RESUME is truly seamless (symlink move only).
- If it caches → `proxy_repoint_slot` returns 1 (evsieve died) and we ALREADY
  fall through to `proxy_restart` (stop+start = clean re-open, ~sub-second input
  gap). Correct, just not seamless.

So the design is correct regardless; the verification only decides whether RESUME
is seamless or a brief blip. Test: on the Deck, start a proxy slot on a DS4, drop
+ reconnect, watch whether the same evsieve pid keeps feeding the virtual after a
repoint, or dies. Rig is ready (evsieve built; DS4s pair). Deferred to build time.

--------------------------------------------------------------------------------
## 10. Watchdog supervision (HW-1 "mandatory")

evsieve can die on a real BT reconnect independent of our repoint. A supervisor
(fold into the existing `watchdog.sh`) polls each enabled slot's proxy liveness
(`_proxy_live_pid`); on death of a slot whose controller is present, it
`proxy_start_slot`-restarts. On death of a slot whose controller is absent, it
does nothing (evsieve legitimately exits/waits per persist mode) — the slot is
just abandoned, handled by the reconnect path when the pad returns.

--------------------------------------------------------------------------------
## 11. Concurrency / correctness

- `_handle_msg` is SERIAL (single FIFO reader) → `slot_claim` reservations don't
  race; no two claims pick the same free slot. Preserve this: the manager mutates
  state in the foreground, BEFORE any backgrounded `spawn_instance`. (Same reason
  today's code reserves `active:true` synchronously.)
- State writes use the existing file-lock discipline (flock) — the manager is the
  only writer of the new fields.
- Reflow: SPAWN and SLOT_DIED reflow layout (as today); RESUME/ADOPT do NOT
  reflow (the window never moved).

--------------------------------------------------------------------------------
## 12. Test matrix (manager unit tests — no hardware)

Decision table for `slot_claim` (mock state, assert OUTCOME+slot):
| state                                             | pad     | expect       |
|---------------------------------------------------|---------|--------------|
| slot2 disconnected, uniq=A                         | uniq=A  | RESUME 2     |
| slot2 active+connected, uniq=A                      | uniq=A  | REJECT       |
| all full, slot3 abandoned                           | uniq=Z  | ADOPT 3      |
| slot3 abandoned 10s ago (grace=180), free slot4     | uniq=Z  | ADOPT 3      |
| slot3 abandoned 999s ago (>grace), free slot4       | uniq=Z  | SPAWN 4      |
| free slot4, no abandoned                            | uniq=Z  | SPAWN 4      |
| all full, none abandoned                            | uniq=Z  | REJECT       |
| slot2 & slot3 both disconnected, both uniq=A (clones)| uniq=A | RESUME newest|
| empty-uniq pad (should never reach here)            | uniq="" | SPAWN/REJECT per free |
Plus: slot_release marks disconnected+ts; slot_free clears; js-owner re-verify
rejects a mouse/event-only node.

--------------------------------------------------------------------------------
## 13. Rollout (incremental; raw-binding never regresses)

PR-a  slot_manager.sh: record schema + GET/SET/RELEASE + CONTROLLER_REMOVE→slot_release
      + SLOT_DIED→slot_free. Behavior-neutral (claim still only SPAWNs; flag off).
      Full unit test matrix (§12).
PR-b  Launch wiring behind MCSS_PROXY_ENABLE: proxy_start on SPAWN, bind virt node.
PR-c  slot_claim full policy (RESUME/ADOPT/grace) + thin CONTROLLER_ADD handler.
PR-d  Watchdog supervision (§10) + on-Deck #112 verify (§9) → flip default ON.

--------------------------------------------------------------------------------
## 14. Decisions (RESOLVED 2026-07-25, Scott)

Q1  GRACE = **180s** (covers a battery swap, excludes a genuine new player).
    Tunable via MCSS_RECONNECT_GRACE_S.
Q2  **A** — the virtual's device-id follows the physical pad. ADOPT restarts the
    proxy with the new vendor:product; prompts flip to match the pad now in hand
    (correct, not cosmetic-wrong). Same-brand swaps are transparent (same id).
Q3  **A** — proxy-OFF reconnect is a no-op. Reconnect is a proxy-ON capability; no
    teardown+relaunch stopgap (it would lose game state and be thrown away once the
    proxy lands).
Q4  **Verify-only** — fold the evsieve-grab-vs-guide-button check into the §9/#112
    Deck session. No design change unless the grab breaks the Steam/guide button;
    if it does, revisit (pass-through the guide button, or drop the exclusive grab).
Q5  **Log only** — REJECT-when-full does NOT surface a message (no Game-Mode message
    surface built). The 4-player limit is documented in the README instead — it's
    the couch co-op de facto standard. (No tie to #125.)

--------------------------------------------------------------------------------
## 15. Gotchas banked
- Steam 28de:11ff virtuals have js handlers + EMPTY uniq → select physical by
  vendor-exclusion; key on physical uniq. (DS4 + Xbox confirmed on-Deck.)
- Xbox pad carries `kbd`+`js`; role rule = "has js", not "js-only".
- eventN is lowest-free (not monotonic) + Steam mints/reaps a virtual per pad →
  the number a pad gets is unpredictable; never cache it.
- Clone-MAC: elimination fallback; simultaneous identical-pad reconnect is the floor.
