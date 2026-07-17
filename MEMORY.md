# MEMORY.md — Running Change History

A chronological log of significant changes to this project: **what** changed,
**why**, and the **decision** behind it. Newest entries at the top. Pairs with the
per-day `SESSION-*.md` (full narrative) and `DECISION-LOG-*.md` (decision detail)
files.

---

## 2026-07-17 — Architecture audit + placement law (docs + issues, no code)

**What:** Three-agent audit of all 27 scripts (~12k lines): full interaction map
(installer chain, runtime FIFO architecture, standalone tools), magic-number sweep,
duplication sweep. Produced `docs/AUDIT-ARCHITECTURE-2026-07-17.md` (mermaid block
diagrams + findings) and `docs/ARCHITECTURE.md` (the placement law: domain
ownership per module, globals decision ladder, sourcing rules, duplication budget
for standalone scripts). Filed #85–#91; deliberately did NOT duplicate #47 (token
×7) or #27.

**Why:** Maintainer question: duplication was "supposed to be stamped out already"
by the D1–D17 kill-list — why is it back? Audit's answer: it never fully left. The
consolidations built the right homes (runtime_context, fetch_url, the manifest,
mcss_query_displays), but (a) specific sites were never migrated (flock -w 5,
_reflow_layout's private probe, launcher_setup's fallback-less mem reads), (b) the
data was consolidated without the code (one manifest, four parsers), and (c) there
was no written rule telling new code where functions/globals GO — STYLE-GUIDE.md
covers naming/format only.

