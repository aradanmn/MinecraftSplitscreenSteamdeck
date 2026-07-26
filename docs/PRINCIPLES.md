# Design Principles

How we make design decisions in this codebase. Complements ARCHITECTURE.md
(*where* code lives) and STYLE-GUIDE.md (*how* code looks) with *why* and *how we
decide*. Every principle here was earned by a specific bug this project already
paid for — the citation is the point, so we don't re-learn it.

Apply these to NEW code and when touching the areas they name. They are not a
mandate to refactor working code that predates them.

--------------------------------------------------------------------------------
## 1. State access goes through accessors; orchestration stays imperative

**Rule.** Shared, multiply-read/written state — `SPLITSCREEN_STATE`, the runtime
globals, per-slot identity — is reached ONLY through accessor functions
(`_get_slot_field`, `update_slot_state`, `_get_mode`/`_set_mode`, the
`slot_manager` verbs). One function owns each piece of state; callers never
reach around it with raw `jq`/global reads. Decision *policy* lives in one
accessor (e.g. `slot_claim`), not scattered across handlers.

**Why.** `slot_manager` made the reconnect decision matrix a hardware-free table
test, and the on-Deck MCSS-virtual bug was cleanly separable *because* identity
lived behind an accessor — the fix was one gate in `controller_monitor`, nothing
else moved. `_get_slot_field` is already "the ONE encoding of `.slots[$slot]`"
(#51); `_set_mode` is already "the single writer of `.mode`" (#43/#45).

**Boundary — do NOT apply to:** process orchestration (`bwrap`/`gamescope`/
`evsieve`/`kwin`/`java`) and pure computation (geometry, version-match ladders).
Those are imperative side-effects and math — there is no *store* to own, and
wrapping them in getters/setters is noise. Get/set is for state, not behavior.

--------------------------------------------------------------------------------
## 2. Ship big features flag-gated and dark-first

**Rule.** Land a large subsystem as a DARK module first (sourced, zero callers,
behavior-neutral). Wire it in behind a default-OFF flag. Validate. Flip the
default LAST, in its own one-line change, only after real validation.

**Why.** The #38 seamless-reconnect feature merged to `main` in four reviewable,
each-behavior-neutral PRs (slot_manager → proxy launch → orchestrator dispatch →
watchdog) behind `MCSS_CONTROLLER_PROXY`, never destabilizing `main`.
`controller_proxy.sh` was literally "DARK ON ARRIVAL: zero callers." The flip
(#150) shipped only after the on-Deck run passed.

**How.** New feature flags default 0 and are documented at their definition with
what validated the flip. `MCSS_RAW_BINDING` / `MCSS_CONTROLLER_PROXY` are the
template.

--------------------------------------------------------------------------------
## 3. Validate on hardware AND through the real process before shipping

**Rule.** Unit tests and a focused probe are NECESSARY but NOT SUFFICIENT for
anything touching controllers, display mode, or the launch path. Before flipping
a default or closing a feature, run it through the actual install + launch on the
Deck.

**Why.** The MCSS-virtual pollution bug passed *every* unit test AND the D2
repoint probe — only a live 4-up game surfaced it (our own evsieve virtuals,
advertising the pad's `054c` id, polluted the monitor's enumeration). The unit
layer and the probe each exercised a slice; only the full monitor→orchestrator→
launch chain, live, caught the integration gap. This is the "test on hardware AND through the real process" rule.

--------------------------------------------------------------------------------
## 4. Mutation-test any test that guards non-trivial logic

**Rule.** After a test passes, BREAK the code it covers (invert a comparison, stub
the function to a no-op) and confirm the test now FAILS. A test that passes
against broken code is worse than none — it certifies nothing while looking green.

**Why.** The first dock-debounce integration test passed with the debounce
replaced by `true` — the blip and the real change were the same value, so
asserting on content proved nothing. Mutation caught it; the rewrite asserted on
"exactly one message." Every substantive test this session was mutation-verified.

--------------------------------------------------------------------------------
## 5. Fail open — detection failures degrade safely, never escalate to teardown

**Rule.** When a probe/detector can't get a clean reading, return a "don't know /
keep last-good" result, never a destructive one. A false positive must not kill a
running player's session.

**Why.** `dock_detection` defaults to handheld and (post-#133 design) confirms a
mode across reads; the watchdog window-check returns `2` ("can't tell — do not
escalate") on any X hiccup instead of firing `SLOT_DIED`; `_maybe_proxy_swap`
falls back to raw binding on ANY proxy failure rather than launching
controller-less. The HW-2 force-reboot came from a single un-debounced sysfs read
escalating straight to a teardown — the exact failure this prevents.

--------------------------------------------------------------------------------
## 6. No unbounded waits in operator paths; show busy vs waiting-for-input

**Rule.** Every wait in an operator-facing script is bounded (timeout or a capped
poll loop). Distinguish "I am working" (a TTY-gated spinner + countdown, to
stderr) from "I am waiting for YOU" (a visible input caret). Silence is a bug.

**Why.** The repoint probe hung — an unbounded read after a prompt that never
rendered — and a bounded-but-silent 30 s wait *looked* identical to a hang. Both
cost a wasted operator session. Operator scripts must signal busy-vs-waiting.

--------------------------------------------------------------------------------
## 7. Kill only PIDs you started — never `pkill`/`killall`

**Rule.** Track every PID you spawn (an array) and signal exactly that set.
`pkill`/`killall`/name-matched kills are banned.

**Why.** The test_orchestrator kill hazard: a name-matched kill in a test group-
killed real processes and disconnected the working session. The probes and
`controller_proxy` both hold to tracked-PID-only discipline for the same reason.

--------------------------------------------------------------------------------
## 8. Redirect backgrounded work off a capture pipe

**Rule.** Any process backgrounded inside a command substitution's reach must
redirect its stdout/stderr off the captured pipe (`>/dev/null 2>&1` or to a file).

**Why.** #80/#103 CI hang: `out=$(bash suite 2>&1)` blocks until EVERY process
holding the stdout pipe exits, and an orphaned watchdog grandchild held it
forever. A backgrounded subshell that inherits the capture pipe hangs the whole
run.

--------------------------------------------------------------------------------
## 9. One encoding of shared data/logic (DRY, with teeth)

**Rule.** Any datum or logic used in more than one place has exactly ONE encoding:
the module manifest, the state schema, the token-fetch, the version-match ladder,
a magic constant. A second copy is a latent silent-drift bug.

**Why.** The #47/#49/#51/#88/#89 duplication batches: the manifest lived in 3–4
places (a missed edit = silent feature loss), the token-fetch was pasted 7× with
timeouts drifting apart. Consolidation to one owner (`runtime_context` globals,
`parse_input_device_blocks`, the `_get_slot_field` schema) is a recurring, high-
value cleanup — and cheaper to never incur.

--------------------------------------------------------------------------------
## 10. The FIFO event loop is the single serialization point; reserve before backgrounding

**Rule.** `_handle_msg` processes one message at a time — lean on that as the
serialization boundary. When a handler backgrounds work (e.g. `spawn_instance`),
first make any state reservation SYNCHRONOUSLY in the foreground, so the next
message can't race on it.

**Why.** Without the synchronous `active:true` reserve, back-to-back
`CONTROLLER_ADD`s (startup burst, or several pads at once) could hand the same
free slot to two spawns → two instances on one slot. The serial loop + up-front
reservation is what makes the rest race-free without locks in the hot path.

--------------------------------------------------------------------------------
## These are industry-standard patterns (not local inventions)

We arrived at the ten above by getting burned, but each has a decades-old
textbook name — look them up to go deeper. This is the canon, rediscovered:

| # | Established name(s) |
|---|---------------------|
| 1 | Encapsulation / Information Hiding (Parnas 1972); Law of Demeter; Single Source of Truth |
| 2 | Feature Toggles (Martin Fowler); Branch by Abstraction; trunk-based development |
| 3 | The Test Pyramid — E2E/integration catch what unit tests can't |
| 4 | Mutation Testing (an established test-quality discipline) |
| 5 | Graceful Degradation / Fail-safe design; defensive programming |
| 6 | Timeouts everywhere (resilience engineering); response-time feedback (Nielsen/Miller) |
| 7 | Least privilege; blast-radius containment |
| 8 | Resource-lifecycle discipline |
| 9 | DRY — Don't Repeat Yourself (Hunt & Thomas, *The Pragmatic Programmer*) |
| 10 | Single-threaded event loop (Node.js / Redis model); serialize instead of lock |

--------------------------------------------------------------------------------
## Also standard practice here (canon we already follow)

Named for vocabulary; each cites where the codebase already does it, so they stay
grounded rather than aspirational.

- **Command–Query Separation (CQS, Meyer).** A function either *does* something
  (a command, mutates, returns a status) or *answers* something (a query, returns
  data, no side effects) — never both. Our getters (`_get_slot_field`,
  `get_active_slots`) return data; our setters (`update_slot_state`,
  `slot_release`) mutate. STYLE-GUIDE already says "stdout — data only!".

- **Single Responsibility Principle (SRP, the "S" in SOLID).** One module, one
  job — the reason the monolith was split into `modules/*.sh` by domain
  (ARCHITECTURE.md §2). A function that grew a second responsibility gets split
  (e.g. the launch machinery extracted to `_launch_slot`).

- **YAGNI — You Aren't Gonna Need It.** Don't build speculative generality. This
  is exactly why we did NOT switch the whole codebase to get/set (#1's boundary):
  the pattern earns its keep on state, not on orchestration, so we don't impose
  it where it buys nothing.

- **Idempotency.** Operations are safe to repeat. `update_slot_state`'s reserve is
  idempotent; `cleanup` guards against double-run with a sentinel; the module
  constants blocks are re-source-safe (`if [[ -z "${_X_LOCKED:-}" ]]`). Retrying a
  step must never corrupt state.

- **Pure functions at the edges.** Computation with no side effects — geometry
  (`window_manager`), the version-match ladder — takes inputs, returns outputs,
  touches no globals. These are the easiest things to test and the safest to
  reuse; keep calculation separate from I/O and state.

- **Parse/validate at the boundary.** Untrusted input (`/proc/bus/input/devices`,
  display-query tool output, the state file) is parsed by ONE reader at the edge
  (`parse_input_device_blocks`, `mcss_query_displays`, `read_state`) that
  normalizes it; the rest of the code trusts the normalized form.

**Further reading** (short, high-leverage): *The Pragmatic Programmer* (DRY,
orthogonality, YAGNI); Martin Fowler's articles on Feature Toggles and the Test
Pyramid; the SOLID principles (SRP especially); "Fail-safe vs fail-secure" for
where #5's fail-open is and isn't the right default.

--------------------------------------------------------------------------------
## Using this document

- New code: follow these; cite the principle number in the PR when a reviewer
  might wonder about a choice.
- New *stateful* subsystem: `slot_manager` is the reference implementation for #1.
- New *feature*: `controller_proxy` + `MCSS_CONTROLLER_PROXY` is the reference for
  #2 and #3.
- Found a new hard-won pattern? Add it here WITH the bug that taught it — a
  principle without a citation is just an opinion.
