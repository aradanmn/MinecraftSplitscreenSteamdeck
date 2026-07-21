# MinecraftSplitscreenSteamdeck — v1.2 Work Plan

**Date:** 2026-07-18 · **Repo:** aradanmn/MinecraftSplitscreenSteamdeck ·
**Baseline:** `main` @ ac1685e (v1.1 complete, #38 design landed) ·
**Centerpiece:** docs/DESIGN-38-CONTROLLER-VIRTUALIZATION-V1_2.md

This plan sequences the v1.2 cycle the way the v1.1 plan sequenced its
own: Part-structured, one roadmap table of milestones with exit criteria,
"validate before you build on it" as doctrine, every gate an
owner-observable check, and paper filed the day it is free. It inherits
v1.1's hard-won rules — **`git pull` ≠ deployed**, logs are evidence and
never closure, and `UNTESTED` stays in the code until a Deck pass converts
it to `VALIDATED <date>` — and adds the two evidence exemplars v1.1 minted
at its close: the M4 comments-only diff proof and the BENCH-AB A/B gate.

---

## Part 1 — State snapshot: what v1.1 → now delivered

v1.1 shipped (tag `v1.1.0`, PR #63) with the whole nested-session
architecture Deck-validated — the 60s supervisor-wait regression found and
killed twice over (#60), teardown authority reconciled (#15 accepted as a
documented limitation), and the raw-controller-bind default validated on
hardware. Since then, running from `main`:

- **Globals consolidation landed** (#45 PR-series): `runtime_context.sh`
  owns the environment/paths/constants set; `runtime_modules.list` is the
  single module manifest (folds D4/#49); API bases, repo-raw URL, and
  heap policy unified. The canonical-globals design in v1.1 Part 4 is now
  code, not paper.
- **Style-guide retrofit complete** (#52 M4): every module carries the
  header/docstring/issue-ref convention; the retrofit was proven
  comments-only by mechanical diff review (the house evidence exemplar).
  It shook out #98 (residual strict-mode / `print_*` stream / `[dex]`
  prefix gaps) as follow-up.
- **Performance baseline established** (BENCH-AB-2026-07-18, PR #94): a v2
  A/B protocol on Deck hardware with a driver-injected teleport-hop and
  input-heartbeat clocks. Verdict MERGE — the standard mods + JVM flags
  branch leads +25% p50 and ~+40% 1%-lows at 4P, parity elsewhere, and
  the v1 "memory wall" was shown to be substantially protocol-borne, not
  real. **The harness in `tests/benchmark/` now exists as a reusable
  regression gate** — this is what v1.2 must clear before it ships.
- **#38 fully de-risked on paper AND partly on hardware.** The evsieve
  probe (`tests/probe-evsieve-reconnect.sh`, PR #99) VALIDATED P0/A/B on a
  patched binary over BT: unprivileged uinput, inode-stable virtual across
  battery-death, byte-equivalent forwarding post-reconnect (~1s recovery)
  with our `tests/evsieve-persist-reopen.patch`. The integration design
  (PR1–PR7 breakdown, hardware-verification matrix H1–H16) is written and
  is this cycle's centerpiece.

**Net:** the codebase is consolidated, styled, and perf-baselined. The one
large feature left before a credible v1 is the controller-identity family
(#38 + #61 + #62 + #79). v1.2 is that feature, staged dark and flipped on
behind evidence.

---

## Part 2 — v1.2 goal statement

**Headline: seamless controller reconnect.** A pad that dies (battery) or
drops (BT flap) and returns rejoins its *own* player slot with the world
still running and no window flicker — because Minecraft was never bound to
the pad, it was bound to a per-slot virtual device that evsieve holds open
across the disconnect. Delivering that headline subsumes three open bugs:

- **#61** — 4-pad cascade / slot theft: fixed by uniq-keyed sticky-slot
  rejoin.
- **#62** — sandboxes leak other players' input nodes and go stale on
  re-enumeration: subsumed because the bound node is a stable virtual the
  re-enumeration never touches.
- **#79** — docked→handheld leaves the survivor bound to the external pad:
  fixed by repointing slot 1's proxy to the built-in on the transition.

**Shipping posture.** Exactly like raw-binding in v1.1: the whole path is
behind `MCSS_CONTROLLER_PROXY` (default **OFF**). v1.2 ships the machinery
dark, validates each PR behind its own OFF-flag check, and flips the
default only after the flag-on hardware family passes and the 4P benchmark
shows no regression. "Fixed" stays reserved for user-confirmed in-game
response — never "the log says forwarding resumed."

**Not in the headline** but in the cycle: harness-trust fixes and the
first-boot input race that would otherwise corrupt the controller
validation itself (#95/#83/#84/#80), and a benchmark regression pass that
measures the one unmeasured cost — evsieve's userspace hop per event.

---

## Part 3 — Working model & the verification doctrine

Orchestrated agents at a fixed cadence, sized so each milestone is one
loop of it:

- **opus designs** — the #38 design is already this phase's output; per-PR
  design deltas (e.g. the exact state-schema fields) are small opus spikes.
- **sonnet implements** — one PR per design slice, behind the OFF flag.
- **the orchestrator reviews with mechanical gates** — the non-negotiable
  ones this cycle inherits from v1.1's close: a **comments-only / no-behavior
  diff proof** for the cleanup PRs (the #52 M4 exemplar), and the
  **BENCH-AB A/B gate** for anything that touches the per-event hot path
  (the #94 exemplar). Evidence, not vibes.

**Hardware is the scarce resource.** Scott is the sole Deck operator and
on-Deck validation is the bottleneck (the v1.1 lesson). So Deck checks are
**batched**: each operator session validates several PRs at once, and the
dark (flag-OFF) work is front-loaded so the one session-wedging-risk
session (flag ON, live pads) is single, late, and thoroughly prepared. The
plan targets **four** operator sessions, HW-1…HW-4, mapped to the
milestones below.

**Schedule the load-bearing check first.** The single highest-information
hardware check in the whole cycle is the D2 symlink-repoint CONFIRM
(design §2 D2 / H5): does our built evsieve's `persist=reopen` re-resolve a
symlink whose *target* changed? It gates PR4–PR7 and decides D2 vs D2-alt.
It lives in PR2, a dark module, so it can run **early and safely** (no flag
on, no live session to wedge). HW-1 batches it with the PR1 acquisition
probe — that first session de-risks the entire remainder of the cycle.

---

## Part 4 — Sequenced roadmap

**Order rationale.** Acquisition and the load-bearing gate first, because
everything downstream is contingent on the D2 verdict (M0→M1, HW-1). Then
the dark plumbing that can be validated with the flag still off (M1). Then
one flag-on family, validated in a single well-prepared live session
(M2+M3, HW-3). Then measure the hot-path cost, flip the default, and ship
(M4, HW-4). Harness-trust and first-boot-race fixes interleave *ahead of*
the hardware sessions that depend on them, never after.

| Milestone | Content (design PRs + interleaved quick-wins) | Agent-phase | Exit criterion (owner-observable) |
|---|---|---|---|
| **M0 — Foundations & acquisition** | PR1 (evsieve build-at-install in distrobox: pinned source + patch, SHA-256 verify, `cargo build`, resolve `MCSS_EVSIEVE_BIN`, graceful degrade, GPL island under `third_party/evsieve/`). Re-confirm deploy.sh freshness discipline. **Filler (must precede any hardware geometry check):** #83, #84 (harness asserts wrong Xwayland / stale pre-#37 teardown), #80 (inert test_orchestrator). Dispose PR #44; file paper. | design done → sonnet impl; mechanical SHA + GPL-island review | Installer produces a working `evsieve --version` in the distrobox on Deck; no-toolchain path degrades to proxy-OFF, not a hard fail. (Validated in HW-1.) |
| **M1 — Symlink-repoint gate + dark modules** | PR2 (`controller_proxy.sh`: symlink farm + `proxy_start/repoint/stop/virtual_nodes`; NOT wired into spawn). PR3 (uniq plumbing: `parse_input_device_blocks` 8th field + all 5 read-arity updates; emit uniq through the ADD contract; `_find_slot_by_uniq` defined, not yet branching). **Filler:** #95 (Controlify first-boot race — MUST land before any in-game controller gate), #89 (runtime_modules.list parsed 4×; rides PR2's list edit). **Parallel (no Deck):** #33 derivation audit — orchestrated read-only fan-out vs the FlyingEwok repo, adversarially judged (Part 6); `token.enc` removal. Proxy still OFF. | opus schema spike → sonnet impl; PR3 isolated (wide blast radius); #33 audit = read-only agent fan-out + adversarial judge | **HW-1 (batched, safe — all flag-OFF):** H1–H4 PR1 probe green against the built binary; **H5 the D2 CONFIRM** — repoint after a forced eventN change resumes forwarding; H6 stable virtual jsN; H7 teardown leaves no evsieve/dangling link; H8/H9 CONTROLLER_ADD carries correct per-pad uniq (log-grep vs `/proc` `U:`, same-MAC + empty-uniq fixtures); #95 fresh install no longer input-dead. **D2 vs D2-alt DECIDED and recorded.** Full stage0–stage5 green, proxy off = v1.1 behavior unchanged. **Off-Deck:** #33 derivation-audit verdict recorded (clean → license freely, or named-functions → clean-room package scoped into M4/v1.2.1). |
| **M2 — Bind-swap + flag flip (gated)** | PR4 (spawn binds the VIRTUAL jsN under `MCSS_CONTROLLER_PROXY=1`; sticky-slot rejoin branch; watchdog gains the dead-`evsieve_pid` check; state schema `phys_uniq` + `evsieve_pid`). Flag-gated; default still OFF. | sonnet impl; watchdog + orchestrator review | **HW-2 (flag ON, 1 DS4 docked):** H10 in-sandbox `ls /dev/input` shows only the virtual jsN, Controlify lists one pad and responds in game; H11 battery-death→reconnect resumes seamlessly, SAME slot, world preserved, no flicker; H12 kill evsieve → clean SLOT_DIED, no black screen, no D-state hang. Multi-cycle re-grab soak (open-q2). |
| **M3 — Bug-family acceptance (#61/#62/#79)** | PR5 (#61/#62 sticky-slot + subsumption proof — the uniq-keyed rejoin path goes live). PR6 (#79 docked→handheld: repoint slot 1's proxy to the built-in evdev on the transition). Flag ON. | sonnet impl | **HW-3 (flag ON — batches with HW-2 if PR4/5/6 all ready):** H13 #61 repro (3 healthy pads + plug the 4th) → no slot theft, no P2/P3 degradation, **report slot COUNT before/after**; mid-list pad disconnect→reconnect rejoins its OWN quadrant; H14 #62 re-enumerate mid-session, input holds; H15 #79 dock→undock → survivor responds to the Deck built-in, not the couch pad. |
| **M4 — Hardening, perf-gate, ship** | PR7 (flip `MCSS_CONTROLLER_PROXY=1` default; keep the flag as escape hatch; write the limitations doc D5 hidraw / D6 capability-differ / clone-uniq). **4P benchmark A/B** (proxy ON vs OFF) — measures the evsieve per-event hop. **Hardening filler:** #71 (burst-spawn reflow race) + #17 (reflow-retry flag never implemented — same subsystem). Interleave remaining small audit items (#21/#22) opportunistically. Tag `v1.2.0`. | sonnet impl; **BENCH-AB gate + comments-only proof for the doc/hardening PRs** | **HW-4:** 4P bench proxy-ON within the BENCH-AB gates (FPS ≥ baseline −5% per screen per N; no new SLOT_DIED/OOM) — **proxy hop overhead measured, not assumed**; H16 Steam overlay still responds via hidraw (documented limitation, expected); full stage0–stage5 green with the flag ON; tag. |

**Batching note.** HW-2 and HW-3 are both flag-ON and can collapse into
one live session if PR4/5/6 are all merged when the operator sits down —
that is the preferred outcome (three operator sessions instead of four).
They are kept as separate milestones on paper because PR4's H10–H12 is the
prerequisite proof for PR5/PR6; if PR4's check fails, M3 does not run.

---

## Part 5 — Quick-win interleave schedule (the filler discipline)

Each known-shape fix is placed **immediately before the hardware session
that depends on it**, never as trailing cleanup:

| Issue | Placed in | Why there (dependency) |
|---|---|---|
| #83 harness resolves the OUTER gamescope Xwayland | M0 | Every geometry assert in HW-1+ compares against the wrong screen until fixed — the harness must be trustworthy before the first Deck session. |
| #84 stage3 asserts pre-#37 teardown-on-disconnect | M0 | Contradicts the current (preserve-on-disconnect) design; would false-fail the very reconnect behavior v1.2 is proving. |
| #80 test_orchestrator inert (sourcing exec-redirects output) | M0 | Cheap; restores an automated check surface before the cycle leans on it. |
| #95 Controlify first-boot input-death race | M1 | Fresh installs come up input-dead; would sabotage HW-2's "Controlify responds in game" gate. Land it dark, well ahead. |
| #89 runtime_modules.list parsed 4× | M1 | PR2 adds `controller_proxy.sh` to that list — fold the parse-consolidation into the same edit. |
| #71 burst-spawn reflow race (+ #17 reflow-retry flag) | M4 | Hardening; not on the reconnect critical path. Groups with #17 (same reflow subsystem). |
| #21 KWin PID-only match, #22 no bwrap liveness check | M4 | Opportunistic; small audit items, no gate depends on them. |

---

## Part 6 — #33 license: engineering, not a standing decision

#33 has been miscategorized as an owner-decision item. Reading it with the
owner reframes it: the blocker was that the installer was originally
derived ~verbatim from FlyingEwok's **unlicensed** (all-rights-reserved)
repo — but the codebase has since been **massively rewritten** (v1.1's
M2–M4: globals migration, the duplication kill-list, module rebuilds, the
style retrofit). Whether any derived material actually *remains* is now an
empirical question with an evidence answer, not a legal judgment call. So
#33 becomes engineering, with one small residual choice at the very end.

**(1) Derivation audit — an orchestrated, evidence-producing work-item.**
Fan-out read-only agents diff the *current* code against the original
FlyingEwok repo function-by-function; an adversarial judge consolidates.
Two possible verdicts, each with a defined next step:

- **"Nothing substantive remains"** → the installer is our own work →
  attach a license freely (step 3).
- **"These named functions remain derived"** → a **targeted clean-room
  rewrite of exactly those** becomes a scoped work-package in v1.2 (or
  v1.2.1 if large). The audit *produces the work-package's contents.*

This is cheap (read-only agents, no Deck), it unblocks distribution
planning, and its result **determines whether a clean-room package exists
in this cycle at all** — so schedule it early-ish (M1, alongside the dark
plumbing; it needs no hardware and runs in parallel with HW-1 prep).

**(2) The two loose scope items already recorded in #33.**

- **Remove `token.enc` from the repo** — still present; engineering, land
  it this cycle (rides the private security hygiene).
- **Regenerate `accounts.json`** — **ALREADY DONE** via PR #96 (Player-name
  profile-id regeneration). Note complete; no further action.

**(3) The only decision left for Scott** — and only *after* the audit
clears the derivation question — is picking the actual license **text**
(MIT / GPL / etc.) for our own code. A small, well-informed final choice,
not a blocking investigation.

**The evsieve addition is orthogonal to all of the above.** We invoke
evsieve as a separate process (arm's-length exec, not linking) = mere
aggregation, so its GPL-2.0 does **not** pull MCSS under GPL. Our ~35-line
patch is a GPL-2.0 derivative, independently compliant as long as we
distribute it as *source* (build-at-install, PR1). It is a self-contained,
already-compliant license island. After PR1 the repo carries **mixed
licensing** (evsieve GPL-2.0 / the installer / our code) → it needs a
top-level **LICENSING note enumerating the islands** regardless of the
audit outcome — filed as paper now (Part 9).

---

## Part 7 — Non-goals (deferred, with reasons)

| Deferred | Reason |
|---|---|
| **#36 SNES button glyphs** | Cosmetic; wrong prompts, not wrong input. No interaction with the proxy path. |
| **#91 installer module merges** | Restructures the installer during the cycle that adds evsieve installer work (PR1) — churn risk next to a load-bearing addition. Defer to v1.2.1. |
| **#14 JVM D-state hang** | Intermittent, no reliable repro. Keep the `/proc/<pid>/{stack,wchan,status}` capture checklist handy — it can masquerade during PR4's evsieve-kill SLOT_DIED tests (see R4). Watch, don't chase. |
| **#15 nested-session teardown** | Accepted known-limitation from v1.1; v1.2 only *adds* to teardown surface (evsieve pids) — covered by the cleanup() backstop, not a reopen. |
| **#27 residual low-severity audit batch** | Opportunistic only; no v1.2 gate depends on it. |
| **`persist=full` session-start priming** (design §7) | Lazy-start `persist=reopen` is the on-Deck-validated config; priming buys nothing under lazy claim. Revisit only if D2 interacts badly with reopen. |
| **Full relaunch-on-reconnect (D2-alt) implementation** | Built **only if** the D2 CONFIRM fails at HW-1. Named and ready (Part 8 R1), not pre-built. |
| **Upstreaming the patch to KarsMulder/evsieve#66** | Tracked, **not blocking** — we build from our pinned fork+patch. Merge-and-track follow-up (Part 9). |

**Not deferred — closed.** #70 (per-instance render caps + right-sized
heaps) is **moot post-benchmark**: BENCH-AB showed the branch leads FPS at
3–4P, no OOM, and the "memory wall" that motivated #70 did not reproduce
under the v2 protocol. **Recommend close** with the BENCH-AB citation
rather than carry it.

---

## Part 8 — Risk table

| # | Risk | Mitigation |
|---|---|---|
| **R1** | **D2 is the load-bearing unknown.** If our built evsieve's `persist=reopen` caches the resolved node instead of re-resolving the repointed symlink, the entire seamless-reconnect story fails. Gates PR4–PR7. | **Schedule it first (HW-1, PR2/H5), flag-OFF and safe.** The try_open path follows symlinks on every open, so it *should* work — but unproven for our exact build. **D2-alt is the named fallback:** stop+restart evsieve on the new node → new virtual inode → live sandbox stranded → degrades to "reconnect requires slot relaunch" (correct, worse UX, = the relaunch-on-reconnect follow-up). A failed check has a defined answer, not a dead end. |
| **R2** | **Proxy hop overhead is unmeasured.** evsieve adds a userspace hop per input event, per slot. Probably negligible; must not be assumed. | 4P BENCH-AB A/B (proxy ON vs OFF) in M4, gated on the existing thresholds. Ship-blocking: no flip without the measurement. |
| **R3** | **evsieve is new teardown surface**, alongside v1.1's already-reconciled two teardown authorities (#15). A leaked evsieve holds a grabbed evdev. | `teardown_instance`→`proxy_stop_slot`; `cleanup()` stops every slot's proxy as a backstop (same discipline as the monitor kills). HW check: `pgrep evsieve` empty post-teardown (H7), run every hardware session. |
| **R4** | **evsieve-death SLOT_DIED can trigger or mask #14** (a D-state JVM surviving SIGKILL). | On any D-state during PR4's evsieve-kill tests, capture `/proc/<pid>/{stack,wchan,status}` immediately — D-state = #14, not a proxy regression. Keep the #14 checklist at HW-2/3. |
| **R5** | **uniq plumbing has wide blast radius** — an arity change across 5 `IFS` read sites; a missed one silently mis-parses the ADD contract. | Isolate in its own PR3; unit fixtures for two same-MAC DS4s and an empty-uniq pad; validate dark (log-grep, HW-1/H8) before any flag flip. |
| **R6** | **evsieve fork/patch maintenance**; upstream #66 pending review. | Pin upstream commit + patch, SHA-256-verify, build-at-install (never redistribute a binary). Track the merge as a non-blocking follow-up; if merged, drop to a version pin. |
| **R7** | **Sole hardware operator; on-Deck time is the bottleneck.** | Four batched sessions, dark work front-loaded, the single flag-on live session late and fully prepared. Redeploy-freshness check before every phase (`git pull` ≠ deployed). |
| **R8** | **#95 unfixed would corrupt the controller validation itself** — fresh instances come up input-dead. | Land #95 dark in M1, ahead of HW-2's in-game gate. |

---

## Part 9 — What lands immediately (paper is free)

Two things land the day this plan is written, regardless of any milestone
gate:

1. **Commit this plan** to `docs/` so every session works from one script.
2. **File the paper** (all non-security):
   - One tracking issue per PR1–PR7 under the #38 umbrella (or reuse the
     #38 issue with a PR checklist).
   - "`controller_proxy.sh` — new runtime module (spec = DESIGN-38 §4)."
   - "uniq plumbing: 8-field input-block parse + ADD-contract arity."
   - "v1.2 limitations doc (hidraw D5 / capability-differ D6 / clone-uniq)."
   - "**Top-level LICENSING note** enumerating the license islands"
     (evsieve GPL-2.0 / installer / our code) — needed regardless of the
     #33 audit outcome (Part 6).
   - **Re-scope #33** from "decision" to the three engineering items:
     derivation audit (M1), `token.enc` removal (M1), license-text pick
     (owner, after the audit). Mark the accounts.json regen **done (#96)**.
   - "deploy-freshness re-confirm before each HW session" (checklist item).

**Dispose PR #44 — recommend CLOSE.** It is a stale (2026-06-28) docs-only
note whose *specific* symptom — "the first-run instance transiently
mishandles input, in-game menu won't close" — is exactly **#95**, which
this cycle fixes. Merging a note that documents a bug we are about to
delete is wrong. Close #44; re-file its still-true residue ("the first run
downloads assets + initializes mods; be patient before play") as a
one-line README addition **bundled with the #95 fix in M1**, so the note
and the fix land together.

**Open one tracking issue (non-blocking):** "Upstream the bounded-retry
patch to KarsMulder/evsieve#66" — the bug is general (any BT evdev
consumer using `persist` hits the udev-ACL EACCES race); merging it shrinks
our maintenance surface. Explicitly does not block v1.2.

**Close #70** with the BENCH-AB-2026-07-18 citation (Part 7).

> **Addendum 2026-07-20 — #70 NOT closed; delivered instead.** The owner's
> 2026-07-18 comment superseded the close recommendation: rather than close on the
> moot memory angle, cap `maxFps` to display refresh (BENCH-AB measured 300–600fps
> per screen into a 60Hz panel at 92–94% CPU, 4P — capping converts discarded
> frames into thermal/CPU headroom). **Implemented on `claude/dynamic-maxfps-displays`:**
> a launch-time `mcss_detect_max_refresh` samples the host output mode's current
> refresh (kscreen-doctor/xrandr, host context before nesting — the nested XWayland
> reports a synthetic 60Hz), carries it across the re-exec, and `spawn_instance`
> rewrites each slot's `options.txt maxFps:` per launch. On by default
> (`MCSS_CAP_FPS_TO_REFRESH`); fallback 60, clamp [30,360]; overridable via
> `MCSS_MAX_REFRESH_HZ`. Steam's per-game Framerate Limit / Refresh Rate composes
> on top (we cap to whatever the host scans out). Per-slot-count render-cap variation
> (renderDistance/heaps) remains out of scope. On-Deck check needed to confirm the
> Game-Mode probe returns a real refresh (degrades safely to fallback otherwise).
