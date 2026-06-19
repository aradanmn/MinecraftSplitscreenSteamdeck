# Archived Documents

These docs are **superseded** but kept for the reasoning trail behind decisions
made on `feat/gamescope-windowing`. They are not current implementation guidance —
see `GAMESCOPE-WINDOWING.md` and the latest `SESSION-*` / `DECISION-LOG-*` files in
the repo root for what actually shipped.

Archived 2026-06-19 during a docs decluttering pass.

| File | What it was | Why archived |
|------|-------------|--------------|
| `WINDOWING-SPEC.md` | "Definitive" windowing spec recommending `dex` / nested-Xwayland-in-kwin_wayland | Superseded — the shipped solution used nested KWin via autostart re-invocation (see SESSION-2026-06-17B.md), not this approach |
| `PLAN-WINDOWING-CONTROLLERS.md` | 3-round challenge/refine plan for windowing + controller isolation | Planning artifact; windowing since solved |
| `RESEARCH-GAMESCOPE-WINDOWING.md` | Background research on gamescope compositing architecture | Reference only; not active guidance |
| `windowing-analysis.md` | 4-round challenge/refine analysis (nested-gamescope exploration) | Explored approaches that were not used |

Two further docs were deleted outright (not archived) in the same pass, as they
described work that is complete or branches that are dead — recover from git history
if ever needed:
- `HANDOFF.md` — pre-windowing handoff for the abandoned `claude/elegant-bell-vdupw5` branch
- `IMPLEMENTATION_HANDOFF.md` — spec for the launcher rewrite that is now implemented in `modules/`
