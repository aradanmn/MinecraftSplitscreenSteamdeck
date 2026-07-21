# MinecraftSplitscreenSteamdeck — Canonical Plan & Roadmap

**This is the single source of truth for where the project stands and where it is
going.** It supersedes the per-campaign `PLAN-V1.x` docs (now archived — see
[Versioning](#versioning) and [Document map](#document-map)).

**Last updated:** 2026-07-20 (Mon) · **Repo:** `aradanmn/MinecraftSplitscreenSteamdeck`
· **Active cycle:** v1.2 — controller identity + consolidation

---

## Versioning

`PLAN.md` is **always the latest plan.** Before any substantive change to it:

1. Copy the current `PLAN.md` to `docs/PLAN-YYYYMMDD.md`, where `YYYYMMDD` is the
   date the *outgoing* version was last updated (the `Last updated` field above).
2. Then edit `PLAN.md` with the new plan and set a fresh `Last updated`.

This keeps one canonical doc plus an immutable dated trail. Prior campaign plans
predate this scheme and are archived under the same naming:
`PLAN-20260705.md` (v1.1 campaign), `PLAN-20260718.md` (v1.2 campaign kickoff).

---

## Product in one paragraph

Splitscreen Minecraft for the Steam Deck: 1–4 players on one screen, each a separate
PolyMC instance rendered inside a nested Plasma/kwin session under gamescope, with
per-player controller isolation. Installer provisions the instances + mods + Steam
shortcut; a launcher/orchestrator spawns and tiles the instances at play time.

---

## Status snapshot (2026-07-20)

| Release | State |
|---------|-------|
| **v1.0 / v1.0.1** | Shipped. |
| **v1.1** | Shipped — raw-device controller binding (`MCSS_RAW_BINDING=1` default), consolidation D-sweeps. One open watch item: **#14** (intermittent JVM D-state hang — watch, don't chase). |
| **v1.1.1** | Closed — validation-debt campaign (15 issues). |
| **v1.2** | **In progress. M0 + M1 done** (see below); M2–M4 remaining. |
| **v1.2.1** | Patch bucket (no code restructuring): **#91** installer merges, **#114** MC-26.1.2 glfw regression. |

### v1.2 progress
- **M0 — Foundations & acquisition: DONE.** evsieve build-at-install (GPL source
  island), harness/geometry groundwork. Merged.
- **M1 — Symlink-repoint gate + dark modules: DONE.** PR2 (`controller_proxy.sh`
  symlink farm + lifecycle, **dark** — `MCSS_CONTROLLER_PROXY=0` until PR7), PR3
  (uniq plumbing: `parse_input_device_blocks` field 8 + read-arity updates). Merged.
  **HW-1 ran 2026-07-19** (full stage0–5 green, proxy-off = v1.1 behaviour unchanged).
- **#70 maxFps → live display refresh: DONE + validated** (PR #113). Round-fix for
  gamescope's under-nominal refresh; on-Deck both modes (handheld `T:90` / docked
  `T:60`, F3-confirmed; 4-up capped 60, aggregate CPU ~42% vs uncapped 92–94%). The
  xrandr-under-gamescope probe was ruled sufficient — no DRM fallback. See
  `VERIFY-70-MAXFPS.md`. The render-cap/heap remainder of #70 stays in M4.

### The load-bearing open question — D2 (#112)
HW-1's D2 CONFIRM test **failed (H5=FAIL)**: the EACCES-race patch rode through
(first hardware validation of it — good), but the BT DS4 re-enumerated with
*different capabilities*, `persist=reopen` grabbed a partially-initialized device,
and **evsieve exited silently ~2 min later**. This is Risk **R1** materializing. It
gates M2/M3 and drives two mandates: **(a)** PR4 must add watchdog supervision of
`evsieve_pid`; **(b)** the fallback **D2-alt** (reconnect-requires-slot-relaunch)
is the named answer if capability-differ reopen can't be made robust. **#112 is the
highest-priority open item — not filler.**

---

## Milestone map (GitHub)

| Milestone | Open | Contents |
|-----------|------|----------|
| **v1.2 — controller identity + consolidation** | 20 | #38 arc + carry-over + HW-1 debt (table below) |
| **v1.2.1** | 2 | #91 (installer merges), #114 (glfw regression — *pending confirmation it's real*) |
| **backlog** | 2 | #98 (M4 style-retrofit gaps), #36 (Controlify SNES glyphs — cosmetic) |
| **v1.1** | 1 | #14 (JVM D-state — watch) |
| **v1.1.1 — validation debt** | 0 | Closed (historical, 15 issues) |

*(Deleted empty milestones `v2` and `v1.0.1` on 2026-07-20.)*

---

## v1.2 remaining roadmap

GitHub has one coarse `v1.2` milestone; the plan sequences it in phases. **M0/M1 are
done** — everything below is what's left.

### Pre-HW-2 (must land before the next Deck session)
Carry-over filler that slipped M0/M1, plus test debt HW-1 surfaced. These gate a
*trustworthy* HW-2, because several are broken **test harnesses**:

| Issue | What |
|-------|------|
| #83 | HW harness resolves the **outer** gamescope Xwayland — every geometry assert compares the wrong screen. |
| #84 | stage3 asserts pre-#37 teardown-on-disconnect (contradicts its own persist check). |
| #80 | `test_orchestrator.sh` inert (launcher exec-redirects test output into the debug log). |
| #103 | Rewrite `test_orchestrator` against the modular layout + kill-scope the suite. |
| #105 | `test_controller_monitor` T2.5/2.7/2.9/2.11 stale vs the `MCSS_RAW_BINDING=1` default flip. |
| #111 | HW stage4 I4.1 stale — counts `/dev/input` fds on bwrap; raw-binding binds js only. |
| #89 | `runtime_modules.list` parsed 4× — fold into the next edit of that list. |

### M2 — Bind-swap + flag flip (gated)
**PR4:** spawn binds the **virtual** jsN under `MCSS_CONTROLLER_PROXY=1`; sticky-slot
rejoin branch; **watchdog gains the dead-`evsieve_pid` check (mandatory, per #112)**;
state schema `phys_uniq` + `evsieve_pid`. Flag-gated, default still OFF.
**HW-2** (flag ON, 1 DS4 docked): H10 sandbox sees only the virtual jsN; H11
battery-death→reconnect resumes seamlessly, same slot; H12 kill evsieve → clean
SLOT_DIED, no D-state hang.
Also here: resolve **#112** (evsieve source read + capability-differ patch, or commit
to D2-alt).

### M3 — Bug-family acceptance
**PR5:** #62 (sandbox input-node leakage / re-enumeration). **PR6:** #79
(docked→handheld leaves the survivor bound to the external pad — repoint slot 1 to
the built-in evdev on transition). Flag ON. **HW-3** batches with HW-2 if PR4/5/6 are
all ready. *(#61 sticky-slot already closed in M1.)*

### M4 — Hardening, perf-gate, ship
**PR7:** flip `MCSS_CONTROLLER_PROXY=1` default (keep flag as escape hatch); write
limitations doc (D5 hidraw / D6 capability-differ / clone-uniq). **4P BENCH-AB**
(proxy ON vs OFF). **Hardening filler:** #71 (burst-spawn reflow race) + #17
(reflow-retry flag), #21/#22 opportunistically, #70 render-cap/heap remainder.
**HW-4:** 4P bench within the BENCH-AB gates; tag `v1.2.0`.

### Parallel / off-Deck
- **#33** — license derivation audit (read-only fan-out vs the FlyingEwok repo,
  adversarially judged). **Scheduled Thu 2026-07-23** (usage-budget pacing). Decides
  clean-license vs clean-room package. `v1-blocker` for distribution.
- **#27** — low-severity audit batch; **#15** — D6 nested-teardown known limitation;
  **#60** — supervised-reap / cross-kill hardening.

---

## Risks (live)

| ID | Risk | Status |
|----|------|--------|
| **R1** | evsieve `persist=reopen` behaviour on a repointed symlink / capability-differ reconnect. | **Partially materialized (#112):** reopen works but a partially-initialized BT device kills evsieve. Mitigation: mandatory watchdog (PR4) + D2-alt fallback. |
| **R4** | evsieve-death SLOT_DIED can trigger or mask **#14** (D-state JVM). | Capture `/proc/<pid>/{stack,wchan,status}` on any D-state during PR4 evsieve-kill tests. |
| **R5** | uniq plumbing arity change spans 5 read sites. | Contained in PR3, dark-validated in HW-1 (H8). |

---

## Document map

- **Design:** `DESIGN-38-CONTROLLER-VIRTUALIZATION-V1_2.md` (the #38 centerpiece),
  `RAW-CONTROLLER-BIND-PLAN.md` (v1.1 raw-bind), `ARCHITECTURE.md` (placement law),
  `SPEC.md`, `STYLE-GUIDE.md`.
- **Records:** `HW1-VALIDATION-2026-07-19.md`, `VERIFY-70-MAXFPS.md`,
  `BENCH-AB-2026-07-18.md`, `AUDIT-ARCHITECTURE-2026-07-17.md`, the `BUG-AUDIT-*` and
  `RESEARCH-*` docs, `CODE-REVIEW-2026-07-21-CLOSED.md`.
- **Running history:** `MEMORY.md` (change log), `TODO.md` (outstanding work),
  `sessions/SESSION-*.md` (daily narrative).
- **Archived plans:** `PLAN-20260705.md` (v1.1), `PLAN-20260718.md` (v1.2 kickoff).
