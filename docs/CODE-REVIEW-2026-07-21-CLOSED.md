# Code Review 2026-07-21 — Closed, No Action

**Status:** Closed — zero defects identified.
**Baseline:** `40bfaef` (v1.2 mainline + HW-1 validation + #70 maxFps cap).
**Reviewers:** Copilot (initial report), Claude (code-grounded verification). Both concur.

A repo-root `CODE_REVIEW_REPORT.md` (added `c2aee02`, updated `a7d53ea`) was removed:
every finding was verified against the current code as **already-implemented,
by-design, or non-manifesting**. No correctness or security issue was found — the
report was entirely maintainability/style, and several items were factually behind
the code. Its line numbers had also drifted (they pointed at pre-#70 locations despite
claiming the `40bfaef` baseline).

## Disposition of each finding

| Finding | Disposition | Evidence |
|---------|-------------|----------|
| Broad `set +e` spans | Non-manifesting | Spans are cleanly paired with defensive per-op handling; **no early `return`** inside them, so no errexit leak. errexit is genuinely on in the runtime, so the trailing `set -e` matches intent. Save/restore would be cosmetic. |
| Legacy overrides / `MCSS_MAX_PLAYERS` 1..4 | By-design | 1–4 is a screen-quadrant invariant, not a latent bug. |
| `/proc/bus/input/devices` parser fragility | Already implemented | Parser is clean (`case` per prefix, `\x1f`-delimited, empty field-8 handled); edge cases already covered by `test_controller_monitor.sh` **T2.13** (field-8 uniq, real + empty) and **T2.17** (empty-uniq, no trailing space). A Python rewrite would add an unwanted runtime dep. |
| `controller_proxy.sh` "dark/unused" | By-design | Explicitly "dark until PR7 flips `MCSS_CONTROLLER_PROXY`" — a deliberate staged PR2 landing. The report's suggested fix (mark experimental) is already in-code; the updated report even praises it as good defensive design in its own Strengths section. |
| Hard-coded magic values | Already implemented | Already named `readonly` constants (`ORCHESTRATOR_FIFO_READ_TIMEOUT_S`, `INSTANCE_LIFECYCLE_POLL_INTERVAL_S`, …), several with env overrides. |
| System-integration fragility | By-design | The concrete part (preflight continues without `inotifywait`) is intentional graceful degradation — it polls instead. |
| Refactor suggestions A–G | Skip | A ↔ set +e (cosmetic); B ↔ constants (already named); C ↔ parser (tests exist); D ↔ proxy (already marked); E legacy consolidation (low payoff, regression risk on validated code); F Steam helper functions (readability only); G `options.txt` template (block is per-instance parameterized — extraction adds complexity for ~zero DRY gain). |

## Conclusion

No action taken. Future automated reviews should verify findings against the current
tree (read the cited code and tests) before filing — the majority here were already
addressed by the #45–#90 de-duplication work, #38 PR2/PR3, and #70.
