# Runbook — HW-2 test-harness validation (Steam Deck)

**Purpose.** Validate the pre-HW-2 test-harness batch on real hardware and confirm the
"already-fixed" issues that need a live session. One docked session covers most of it.

**How to use.** Non-interactive commands can run over `ssh steamdeck`; the staged suite's
own prompts and the Game-Mode launch happen at the Deck. Check each `- [ ]`; record
PASS/FAIL. Logs land at `~/splitscreen-hwtest-<ts>.log`.

**What this run closes:** #111 (stage4), #83/#84 (stage3 re-confirm), #60 / #71 / #62(b)
(confirm/measure). #80/#103 already closed in CI — Part 1 is the belt-and-suspenders smoke.

---

## Part 0 — Deploy `main` to the Deck (do first)

```bash
ssh steamdeck
cd ~/MinecraftSplitscreenSteamdeck
git checkout main && git pull --ff-only
./deploy.sh
./deploy.sh --check      # must report fresh (exit 0)
```
- [ ] `--check` is clean (no drift). Deploy is what puts code where the launcher runs — a
  `git pull` alone is **not** a deploy.

---

## Part 1 — Orchestrator Deck smoke (#80/#103) · Desktop Mode · SAFE

```bash
bash tests/test_orchestrator.sh
```
- [ ] Prints `8/8 tests passed.`, exit 0. → **PASS / FAIL**
- [ ] **Your Konsole/SSH session survives** (the kill-scoping holds on a real session — this
  is the whole point of the Deck smoke). → **PASS / FAIL**

> Safety: fixtures are all > `kernel.pid_max`, every teardown is mocked, and a pid_max guard
> refuses to run if a fixture were ever reachable — so no group-kill can hit your session.
> (If it prints `FATAL: fixture PID … <= pid_max`, stop and tell Claude — the Deck's pid_max
> is unusually high; do **not** force it.)

---

## Part 2 — stage3 (docked hotplug) · Game Mode · docked · exactly ONE external pad

Launch the splitscreen session **through the Steam shortcut**, docked, with exactly one
external controller connected before launch. Then:
```bash
bash tests/hardware/run_all.sh stage3
```
Watch for / record:
- [ ] **D3.2 / D3.4–D3.8 geometry asserts GREEN** — re-confirms **#83** (geometry now
  measured against the correct 1280×720 nested root). → **PASS / FAIL**
- [ ] **D3.7 sticky-slot asserts GREEN** — re-confirms **#84**. ⚠️ **At the D3.7 unplug
  prompt, press `y`, NOT Enter** (the lone HW-1 blemish was this operator slip). → **PASS / FAIL**
- [ ] **#60 supervise-reap:** after a clean session exit, check the session-exit log for
  `[supervise_reap] own nested-session tree confirmed clean`:
  ```bash
  grep -i "supervise_reap" ~/.local/share/PolyMC/splitscreen-debug-latest.log 2>/dev/null \
    || grep -ri "supervise_reap" /tmp/splitscreen-debug-*.log 2>/dev/null | tail -3
  ```
  → seen? **YES / NO**
- Leaves instances running → go straight to Part 3.

---

## Part 3 — stage4 (isolation) · after stage3, instances live · validates #111 + measures #62

```bash
bash tests/hardware/run_all.sh stage4
```
- [ ] **I4.1 GREEN on every active slot** — new form reads the **java child's** `/dev/input`
  fds and asserts they're all within the slot's bwrap-bound node(s). The log prints, per
  slot, `java_pid` + bound nodes + observed fds. → **PASS / FAIL** (this closes **#111**)
- [ ] **#62(b) measurement:** confirm each slot's java process holds **only its own `jsN`**
  (no other slot's node). If so, isolation is now **kernel-enforced**, not app-layer — record
  the per-slot fd set from the log. → observation: __________
- [ ] I4.2 / I4.3 / I4.4 unchanged (still pass). → **PASS / FAIL**

---

## Part 4 — #71 burst-reflow re-test (optional) · docked

Repro the party scenario: connect **all 4 pads BEFORE launch**, then launch docked.
- [ ] Does **slot 4's window tile correctly**, or stay centered at Minecraft's 854×480?
  (The architecture now defers each spawn's reflow until *its own* window exists, which
  should prevent the old race.) → tiled? **YES / NO** (YES → close **#71**)

---

## Part 5 — Close-out

- [ ] stage3 geometry + D3.7 green → close **#83**, **#84**.
- [ ] stage4 I4.1 green → close **#111**; note the #62 isolation observation on #62.
- [ ] orchestrator smoke 8/8 + session survived → #80/#103 confirmed on hardware (already closed).
- [ ] supervise_reap line seen → close **#60**.
- [ ] slot 4 tiled in the burst test → close **#71** (or note if it reproduced).
- [ ] Record results in `docs/HW2-VALIDATION-YYYYMMDD.md` (mirror `docs/HW1-VALIDATION-2026-07-19.md`).

---

## Quick reference

| Thing | Value |
|-------|-------|
| Deploy | `./deploy.sh` then `./deploy.sh --check` (must be fresh) |
| Orchestrator smoke | `bash tests/test_orchestrator.sh` → 8/8, session survives |
| Single stage | `bash tests/hardware/run_all.sh stage3` \| `stage4` |
| Full suite | `bash tests/hardware/run_all.sh` (stage0→5) |
| Logs | `~/splitscreen-hwtest-<ts>.log` |
| stage3 needs | docked, Steam-shortcut launch, exactly 1 external pad pre-connected |
| stage4 needs | active instances (run after stage3) |
| Closes on green | #111 (stage4), #83/#84 (stage3), #60/#71 (checks), #62(b) measured |
