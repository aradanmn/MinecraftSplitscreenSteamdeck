# MinecraftSplitscreenSteamdeck — Canonical Plan & Roadmap

**This is the single source of truth for where the project stands and where it is
going.** It supersedes the per-campaign `PLAN-V1.x` docs (now archived — see
[Versioning](#versioning) and [Document map](#document-map)).

**Last updated:** 2026-08-01 (Sat) · **Repo:** `aradanmn/MinecraftSplitscreenSteamdeck`
· **Active cycle:** post-v1.2.3 — install-path polish, then the virtual pad rig

---

## Versioning

`PLAN.md` is **always the latest plan.** Before any substantive change to it:

1. Copy the current `PLAN.md` to `docs/PLAN-YYYYMMDD.md`, where `YYYYMMDD` is the
   date the *outgoing* version was last updated (the `Last updated` field above).
2. Then edit `PLAN.md` with the new plan and set a fresh `Last updated`.

This keeps one canonical doc plus an immutable dated trail. Prior campaign plans
live under `docs/PLAN-*.md`.

---

## Product in one paragraph

Splitscreen Minecraft for the Steam Deck: 1–4 players on one screen, each a separate
PolyMC instance rendered inside a nested Plasma/kwin session under gamescope, with
per-player controller isolation. Installer provisions the instances + mods + Steam
shortcut; a launcher/orchestrator spawns and tiles the instances at play time.

---

## The scheduling constraint (read this before planning anything)

**Operator time at a docked Deck is the scarce resource, not agent working time.**
Estimate the two separately and batch Deck work; agent work is cheap and
parallelisable, Deck sittings are not, and some carry reboot risk.

Three constraints that shape *how* Deck work can be done:

- **SSH rides the dock's USB ethernet** (`enp4s0f3u1u4c2`, .105; wlan0 is .104 but
  replies still route out the dock NIC). **Undocking severs the connection**, so any
  cross-undock capture must be a detached local logger read back after re-dock.
- **Nothing is visible in Game Mode.** gamescope presents Steam's UI and the focused
  game surface only; `kdialog`/`zenity` never appear. Measured across four attempts
  (#125).
- **A launch cannot be driven over SSH.** The runtime-context guard refuses a bare
  invocation, and Steam must not be manipulated remotely. Anything needing a live
  session needs the operator to press play.

---

## Status snapshot (2026-08-01)

| Release | State |
|---------|-------|
| **v1.0 → v1.1.1** | Shipped / closed. |
| **v1.2.0** | Shipped 2026-07-26 — #38 seamless reconnect, `MCSS_CONTROLLER_PROXY=1` default. |
| **v1.2.1** | Shipped 2026-07-29 — docs + test tooling only. |
| **v1.2.2** | Shipped 2026-07-31 — installer consolidation (#89, #91), validated through a real `curl\|bash` install. |
| **v1.2.3** | **Shipped 2026-08-01** — #167, #170, #172, #174, #98. Two silent data-loss bugs and a session wedge. |
| **v1.2.4** | Next. #122, #126, #36 — install-path polish. |
| **v1.3** | Virtual pad rig. **Unblocked** — all ten probe verdicts green on hardware. |
| **v1.4** | Docking + visibility. Blocked on a design question, not code. |

### The load-bearing open question

**Can we show the user anything at all in Game Mode?** #125 and #160 both depend on
it, and four measured attempts say no via any dialog — Wayland-native, host `:0`, and
forced XWayland all ran cleanly and were never visible. Until an experiment finds a
working channel, both are **un-fixable rather than merely unfixed**, and may end as
documented limitations.

### What v1.2.3 changed about how we work

Every bug in it was found by **validating the previous release on hardware**, not by
reading code. #167, #172 and #174 were invisible to CI, to unit tests, and to the
logs — two of them reported success while destroying user data. That is PRINCIPLES #3
restated with evidence.

---

## Milestone map (GitHub)

| Milestone | Open | Theme |
|-----------|------|-------|
| **v1.2.4** | #122, #126, #36 | Install-path polish + cosmetics |
| **v1.3** | #157, #136, #151, #71, #70 | Automated multi-player testing + the bugs only it can reproduce |
| **v1.4** | #125, #134, #135, #79, #160 | Docking end to end + "the user can see what happened" |
| **backlog** | #179, #15, #14 | Documented, not scheduled |

**#15 may be closable.** #174 fixed the orphaned-proxy wedge that plausibly caused
the Abort Game black screen it describes. Check after a few more sessions.

---

## v1.2.4 — install-path polish

| Chunk | Notes | Estimate |
|---|---|---|
| **#122** inventory `$HOME` writers, route to `.workdir/`, make uninstall one wipe | One offender already found and fixed (the uhid probe's results file) | agent 1.5–2h · **Deck 20 min** (destructive) |
| **#126a** decide how the binary is produced | Real design content: CI cross-build against a SteamOS-compatible glibc vs. build-on-Deck-and-upload | agent 1h |
| **#126b/c** release-asset plumbing + installer fetch with checksum and fallback | Must degrade cleanly to the existing build path (PRINCIPLES #5) | agent 2.5h |
| **#126d** validate fetch path **and** forced-fallback path | | **Deck 30 min** |
| **#36** Controlify SNES glyphs | Investigation-first; likely bounded by upstream Controlify behaviour against our virtual device-id | agent 1–2h · **Deck 20 min** |

**Total: agent ~6h · Deck ~1h.**

---

## v1.3 — the virtual pad rig

**Unblocked.** The udev rule is installed (`60-mcss-uhid.rules` — the `60-` prefix is
load-bearing, since `uaccess` is consumed at 70/73) and PR-0 returned all ten
verdicts green on hardware: `uniq` reaches the input device, two pads each keep their
own sysfs parent, and Steam mints a `28de` virtual exactly as for a real pad.

**PR-0b is NOT needed** — V7 came back `BOTH`, so step-6 dedup does not collapse uhid
pads and no production code change is required.

| Chunk | Estimate |
|---|---|
| **PR-1** pad primitive hardened + CI tests | agent 2h · Deck 15 min |
| **PR-2** rig control surface (create/destroy/inject/cleanup, PID-tracked) | agent 2h · Deck 20 min |
| **PR-3** automate `stage3_hotplug` behind `MCSS_VIRTUAL_PADS` (human mode stays default) | agent 3h · **Deck 40 min** |
| **PR-4** #71 burst-spawn repro + fix | agent 2h · Deck 30 min |
| **PR-5** #151 repro + quiesce-then-repoint fix | agent 3h · **Deck 45 min** |
| **#70** benchmark pilot | agent 4h+ · **Deck 3h+** |

**Total: agent ~16h · Deck ~6h.** #70 alone is a third of it.

**One gap from PR-0:** V8 returned `SAME_NODE`, not `RENUMBERED` — destroy+recreate
reused the same `eventN`, so the renumber case (#112's mechanism, and what #151 is
about) is still untested. Forcing it needs the 3-pad trick; that is PR-5's job.

**#70's blocking decision:** open-loop timed input is *self-damping under load* — a
slower configuration flies less far, generates fewer chunks, and incurs less load,
flattening the very A/B difference being measured. Decide before the campaign, not
during. See `RESEARCH-136-VIRTUAL-PAD-RIG.md` §5.

---

## v1.4 — docking + visibility (the riskiest milestone)

**#125 and #160 share one root cause and should be worked as a single design
question, not two bugs.**

| Chunk | Steps | Estimate |
|---|---|---|
| **D1 — "is there ANY visible channel in Game Mode?"** | Try, in order: a fullscreen window through the `window_manager`/`kwin_positioner` path (the only path proven to put pixels on the external display); a client on `:1` *during* a launch; dismissing ksplash via `qdbus`. Answer empirically before writing any fix | agent 1.5h · **Deck 45–60 min** |
| **D2 — implement the winner** for #125 and #160 | One channel, two callers. `mcss_notify_user` (preflight.sh) is already the single encoding to swap out | agent 2h · **Deck 20 min** |
| **#134 + #79** dock-transition pair | Same machinery — work together. Capture must be detached loggers (see the SSH/dock constraint) | agent 2–3h · **Deck 45 min** |
| **#135** teardown wedge | Highest risk in the plan. Needs a written protocol and a recovery plan **before** the first attempt. Schedule alone, fresh | agent 2h · **Deck 60 min+, reboot risk** |

**Total: agent ~8h · Deck ~3h**, widest error bars in the plan.

---

## Suggested sequencing

1. **v1.2.4** — low risk, ~1h of Deck time, and #126 removes the multi-minute
   container build from every fresh install.
2. **v1.3 through PR-3** — the rig starts paying back Deck time the moment
   `stage3_hotplug` automates.
3. **v1.4 last.**

The milestones were renumbered on 2026-07-31 so version order matches build order —
releases ship in version order, so whichever track goes first *is* v1.3. The dock
track goes last because it is the riskiest work, needs the most Deck time, and #135
can cost a reboot per attempt. The rig does not help with any of it.

---

## Risks (live)

| ID | Risk | Status |
|----|------|--------|
| **R6** | No visible user-message channel exists in Game Mode at all. | **Materialized for dialogs** (#125, four measured attempts). D1 decides whether the `window_manager` path works. If not, #125/#160 become documented limitations. |
| **R8** | #135 reproduction costs a force reboot per attempt. | Unmitigated. Budget one Deck sitting per attempt. |
| **R9** | The `/dev/uhid` udev rule may not survive a SteamOS update. | Treat as re-installable; the probe detects it and prints the fix. |
| **R10** | Validation gaps carried into a shipped release. | #170's `ref:` fallback and `kwin_place_windows` under `-e` are both unproven on hardware — recorded in the v1.2.3 notes rather than implied away. |
| **R4** | evsieve-death `SLOT_DIED` can trigger or mask **#14** (D-state JVM). | Carried forward — capture `/proc/<pid>/{stack,wchan,status}` on any D-state seen during rig work. |
| ~~R1 / R5~~ | evsieve reopen behaviour; uniq plumbing arity. | Retired with v1.2.0. |
| ~~R7~~ | `INSTALLER_MODULE_FILES` drift invisible to every test. | Retired — v1.2.2 was validated through a real `curl\|bash` install, the only mode that exercises the download list. |

---

## Deck state (2026-08-01)

- Minecraft **26.2** — moved off the 26.1.2 home-server pin during the #167 test.
  **Move it back before playing on the home server.**
- Pre-wipe backups (world, accounts, four `options.txt`) in
  `.workdir/preinstall-backup-20260731-175532/`.
- `60-mcss-uhid.rules` installed; `/dev/uhid` carries `user:deck:rw-`.

---

## Document map

- **Design / law:** `PRINCIPLES.md` (why), `ARCHITECTURE.md` (where code goes),
  `STYLE-GUIDE.md` (how it looks), `SPEC.md`,
  `DESIGN-38-RECONNECT-WIRING.md`, `RESEARCH-136-VIRTUAL-PAD-RIG.md`.
- **Records:** `HW1-VALIDATION-2026-07-19.md`, `HW2-VALIDATION-2026-07-22.md`,
  `VERIFY-70-MAXFPS.md`, `BENCH-AB-2026-07-18.md`,
  `AUDIT-ARCHITECTURE-2026-07-17.md`, `AUDIT-98-STYLE-GAPS.md`,
  `DERIVATION-AUDIT-2026-07-22.md`, the `BUG-AUDIT-*` and `RESEARCH-*` docs.
- **Running history:** `MEMORY.md`, `TODO.md`.
- **Archived plans:** `PLAN-20260705.md` (v1.1), `PLAN-20260718.md` (v1.2 kickoff),
  `PLAN-20260720.md` (v1.2 mid-campaign), `PLAN-20260731.md` (pre-v1.2.3).
