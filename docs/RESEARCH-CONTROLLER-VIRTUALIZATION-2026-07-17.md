# Research — can Valve's controller virtualization be reused for per-slot reconnect?

> Deep-research pass, 2026-07-16/17. Feeds #38 (per-slot virtual device),
> #62 (static dev-binds can't reattach), #79 (transition binding). Builds on
> docs/RESEARCH-CONTROLLER-IDENTITY-2026-07-01.md. Verification status is
> marked per claim: **[3-0]** = unanimously verified against the primary
> source; **[on-Deck]** = observed on our own hardware (2026-07-15 PR #82
> validation session); **[repo-2026-07-01]** = the prior research doc's
> primary-source findings; **[unverified]** = search-level only, treat as a
> lead; **[contested]** = a verifier refuted one phrasing.

## The question

A bwrap sandbox `--dev-bind`s one pad's `/dev/input/jsN`+`eventN`. When the
pad dies mid-session (battery), the bind-mounted inode is gone forever — even
a reconnect that reuses the same `jsN` number creates a NEW inode the sandbox
can never see. Valve visibly solved reconnect for Steam-launched games. Can we
ride their mechanism instead of building our own (#38)?

## Verdict

**No for Steam Input, not-on-stock-SteamOS for InputPlumber — but the pattern
Valve uses is exactly #38's design, and an off-the-shelf implementation
(evsieve) exists.** Valve never re-identifies a reconnected pad; they keep a
persistent virtual device open so the game never sees the disconnect at all
[repo-2026-07-01]. That persistence guarantee is a property of *Steam
brokering the game session* — which our instances deliberately don't have.
What we can (and should) borrow is the architecture, not the running stack.

## 1. Why Steam Input's 28de:11ff virtuals can't be our stable nodes

- The persistent-virtual guarantee is scoped to games Steam launches and
  routes input to. Our four instances are launched by our orchestrator, not
  Steam; Steam performs no per-instance slot routing for them, and no public
  API lets a third-party consumer pin physical→virtual assignment
  [repo-2026-07-01; no counter-evidence found in this pass].
- **On our own hardware the virtual pool churns when no Steam game session
  owns the pads** [on-Deck]: during the 2026-07-15 session, a DS4
  power-cycle produced a *freshly minted* virtual ("Microsoft X-Box 360
  pad 1", `input76`) after the removal of the prior tree (`input73`) — new
  sysfs path, new node, i.e. exactly the inode death our sandbox cannot
  survive. Idle-pool `inputN` ordering also does not track physical
  connection order (the §3b leak that made raw binding our docked default —
  validated 2026-06-26).
- SDL's own handling confirms slot identity lives in Steam-internal metadata:
  SDL ≥2.30 deliberately sorts Steam virtual pads by Steam controller slot so
  Steam-launched games match the Steam UI ordering [3-0]. How SDL *reads*
  that slot is contested — the claim "the slot is parseable from the 'pad N'
  device-name digits, no Steam API needed" was **refuted 1-2** by verifiers
  [contested] — so treat name-derived slot mapping as unproven. Our design
  should not depend on it either way.

## 2. InputPlumber: right architecture, wrong availability

InputPlumber is architecturally the finished version of #38 — composite
devices that read physical sources and re-emit through emulated target pads
[3-0], with (per search-level docs) YAML per-device matching, a root D-Bus
API (`CreateCompositeDevice`, intercept modes), `persist=true` composite
survival across source loss, and Deck/DualSense/Xbox target emulation — all
headless [unverified, multiple]. But:

- **It is not present on stock SteamOS on our Deck** [on-Deck]: hardware
  stage0 P0.6 reports it absent (2026-07-15), consistent with the #45-era
  finding that the service ships disabled/dead ("autostart skips Valve").
  Its own install docs cover Arch/Fedora/Debian/NixOS and say nothing about
  SteamOS [unverified].
- Adopting it means installing and maintaining a root daemon on a read-only
  rootfs across SteamOS updates, plus arbitrating with Steam Input over who
  grabs the physical pads — the exact fragility our constraints exclude.
  It remains the fallback if our needs outgrow a minimal forwarder.

## 3. The off-the-shelf #38: evsieve

All core claims unanimously verified against the primary source [3-0 ×5]:

- evsieve reads physical evdev devices and re-emits through **persistent
  virtual uinput output devices** — precisely the per-slot stable node #38
  proposes.
- `persist=reopen`: on disconnect (battery death, unplug) it waits and
  reopens the physical device; the virtual output — the node our sandbox
  would bind — normally stays alive across the cycle.
- `persist=full` (main branch since 2024-01): caches the pad's capabilities
  to disk so evsieve can start *before* the physical device exists — this is
  what lets a slot's node be created at session start and primed from the
  first claim.
- **The physics constraint every implementation shares:** uinput capabilities
  are immutable after creation. If a reopened device's capabilities differ,
  evsieve destroys and recreates the output node — new inode, dead bind. The
  maintainer's own broken-consumer example (Qemu holding a passed-through
  node) is our failure class exactly. Same-model reconnects (DS4→DS4, our
  common case) keep capabilities identical; the capability cache makes the
  node shape deterministic per slot.

What evsieve does NOT do for us: decide *which* physical pad feeds *which*
slot node on reconnect. That matching stays ours — and the 2026-07-01
research already identified the tool: the evdev `uniq` field (BT MAC on
DS4/DualSense) stably identifies a unit across replug [repo-2026-07-01].

## 4. Recommended v1.2 shape

1. Per-slot persistent uinput node (evsieve `persist=full`, one process per
   claimed slot, capability cache primed at first claim), `--dev-bind` the
   slot's VIRTUAL node into the sandbox instead of the raw pad. Isolation
   semantics unchanged: one node per sandbox, udev still blanked.
2. Orchestrator owns reconnect matching by `uniq` (falls back to
   vendor:product + claim order for USB pads without uniq), and re-points the
   slot's evsieve input on CONTROLLER_ADD — the sandbox never notices.
3. Decision between evsieve binary vs ~200-line custom forwarder hinges on
   two on-Deck experiments (both fit tests/probe-controller-reconnect.sh):
   (a) evsieve output-node inode stability across a DS4 BT power-cycle;
   (b) capability equality across that cycle (`/sys/class/input/.../capabilities`
   before/after). If (a) holds and (b) is byte-identical, evsieve wins on
   maintenance; if we need custom masking/matching semantics inside the
   forwarder anyway, the custom path stays on the table.
4. Deployment reality: evsieve is a single Rust binary — user-space
   installable without touching the rootfs, pinned + shipped by our
   installer like the JDK is today. /dev/uinput access needs the `uinput`
   group or a udev rule — verify writability from the `deck` user on stock
   SteamOS before committing (one-line on-Deck check).

## 5. What this closes and what stays open

- Closes the "should we use Valve's system?" question: their *system* is
  session-scoped to Steam-launched games; their *pattern* is public domain
  and already productized. Building on the pattern is not reinventing —
  Steam Input, InputPlumber, MoltenGamepad and evsieve all converged on it
  independently [repo-2026-07-01; 3-0].
- Open empirical items (cheap, on-Deck, no research spend): the two probes
  in §4.3, the /dev/uinput permission check, and whether Steam Input tries
  to also claim the physical pad while evsieve holds it (EVIOCGRAB
  arbitration — expected fine since our sandboxes already coexist with
  Steam's grabs, but verify).

## Sources

- https://github.com/KarsMulder/evsieve (README; issue #2 — persist modes,
  capability immutability, recreate-on-mismatch, Qemu example)
- https://github.com/ShadowBlip/InputPlumber (+ readthedocs install matrix)
- https://discourse.libsdl.org/t/sdl-sort-steam-virtual-gamepads-by-steam-controller-slot/47752
  (SDL 1772338 / 2.30 slot sorting)
- docs/RESEARCH-CONTROLLER-IDENTITY-2026-07-01.md (SDL GUID construction,
  uniq/serial identity, convergent persistent-virtual pattern)
- On-Deck observations, 2026-07-15 PR #82 validation session (virtual pool
  churn on reconnect without a Steam game session; InputPlumber absent;
  raw-binding §3b history)
