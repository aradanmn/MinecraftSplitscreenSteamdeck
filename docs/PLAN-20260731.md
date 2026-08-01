# MinecraftSplitscreenSteamdeck — Canonical Plan & Roadmap

**This is the single source of truth for where the project stands and where it is
going.** It supersedes the per-campaign `PLAN-V1.x` docs (now archived — see
[Versioning](#versioning) and [Document map](#document-map)).

**Last updated:** 2026-07-31 (Fri) · **Repo:** `aradanmn/MinecraftSplitscreenSteamdeck`
· **Active cycle:** post-v1.2.1 — installer consolidation, then the virtual pad rig

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
Every estimate below is split accordingly. Agent work is cheap and parallelisable;
Deck sittings are not, and some of them carry reboot risk.

Two constraints that shape *how* Deck work can be done:

- **SSH rides the dock's USB ethernet** (`enp4s0f3u1u4c2`, .105; wlan0 is .104 but
  replies still route out the dock NIC). **Undocking severs the connection**, so any
  cross-undock capture must be a detached local logger read back after re-dock —
  never a live SSH session.
- **Nothing is visible in Game Mode.** gamescope presents Steam's UI and the focused
  game surface only; `kdialog`/`zenity` never appear. Inside the nested session a
  message is additionally covered by Plasma's startup splash during a launch-abort.
  Measured 2026-07-29 across four attempts — see #125.

---

## Status snapshot (2026-07-31)

| Release | State |
|---------|-------|
| **v1.0 / v1.0.1 / v1.1 / v1.1.1** | Shipped / closed. |
| **v1.2.0** | **Shipped 2026-07-26** — #38 seamless reconnect, `MCSS_CONTROLLER_PROXY=1` default. |
| **v1.2.1** | **Shipped 2026-07-29** — docs + test tooling only, no runtime change. |
| **v1.2.2** | **Code complete, unmerged.** 4-PR stack (#162, #163, #164, #165) awaiting one install run. |
| **v1.2.3 / v1.2.4** | Scoped, not started. |
| **v1.3** | Virtual pad rig + the bugs it unlocks. Blocked on one 10-minute root step. |
| **v1.4** | Docking + visibility — the riskiest. Not started. |

### The load-bearing open question

**Can we show the user anything at all in Game Mode?** #125 and #160 both depend on
it, and four measured attempts say no via any dialog. Until an experiment
(**D1** below) finds a working channel, both issues are un-fixable rather than
merely unfixed. This replaces D2/#112 as the project's central unknown — that one
closed with v1.2.0.

---

## Milestone map (GitHub)

| Milestone | Open | Theme |
|-----------|------|-------|
| **v1.2.2** | #89, #91 | Installer consolidation — behaviour-neutral |
| **v1.2.3** | #98, #122 | Code hygiene, on what survives v1.2.2 |
| **v1.2.4** | #126, #36 | Install-path polish + cosmetics |
| **v1.3** | #136, #157, #151, #71, #70 | Automated multi-player testing + the bugs only it can reproduce |
| **v1.4** | #125, #134, #135, #79, #160 | Docking end to end + "the user can see what happened" |
| **backlog** | #15, #14 | Documented, not scheduled |

---

## Do this first: the 90-minute unblocking sitting

Three short, independent Deck steps that between them ship one milestone and open
another. **Nothing else should consume a Deck sitting until these are done.**

| Step | Deck | Unblocks |
|---|---|---|
| `REPO_REF=refactor/91-pr-c` install run | ~25 min | v1.2.2 ships |
| Install the uhid udev rule (one-time, root) | ~10 min | all of v1.3 |
| Re-run `tests/probe-uhid-feasibility.sh` → V2–V9 | ~15 min | rig design confirmed, or PR-0b needed |

---

## v1.2.2 — installer consolidation (code complete)

Four stacked PRs, all CI green, none merged:

```
#162  #89 stamp helper                       -> main
#163  #91 PR-a  lwjgl -> version_management  -> #162
#164  #91 PR-b  steam+desktop -> system_integration
#165  #91 PR-c  launcher_setup split (+runtime_deploy.sh)
```

| | |
|---|---|
| **Tools** | `ssh steamdeck`, installer with `REPO_REF`, `gh pr merge`, `gh release create` |
| **Steps** | checkout `refactor/91-pr-c` on Deck → `REPO_REF=refactor/91-pr-c ./install-minecraft-splitscreen.sh` (update mode) → verify stamp, deployed modules, launcher runs → merge #162→#165 in order → tag v1.2.2 |
| **Estimate** | agent 20 min · **Deck 25–35 min** |

**Why `REPO_REF` and not a checkout install:** it is the only mode that exercises
`INSTALLER_MODULE_FILES`, the module *download* list. That list was edited three
times across the stack (+`version_stamp.sh`, +`runtime_deploy.sh`,
+`system_integration.sh`, −3 removed). A missing entry there is invisible to every
test in the repo *and* to a checkout install — it only breaks for a real
`curl|bash` user.

**If it fails:** the four commits are separately bisectable; `git bisect` costs at
most two extra runs, and only in the failure case.

---

## v1.2.3 — code hygiene (must follow v1.2.2)

Ordering is not arbitrary: the 2026-07-17 audit says do the installer merges
*before* the style retrofit, so we do not retrofit files that v1.2.2 deletes or
folds away.

| Chunk | Tools | Estimate |
|---|---|---|
| **#98a** audit what is actually non-conforming (strict mode, `print_*` streams, `[dex]` prefix) — deliverable is a per-module list, not edits | `shellcheck -S warning`, grep | agent 1h |
| **#98b** apply in 3–4 module batches, one commit each, suites after each | Edit, test suites | agent 2h |
| **#98c** smoke: no runtime regression | `deploy.sh`, one launch | agent 15 min · **Deck 20 min** |
| **#122** inventory `$HOME` writers, route to `.workdir/`, make uninstall one wipe | grep, uninstaller | agent 1.5–2h · **Deck 20 min** (destructive) |

**Total: agent ~5h · Deck ~40 min.** Low risk, mostly unattended.

---

## v1.2.4 — install-path polish

| Chunk | Notes | Estimate |
|---|---|---|
| **#126a** decide how the binary is produced | Real design content: CI cross-build against a SteamOS-compatible glibc vs. build-on-Deck-and-upload. Decide before writing code | agent 1h |
| **#126b** release-asset plumbing in `release.yml` | | agent 1h |
| **#126c** installer fetch + checksum + fallback | Must degrade cleanly to the existing build path (PRINCIPLES #5) | agent 1.5h |
| **#126d** validate fetch path **and** forced-fallback path | | agent 15 min · **Deck 30 min** |
| **#36** Controlify SNES glyphs | Investigation-first; bounded by upstream Controlify behaviour against our virtual device-id. Real chance the answer is "upstream, won't fix" | agent 1–2h · **Deck 20 min** |

**Total: agent ~5h · Deck ~50 min.**

---

## v1.3 — the virtual pad rig

Gated on the udev rule. Build ladder is specified in #157.

| Chunk | Estimate |
|---|---|
| **PR-0b** step-6 dedup fix — **only if V7 returns COLLAPSED** | agent 1h · Deck 10 min |
| **PR-1** pad primitive hardened + CI tests | agent 2h · Deck 15 min |
| **PR-2** rig control surface (create/destroy/inject/cleanup, PID-tracked) | agent 2h · Deck 20 min |
| **PR-3** automate `stage3_hotplug` behind `MCSS_VIRTUAL_PADS` (human mode stays default) | agent 3h · **Deck 40 min** |
| **PR-4** #71 burst-spawn repro + fix | agent 2h · Deck 30 min |
| **PR-5** #151 repro + quiesce-then-repoint fix | agent 3h · **Deck 45 min** |
| **#70** benchmark pilot | Blocked on the methodology decision below | agent 4h+ · **Deck 3h+** |

**Total: agent ~17h · Deck ~6h.** #70 alone is a third of it.

**#70's blocking decision:** open-loop timed input is *self-damping under load* — a
slower configuration flies less far, generates fewer chunks, and incurs less load,
flattening the very A/B difference being measured. Recommendation on the table is
distance-as-covariate plus log-gated phase transitions for the first campaign.
Decide before the campaign, not during. See `RESEARCH-136-VIRTUAL-PAD-RIG.md` §5.

---

## v1.4 — docking + visibility (the riskiest milestone)

**#125 and #160 share one root cause and should be worked as a single design
question, not two bugs.**

| Chunk | Steps | Estimate |
|---|---|---|
| **D1 — "is there ANY visible channel in Game Mode?"** | Build a probe that tries, in order: a fullscreen window through the `window_manager`/`kwin_positioner` path (the only path proven to put pixels on the external display); a client on `:1` *during* a launch (untested condition — the earlier `:1` test ran while the library was showing); dismissing ksplash via `qdbus org.kde.KSplash /KSplash setStage`. Answer empirically before writing any fix | agent 1.5h · **Deck 45–60 min** |
| **D2 — implement the winner** for #125 and #160 | One channel, two callers. `mcss_notify_user` (preflight.sh) is already the single encoding to swap out | agent 2h · **Deck 20 min** |
| **#134 + #79** dock-transition pair | Same transition machinery — work together. Capture must be detached loggers (see the SSH/dock constraint above) | agent 2–3h · **Deck 45 min** |
| **#135** teardown wedge | Highest risk in the plan: reproducing it means deliberately provoking a no-display state that has needed a force reboot. Needs a written protocol and a recovery plan **before** the first attempt. Schedule alone, fresh | agent 2h · **Deck 60 min+, reboot risk** |

**Total: agent ~8h · Deck ~3h**, widest error bars in the plan.

---

## Suggested sequencing

1. **The 90-minute unblocking sitting.** Ships v1.2.2, opens v1.3.
2. **v1.2.3 + v1.2.4** — ~10h agent, under 2h Deck, low risk. Good background work
   between Deck sessions.
3. **v1.3 through PR-3** — the rig starts paying back Deck time the moment
   `stage3_hotplug` automates.
4. **v1.4 last.**

**The milestones were renumbered on 2026-07-31 to match this order** (the rig track
and the dock track swapped places). That is bookkeeping, not preference: releases
ship in version order, so whichever track goes first *is* v1.3. Leaving the old
labels would have meant either shipping out of order or blocking the rig behind the
dock work, contradicting the plan.

The dock track goes last because it is the riskiest work, needs the most Deck time,
and #135 can cost a reboot per attempt. The rig does not help with any of it, so
there is no tooling benefit to ordering it first — only risk.

---

## Risks (live)

| ID | Risk | Status |
|----|------|--------|
| **R6** | No visible user-message channel exists in Game Mode at all. | **Materialized for dialogs** (#125, four measured attempts). D1 decides whether the `window_manager` path works. If it does not, #125/#160 become "documented limitation", not "fixed". |
| **R7** | `INSTALLER_MODULE_FILES` drift — a module added/removed without updating the download list. | Invisible to all tests and to checkout installs. Mitigated only by running the v1.2.2 validation as `REPO_REF`, not a checkout install. |
| **R8** | #135 reproduction costs a force reboot each attempt. | Unmitigated. Needs a protocol before the first attempt; budget one Deck sitting per attempt. |
| **R9** | `/dev/uhid` udev rule may not survive a SteamOS update. | Treat as re-installable; the probe detects and prints the fix. |
| **R4** | evsieve-death `SLOT_DIED` can trigger or mask **#14** (D-state JVM). | Carried forward — capture `/proc/<pid>/{stack,wchan,status}` on any D-state seen during rig work. |

---

## Document map

- **Design / law:** `PRINCIPLES.md` (why), `ARCHITECTURE.md` (where code goes),
  `STYLE-GUIDE.md` (how it looks), `SPEC.md`,
  `DESIGN-38-RECONNECT-WIRING.md`, `RESEARCH-136-VIRTUAL-PAD-RIG.md`.
- **Records:** `HW1-VALIDATION-2026-07-19.md`, `HW2-VALIDATION-2026-07-22.md`,
  `VERIFY-70-MAXFPS.md`, `BENCH-AB-2026-07-18.md`,
  `AUDIT-ARCHITECTURE-2026-07-17.md`, `DERIVATION-AUDIT-2026-07-22.md`,
  the `BUG-AUDIT-*` and `RESEARCH-*` docs.
- **Running history:** `MEMORY.md`, `TODO.md`.
- **Archived plans:** `PLAN-20260705.md` (v1.1), `PLAN-20260718.md` (v1.2 kickoff),
  `PLAN-20260720.md` (v1.2 mid-campaign).