**Decision:** Yes to an architecture document (maintainer asked). ARCHITECTURE.md
is the living law, the audit doc is the point-in-time record. Key rules: MCSS_*
only in a constants root; "a constant's existence obligates its use" (naming a
value + leaving the literal elsewhere is worse than no constant); consumer-side
`:-fallback` re-embedding of literals is the drift pattern to reject; standalone
scripts may duplicate only with a `# PAIRED WITH` comment. Fix ordering in audit
§7: mechanical (#86) → correctness-adjacent (#85/#87) → mod-pipeline dedup
(#47+#88) → prototype-path deletion (#90) → structural merges (#89/#91), merges
BEFORE the #52 retrofit.

**Status:** docs + TODO/MEMORY on `claude/script-diagram-refactor-9f3qw6`; issues
live. No code changed — every fix goes through its issue per the normal flow.

---

## 2026-07-01 — Codebase review + v1.1 fix batch (all [CODE], NOT Deck-validated)

**What:** A full codebase + open-issue review, followed by a fix pass in the same
session: the #43 architectural root-cause (no authoritative environment/mode global,
closes #42's Desktop-Mode runaway at the source instead of just its symptom), the #40
`_set_mode` crash, #15's nested-session teardown (stopped `exec`-ing away the outside
supervisor so a bounded reap loop can out-wait systemd's respawn), and 14 smaller
audit-tracked issues (#16-27, #31, #32) spanning monitor heartbeats, reflow retry,
the controller_monitor snapshot-skew race, KWin PID-only matching, and several
smaller hygiene/robustness fixes. Added the project's first CI (shellcheck +
baseline-gated unit tests) and a research doc on how Steam/SDL/InputPlumber actually
handle controller-reconnect identity (feeds #38).

**Why:** The issue tracker had 23 open items and no CI; several (#42/#40 in
particular) were live, user-visible bugs on the current `main`. #43 was flagged in
its own issue as "the architectural root behind a recurring 'nothing told the code
what context it's in' failure mode" — worth fixing before patching more symptoms.

**Decision:** Fixed forward rather than redesigning — e.g. #15's fix keeps the
existing `_end_nested_session` kill-by-name approach but wraps it in a supervising
outer loop, rather than a rewrite. Full list + issue cross-references in TODO.md's
2026-07-01 entry. Left the RAW-CONTROLLER-BIND-PLAN.md rewrite untouched (still
flag-gated, still needs the in-sandbox SDL probe it names before flipping default) —
the research doc informs it but doesn't implement it.

**Status:** pushed to `claude/codebase-review-v1-1-120ktb`; awaiting Deck validation
per this project's standing rule (SPEC §3a/§3b) before anything here is "done."

---

## 2026-06-19 — Docs decluttering pass

**What:** Reduced root-level `.md` clutter (was 15 files, ~400KB).
- **Deleted** (recoverable from git history): `HANDOFF.md` (pre-windowing handoff for
  the abandoned `claude/elegant-bell-vdupw5` branch) and `IMPLEMENTATION_HANDOFF.md`
  (63KB spec for the launcher rewrite that is now implemented in `modules/`).
- **Archived to `docs/archive/`**: `WINDOWING-SPEC.md`, `PLAN-WINDOWING-CONTROLLERS.md`,
  `RESEARCH-GAMESCOPE-WINDOWING.md`, `windowing-analysis.md` — superseded windowing
  planning/research, kept for the reasoning trail with an explanatory
  `docs/archive/README.md`.

**Why:** The two deleted handoffs described complete or dead work and had zero
inbound references. The four archived docs were overlapping 2026-06-17 "challenge &
refine" explorations of the windowing problem that `SESSION-2026-06-17B.md` later
solved with a *different* approach (nested KWin via autostart, not the `dex` /
nested-Xwayland path some of these recommended) — superseded for current work but
valuable as decision history.

**Decision:** Archive rather than delete the planning cluster (browsable folder beats
git-archaeology for the "why"); delete only the two truly dead handoffs. README
references none of these, so no user-facing links broke. Updated the two internal
references to `PLAN-WINDOWING-CONTROLLERS.md` (in DECISION-LOG-2026-06-17.md and
GAMESCOPE-WINDOWING.md) to the new archive path. Left `SESSION-2026-06-16.md` (226KB
raw log) in place as history.

**Kept as authoritative:** README, MEMORY, GAMESCOPE-WINDOWING, and the
2026-06-17/2026-06-19 SESSION + DECISION-LOG files.

---

## 2026-06-19 — bwrap GPU regression fixed

**What:** In both `launchSlot` functions (`minecraftSplitscreen.sh` ~L171 and
`modules/launcher_script_generator.sh` ~L338), re-bound the GPU and supporting
paths into the bwrap sandbox after `--dev /dev`:
`/dev/dri`, `/dev/fuse`, `/dev/shm`, `/tmp/.X11-unix` (each existence-guarded).

**Why:** `--dev /dev` mounts a fresh empty devtmpfs over `/dev`, wiping the
`/dev/dri/*` GPU nodes that `--dev-bind / /` had provided. Qt's xcb platform
plugin (and LWJGL) need the GPU to initialize, so PolyMC was exiting silently.

**Decision / context:** A handoff prompt recommended **removing bwrap entirely**,
claiming a separate unfixable SingleApplication/abstract-socket bug. git history
proved otherwise: working commit `d5f060c` did `--dev /dev` **and re-bound
`/dev/dri` afterward**; Phase A (`38c4f99`) rebuilt `launchSlot` and dropped that
re-bind. The user's memory ("bwrap worked before the window-positioning test") was
correct. We fixed the regression instead of removing the sandbox.
- Controller isolation = `--bind /dev/null <other-pads>`, NOT `--unshare-net`.
- SingleApplication forwarding is the *intended* way one PolyMC primary launches
  all 4 JVMs — it only appeared broken because the GPU bug killed the primary.
- The per-slot `XDG_RUNTIME_DIR=/tmp/polymc-runtime-slotN` hack is a no-op for
  abstract sockets; left in place as harmless.
- Process note: delegation default is `llama3.1:8b` which cannot reliably call
  tools (fabricated a fake success here). Repoint delegation at `qwen2.5-coder:14b`.

**Commit:** `d348bf1` on `feat/gamescope-windowing`.
**Status:** pushed; awaiting Deck test (expect 4 windows in 2×2 grid).
**Refs:** SESSION-2026-06-19.md, DECISION-LOG-2026-06-19.md

---

## 2026-06-17 — Windowing solved via nested KWin; controller isolation plan

**What:** Established nested-KWin-inside-gamescope approach for window positioning;
documented SDL env configuration for controller isolation.

**Why / decisions (summary — see DECISION-LOG-2026-06-17.md for full detail):**
- xdotool geometry tested directly in gamescope first (no Xephyr dependency).
- gamescope ignores `ConfigureRequest`, so a nested WM (KWin) is required to
  actually reposition OS windows; the Splitscreen mod only controls the viewport.
- Controller isolation: `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1`,
  clear `SDL_GAMECONTROLLER_IGNORE_DEVICES`, `SDL_JOYSTICK_HIDAPI=0`; mask the
  Deck built-in `28de:11ff` event node with `--bind /dev/null` per sandbox.

**Refs:** SESSION-2026-06-16.md, SESSION-2026-06-17.md, SESSION-2026-06-17B.md,
DECISION-LOG-2026-06-17.md
