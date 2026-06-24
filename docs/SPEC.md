# Minecraft Splitscreen — Project Spec (DRAFT)

> **Status: DRAFT, in progress.** Being filled in decision-by-decision with the maintainer.
> Open questions are marked `❓DECISION`. Nothing here is final until that marker is gone.
> This doc is the source of truth for *what we're building* and *what "done" means*; the
> branch is measured against it. Location is movable (root vs docs/).

## 1. Product (one paragraph)

A one-command installer + Game-Mode launcher that turns a Steam Deck (and possibly other
KDE-based Linux handhelds/desktops) into a **1–4 player local splitscreen Minecraft** setup:
each player uses their own controller, each gets their own Minecraft instance, and the
instances are auto-tiled on one screen (full / half / quad) that re-flows as players join
and leave. Launched like any Steam game; exits cleanly back to Steam.

## 1a. Project identity & lineage

Its **own project**, descended from [FlyingEwok](https://github.com/FlyingEwok) (itself
inspired by [ArnoldSmith86/minecraft-splitscreen](https://github.com/ArnoldSmith86/minecraft-splitscreen)).
NOT a live fork: no upstream remote, no shared git history (repo starts at its own first
commit), and the entire splitscreen **runtime** (~13.7k lines: orchestrator, dex, windowing,
controllers, lifecycle) is net-new — only the **installer** half carries FlyingEwok lineage,
heavily rewritten. → Credit origins in README; treat as an independent product, not something
to reconcile with upstream.

❗ **LICENSE GAP (pre-release blocker):** the repo currently has **no LICENSE file**. Before
release: determine FlyingEwok's / ArnoldSmith86's license (obligations on inherited installer
code) and add a license for this project. Shipping with no license is a real liability.

## 2. Supported platforms

**DECISION-1 = Steam Deck / SteamOS (Game Mode) only for v1.** ✅ resolved.
Rationale: one compositor stack + one controller model (Steam Input `28de:11ff` virtual pads,
which only exist inside Steam/gamescope). Bazzite / CachyOS+KDE deferred to a later version —
they're a *second controller-enumeration design*, not just "more test machines."
> ⚠️ README currently over-claims Bazzite/CachyOS as supported — must be walked back to
> "Deck-first; others untested/experimental" to match this decision (honesty + DECISION-1).

## 3. End deliverables & acceptance criteria (v1)

**DECISION-2 = v1 is the core docked couch-co-op loop.** ✅ resolved.
Acceptance = **demonstrated on the Deck, maintainer-confirmed** — not "fixed in code."
Acceptance criteria below are DRAFT (next decision round).

| # | Capability | Acceptance criterion (draft) | Status |
|---|---|---|---|
| 1 | Install / update | fresh install + idempotent update (saves/options preserved) complete on a clean Deck | code exists, unverified |
| 2 | Launch | Steam shortcut → nested KWin → instances, no manual steps | partially seen |
| 3 | Windowing | tile by count, borderless, scale on join/leave | ✅ validated on screen |
| 4 | Controllers | per-player isolation; built-in pad excluded when docked; hotplug join/leave; already-connected detected at start | code only, unverified |
| 5 | Lifecycle (docked) | start on ≥1 pad; clean exit to Steam when all players quit | code only, unverified |
| 6 | Robustness | clean teardown (no orphans / Abort-Game); no OOM at 4 players; watchdog reaps dead slots | code only, unverified |
| 7 | LICENSE | a license file present + upstream obligations satisfied | ❗ missing (pre-release blocker) |

## 3a. Definition of Done (v1) — on-Deck acceptance tests

Each test is **run on a Deck, maintainer-confirmed**. 👁 = needs your eyes on screen;
🔧 = can be a process/log check. DRAFT — cut/tighten freely.

**D1 — Install / update** 🔧
- [ ] Fresh install on a clean machine completes with no manual steps → 4 instances
      (`latestUpdate-1..4`) + PolyMC + Java + Fabric + Controlify + Steam shortcut.
- [ ] Re-run on an existing setup (update) **preserves each instance's saves + options.txt**,
      updates mods to the target MC version, and does NOT duplicate instances.
- [ ] preflight hard-stops with a clear message when a required dep is missing.

**D2 — Launch** 👁
- [ ] Tapping the Steam shortcut in Game Mode goes library → nested KWin → instance(s) with
      no desktop drop, no terminal, no manual step.
- [ ] **(infra) Installer pulls the runtime modules from the right source.** Today
      `install_runtime_modules()` downloads them from GitHub **`main`**, but the runtime
      only exists on this branch → a fresh from-GitHub install currently 404s on all 9
      runtime modules. Fixes itself once this branch becomes the trunk; until then the
      install path is broken. ← **priority: this breaks real installs.**
- [ ] **(infra) Dev deploy script** (`deploy.sh`: pull + cp into `~/.local/share/PolyMC/`)
      so committed code reliably becomes running code — no more validating stale copies
      (bit us twice on 2026-06-24). Smaller piece, dev-loop only.

**D3 — Windowing** 👁  *(core already seen; re-confirm after N9)*
- [ ] 1 pad → fullscreen, **borderless** (no titlebar). 2 → halves. 3–4 → quad. Each covers
      its cell; no panel/desktop showing.
- [ ] Quit/disconnect one → survivors reflow to the correct layout (quad→half→full) within
      a few seconds.
- [ ] Borderless still correct after the `c_long` (N9) fix.

**D4 — Controllers** 👁
- [ ] N pads connected at launch → exactly N instances (no missing, no phantom/double-spawn).
- [ ] Pad connected mid-session → new player joins; disconnect → that player leaves + reflow.
- [ ] Built-in Deck pad does NOT spawn its own instance when docked.
- [ ] **Each pad drives only its own instance** (isolation) — input on pad A doesn't move
      player B. *(the hard one; may slip to v1.1 per DECISION-3 if it can't be made solid.)*

**D5 — Lifecycle (docked)** 👁🔧
- [ ] Launch with ≥1 external pad → session starts.
- [ ] Launch with zero external pads → exits to Steam within ~5s (no hang).
- [ ] All players quit (in-game or unplug) → returns to the Steam library **unaided** (no
      manual reap).

**D6 — Robustness** 🔧
- [ ] After a normal exit: no orphaned `kwin_wayland`/`java`/`bwrap`/plasma-helper processes;
      gamescope/Steam healthy; no Abort-Game overlay.
- [ ] 4 instances run concurrently without OOM (RAM within budget; 4×3072 cap holds).
- [ ] An instance killed unexpectedly (not a graceful quit) is reaped + reflowed by the
      watchdog / `_reap_dead_slots`.
- [ ] A failed spawn frees its slot (N1) — no permanently-dead seat.

**D7 — LICENSE / README** (gates *distribution*, not personal use)
- [ ] LICENSE present + FlyingEwok obligation resolved (DECISION-4 path A or B).
- [ ] README rewritten: personal-use, requires owning Minecraft, Deck-only (others
      experimental), accurate description of how it works.

## 4. Non-goals for v1 (explicitly deferred)

- **Handheld mode + live dock/undock switching.** Splitscreen is a docked feature: dock
  first, then launch. Undocking mid-session is unsupported in v1.
- **Suspend/resume resilience.** If it breaks on wake, relaunch. (SteamOS hooks exist but
  aren't a v1 acceptance gate.)
- **Bazzite / CachyOS+KDE / non-Deck platforms** (DECISION-1).
- **Full symmetric controller isolation** (earlier-joined slots can't retroactively mask a
  later joiner — bwrap mounts are fixed at launch). v1 accepts "strongest for most-recent
  joiner"; full symmetry would need re-spawning earlier slots.

## 5. Decisions

- ✅ DECISION-1: platforms — Deck/SteamOS Game Mode only (v1).
- ✅ DECISION-2: MVP line — core docked loop (§3); handheld/dock-switch/suspend deferred (§4).
- ✅ DECISION-5/6: **Distribution = personal use; users are expected to own Minecraft.**
  Offline P1–P4 accounts are a convenience for local splitscreen *seats* on an owned copy —
  honor-system (the tool does NOT verify ownership). Defensible for personal use among
  owners; do NOT market it as "play without owning."
  - **README must be rewritten** (current copy over-claims): drop "no accounts to buy" →
    state "requires owning Minecraft; no separate purchase per local seat," and walk back
    the multi-distro support claim (DECISION-1). README rewrite is a v1 deliverable.
  - Regenerate our OWN `accounts.json` (don't ship FlyingEwok's byte-identical file); drop
    `token.enc` entirely.
  - NOTE: personal-use framing addresses the *Minecraft-ownership* concern, NOT the
    *FlyingEwok code license* — redistributing their installer to others is still
    redistribution → DECISION-4 (license) remains a pre-distribution blocker.
- ❓DECISION-3: controller isolation — keep on this branch (it's core to v1 §3.4) but
  gated-off until validated, or split to its own branch. PENDING.
- ❓DECISION-4: LICENSE. Research done + independently verified (GitHub API). Findings:
  - **FlyingEwok/MinecraftSplitscreenSteamdeck = NO LICENSE → all-rights-reserved.**
    Verified: `license: null`, license endpoint HTTP 404. Our README says our installer was
    "originally forked from FlyingEwok," so the inherited installer code is legally
    all-rights-reserved — **we have no clear right to redistribute it as-is.** ← the blocker.
  - **ArnoldSmith86/minecraft-splitscreen = MIT** (verified). But FlyingEwok only "inspired
    by" it (not a fork), so our lineage runs through the *unlicensed* repo, not the MIT one.
  - **Dependencies impose nothing on our license** (PolyMC GPL-3, Temurin GPLv2+CE, Fabric
    Apache-2, Controlify LGPL-3): we DOWNLOAD unmodified binaries + INVOKE as separate
    processes = mere aggregation/use, no copyleft propagation. Caveat: don't copy their
    source into our repo; if we ever *vendor/mirror* binaries, ship their license texts.
  - **Paths to resolve (pick one+):** (A) ask FlyingEwok to add a license / grant permission;
    (B) clean-room the remaining FlyingEwok-derived installer code so we own it outright;
    (C) assess first how much FlyingEwok code actually remains (we rewrote a lot) → then B.
  - **Our own license once clear:** MIT (pragmatic — we link nothing) or GPL-3 (if we want
    forks to stay open). 
  - ⚠️ This is legal *interpretation*, not legal advice — for anything public, get a human eye.
  - **ASSESSMENT DONE (agent + spot-verified):** the installer is **substantially verbatim
    FlyingEwok** — ~10 files at 82–100% (utilities.sh byte-identical; instance_creation.sh
    96%; mod_management.sh ~2k lines ~96%; java/version/steam/lwjgl/main_workflow/desktop
    all 82–100%). `minecraftSplitscreen.sh` also has derived scaffolding (nestedPlasma,
    splitscreen-mode mapping). `token.enc` + `accounts.json` are byte-identical upstream
    artifacts (drop them regardless). Only the 9 runtime modules + mods.conf are clean.
  - **→ Clean-room (B) is now a LARGE job (re-authoring the installer, ~4k+ lines).
    REVISED PLAN: lead with A — ask FlyingEwok to add a license (cheap unlock vs big
    rewrite); B only as fallback. Drop token.enc + accounts.json now. No public release
    until resolved.** PARKED — will loop back (draft the FlyingEwok ask later).
- _(more will be added as we go)_
