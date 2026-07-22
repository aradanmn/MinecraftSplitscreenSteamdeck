# Derivation & License Audit — #33 (DECISION-4)

**Date:** 2026-07-22 · **Author:** Claude (opus-4.8), for Scott
**Question:** Can this project be publicly redistributed, given it originated as a
fork of [FlyingEwok/MinecraftSplitscreenSteamdeck](https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck)?

## TL;DR

**No — not freely, today.** FlyingEwok's repo carries **no license** (all-rights-reserved).
Despite ~44.5k lines of original work added here, **substantial FlyingEwok copyrightable
code still ships in ~10 files**. We have no grant to redistribute it. This is a real
blocker for a formal public/off-GitHub release; it does **not** block personal use or a
credited GitHub fork.

## Method

Per-file comparison of `main` against `upstream/main` (FlyingEwok), measuring how much of
FlyingEwok's original line content survives in each shared file. `git diff --numstat`
per file; "% survives" = `(FE_lines − lines_deleted) / FE_lines` (a **conservative
upper bound** — a modified line counts as deleted, so true verbatim retention is at or
below these figures, never above). Qualitative confirmation on the highest-retention files.

## Findings — the 17 shared files

| File | FE lines | ~% of FE expression still present | Status |
|---|---:|---:|---|
| `add-to-steam.py` | 141 | ~98% | **Essentially verbatim** |
| `uninstall-minecraft-splitscreen.sh` | 191 | ~93% | Heavily derived |
| `modules/desktop_launcher.sh` | 228 | ~86% | Heavily derived |
| `modules/launcher_setup.sh` | 102 | ~84% | Heavily derived |
| `install-minecraft-splitscreen.sh` | 272 | ~82% | Heavily derived |
| `modules/steam_integration.sh` | 257 | ~77% | Derived |
| `modules/main_workflow.sh` | 171 | ~76% | Derived |
| `modules/instance_creation.sh` | 801 | ~67% | Derived |
| `modules/mod_management.sh` | 2050 | ~65% (~1,335 lines) | Derived (largest volume) |
| `modules/lwjgl_management.sh` | 95 | ~64% | Derived |
| `modules/version_management.sh` | 402 | ~55% | Mixed |
| `modules/utilities.sh` | 60 | orig 60 lines retained + heavy additions | Derived core |
| `modules/java_management.sh` | 476 | ~36% | Mostly rewritten |
| `minecraftSplitscreen.sh` | 603 | ~12% | **Essentially rewritten (ours)** |

Original-to-this-project (not in FlyingEwok at all): the entire modular runtime
(`runtime_context.sh`, `controller_monitor.sh`, `controller_proxy.sh`, `watchdog.sh`,
`window_manager.sh`, `dock_detection.sh`, `evsieve_management.sh`, …), the whole `tests/`
suite, CI, and docs. That is genuinely ours.

**Conclusion:** The *architecture and runtime* are ours; the *installer/launcher plumbing*
(add-to-steam, install/uninstall, and several modules) remains a derivative work of
FlyingEwok's all-rights-reserved code.

## Mechanical cleanup done in this pass (path-independent, #33 sub-items)

- **`token.enc` removed** — FlyingEwok's committed encrypted token (their commit
  `17be33c`). Its runtime download path was already retired (BYOK, #120); nothing fetches
  it. Legacy installs keep their local copy.
- **`accounts.json` regenerated** — the four accounts are inert **offline** placeholders
  (`type: Offline`, `token: "0"`) — no real credentials. Regenerated the random
  `clientToken`s so the file is unambiguously ours; kept the offline UUIDs to preserve
  benchmark-world player-data continuity.
- **Attribution** — README already credits FlyingEwok as the installer's origin and states
  the honest interim posture ("not cleared for public redistribution … personal use for now").

## The decision (Scott's) — three ways to clear the blocker

**A. Ask FlyingEwok to add a permissive license (MIT).**
If they agree, every derived file becomes licensed and we can relicense the combined work
and ship publicly. Cleanest outcome, lowest effort for us. Risk: external dependency —
FlyingEwok's last commit was 2026-04-26, so a reply is plausible but not guaranteed, and it
may take weeks or never come.

**B. Clean-room rewrite the ~10 still-derived files.**
Removes the dependency permanently; fully ours. Real work, but bounded — the hard/creative
parts (architecture, runtime) are already ours; what remains is installer plumbing. Well
suited to an orchestrated file-by-file rewrite-from-behavior pass.

**C. Stay personal-use / credited GitHub fork; drop the off-GitHub public-release goal.**
Zero work — the current README posture already reflects this. Forking a public GitHub repo
is permitted by GitHub's ToS even absent an explicit license; the constraint is only on
redistributing outside GitHub or claiming a license we can't grant. Closes #33 as
won't-fix-for-distribution.

## Recommendation

**A now + adopt the honest interim posture (already in README), fall back to B if
FlyingEwok declines or goes silent.** Sending the license ask is a 2-minute action that can
fully resolve #33 for free; meanwhile the honest posture means #33 no longer *blocks* the
v1.2 roadmap — it becomes "awaiting reply," revisited only on their response or a set
timeout (~3–4 weeks → then B). Reserve the clean-room effort for when it's actually needed.
