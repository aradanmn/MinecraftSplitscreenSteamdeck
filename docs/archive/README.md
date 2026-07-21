# Archived Documents

These docs are **superseded** but kept for the reasoning trail behind decisions
made on `feat/gamescope-windowing`. They are not current implementation guidance —
see the repo-root `TODO.md` (single source of outstanding work) and the dated logs
under `sessions/` for what actually shipped.

Archived 2026-06-19 during a docs decluttering pass; a second batch added 2026-06-23.

| File | What it was | Why archived |
|------|-------------|--------------|
| `WINDOWING-SPEC.md` | "Definitive" windowing spec recommending `dex` / nested-Xwayland-in-kwin_wayland | Superseded — the shipped solution used nested KWin via autostart re-invocation (see sessions/SESSION-2026-06-17B.md), not this approach |
| `PLAN-WINDOWING-CONTROLLERS.md` | 3-round challenge/refine plan for windowing + controller isolation | Planning artifact; windowing since solved |
| `RESEARCH-GAMESCOPE-WINDOWING.md` | Background research on gamescope compositing architecture | Reference only; not active guidance |
| `windowing-analysis.md` | 4-round challenge/refine analysis (nested-gamescope exploration) | Explored approaches that were not used |
| `INTEGRATION-PLAN.md` | Full branch→main landing analysis (install→run flow trace, runtime-deps table, merge mechanics) | Still-open action items folded into root `TODO.md`; kept here for the detailed analysis (added 2026-06-23) |
| `GAMESCOPE-WINDOWING.md` | Main windowing work log — architecture, what worked, commit history | Historical work log; current state lives in `TODO.md` (added 2026-06-23) |
| `DECISION-LOG-2026-06-17.md` | Decision record: xdotool-in-gamescope plan + controller-isolation SDL env fix | Decisions implemented; historical (added 2026-06-23) |
| `DECISION-LOG-2026-06-19.md` | Decision record: keep bwrap, restore GPU re-bind regression (commit d348bf1) | Decision implemented; historical (added 2026-06-23) |
| `GAMESCOPE_INVESTIGATION.md` | Feb-2026 Border Enforcer / static-mode gamescope memory-leak root-cause analysis | Superseded — the mod + Border Enforcer approach was abandoned for nested KWin (added 2026-06-23) |
| `GAMESCOPE_RESEARCH.md` | Feb-2026 research: "gamescope can't do splitscreen" | Same era/conclusion; superseded by the nested-KWin architecture (added 2026-06-23) |
| `research-controller-identity-raw.json` | 2.5k-line raw research dump behind the controller-identity / reconnect handoff (from the `docs/controller-identity-research` branch, 2026-07-03) | Superseded by `DESIGN-38-CONTROLLER-VIRTUALIZATION-V1_2.md` + `RESEARCH-CONTROLLER-VIRTUALIZATION-2026-07-17.md`; raw data kept for the reasoning trail (added 2026-07-20; branch then deleted) |

Two further docs were deleted outright (not archived) in the same pass, as they
described work that is complete or branches that are dead — recover from git history
if ever needed:
- `HANDOFF.md` — pre-windowing handoff for the abandoned `claude/elegant-bell-vdupw5` branch
- `IMPLEMENTATION_HANDOFF.md` — spec for the launcher rewrite that is now implemented in `modules/`
