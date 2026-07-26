# Working in this repo

A Steam Deck splitscreen Minecraft launcher — ~29k lines of bash (`modules/*.sh`)
plus a Python `dex.sh` backend. Read these before writing code; they encode
decisions already paid for in bugs.

## Read first
- **`docs/PRINCIPLES.md`** — *why* / how we decide. Every principle was earned by a
  specific bug. Follow these on new code; cite the principle number in a PR when a
  choice might raise an eyebrow. Highest-leverage: **#1** (shared state goes through
  accessors — `_get_slot_field`, `slot_manager` verbs — never raw `jq`), and
  **#5** (fail open — detection failures degrade to "keep last-good", never escalate
  to teardown).
- **`docs/ARCHITECTURE.md`** — *where* code lives (module boundaries, one job each).
- **`docs/STYLE-GUIDE.md`** — *how* code looks, plus the §8 pre-commit checklist.

## Non-negotiables (the ones that bite)
- **Kill only PIDs you started** — no `pkill`/`killall`/name-matched kills
  (PRINCIPLES #7). A name-matched kill once group-killed a live session.
- **Validate on hardware AND through the real launch** before flipping a default or
  closing a feature (#3). Unit tests + a probe are necessary, never sufficient —
  they've passed while a real 4-up game failed.
- **Mutation-test** any test guarding real logic: break the code, confirm the test
  goes red (#4). A test that's green against broken code certifies nothing.
- **Ship big features flag-gated + dark-first**, flip the default last, in its own
  change, after real validation (#2). `MCSS_CONTROLLER_PROXY` is the template.
- **No unbounded/silent waits in operator scripts** — bound every wait; show busy
  (spinner→stderr) vs waiting-for-input (a caret) (#6).

## Reference
`docs/DESIGN-38-RECONNECT-WIRING.md` (seamless reconnect), `docs/SPEC.md`,
`docs/TODO.md`. Milestones tracked as GitHub issues/PRs; v1.2 shipped.
