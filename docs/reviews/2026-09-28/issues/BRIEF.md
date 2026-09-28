# Issue-drafting brief (shared by all drafting agents)

Repo: /home/user/MinecraftSplitscreenSteamdeck (branch claude/codebase-review-report-3611su).
Source of truth: docs/CODE-REVIEW-2026-09-28.md (consolidated) and your module report under
docs/reviews/2026-09-28/<X>.md. Read both first, then re-open the code for each finding.

Your job: for each finding assigned to you, write ONE GitHub issue body file with a concrete,
tested SUGGESTED CODE FIX. Do NOT modify any tracked repo file. Work on copies in the
scratchpad when testing diffs (e.g. `cp -r modules $SCRATCH/wt/` or `git worktree add` is NOT
allowed — just copy files).

Output: one file per issue at the path given in your assignment: `<ID>.md`, e.g. `A1.md`.
Grouped Low/Info issues (if assigned) go to `<PREFIX>-lowinfo.md`.

File format (exact — the first lines are machine-parsed):
```
title: <severity emoji-free, <= 100 chars, starts with the finding ID in brackets, e.g. "[A1] Startup guard pkill -9 -f PolyMC SIGKILLs the launcher itself">
severity: critical|high|medium|low
security: yes|no
type: Bug|Task
related: <comma-separated existing issue numbers this touches, e.g. #134, #79 — or "none">
---
<markdown body>
```

Body sections, in this order:
1. `## Summary` — 2-4 sentences: what is wrong and why it matters. Cite `path:line`.
2. `## Evidence` — quote the offending code (fenced), and the reproduction if the review had one.
3. `## Failure scenario` — concrete.
4. `## Suggested fix` — a unified diff in a ```diff fenced block, generated against the CURRENT
   file content (use `diff -u original patched` on a scratch copy so line numbers and context are
   real). Keep it minimal: what the finding needs, nothing more. If the right fix needs a design
   decision, give the minimal safe diff AND a one-paragraph "fuller fix" note. Then a short
   explanation of why this fix is correct and what it deliberately does NOT change.
   REQUIREMENTS for every diff: (a) `bash -n` (or `python3 -m py_compile`) passes on the patched
   copy; (b) `git apply --check` of the diff succeeds from the repo root (run it against the
   pristine tree — it does not modify anything); (c) if a unit test suite covers the file
   (tests/test_<module>.sh), run it against the patched copy where feasible (point the suite at
   the patched module via a copied modules/ dir or by temporarily copying the patched file in a
   scratch clone: `cp -r /home/user/MinecraftSplitscreenSteamdeck $SCRATCH/clone-<ID>` then patch
   and run there) and report the result. State in the issue exactly which of (a)(b)(c) you did.
5. `## Tests` — the unit test to add or change (name, what it asserts, and the mutation that must
   turn it red per PRINCIPLES #4). Give the test code if it is short.
6. `## Hardware verification` — exact steps on a Steam Deck to confirm the fix through the real
   launch (PRINCIPLES #3): which mode (Game Mode docked / handheld / Desktop), how many pads,
   what to do, what to observe, which log line or command proves it (e.g. `grep ... ~/.local/share/
   PolyMC/splitscreen-debug-latest.log`), and which tests/hardware stage (stage0..stage6, see
   tests/hardware/run_all.sh) or RUNBOOK applies. If no hardware step is needed (pure installer
   logic, test-only), say "CI + unit test only" and why.
7. `## References` — the review IDs (yours and any merged duplicates), PRINCIPLES numbers, and
   related existing issues from this list when relevant:
   #14 (Bug B JVM D-state hang), #79 (docked→handheld leaves instance bound to external pad),
   #125 (docked launch no-controller message), #133 (closed: dock debounce, not_planned),
   #134 (handheld→docked is a no-op), #135 (teardown wedge + orphaned dock monitor),
   #138 (reverted dock debounce), #160 (preflight popups invisible in Game Mode),
   #196 (evsieve build-at-install broken on Debian 12), #198, #199.
   Do NOT open or comment on GitHub yourself.

Grouped Low/Info file (`<PREFIX>-lowinfo.md`): same header (severity: low, type: Task), body =
`## Summary` (one paragraph) + one `### <ID>. <title>` subsection per finding containing
`path:line`, a 1-2 sentence description, and a suggested fix (a short diff for one-liners, or a
sentence for larger ones), + `## Hardware verification` (one paragraph covering the group) +
`## References`. Every finding must have a checkbox line at the top: `- [ ] <ID> — <title>` so
the issue doubles as a checklist.

Keep each individual issue under ~250 lines. Be precise; a maintainer will apply these diffs.
